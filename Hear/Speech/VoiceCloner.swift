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

    var isLoaded: Bool { model != nil }

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
        try await loadModel(offline: false, progress: progress)
    }

    func load() async throws {
        guard model == nil else { return }
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
