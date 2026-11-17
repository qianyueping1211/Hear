import Foundation
import llama

enum TranslatorError: LocalizedError {
    case notLoaded, loadFailed(String), decodeFailed, tooLong
    var errorDescription: String? {
        switch self {
        case .notLoaded: return "翻译模型尚未加载"
        case .loadFailed(let p): return "无法加载翻译模型：\(p)"
        case .decodeFailed: return "翻译推理失败"
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

/// 用 llama.cpp（Metal GPU）在本机运行 Hy-MT2 GGUF 翻译模型
actor LlamaTranslator {
    private let stopFlag = CancelFlag()

    /// 立刻停止正在进行的翻译（不用等 actor 空闲）
    nonisolated func cancelCurrent() { stopFlag.set() }

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private let nCtx: UInt32 = 4096
    private(set) var loadedPath: String?

    private static let backendOnce: Void = { llama_backend_init() }()

    var isLoaded: Bool { ctx != nil }

    func load(path: String) throws {
        _ = Self.backendOnce
        if loadedPath == path, ctx != nil { return }
        unload()

        var mp = llama_model_default_params()
        mp.n_gpu_layers = 999               // 全部放到 GPU
        guard let m = llama_model_load_from_file(path, mp) else {
            throw TranslatorError.loadFailed((path as NSString).lastPathComponent)
        }

        var cp = llama_context_default_params()
        cp.n_ctx = nCtx
        cp.n_batch = nCtx
        let threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw TranslatorError.loadFailed("context")
        }

        // Hy-MT 官方推荐采样参数：top_k 20, top_p 0.6, temperature 0.7
        let s = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(s, llama_sampler_init_top_k(20))
        llama_sampler_chain_add(s, llama_sampler_init_top_p(0.6, 1))
        llama_sampler_chain_add(s, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(s, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))

        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        sampler = s
        loadedPath = path
    }

    func unload() {
        if let sampler { llama_sampler_free(sampler) }
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        sampler = nil; ctx = nil; model = nil; vocab = nil; loadedPath = nil
    }

    deinit {
        if let sampler { llama_sampler_free(sampler) }
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
    }

    /// 翻译。onUpdate 会在生成过程中收到“到目前为止的译文”。
    func translate(prompt userPrompt: String,
                   maxNewTokens: Int = 512,
                   onUpdate: @escaping @Sendable (String) -> Void) throws -> String {
        guard let ctx, let vocab, let sampler else { throw TranslatorError.notLoaded }
        stopFlag.reset()

        let prompt = applyChatTemplate(userPrompt)
        var tokens = tokenize(prompt)
        if tokens.count + maxNewTokens > Int(nCtx) { throw TranslatorError.tooLong }

        llama_memory_clear(llama_get_memory(ctx), true)
        llama_sampler_reset(sampler)

        let rc = tokens.withUnsafeMutableBufferPointer { buf in
            llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
        }
        guard rc == 0 else { throw TranslatorError.decodeFailed }

        var output = ""
        var pending: [UInt8] = []

        for _ in 0..<maxNewTokens {
            if Task.isCancelled || stopFlag.isSet { break }
            var tok = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }

            pending += piece(tok)
            if let s = String(data: Data(pending), encoding: .utf8) {
                output += s
                pending.removeAll()
                onUpdate(Self.clean(output))
            }

            let r = withUnsafeMutablePointer(to: &tok) { p in
                llama_decode(ctx, llama_batch_get_one(p, 1))
            }
            if r != 0 { break }
        }
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
