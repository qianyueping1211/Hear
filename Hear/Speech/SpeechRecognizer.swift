import Foundation
import WhisperKit
import CoreML

/// 本地语音识别（WhisperKit，跑在神经网络引擎上）
actor SpeechRecognizer {
    static let modelVariant = "openai_whisper-large-v3-v20240930_turbo"

    private var pipe: WhisperKit?
    private var zhPromptTokens: [Int]?
    private var busy = false   // WhisperKit 不保证并发安全，这里串行化

    /// 排队的优先级：数字小的先走
    ///   0 整句识别（最终结果，最急）
    ///   1 实时预览（说话过程中出字，可以等）
    ///   2 校正（Whisper 再认一遍，最不急，可以一直等）
    private enum Priority: Int, Comparable {
        case finalASR = 0
        case preview = 1
        case correction = 2
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    /// 排队等着用引擎的请求
    private struct Waiter {
        let prio: Priority
        let order: Int              // 同一个优先级里按先来后到
        let cont: CheckedContinuation<Void, Never>
    }
    private var waiters: [Waiter] = []
    private var ticket = 0

    /// 等到轮到我们。
    ///
    /// 之前这地方是用"几个计数器"互相等的（整句等预览让路、预览又等校正让路），
    /// 两边都在等对方 → 谁也走不了，整条识别队列就卡死了。
    /// 现在改成一条真正的排队：按优先级挑下一个，取消的请求不占位置。
    private func acquire(_ prio: Priority) async throws {
        if busy {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                ticket += 1
                waiters.append(Waiter(prio: prio, order: ticket, cont: c))
            }
        } else {
            busy = true
        }
        // 排队期间被取消了：把位置让出去，别占着引擎
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    /// 释放：位置交给下一个等着的（优先级高的先，同级先来后到）
    private func release() {
        if waiters.isEmpty {
            busy = false
            return
        }
        var best = 0
        for i in waiters.indices.dropFirst() {
            if waiters[i].prio < waiters[best].prio
                || (waiters[i].prio == waiters[best].prio && waiters[i].order < waiters[best].order) {
                best = i
            }
        }
        let w = waiters.remove(at: best)
        w.cont.resume()          // 位置直接交给他（busy 仍然是 true）
    }

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

        Self.prepareTokenizer(modelFolder: folder)
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
            // 分词文件（tokenizer.json）不在本地时 WhisperKit 会联网下载，下载失败就给一个看得懂的提示
            if !FileManager.default.fileExists(atPath: Self.tokenizerRepo.appendingPathComponent("tokenizer.json").path) {
                throw NSError(domain: "Hear", code: 6, userInfo: [NSLocalizedDescriptionKey:
                    "缺少 Whisper 分词文件 tokenizer.json（约 2 MB）。请联网后重试；或把 tokenizer.json 和 tokenizer_config.json 放进模型文件夹后重新导入。"])
            }
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

    /// WhisperKit 找分词文件的位置：Documents/huggingface/models/openai/whisper-large-v3
    static var tokenizerRepo: URL {
        ModelManager.whisperBase.appendingPathComponent("models/openai/whisper-large-v3", isDirectory: true)
    }

    /// 导入的模型里通常没有分词文件，WhisperKit 会去网上下载。这里先准备好：
    /// 模型文件夹里带了分词文件就复制过去；本地没有时清掉上次没下完的临时文件，并建好文件夹，避免下载后移动失败
    static func prepareTokenizer(modelFolder: URL) {
        let fm = FileManager.default
        let repo = tokenizerRepo
        try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
        let names = ["tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt",
                     "special_tokens_map.json", "added_tokens.json", "normalizer.json"]
        var copied: [String] = []
        for n in names {
            let src = modelFolder.appendingPathComponent(n)
            let dst = repo.appendingPathComponent(n)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            if (try? fm.copyItem(at: src, to: dst)) != nil { copied.append(n) }
        }
        if !copied.isEmpty { hearLog("语音识别：从模型文件夹复制分词文件 \(copied.joined(separator: "、"))") }
        if fm.fileExists(atPath: repo.appendingPathComponent("tokenizer.json").path) {
            hearLog("语音识别：分词文件已在本地")
        } else {
            try? fm.removeItem(at: repo.appendingPathComponent(".cache", isDirectory: true))
            hearLog("语音识别：本地没有分词文件 tokenizer.json，需要联网下载（约 2 MB）", .warning)
        }
    }

    /// 识别一句话：先让 Whisper 自动判断语种；如果判断结果不在两种候选语言里，再用 fallback 语言重识别。
    /// 返回 (语言代码, 文字)
    /// preview = true：说话过程中的实时预览，只识别一遍、不重试，速度优先
    /// correction = true：这是"校正"（整句之后再用 Whisper 复核一遍），
    /// 优先级最低，不挡着新句子
    func recognize(_ samples: [Float], candidates: [String], fallback: String,
                   preview: Bool = false, correction: Bool = false) async throws -> (String, String) {
        guard let pipe else {
            // 模型不在了（内存不足被卸载、或者没加载成功）：
            // 静悄悄返回空字符串的话，上层会当成"用户没说话"，
            // 说的话就被当噪声丢掉了。报错才能让人知道出事了。
            throw NSError(domain: "Hear", code: 20, userInfo: [NSLocalizedDescriptionKey:
                "语音识别模型不在了（可能被内存不足卸载了），请重新开始一次"])
        }
        let prio: Priority = correction ? .correction : (preview ? .preview : .finalASR)
        try await acquire(prio); defer { release() }
        // 等到了位置，但排队期间可能被取消了：别再跑模型
        if Task.isCancelled { throw CancellationError() }
        let secs = Double(samples.count) / 16_000

        // 只有一种候选语言（对话翻译模式按住了某种语言）：直接按这种语言识别，不再自动判断
        if candidates.count == 1, let only = candidates.first {
            let r = try await pipe.transcribe(audioArray: samples,
                                              decodeOptions: options(language: only, preview: preview, seconds: secs))
            return (only, Self.confident(r) ? Self.joinText(r, language: only) : "")
        }

        let auto = try await pipe.transcribe(audioArray: samples,
                                             decodeOptions: options(language: nil, preview: preview, seconds: secs))
        let detected = auto.first?.language ?? ""
        if candidates.contains(detected) {
            return (detected, Self.confident(auto) ? Self.joinText(auto, language: detected) : "")
        }
        if preview {
            return (fallback, Self.confident(auto) ? Self.joinText(auto, language: fallback) : "")
        }
        let forced = try await pipe.transcribe(audioArray: samples,
                                               decodeOptions: options(language: fallback, preview: false, seconds: secs))
        return (fallback, Self.confident(forced) ? Self.joinText(forced, language: fallback) : "")
    }

    /// 指定语言识别（用于说话过程中的实时预览）
    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let pipe else { return "" }
        try await acquire(.preview); defer { release() }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options(language: language))
        return Self.joinText(results, language: language ?? results.first?.language)
    }

    /// seconds：这段声音有多长。输出长度按时长封顶：正常说话每秒最多十来个字，
    /// 噪声上 Whisper 容易“复读”出几百个字，封顶后不会卡很久
    private func options(language: String?, preview: Bool = false, seconds: Double = 30) -> DecodingOptions {
        var opts = DecodingOptions()
        opts.verbose = false
        opts.task = .transcribe
        opts.language = language
        opts.detectLanguage = (language == nil)
        opts.usePrefillPrompt = (language != nil)
        opts.temperature = 0
        // 噪声或半句话时 Whisper 容易“复读”很长的内容并反复重试，非常慢：
        // 都不重试（重试一次要再花一整遍的时间）；长度按声音时长封顶
        opts.temperatureFallbackCount = 0
        opts.sampleLength = min(preview ? 96 : 224, max(24, Int(seconds * 15)))
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
        return Fillers.clean(text)          // 去掉单独的语气词（嗯、啊、um…）
    }

    /// Whisper 自己都没把握的结果（多半是在噪声、咳嗽、碰撞声里“听”出来的），直接丢掉
    private static func confident(_ results: [TranscriptionResult]) -> Bool {
        let segs = results.flatMap(\.segments)
        guard !segs.isEmpty else { return true }
        let n = Double(segs.count)
        let noSpeech = segs.reduce(0.0) { $0 + Double($1.noSpeechProb) } / n
        let logProb = segs.reduce(0.0) { $0 + Double($1.avgLogprob) } / n
        if logProb < -1.0 { return false }                     // 整体很没把握
        if noSpeech > 0.5 && logProb < -0.6 { return false }   // 像是没人说话，又识别得很勉强
        return true
    }

    /// 文字是不是这种语言写的：例如选的是英语，结果却是俄文“Продолжение следует…”，就是识别错了。
    /// 中日韩里夹的英文单词按一个字算，不会因为“我用 iPhone”这种句子误判。
    static func matchesLanguage(_ text: String, _ lang: String) -> Bool {
        var total = 0, hit = 0
        var inLatinRun = false
        let cjkLang = ["zh", "ja", "ko"].contains(lang)
        for s in text.unicodeScalars {
            guard s.properties.isAlphabetic else { inLatinRun = false; continue }
            let latin = isLatin(s.value)
            if cjkLang && latin {
                if inLatinRun { continue }      // 一串英文字母只算一个
                inLatinRun = true
            } else {
                inLatinRun = false
            }
            total += 1
            if inScript(s.value, lang) { hit += 1 }
        }
        guard total > 0 else {
            // 一个字母都没有（纯数字、订单号、"2026"这种）：
            // 判断不了语言，但也不能因为这个把用户说的话丢掉
            return true
        }
        return Double(hit) / Double(total) >= 0.6
    }

    private static func isLatin(_ v: UInt32) -> Bool {
        (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) ||
        (0xC0...0x24F).contains(v) || (0x1E00...0x1EFF).contains(v)
    }

    private static func inScript(_ v: UInt32, _ lang: String) -> Bool {
        let han = (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
        switch lang {
        case "zh": return han
        case "ja": return han || (0x3040...0x30FF).contains(v)
        case "ko": return (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v)
        case "ru": return (0x0400...0x04FF).contains(v)
        case "ar": return (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v)
        case "th": return (0x0E00...0x0E7F).contains(v)
        default:   return isLatin(v)            // 英、法、德、西、葡、意、越 等拉丁字母语言
        }
    }

    /// 过滤 Whisper 在噪声/静音上常见的“幻觉”句子
    static func isMeaningful(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if t.count < 1 { return false }
        if Fillers.isOnlyFillers(t) { return false }        // 只有「嗯」「啊」这类语气词
        let junk = ["字幕", "订阅", "點贊", "点赞", "打赏", "Amara", "谢谢观看", "感谢观看",
                    "Thank you for watching", "Thanks for watching", "Subtitles by", "明镜", "请不吝",
                    "Продолжение следует", "Субтитры", "Редактор субтитров", "ご視聴ありがとうございました",
                    "MBC 뉴스", "시청해주셔서"]
        // 黑名单：整句就是这些短语才丢。
        // 长句里顺带提到"谢谢观看""字幕"这种，不能把整句话丢掉；
        // 短句也一样：像"字幕由你提供"这种是真的有人在说话，不能因为里面
        // 有"字幕由"三个字就把整句丢了——只有四个字以上的整句黑名单短语
        // 才允许"包含即丢"。
        if junk.contains(where: { p in
            if t.localizedCaseInsensitiveCompare(p) == .orderedSame { return true }
            return p.count >= 4 && t.count <= 8 && t.localizedCaseInsensitiveContains(p)
        }) { return false }
        if t.hasPrefix("[") || t.hasPrefix("(") || t.hasPrefix("（") { return false }
        // 背景声的描述，例如 *Humming*、♪音乐♪、(笑声)
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("*") || raw.hasPrefix("♪") || raw.hasPrefix("[") || raw.hasPrefix("(") || raw.hasPrefix("（") {
            return false
        }
        if raw.contains("*") || raw.contains("♪") { return false }      // 例如 “Burz*.”
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
