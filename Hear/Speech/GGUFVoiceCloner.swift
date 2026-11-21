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

    /// 两个 gguf 放在磁盘上的总大小（MB）。
    /// 放 GPU 时 Metal 里还要再存一份，所以实际占用的内存比这个数字大得多。
    static var totalMB: Int {
        let fm = FileManager.default
        var total = 0
        for url in [backboneURL, mmprojURL] {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let bytes = attrs[.size] as? Int {
                total += bytes
            }
        }
        return total / 1_048_576
    }

    /// 两部分都下载好了
    static var installed: Bool {
        FileManager.default.fileExists(atPath: backboneURL.path)
            && FileManager.default.fileExists(atPath: mmprojURL.path)
    }

    /// 把本地导入的两个 gguf 文件复制到位
    static func install(backbone: URL, mmproj: URL) throws {
        try ModelManager.checkGGUF(backbone)
        try ModelManager.checkGGUF(mmproj)
        let files = FileManager.default
        let temporary = base.deletingLastPathComponent().appendingPathComponent(".qwen-\(UUID().uuidString)")
        try files.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: temporary) }
        try files.copyItem(at: backbone, to: temporary.appendingPathComponent(backboneFile))
        try files.copyItem(at: mmproj, to: temporary.appendingPathComponent(mmprojFile))
        try ModelManager.installModelFile(temporary, at: base)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: base)
    }

    /// 下载骨架模型和 mmproj（各约 360 MB / 400 MB）
    static func download(host: String, force: Bool = false,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        if installed && !force { return }
        let files = FileManager.default
        let temporary = base.deletingLastPathComponent().appendingPathComponent(".qwen-\(UUID().uuidString)")
        try files.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: temporary) }
        let backbone = temporary.appendingPathComponent(backboneFile)
        let projector = temporary.appendingPathComponent(mmprojFile)
        try await downloadFile(repo: backboneRepo, path: backbonePath, to: backbone,
                               host: host, progress: progress, from: 0.0, to: 0.5)
        try await downloadFile(repo: mmprojRepo, path: mmprojPath, to: projector,
                               host: host, progress: progress, from: 0.5, to: 1.0)
        try Task.checkCancellation()
        try ModelManager.checkGGUF(backbone)
        try ModelManager.checkGGUF(projector)
        try ModelManager.installModelFile(temporary, at: base)
    }

    /// 从 HF 下载单个文件（支持 hf-mirror 镜像）
    /// 用 FileDownloader（下载任务，不会因为传输慢而超时）
    private static func downloadFile(repo: String, path: String, to dst: URL,
                                     host: String, progress: @escaping @Sendable (Double) -> Void,
                                     from p0: Double, to p1: Double) async throws {
        let base = host == "huggingface.co"
            ? "https://huggingface.co"
            : "https://\(host)"
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let url = URL(string: "\(base)/\(repo)/resolve/main/\(encoded)")!
        // 进度要合并成整段（骨架占前一半，mmproj 占后一半）
        try await FileDownloader().download(url, to: dst) { frac in
            progress(p0 + frac * (p1 - p0))
        }
    }

    /// 导入本地已下载好的模型文件。
    /// 选一个文件夹就行：里面直接放两个 gguf，或者每个模型各有自己的子文件夹，都认。
    /// （递归往下找，最顶层选对就行）
    static func importFolder(at folder: URL) throws {
        let fm = FileManager.default
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }

        // 递归找所有 gguf（最多往下找 3 层，够用了）
        var ggufs: [URL] = []
        func scan(_ dir: URL, depth: Int) {
            guard depth < 4 else { return }
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for it in items {
                let isDir = (try? it.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    scan(it, depth: depth + 1)
                } else if it.pathExtension.lowercased() == "gguf" {
                    ggufs.append(it)
                }
            }
        }
        scan(folder, depth: 0)

        // 旧的 MLX 版本用的编解码器（GGUF 版用不到），跳过
        ggufs = ggufs.filter { f in
            let n = f.lastPathComponent.lowercased()
            return !n.contains("tokenizer") && !n.contains("codec")
        }
        guard !ggufs.isEmpty else {
            throw NSError(domain: "Hear", code: 21, userInfo: [NSLocalizedDescriptionKey:
                "这个文件夹里没找到 .gguf 文件。需要 Qwen3-TTS-12Hz-0.6B-Base-Q4_K_M.gguf 和 mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf。"])
        }

        // 按文件名分：带 mmproj 的是 mmproj，其余是骨架
        var backbone: URL?
        var mmproj: URL?
        for f in ggufs {
            let n = f.lastPathComponent.lowercased()
            if n.contains("mmproj") { mmproj = mmproj ?? f }
            else if backbone == nil { backbone = f }
        }
        // 只找到一个、或者分不出来时，按大小兜底：mmproj 通常不比骨架小
        if backbone == nil || mmproj == nil {
            let sorted = ggufs.sorted { a, b in
                let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return sa < sb
            }
            if sorted.count >= 2 {
                if backbone == nil { backbone = sorted[0] }
                if mmproj == nil { mmproj = sorted[1] }
            } else if backbone == nil {
                backbone = sorted.first
            }
        }
        guard let backbone, let mmproj else {
            throw VoiceCloneGGUFError.modelMissing("需要同时提供主模型和 mmproj")
        }
        try install(backbone: backbone, mmproj: mmproj)
    }
}

