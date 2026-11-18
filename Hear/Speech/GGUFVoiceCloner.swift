import Foundation
import llama
import AVFoundation

/// 声音克隆朗读：Qwen3-TTS 0.6B（GGUF，走 llama.cpp，和翻译模型共用同一套运行时）。
///
/// 为什么用 GGUF 而不是 MLX：
/// MLX 会把整个模型搬进内存（0.6B 4bit 也要约 3 GB），和翻译模型、Whisper 抢同一个
/// 内存额度，8 GB 机器上必然被系统杀掉。llama.cpp 用 mmap 按需映射，0.6B Q4 骨架
/// 361 MB + mmproj 402 MB，常驻内存小得多，三个模型可以共存。
enum VoiceCloneGGUFError: LocalizedError {
    case notLoaded
    case modelMissing(String)
    case loadFailed(String)
    case encodeFailed
    case generateFailed(String)
    case unsupportedLanguage

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "声音克隆模型尚未加载"
        case .modelMissing(let p): return "缺少声音克隆模型文件：\(p)"
        case .loadFailed(let p): return "声音克隆模型加载失败：\(p)"
        case .encodeFailed: return "参考音频编码失败"
        case .generateFailed(let p): return "声音克隆生成失败：\(p)"
        case .unsupportedLanguage: return "这种语言不支持声音克隆"
        }
    }
}

/// 声音克隆用的模型文件放在 Application Support/VoiceCloneGGUF 下
enum VoiceCloneGGUF {
    /// 骨架模型（backbone）：负责把文字变成语义 token
    static let backboneFile = "qwen3-tts-0.6b-q4_k_m.gguf"
    /// mmproj：包含语音 tokenizer 编码器和解码器，参考音频靠它编码
    static let mmprojFile = "mmproj-qwen3-tts-0.6b-q8_0.gguf"

    /// 支持的语言（和 Qwen3-TTS 一致）
    static let languageNames: [String: String] = [
        "zh": "chinese", "en": "english", "ja": "japanese", "ko": "korean",
        "de": "german", "fr": "french", "ru": "russian", "pt": "portuguese",
        "es": "spanish", "it": "italian",
    ]

