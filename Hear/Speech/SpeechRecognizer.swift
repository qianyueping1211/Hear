import Foundation
import WhisperKit

/// 本地语音识别（WhisperKit，跑在神经网络引擎上）
actor SpeechRecognizer {
    static let modelVariant = "openai_whisper-large-v3-v20240930_turbo"

    private var pipe: WhisperKit?
    private var zhPromptTokens: [Int]?
    private var busy = false   // WhisperKit 不保证并发安全，这里串行化

    private func acquire() async {
        while busy { try? await Task.sleep(nanoseconds: 15_000_000) }
        busy = true
    }
    private func release() { busy = false }

    var isLoaded: Bool { pipe != nil }

    func unload() {
        pipe = nil
        zhPromptTokens = nil
    }

    func load(folder: URL) async throws {
        let config = WhisperKitConfig()
        config.modelFolder = folder.path
        config.verbose = false
        config.prewarm = true
        config.load = true
        config.download = false
        let p = try await WhisperKit(config)
        pipe = p

        // 提示 Whisper 输出简体中文 + 标点
        if let tk = p.tokenizer {
            zhPromptTokens = tk.encode(text: " 以下是普通话的句子，使用简体中文。")
                .filter { $0 < tk.specialTokens.specialTokenBegin }
        }
    }

    /// 识别一句话：先让 Whisper 自动判断语种；如果判断结果不在两种候选语言里，再用 fallback 语言重识别。
    /// 返回 (语言代码, 文字)
    func recognize(_ samples: [Float], candidates: [String], fallback: String) async throws -> (String, String) {
        guard let pipe else { return (fallback, "") }
        await acquire(); defer { release() }

        let auto = try await pipe.transcribe(audioArray: samples, decodeOptions: options(language: nil))
        let detected = auto.first?.language ?? ""
        if candidates.contains(detected) {
            return (detected, Self.joinText(auto, language: detected))
        }
        let forced = try await pipe.transcribe(audioArray: samples, decodeOptions: options(language: fallback))
        return (fallback, Self.joinText(forced, language: fallback))
    }

    /// 指定语言识别（用于说话过程中的实时预览）
    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let pipe else { return "" }
        await acquire(); defer { release() }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options(language: language))
        return Self.joinText(results, language: language ?? results.first?.language)
    }

    private func options(language: String?) -> DecodingOptions {
        var opts = DecodingOptions()
        opts.verbose = false
        opts.task = .transcribe
        opts.language = language
        opts.detectLanguage = (language == nil)
        opts.usePrefillPrompt = (language != nil)
        opts.temperature = 0
        opts.temperatureFallbackCount = 2
        opts.skipSpecialTokens = true
        opts.withoutTimestamps = true
        opts.suppressBlank = true
        if language == "zh", let t = zhPromptTokens { opts.promptTokens = t }
        return opts
    }

    private static func joinText(_ results: [TranscriptionResult], language: String?) -> String {
        var text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if language == "zh" {
            text = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        }
        return text
    }

    /// 过滤 Whisper 在噪声/静音上常见的“幻觉”句子
    static func isMeaningful(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if t.count < 1 { return false }
        let junk = ["字幕", "订阅", "點贊", "点赞", "打赏", "Amara", "谢谢观看", "感谢观看",
                    "Thank you for watching", "Thanks for watching", "Subtitles by", "明镜", "请不吝"]
        if junk.contains(where: { t.localizedCaseInsensitiveContains($0) }) { return false }
        if t.hasPrefix("[") || t.hasPrefix("(") || t.hasPrefix("（") { return false }
        return true
    }
}