/// 声音克隆生成的一段声音
struct CloneAudio: Sendable {
    var samples: [Float]
    var sampleRate: Int
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

    /// 当前是不是放在 GPU 上跑的
    private(set) var usingGPU = true

    /// 加载骨架模型 + mmproj
    /// useGPU = false 时整个模型都放 CPU：
    /// 内存紧张时用，Metal 里的权重是常驻的、不可回收，mmap 出来的文件页还能被系统回收。
    func load(useGPU: Bool = true, lowMemory: Bool = false) async throws {
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

        // 骨架模型：内存够就整个放 GPU
        usingGPU = useGPU
        var mp = llama_model_default_params()
        mp.n_gpu_layers = useGPU ? 999 : 0
        guard let m = llama_model_load_from_file(VoiceCloneGGUF.backboneURL.path, mp) else {
            throw VoiceCloneGGUFError.loadFailed("backbone")
        }
        model = m

        // 上下文：需要 embedding 模式才能把 hidden state 传给音频生成器
        var cp = llama_context_default_params()
        cp.embeddings = true
        cp.n_ctx = 2048
        cp.n_batch = lowMemory ? 512 : 2048
        if lowMemory { cp.n_ubatch = 128 }
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
        mp2.use_gpu = useGPU
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
        hearLog("声音克隆（GGUF）：加载完成\(useGPU ? "" : "（CPU 运行：内存紧张，速度较慢）")")
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
                   reference: [Float], referenceText: String) throws -> CloneAudio {
        let t0 = Date()
        guard let model, let ctx, let mctx, let gen else {
            throw VoiceCloneGGUFError.notLoaded
        }
        guard let lang = VoiceCloneGGUF.languageNames[language] else {
            throw VoiceCloneGGUFError.unsupportedLanguage
        }
        guard !text.isEmpty else { return CloneAudio(samples: [], sampleRate: VoiceCloneGGUF.sampleRate) }

        // 0) 先把上下文清空
        //    Qwen3-TTS 这条管线在生成完以后不会自己清 KV 缓存，
        //    上一次如果失败（或者生成了一半），这次再跑就会在 step_prompt 挂掉。
        //    每次生成前清一次，就不会有这个问题。
        llama_memory_clear(llama_get_memory(ctx), true)

        // 1) 参考音频编码成 bitmap（语音 tokenizer 编码）
        //    mtmd 的接口要文件路径，这里先把 16 kHz PCM 写成临时 wav
        //    克隆会把参考音频里的环境音也一起学过去，先降一遍噪
        let cleanRef = Self.denoise(reference)
        let refPath = try writeTempWav(samples: cleanRef, sampleRate: 16000)
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

        // 生成失败的话上下文是脏的（Qwen3-TTS 这条管线自己不清 KV 缓存），
        // 清掉，下次重来就不会在 step_prompt 挂掉。
        var failed = false
        defer {
            if failed { llama_memory_clear(llama_get_memory(ctx), true) }
        }

        // 3) 处理提示词（把文字喂进骨架模型）
        let batch = Int32(llama_n_batch(ctx))
        while true {
            let r = mtmd_helper_gen_audio_step_prompt(gen, batch)
            if r < 0 {
                failed = true
                throw VoiceCloneGGUFError.generateFailed("step_prompt")
            }
            if r == 0 { break }
        }

        // 4) 逐帧生成
        //    注意：Qwen3-TTS 必须先从骨架模型采样出一个 token 才能进 step_gen，
        //    传空 token（LLAMA_TOKEN_NULL）会直接失败。
        let maxFrames = mtmd_helper_gen_audio_max_frames(gen)
        var nFrames = 0
        var stop = false
        // 先采一个 token
        var sampled = sampleToken(ctx, model)
        guard sampled >= 0 else {
            throw VoiceCloneGGUFError.generateFailed("拿不到第一个 token")
        }
        guard let hStateRaw = llama_get_embeddings_ith(ctx, -1) else {
            throw VoiceCloneGGUFError.generateFailed("拿不到 embedding")
        }
        var hState: UnsafePointer<Float> = UnsafePointer(hStateRaw)

        while !stop && nFrames < maxFrames {
            var hNext: UnsafePointer<Float>?
            let rc2 = mtmd_helper_gen_audio_step_gen(gen, sampled, hState, &hNext, &stop)
            guard rc2 == 0 else {
                failed = true
                throw VoiceCloneGGUFError.generateFailed("step_gen")
            }
            // 结束信号：这一帧没有产出，hNext 为空
            guard let h = hNext else { break }
            nFrames += 1
            hState = h
            // 从 logits 采样下一个语义 token
            sampled = sampleToken(ctx, model)
            if sampled < 0 { break }
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
        let rate = Int(sampleRate) > 0 ? Int(sampleRate) : VoiceCloneGGUF.sampleRate
        let secs = Double(pcm.count) / Double(rate)

        // 参考音频也要看一眼：麦克风没录到东西的话，克隆出来的声音也是没声音的
        var refPeak: Float = 0
        for s in cleanRef { let a = abs(s); if a > refPeak { refPeak = a } }
        hearLog("声音克隆（\(usingGPU ? "GPU" : "CPU")）：生成 \(String(format: "%.1f", secs)) 秒声音（\(rate) Hz），"
                + "参考音频 \(String(format: "%.1f", Double(reference.count) / 16000)) 秒 峰值 \(String(format: "%.3f", refPeak))，"
                + "用时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")

        // 模型输出的音量有时很小，直接放会听不到：统一调到能听见的水平
        let norm = Self.normalize(pcm, rate: rate)
        hearLog("声音克隆：输出峰值 \(String(format: "%.3f", norm.peak))，均方根 \(String(format: "%.3f", norm.rms))"
                + (norm.gain > 1 ? "，已放大 \(String(format: "%.1f", norm.gain)) 倍" : ""))
        if norm.peak < 0.0005 {
            // 全是静音：宁可退回系统声音，也不要一片安静
            throw VoiceCloneGGUFError.generateFailed("生成的声音是静音")
        }
        return CloneAudio(samples: norm.pcm, sampleRate: rate)
    }

    /// 简单降噪参考音频：
    /// 1) 一阶高通（80 Hz）去掉隆隆声和直流偏置
    /// 2) 按 20 ms 一段估底噪，把比底噪还安静的部分压下去（环境音里的大多是这种）
    /// 语音本身基本不动，所以不会把说话声也削掉。
    static func denoise(_ samples: [Float], sampleRate: Int = 16_000) -> [Float] {
        guard samples.count > 512 else { return samples }
        let origPeak = peak(of: samples)
        var out = [Float](repeating: 0, count: samples.count)

        // 1) 一阶高通（80 Hz）：去掉隆隆声、直流偏置
        //    rc = 1/(2*pi*fc) 是秒，dt = 1/fs 也是秒，两者单位一致
        let dt = 1.0 / Float(sampleRate)
        let rc = 1.0 / (2.0 * Float.pi * 80.0)
        let a = rc / (rc + dt)
        var prevIn: Float = 0
        var prevOut: Float = 0
        for i in samples.indices {
            let x = samples[i]
            let y = a * (prevOut + x - prevIn)
            out[i] = y
            prevIn = x
            prevOut = y
        }

        // 2) 底噪估计：20 ms 一段，取能量较低的 20% 当底噪
        let win = max(1, sampleRate / 50)
        var levels: [Float] = []
        var i = 0
        while i + win <= out.count {
            var sum: Float = 0
            for k in i..<(i + win) { sum += out[k] * out[k] }
            levels.append(sqrt(sum / Float(win)))
            i += win
        }
        guard !levels.isEmpty else { return out }
        let sorted = levels.sorted()
        let idx = max(0, Int(Double(sorted.count) * 0.2) - 1)
        let floorLevel = sorted[idx]
        // 底噪比说话声低很多时才做门限，否则说明一直在说话，别乱压
        let median = sorted[sorted.count / 2]
        if floorLevel > 0, median > floorLevel * 4 {
            let gate = max(floorLevel * 2.0, 0.002)
            var j = 0
            while j + win <= out.count {
                var sum: Float = 0
                for k in j..<(j + win) { sum += out[k] * out[k] }
                let rms = sqrt(sum / Float(win))
                if rms < gate {
                    // 压到底噪的一半，不是一刀切静音（免得把字头也削掉）
                    let k = 0.5 + 0.5 * (rms / gate)
                    for idx2 in j..<(j + win) { out[idx2] *= k }
                }
                j += win
            }
        }

        // 3) 安全检查：处理完不能明显变小，否则说明滤过头了，用原声
        let newPeak = peak(of: out)
        if newPeak < origPeak * 0.5 || newPeak < 0.0001 {
            hearLog("声音克隆：降噪后声音太小，改用原始参考音频", .warning)
            return samples
        }
        return out
    }

    /// 一段声音的最大绝对值
    private static func peak(of samples: [Float]) -> Float {
        var p: Float = 0
        for s in samples { let a = abs(s); if a > p { p = a } }
        return p
    }

    /// 把声音调整到能听见的音量，并去掉头尾的咔哒声
    private static func normalize(_ pcm: [Float], rate: Int) -> (pcm: [Float], peak: Float, rms: Float, gain: Float) {
        guard !pcm.isEmpty else { return ([], 0, 0, 1) }
        var peak: Float = 0
        var sum: Float = 0
        for s in pcm {
            let a = abs(s)
            if a > peak { peak = a }
            sum += s * s
        }
        let rms = sqrt(sum / Float(pcm.count))
        var out = pcm
        var gain: Float = 1
        // 峰值太小就整体放大（模型输出的音量偏小的情况）
        if peak > 0.0005, peak < 0.5 {
            gain = 0.85 / peak
            for i in out.indices { out[i] *= gain }
        }
        // 头尾各淡入淡出 5 毫秒
        let fade = min(out.count / 2, max(2, rate / 200))    // 5 毫秒
        if fade > 1 {
            for i in 0..<fade {
                let k = Float(i) / Float(fade)
                out[i] *= k
                out[out.count - 1 - i] *= k
            }
        }
        return (out, peak, rms, gain)
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