    static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceCloneGGUF", isDirectory: true)
    }
    static var backboneURL: URL { base.appendingPathComponent(backboneFile) }
    static var mmprojURL: URL { base.appendingPathComponent(mmprojFile) }

    /// Qwen3-TTS 输出 24 kHz
    static let sampleRate = 24_000

    /// 下载地址（HF 上已转好的 0.6B GGUF：骨架 Q4_K_M + mmproj Q8_0）
    static let backboneRepo = "Shlomo426/Qwen3-TTS-12Hz-0.6B-Base-GGUF"
    static let backbonePath = "Qwen3-TTS-12Hz-0.6B-Base-Q4_K_M.gguf"
    static let mmprojRepo = "Shlomo426/Qwen3-TTS-12Hz-0.6B-Base-GGUF"
    static let mmprojPath = "mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf"

    /// 两部分都下载好了
    static var installed: Bool {
        FileManager.default.fileExists(atPath: backboneURL.path)
            && FileManager.default.fileExists(atPath: mmprojURL.path)
    }

    /// 把本地导入的两个 gguf 文件复制到位
    static func install(backbone: URL, mmproj: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try replace(backboneURL, with: backbone)
        try replace(mmprojURL, with: mmproj)
    }

    private static func replace(_ dst: URL, with src: URL) throws {
        let fm = FileManager.default
        if src.standardizedFileURL.path == dst.standardizedFileURL.path { return }
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: base)
    }

    /// 下载骨架模型和 mmproj（各约 360 MB / 400 MB）
    static func download(host: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        // 先下骨架模型
        if !fm.fileExists(atPath: backboneURL.path) {
            try await downloadFile(repo: backboneRepo, path: backbonePath,
                                   to: backboneURL, host: host, progress: progress, from: 0.0, to: 0.5)
        }
        // 再下 mmproj
        if !fm.fileExists(atPath: mmprojURL.path) {
            try await downloadFile(repo: mmprojRepo, path: mmprojPath,
                                   to: mmprojURL, host: host, progress: progress, from: 0.5, to: 1.0)
        }
    }

    /// 从 HF 下载单个文件（支持 hf-mirror 镜像）
    private static func downloadFile(repo: String, path: String, to dst: URL,
                                     host: String, progress: @escaping @Sendable (Double) -> Void,
                                     from p0: Double, to p1: Double) async throws {
        let base = host == "huggingface.co"
            ? "https://huggingface.co"
            : "https://\(host)"
        let url = URL(string: "\(base)/\(repo)/resolve/main/\(path)")!
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let http = response as? HTTPURLResponse
        guard let http, http.statusCode == 200 else {
            throw NSError(domain: "Hear", code: 20, userInfo: [NSLocalizedDescriptionKey:
                "下载失败（HTTP \(http?.statusCode ?? 0)）：\(path)"])
        }
        let total = Int(http.expectedContentLength)
        var out = Data()
        out.reserveCapacity(total > 0 ? total : 1 << 20)
        var got = 0
        for try await b in bytes {
            out.append(b)
            got += 1
            if total > 0 {
                let frac = Double(got) / Double(total)
                progress(p0 + frac * (p1 - p0))
            }
        }
        try out.write(to: dst)
        progress(p1)
    }

    /// 导入本地已下载的两个 gguf 文件（在一个文件夹里）
    static func importFiles(at folder: URL) throws {
        let fm = FileManager.default
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let ggufs = files.filter { $0.pathExtension.lowercased() == "gguf" }
        guard ggufs.count >= 2 else {
            throw NSError(domain: "Hear", code: 21, userInfo: [NSLocalizedDescriptionKey:
                "需要两个 .gguf 文件：骨架模型（\(backboneFile)）和 mmproj（\(mmprojFile)）"])
        }
        // 按文件名判断哪个是骨架、哪个是 mmproj
        var backbone: URL?
        var mmproj: URL?
        for f in ggufs {
            let n = f.lastPathComponent.lowercased()
            if n.contains("mmproj") { mmproj = mmproj ?? f }
            else if backbone == nil { backbone = f }
        }
        // 只认得出名字时，按大小兜底：mmproj 通常和骨架差不多大或更大
        if backbone == nil || mmproj == nil {
            let sorted = ggufs.sorted { (a, b) -> Bool in
                let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return sa < sb
            }
            if sorted.count == 2 {
                if backbone == nil { backbone = sorted[0] }
                if mmproj == nil { mmproj = sorted[1] }
            }
        }
        guard let b = backbone, let m = mmproj else {
            throw NSError(domain: "Hear", code: 22, userInfo: [NSLocalizedDescriptionKey:
                "分不清哪个是骨架模型、哪个是 mmproj。请确保文件名里有一个带 mmproj。"])
        }
        try install(backbone: b, mmproj: m)
    }
}

