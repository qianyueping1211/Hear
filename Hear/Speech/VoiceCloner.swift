import Foundation
import Qwen3TTS

/// 声音克隆朗读：Qwen3-TTS 0.6B（speech-swift，MLX 跑在 GPU 上）。
/// 用说话人刚说的那句话（声音 + 识别出的文字）当样本，把译文用他的声音读出来。
/// 模型约 0.7 GB + 声音编解码器约 0.7 GB，只在打开“声音克隆”时才加载，关掉就卸载。
actor VoiceCloner {
    /// 0.6B 基础版（只有基础版能克隆），4bit 量化，省内存
    static let modelId = "aufklarer/Qwen3-TTS-12Hz-0.6B-Base-MLX-4bit"
    static let tokenizerId = "Qwen/Qwen3-TTS-Tokenizer-12Hz"
    static let sampleRate = 24_000

    private var model: Qwen3TTSModel?
    private var encoder: SpeechTokenizerEncoder?
    /// 正在加载中：同一个模型加载两份会吃掉双倍内存，App 会被系统直接杀掉
    private var loading = false

    var isLoaded: Bool { model != nil }
    /// 正在加载（下载）中：加载别的模型前要先等它结束，避免同时占内存
    var isLoading: Bool { loading }

    /// 模型放在 Application Support/VoiceClone 下
    static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceClone", isDirectory: true)
    }
    static var modelDir: URL { base.appendingPathComponent("model", isDirectory: true) }
    static var tokenizerDir: URL { base.appendingPathComponent("tokenizer", isDirectory: true) }

    /// 两部分都下载好了
    static func installed() -> Bool {
        hasWeights(modelDir) && hasWeights(tokenizerDir)
    }

    private static func hasWeights(_ dir: URL) -> Bool {
        guard let e = FileManager.default.enumerator(atPath: dir.path) else { return false }
        for case let p as String in e where p.hasSuffix(".safetensors") && !p.contains(".incomplete") {
            return true
        }
        return false
    }

    static func delete() {
        try? FileManager.default.removeItem(at: base)
    }

    /// 导入本地下载好的模型。可以选：
    /// - 一个大文件夹，里面放着 Qwen3-TTS-12Hz-0.6B-Base-MLX-4bit 和 Qwen3-TTS-Tokenizer-12Hz 两个文件夹（一次导入两部分）
    /// - 或者只选其中一个文件夹（只导入那一部分）
    /// 两个文件夹里有重名的文件（config.json 等），分别复制到各自的位置，不会互相覆盖。
    /// 返回导入了哪些部分
    static func importFolder(from src: URL) throws -> (model: Bool, tokenizer: Bool) {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        var dirs = [src]
        if let subs = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey]) {
            dirs += subs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        }
        func has(_ dir: URL, _ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        var gotModel = false, gotTokenizer = false
        for dir in dirs where hasWeights(dir) {
            let isTokenizer = dir.lastPathComponent.lowercased().contains("tokenizer") || has(dir, "preprocessor_config.json")
            let isModel = !isTokenizer && has(dir, "config.json") && has(dir, "vocab.json")
            if isTokenizer && !gotTokenizer {
                try replace(tokenizerDir, with: dir)
                gotTokenizer = true
                hearLog("声音克隆：已导入声音编解码器 \(dir.lastPathComponent)")
            } else if isModel && !gotModel {
                try replace(modelDir, with: dir)
                gotModel = true
                hearLog("声音克隆：已导入主模型 \(dir.lastPathComponent)")
            }
        }
        guard gotModel || gotTokenizer else {
            throw NSError(domain: "Hear", code: 7, userInfo: [NSLocalizedDescriptionKey:
                "没有找到声音克隆模型。请选包含 Qwen3-TTS-12Hz-0.6B-Base-MLX-4bit 和 Qwen3-TTS-Tokenizer-12Hz 两个文件夹的大文件夹"])
        }
        return (gotModel, gotTokenizer)
    }

    private static func replace(_ dst: URL, with src: URL) throws {
        let fm = FileManager.default
        if src.standardizedFileURL.path == dst.standardizedFileURL.path { return }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
    }

    /// 支持的语言（Qwen3-TTS 10 种）：App 的语言代码 → Qwen3-TTS 的语言名
    static func languageName(_ id: String) -> String? {
        [
            "zh": "chinese", "en": "english", "ja": "japanese", "ko": "korean",
            "de": "german", "fr": "french", "ru": "russian", "pt": "portuguese",
            "es": "spanish", "it": "italian",
        ][id]
    }

    /// 下载（已下载就直接加载）。下载完模型会留在内存里
    func download(host: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        setenv("HF_ENDPOINT", "https://\(host)", 1)
        guard !loading else { return }                    // 已经在加载了，别再加载一份
        loading = true
        defer { loading = false }
        try await loadModel(offline: false, progress: progress)
    }

    func load() async throws {
        guard model == nil, !loading else { return }      // 已经在加载了，别再加载一份
        loading = true
        defer { loading = false }
        try await loadModel(offline: Self.installed(), progress: nil)
    }

    private func loadModel(offline: Bool, progress: (@Sendable (Double) -> Void)?) async throws {
        let t0 = Date()
        try? FileManager.default.createDirectory(at: Self.modelDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.tokenizerDir, withIntermediateDirectories: true)
        hearLog("声音克隆：开始\(offline ? "加载" : "下载并加载") Qwen3-TTS 0.6B")
        let (m, enc) = try await Qwen3TTSModel.fromPretrainedWithEncoder(
            modelId: Self.modelId,
            tokenizerModelId: Self.tokenizerId,
            cacheDir: Self.modelDir,
            tokenizerCacheDir: Self.tokenizerDir,
            offlineMode: offline,
            progressHandler: { p, _ in progress?(p) }
        )
        model = m
        encoder = enc
        hearLog("声音克隆：加载完成，用时 \(Int(Date().timeIntervalSince(t0)))s")
    }

    func unload() {
        model?.clearReferenceAudioCache()
        model = nil
        encoder = nil
    }

    /// 用样本声音（16 kHz）和样本文字，把 text 用这个声音读出来。返回 24 kHz 的声音；做不了返回 nil
    func synthesize(text: String, language: String,
                    reference: [Float], referenceText: String) -> [Float]? {
        guard let model, let encoder, let lang = Self.languageName(language) else { return nil }
        let t0 = Date()
        let ref = Self.resample16kTo24k(reference)
        let out = model.synthesizeWithVoiceCloneICL(
            text: text,
            referenceAudio: ref,
            referenceSampleRate: Self.sampleRate,
            referenceText: referenceText,
            language: lang,
            codecEncoder: encoder
        )
        let secs = Double(out.count) / Double(Self.sampleRate)
        hearLog("声音克隆：生成 \(String(format: "%.1f", secs)) 秒声音，用时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        return out.isEmpty ? nil : out
    }

    /// 16 kHz → 24 kHz（线性插值，够用）
    static func resample16kTo24k(_ x: [Float]) -> [Float] {
        guard x.count > 1 else { return x }
        let n = x.count * 3 / 2
        var y = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let pos = Double(i) * 2.0 / 3.0
            let j = Int(pos)
            let f = Float(pos - Double(j))
            let a = x[min(j, x.count - 1)]
            let b = x[min(j + 1, x.count - 1)]
            y[i] = a + (b - a) * f
        }
        return y
    }
}
