import Foundation
import llama

enum TranslatorError: LocalizedError {
    case notLoaded, loadFailed(String), decodeFailed(stage: String, status: Int32? = nil), tooLong
    var errorDescription: String? {
        switch self {
        case .notLoaded: return "翻译模型尚未加载"
        case .loadFailed(let p): return "无法加载翻译模型：\(p)"
        case .decodeFailed: return "本地模型未能完成这句"
        case .tooLong: return "句子太长"
        }
    }
}

/// 线程安全的“停止”标记：翻译进行中也能从外面让它马上停下
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// 线程安全的计数器：实时预览翻译的“轮次”，换轮次后旧的预览翻译马上停下
final class EpochCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0
    func bump() { lock.lock(); v += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return v }
}

/// Changes synchronously on UIKit notifications, even while llama.cpp is decoding.
private final class TranslationGPUAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    private var generation = 0

    func setAllowed(_ value: Bool) {
        lock.withLock {
            guard value != allowed else { return }
            allowed = value
            generation += 1
        }
    }

    var epoch: Int? { lock.withLock { allowed ? generation : nil } }
}

/// Run Hy-MT2 with Metal in the foreground and with CPU-only inference in the background.
actor LlamaTranslator {
    private enum Backend: String { case cpu = "CPU", metal = "GPU" }
    private struct GPUUnavailable: Error {}
    private let cancelEpoch = EpochCounter()
    private let previewEpoch = EpochCounter()
    private let gpuAccess = TranslationGPUAccess()

    nonisolated func setGPUAllowed(_ allowed: Bool) { gpuAccess.setAllowed(allowed) }

    /// 立刻停止正在进行的翻译（不用等 actor 空闲；使用单调代数避免后续排队任务误清除取消信号）
    nonisolated func cancelCurrent() { cancelEpoch.bump() }

    /// 只停止实时预览的翻译（整句翻译不受影响），让整句翻译马上开始
    nonisolated func cancelPreview() { previewEpoch.bump() }
    nonisolated var currentPreviewEpoch: Int { previewEpoch.value }

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var backend: Backend?
    private var failedGPUEpoch: Int?
    // 句子级实时翻译不需要 4K 上下文。2K 上下文、256 批处理
    // 能明显降低 KV cache 和临时 batch 的内存峰值，仍足够容纳
    // 两段上下文、术语表和最多 512 个输出 token。
    private let nCtx: UInt32 = 2048
    private var loadedPath: String?

    private static let backendOnce: Void = { LlamaBackend.ensureReady() }()

    var isLoaded: Bool { ctx != nil }

    func load(path: String) throws {
        _ = Self.backendOnce
        if loadedPath != path { unload() }
        try withBackend(path: path) { _ in }
        loadedPath = path
    }

    private func withBackend<T>(path: String, _ run: (Int?) throws -> T) throws -> T {
        try Task.checkCancellation()
        if let epoch = gpuAccess.epoch, epoch != failedGPUEpoch {
            do {
                try prepare(path: path, backend: .metal, gpuEpoch: epoch)
                return try run(epoch)
            } catch {
                try Task.checkCancellation()
                switch error {
                case is GPUUnavailable:
                    hearLog("本地翻译：切换到后台，改用 CPU 继续")
                case let failure as TranslatorError:
                    switch failure {
                    case .loadFailed, .decodeFailed:
                        hearLog("本地翻译：GPU 执行失败，改用 CPU 重试：\(failure)", .info)
                    default:
                        throw error
                    }
                default:
                    throw error
                }
                failedGPUEpoch = epoch
            }
        }
        try prepare(path: path, backend: .cpu, gpuEpoch: nil)
        return try run(nil)
    }

    private func checkGPU(_ epoch: Int?) throws {
        if let epoch, gpuAccess.epoch != epoch { throw GPUUnavailable() }
    }

    private func prepare(path: String, backend: Backend, gpuEpoch: Int?) throws {
        try Task.checkCancellation()
        try checkGPU(gpuEpoch)
        if self.backend == backend, ctx != nil { return }
        // Retain only one copy of the model and its context across mode changes.
        releaseModel()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = backend == .metal ? 999 : 0
        let loaded: OpaquePointer?
        if backend == .metal {
            loaded = llama_model_load_from_file(path, mp)
        } else {
            // A list containing only the terminator means no offload devices.
            var noDevices: ggml_backend_dev_t? = nil
            loaded = withUnsafeMutablePointer(to: &noDevices) { devices in
                mp.devices = devices
                return llama_model_load_from_file(path, mp)
            }
        }
        guard let m = loaded else {
            throw TranslatorError.loadFailed((path as NSString).lastPathComponent)
        }

        var cp = llama_context_default_params()
        cp.n_ctx = nCtx
        cp.n_batch = 256
        if backend == .cpu {
            cp.offload_kqv = false
            cp.op_offload = false
            cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED
        }
        let limit = backend == .cpu ? 3 : 6
        let threads = Int32(max(2, min(limit, ProcessInfo.processInfo.activeProcessorCount - 1)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        do {
            try Task.checkCancellation()
            try checkGPU(gpuEpoch)
        } catch {
            llama_model_free(m)
            throw error
        }
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw TranslatorError.loadFailed("context")
        }

        // Hy-MT2-1.8B/7B 官方推荐采样参数：repeat_penalty 1.05, top_k 20, top_p 0.6, temperature 0.7
        let v = llama_model_get_vocab(m)
        let s = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(s, llama_sampler_init_penalties(llama_vocab_n_tokens(v), 64, 1.05, 0.0, 0.0))
        llama_sampler_chain_add(s, llama_sampler_init_top_k(20))
        llama_sampler_chain_add(s, llama_sampler_init_top_p(0.6, 1))
        llama_sampler_chain_add(s, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(s, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))

        model = m
        ctx = c
        vocab = v
        sampler = s
        self.backend = backend
        hearLog("本地翻译：已启用 \(backend.rawValue)")
    }

    func unload() {
        releaseModel()
        loadedPath = nil
        failedGPUEpoch = nil
    }

    private func releaseModel() {
        if let sampler { llama_sampler_free(sampler) }
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        sampler = nil; ctx = nil; model = nil; vocab = nil
        backend = nil
    }

    deinit {
        if let sampler { llama_sampler_free(sampler) }
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
    }

    /// 翻译。onUpdate 会在生成过程中收到“到目前为止的译文”。
    func translate(prompt userPrompt: String,
                   maxNewTokens: Int = 512,
                   previewEpoch epoch: Int? = nil,
                   onUpdate: @escaping @Sendable (String) -> Void) throws -> String {
        try Task.checkCancellation()
        if let epoch, epoch != previewEpoch.value { throw CancellationError() }
        guard let path = loadedPath else { throw TranslatorError.notLoaded }
        let myCancelEpoch = cancelEpoch.value
        var shown = ""
        return try withBackend(path: path) { gpuEpoch in
            try self.decode(userPrompt, maxNewTokens: maxNewTokens, previewEpoch: epoch,
                            cancelEpoch: myCancelEpoch, gpuEpoch: gpuEpoch) { text in
                // If the CPU retries a sentence, keep the readable draft until it catches up.
                guard text.count >= shown.count, text != shown else { return }
                shown = text
                onUpdate(text)
            }
        }
    }

    /// 增量 UTF-8 解码：只保留尾部 1~3 字节合法的未完多字节序列，其余立即容错解码，
    /// 避免单个异常字节 token 导致整句后续译文永久卡死在 pending 里被丢弃。
    private static func splitValidUTF8Prefix(_ bytes: [UInt8]) -> (String, [UInt8]) {
        guard !bytes.isEmpty else { return ("", []) }
        let count = bytes.count
        var tail = 0
        // 最多回看最后 3 个字节，检查是否为尚未收齐的合法 UTF-8 多字节序列前导
        let maxCheck = min(3, count)
        for len in 1...maxCheck {
            let b = bytes[count - len]
            if b & 0x80 == 0 {
                break // ASCII 字节，末尾完整
            }
            if (b & 0xC0) == 0x80 {
                continue // 续字节，继续往前找前导字节
            }
            let expected: Int
            if (b & 0xE0) == 0xC0 { expected = 2 }
            else if (b & 0xF0) == 0xE0 { expected = 3 }
            else if (b & 0xF8) == 0xF0 { expected = 4 }
            else { expected = 0 }
            if expected > len {
                tail = len
            }
            break
        }
        let splitAt = count - tail
        if splitAt == 0 { return ("", bytes) }
        let decoded = String(decoding: bytes[0..<splitAt], as: UTF8.self)
        let remainder = tail > 0 ? Array(bytes[splitAt..<count]) : []
        return (decoded, remainder)
    }

    private func decode(_ userPrompt: String, maxNewTokens: Int, previewEpoch epoch: Int?,
                        cancelEpoch myCancelEpoch: Int, gpuEpoch: Int?,
                        onUpdate: (String) -> Void) throws -> String {
        guard let ctx, let vocab, let sampler else { throw TranslatorError.notLoaded }
        func checkWork() throws {
            try Task.checkCancellation()
            if cancelEpoch.value != myCancelEpoch { throw CancellationError() }
            if let epoch, epoch != previewEpoch.value { throw CancellationError() }
            try checkGPU(gpuEpoch)
        }
        let prompt = applyChatTemplate(userPrompt)
        let tokens = tokenize(prompt)
        guard !tokens.isEmpty else { throw TranslatorError.decodeFailed(stage: "tokenize") }
        if tokens.count + maxNewTokens > Int(nCtx) { throw TranslatorError.tooLong }

        try checkWork()
        llama_memory_clear(llama_get_memory(ctx), true)
        llama_sampler_reset(sampler)

        // 用新的扩展批接口（llama_decode/llama_batch_get_one 已弃用）
        guard let batch = llama_batch_ext_init(ctx) else { throw TranslatorError.decodeFailed(stage: "batch") }
        defer { llama_batch_ext_free(batch) }

        // 处理提示词：分批喂进去，最后一个 token 标记为要输出 logits
        // （不标记的话不会产生 logits，采样会读到无效数据）
        let batchSize = Int32(llama_n_batch(ctx))
        var pos = llama_pos(0)
        var i = 0
        while i < tokens.count {
            let n = Int32(min(Int(batchSize), tokens.count - i))
            llama_batch_ext_clear(batch)
            // 注意：llama_batch_ext_add_token 返回 int32_t（Swift 里是 Int32）
            var lastIdx = Int32(-1)
            for k in 0..<Int(n) {
                let idx = llama_batch_ext_add_token(batch, 0, tokens[i + k])
                if idx < 0 { throw TranslatorError.decodeFailed(stage: "prompt token") }
                var p = pos + llama_pos(k)
                if !llama_batch_ext_set_pos(batch, idx, &p) {
                    throw TranslatorError.decodeFailed(stage: "prompt position")
                }
                lastIdx = idx
            }
            // 只有最后一批的最后一个 token 要 logits
            if i + Int(n) >= tokens.count {
                llama_batch_ext_set_output_logits(batch, lastIdx, true)
            }
            try checkWork()
            let rc = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)
            try checkWork()
            guard rc == 0 else { throw TranslatorError.decodeFailed(stage: "prompt", status: rc) }
            pos += n
            i += Int(n)
        }

        var output = ""
        var pending: [UInt8] = []
        for index in 0..<maxNewTokens {
            try checkWork()
            let tok = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }

            pending += piece(tok)
            let (chunk, rest) = Self.splitValidUTF8Prefix(pending)
            if !chunk.isEmpty {
                output += chunk
                pending = rest
                onUpdate(Self.clean(output))
            }
            if index + 1 == maxNewTokens { break }

            // 把刚采样出来的 token 喂回去，继续生成下一个
            llama_batch_ext_clear(batch)
            let idx = llama_batch_ext_add_token(batch, 0, tok)
            if idx < 0 { throw TranslatorError.decodeFailed(stage: "output token") }
            var p = pos
            if !llama_batch_ext_set_pos(batch, idx, &p) {
                throw TranslatorError.decodeFailed(stage: "output position")
            }
            // 每生成一个 token 都要它的 logits，才能继续采样下一个
            llama_batch_ext_set_output_logits(batch, idx, true)
            try checkWork()
            let rc = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)
            try checkWork()
            guard rc == 0 else { throw TranslatorError.decodeFailed(stage: "output", status: rc) }
            pos += 1
        }
        if !pending.isEmpty {
            output += String(decoding: pending, as: UTF8.self)
            pending.removeAll()
        }
        try checkWork()
        return Self.clean(output)
    }

    // MARK: - helpers

    private func applyChatTemplate(_ user: String) -> String {
        guard let model, let tmpl = llama_model_chat_template(model, nil) else { return user }
        let role = strdup("user")!
        let content = strdup(user)!
        defer { free(role); free(content) }
        var msg = llama_chat_message(role: UnsafePointer(role), content: UnsafePointer(content))

        var buf = [CChar](repeating: 0, count: user.utf8.count * 2 + 1024)
        var n = llama_chat_apply_template(tmpl, &msg, 1, true, &buf, Int32(buf.count))
        if n > Int32(buf.count) {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(tmpl, &msg, 1, true, &buf, Int32(buf.count))
        }
        guard n > 0 else { return user }   // 模板不认识时退回原始提示词
        let bytes = buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func tokenize(_ text: String) -> [llama_token] {
        guard let vocab else { return [] }
        let len = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(len) + 16)
        var n = llama_tokenize(vocab, text, len, &tokens, Int32(tokens.count), true, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, len, &tokens, Int32(tokens.count), true, true)
        }
        var result = Array(tokens.prefix(Int(max(n, 0))))
        // 模板自带 BOS 时避免重复
        let bos = llama_vocab_bos(vocab)
        if result.count >= 2, result[0] == bos, result[1] == bos { result.removeFirst() }
        return result
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        guard let vocab else { return [] }
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        return buf.prefix(Int(max(n, 0))).map { UInt8(bitPattern: $0) }
    }

    private static func clean(_ s: String) -> String {
        var t = s
        if let r = t.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) {
            t.removeSubrange(r)
        }
        if let r = t.range(of: "<think>") { t = String(t[..<r.lowerBound]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
