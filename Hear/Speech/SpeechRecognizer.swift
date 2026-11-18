import Foundation
import WhisperKit
import CoreML

/// 本地语音识别（WhisperKit，跑在神经网络引擎上）
actor SpeechRecognizer {
    static let modelVariant = "openai_whisper-large-v3-v20240930_turbo"

    private var pipe: WhisperKit?
    private var zhPromptTokens: [Int]?
    private var busy = false   // WhisperKit 不保证并发安全，这里串行化
    private var finalWaiting = 0

    /// 整句识别优先：有整句在等时，实时预览先让路
    private func acquire(final: Bool) async {
        if final { finalWaiting += 1 }
        while busy || (!final && finalWaiting > 0) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if final { finalWaiting -= 1 }
        busy = true
    }
    private func release() { busy = false }

    var isLoaded: Bool { pipe != nil }

    func unload() {
        pipe = nil
        zhPromptTokens = nil
    }

    /// 加载语音识别模型。
    /// useGPU = true：用 GPU 运行，几乎不用等待编译（推荐）
    /// useGPU = false：用神经引擎，更省电，但第一次需要编译，可能要好几分钟
    func load(folder: URL, useGPU: Bool) async throws {
        let t0 = Date()
        ASRProgress.shared.set(stage: "初始化", pipe: nil)
        hearLog("语音识别：开始加载 \(folder.lastPathComponent)，运行在 \(useGPU ? "GPU" : "神经引擎")")

        let config = WhisperKitConfig()
        config.modelFolder = folder.path
        config.verbose = false
        config.prewarm = false
        config.load = false
        config.download = false
        config.computeOptions = useGPU
            ? ModelComputeOptions(audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU)
            : ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)

        let p: WhisperKit
        do {
            p = try await WhisperKit(config)
        } catch {
            hearLog("语音识别：初始化失败 \(error)", .error)
            throw error
        }
        hearLog("语音识别：初始化完成（\(Int(Date().timeIntervalSince(t0)))s），开始载入模型")
        ASRProgress.shared.set(stage: "载入模型", pipe: p)

        do {
            try await p.loadModels()
        } catch {
            ASRProgress.shared.set(stage: "失败", pipe: nil)
            hearLog("语音识别：载入模型失败 \(error)", .error)
            throw error
        }
        pipe = p
        ASRProgress.shared.set(stage: "完成", pipe: nil)
        hearLog("语音识别：加载完成，共用时 \(Int(Date().timeIntervalSince(t0)))s")

        // 提示 Whisper 输出简体中文 + 标点
        if let tk = p.tokenizer {
            zhPromptTokens = tk.encode(text: " 以下是普通话的句子，使用简体中文。")
                .filter { $0 < tk.specialTokens.specialTokenBegin }
        }
    }

    /// 识别一句话：先让 Whisper 自动判断语种；如果判断结果不在两种候选语言里，再用 fallback 语言重识别。
    /// 返回 (语言代码, 文字)
    /// preview = true：说话过程中的实时预览，只识别一遍、不重试，速度优先
    func recognize(_ samples: [Float], candidates: [String], fallback: String,
                   preview: Bool = false) async throws -> (String, String) {
        guard let pipe else { return (fallback, "") }
        await acquire(final: !preview); defer { release() }

        let auto = try await pipe.transcribe(audioArray: samples,
                                             decodeOptions: options(language: nil, preview: preview))
        let detected = auto.first?.language ?? ""
        if candidates.contains(detected) {
            return (detected, Self.joinText(auto, language: detected))
        }
        if preview {
            return (fallback, Self.joinText(auto, language: fallback))
        }
        let forced = try await pipe.transcribe(audioArray: samples,
                                               decodeOptions: options(language: fallback, preview: false))
        return (fallback, Self.joinText(forced, language: fallback))
    }

    /// 指定语言识别（用于说话过程中的实时预览）
    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let pipe else { return "" }
        await acquire(final: true); defer { release() }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options(language: language))
        return Self.joinText(results, language: language ?? results.first?.language)
    }

    private func options(language: String?, preview: Bool = false) -> DecodingOptions {
        var opts = DecodingOptions()
        opts.verbose = false
        opts.task = .transcribe
        opts.language = language
        opts.detectLanguage = (language == nil)
        opts.usePrefillPrompt = (language != nil)
        opts.temperature = 0
        // 噪声或半句话时 Whisper 容易“复读”很长的内容并反复重试，非常慢：
        // 预览不重试、限制长度；整句最多重试一次
        opts.temperatureFallbackCount = preview ? 0 : 1
        opts.sampleLength = preview ? 96 : 224
        opts.compressionRatioThreshold = 2.4
        opts.logProbThreshold = -1.0
        opts.firstTokenLogProbThreshold = -1.5
        opts.noSpeechThreshold = 0.6          // 判断为“没人说话”的片段直接丢掉
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
        // 背景声的描述，例如 *Humming*、♪音乐♪、(笑声)
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("*") || raw.hasPrefix("♪") || raw.hasPrefix("[") || raw.hasPrefix("(") || raw.hasPrefix("（") {
            return false
        }
        return true
    }
}

/// 加载进度（任何线程都能读，用于界面显示“已用 xx 秒 / 当前阶段”）
final class ASRProgress {
    static let shared = ASRProgress()
    private let lock = NSLock()
    private var stage = ""
    private weak var pipe: WhisperKit?

    func set(stage: String, pipe: WhisperKit?) {
        lock.lock(); self.stage = stage; self.pipe = pipe; lock.unlock()
    }

    /// 例如 “载入模型 · loading”
    var description: String {
        lock.lock(); defer { lock.unlock() }
        if let p = pipe { return "\(stage) · \(p.modelState)" }
        return stage
    }
}