/// 用 llama.cpp 跑 Qwen3-TTS 的声音克隆。
/// 单独一个 actor：llama 的 context 不允许跨线程使用。
actor GGUFVoiceCloner {
    private var model: OpaquePointer?          // llama_model
    private var ctx: OpaquePointer?            // llama_context
    private var mctx: OpaquePointer?           // mtmd_context
    private var gen: OpaquePointer?            // mtmd_helper_gen_audio

    var isLoaded: Bool { gen != nil }
    /// 正在加载（模型文件较大，加载时要几秒）
    var isLoading: Bool { loading }
    private var loading = false

    /// 加载骨架模型 + mmproj
    func load() async throws {
        guard model == nil else { return }
        guard !loading else { return }
        loading = true
        defer { loading = false }

        guard VoiceCloneGGUF.installed else {
            throw VoiceCloneGGUFError.modelMissing("请在设置里下载或导入声音克隆模型")
        }

        // llama 的后端是全局的，由 LlamaBackend 统一初始化。
        // 这里绝不能调 llama_backend_free()：翻译模型还在用，释放了会把它的运行时一起关掉。
        LlamaBackend.ensureReady()

        // 骨架模型：和翻译模型一样全部放 GPU
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 999
        guard let m = llama_model_load_from_file(VoiceCloneGGUF.backboneURL.path, mp) else {
            throw VoiceCloneGGUFError.loadFailed("backbone")
        }
        model = m

        // 上下文：需要 embedding 模式才能把 hidden state 传给音频生成器
        var cp = llama_context_default_params()
        cp.embeddings = true
        cp.n_ctx = 2048
        cp.n_batch = 2048
        let threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            model = nil
            throw VoiceCloneGGUFError.loadFailed("context")
        }
        ctx = c

        // mmproj：语音 tokenizer 的编码器 + 解码器
        var mp2 = mtmd_context_params_default()
        mp2.use_gpu = true
        guard let mc = mtmd_init_from_file(VoiceCloneGGUF.mmprojURL.path, m, mp2) else {
            llama_free(c); ctx = nil
            llama_model_free(m); model = nil
            throw VoiceCloneGGUFError.loadFailed("mmproj")
        }
        mctx = mc

        let info = mtmd_gen_audio_get_info(mc)
        guard info.type == MTMD_GEN_AUDIO_TYPE_QWEN3TTS else {
            mtmd_free(mc); mctx = nil
            llama_free(c); ctx = nil
            llama_model_free(m); model = nil
            throw VoiceCloneGGUFError.loadFailed("这个 mmproj 不支持 Qwen3-TTS")
        }

        // 音频生成器
        guard let g = mtmd_helper_gen_audio_init(c, mc) else {
            mtmd_free(mc); mctx = nil
            llama_free(c); ctx = nil
            llama_model_free(m); model = nil
            throw VoiceCloneGGUFError.loadFailed("gen")
        }
        gen = g
        hearLog("声音克隆（GGUF）：加载完成")
    }

    func unload() {
        if let g = gen { mtmd_helper_gen_audio_free(g) }
        gen = nil
        if let mc = mctx { mtmd_free(mc) }
        mctx = nil
        if let c = ctx { llama_free(c) }
        ctx = nil
        if let m = model { llama_model_free(m) }
        model = nil
        // 后端不释放：翻译模型可能还在用（见 load() 里的说明）
    }

    /// 用参考音频克隆声音，生成 text 的朗读。
    /// reference：16 kHz 单声道 PCM（说话人的原声）；referenceText：说话人说的那句话（ICL 用）
    /// 返回 24 kHz 单声道 PCM
    func synthesize(text: String, language: String,
                   reference: [Float], referenceText: String) throws -> [Float] {
        guard let model, let ctx, let mctx, let gen else {
            throw VoiceCloneGGUFError.notLoaded
        }
        guard let lang = VoiceCloneGGUF.languageNames[language] else {
            throw VoiceCloneGGUFError.unsupportedLanguage
        }
        guard !text.isEmpty else { return [] }

        // 1) 参考音频编码成 bitmap（语音 tokenizer 编码）
        //    mtmd 的接口要文件路径，这里先把 16 kHz PCM 写成临时 wav
        let refPath = try writeTempWav(samples: reference, sampleRate: 16000)
        defer { try? FileManager.default.removeItem(atPath: refPath) }

        var opt = mtmd_helper_init_opt_default()
        let wrapper = mtmd_helper_bitmap_init_from_file(mctx, refPath, false, opt)
        guard let bitmap = wrapper.bitmap else {
            throw VoiceCloneGGUFError.encodeFailed
        }
        defer { mtmd_bitmap_free(bitmap) }

        // 2) 准备输入
        //    C 结构体里的字符串是 const char*，Swift 侧要用 withCString 包起来
        var inp = mtmd_helper_gen_audio_inp_default()
        inp.stream = false
        inp.seq_id = 0
        inp.speaker_ref = bitmap
        inp.top_k = 20
        inp.top_p = 0.6
        inp.temp = -1            // 用模型默认值
        inp.seed = UInt32.max
        // 直接要裸 F32 PCM（不用 WAV，省一层解析）
        inp.out_type = MTMD_HELPER_GEN_AUDIO_OUTTYPE_PCM

        let rc = text.withCString { textPtr in
            lang.withCString { langPtr in
                if referenceText.isEmpty {
                    inp.prompt = textPtr
                    inp.prompt_len = text.utf8.count
                    inp.speaker_ref_text = nil
                    inp.lang = langPtr
                    return mtmd_helper_gen_audio_set_input(gen, &inp)
                }
                return referenceText.withCString { refPtr in
                    inp.prompt = textPtr
                    inp.prompt_len = text.utf8.count
                    inp.speaker_ref_text = refPtr
                    inp.lang = langPtr
                    return mtmd_helper_gen_audio_set_input(gen, &inp)
                }
            }
        }
        guard rc == 0 else {
            throw VoiceCloneGGUFError.generateFailed("set_input 返回 \(rc)")
        }

        // 3) 处理提示词（把文字喂进骨架模型）
        let batch = Int32(llama_n_batch(ctx))
        while true {
            let r = mtmd_helper_gen_audio_step_prompt(gen, batch)
            if r < 0 { throw VoiceCloneGGUFError.generateFailed("step_prompt") }
            if r == 0 { break }
        }

        // 4) 逐帧生成
        let maxFrames = mtmd_helper_gen_audio_max_frames(gen)
        var nFrames = 0
        var stop = false
        var sampled = llama_token(-1)
        guard let hStateRaw = llama_get_embeddings_ith(ctx, -1) else {
            throw VoiceCloneGGUFError.generateFailed("拿不到 embedding")
        }
        var hState: UnsafePointer<Float> = UnsafePointer(hStateRaw)

        while !stop && nFrames < maxFrames {
            var hNext: UnsafePointer<Float>?
            let rc2 = mtmd_helper_gen_audio_step_gen(gen, sampled, hState, &hNext, &stop)
            guard rc2 == 0 else {
                throw VoiceCloneGGUFError.generateFailed("step_gen")
            }
            guard let h = hNext else { break }
            nFrames += 1
            hState = h
            // 从 logits 采样下一个语义 token
            sampled = sampleToken(ctx, model)
        }

        // 5) 取音频
        var sampleRate: Int32 = 0
        var data: UnsafePointer<CChar>?
        var dataLen: Int = 0
        var nSamples: Int64 = 0
        let rc3 = mtmd_helper_gen_audio_get_output(gen, &sampleRate, &data, &dataLen, &nSamples)
        guard rc3 == 0, let data, nSamples > 0 else {
            throw VoiceCloneGGUFError.generateFailed("get_output")
        }
        // 裸 PCM：字节数 = 样本数 × 4（F32）
        let pcm = Self.pcmToFloat32(data: data, byteCount: dataLen)
        let t0 = Date()
        let secs = Double(pcm.count) / Double(max(Int(sampleRate), 1))
        hearLog("声音克隆（GGUF）：生成 \(String(format: "%.1f", secs)) 秒声音，用时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        return pcm
    }

    /// 从 logits 里采样一个 token（贪心，最稳）
    private func sampleToken(_ ctx: OpaquePointer, _ model: OpaquePointer) -> llama_token {
        guard let vocab = llama_model_get_vocab(model) else { return -1 }
        let n = Int(llama_vocab_n_tokens(vocab))
        guard n > 0 else { return -1 }
        var best = llama_token(0)
        var bestLogit = -Float.greatestFiniteMagnitude
        guard let logitsPtr = llama_get_logits_ith(ctx, -1) else { return -1 }
        let logits = UnsafePointer(logitsPtr)
        for i in 0..<n {
            let l = logits[i]
            if l > bestLogit { bestLogit = l; best = llama_token(i) }
        }
        return best
    }

    /// 把 16 kHz 单声道 PCM 写成临时 wav（mtmd 的编码接口要文件）
    private func writeTempWav(samples: [Float], sampleRate: Int) throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("hear-ref-\(UUID().uuidString).wav")
        var data = Data()
        let nSamples = UInt32(samples.count)
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign = UInt16(2)
        let bits = UInt16(16)
        func u32(_ v: UInt32) -> Data { var x = v.littleEndian; return withUnsafeBytes(of: &x) { Data($0) } }
        func u16(_ v: UInt16) -> Data { var x = v.littleEndian; return withUnsafeBytes(of: &x) { Data($0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(u32(UInt32(36 + samples.count * 2)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(u32(16))
        data.append(u16(1))                       // PCM
        data.append(u16(1))                       // 单声道
        data.append(u32(UInt32(sampleRate)))
        data.append(u32(byteRate))
        data.append(u16(blockAlign))
        data.append(u16(bits))
        data.append(contentsOf: Array("data".utf8))
        data.append(u32(nSamples * 2))
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            var v = Int16(clamped * 32767)
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// 裸 PCM（F32）转 Swift 数组
    private static func pcmToFloat32(data: UnsafePointer<CChar>, byteCount: Int) -> [Float] {
        let floats = UnsafeRawPointer(data).assumingMemoryBound(to: Float.self)
        let count = byteCount / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: floats, count: count))
    }
}
