import Foundation
import AVFoundation
import CoreMedia
import Speech

/// 说话时“逐字显示原文”的引擎（目前是 iOS 26 自带的系统听写）。
/// 只负责实时显示；一句话说完后仍由 Whisper 做最终识别和语言判断。
protocol LiveTextEngine: AnyObject {
    /// 有新的识别结果（在任意线程回调）；用 segmentText 取某一句的文字
    var onUpdate: (() -> Void)? { get set }
    /// 听写自己出错了（结果流断了之类）：上层要知道，
    /// 不然界面一直等着没反应，用户以为是自己说错了
    var onFailure: ((String) -> Void)? { get set }
    /// 正在听的语言（Whisper 语言代码，例如 "zh"）
    var languageID: String? { get }
    /// 按某种语言开始听写；第一次使用某种语言时系统会先下载语言包
    func start(languageID: String, locale: String) async throws
    func stop() async
    /// 16kHz 单声道 Float 采样（音频线程调用）
    func feed(_ samples: [Float])
    /// 断句检测到第 id 句开始 / 结束（用来把识别结果对到这一句上）
    func markSegmentStart(_ id: Int)
    func markSegmentEnd(_ id: Int)
    /// 第 id 句目前识别到的文字，以及平均置信度（0~1）
    func segmentText(_ id: Int) -> (text: String, confidence: Double)
    func hasFinalText(_ id: Int) -> Bool
    /// 第 id 句覆盖的时间范围（秒）
    /// 用来判断两句话是不是同一段声音：
    /// 范围不重叠 = 用户真的说了两遍，要分开记，不能合并
}

enum LiveTextEngineFactory {
    /// 系统听写需要 iOS 26
    static var isSupported: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    /// 系统听写支持这些语言里的哪些（iOS 26 以下返回 nil）
    static func supportedLanguageIDs(_ langs: [Language]) async -> Set<String>? {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            var ids = Set<String>()
            for l in langs {
                if await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: l.tts)) != nil {
                    ids.insert(l.id)
                }
            }
            return ids
        }
        #endif
        return nil
    }

    static func make() -> LiveTextEngine? {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return AppleLiveTranscriber() }
        #endif
        return nil
    }
}

enum LiveTextError: LocalizedError {
    case unsupportedLanguage, noAudioFormat
    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage: return "系统听写不支持这种语言"
        case .noAudioFormat: return "系统听写没有可用的音频格式"
        }
    }
}

#if compiler(>=6.2)
/// iOS 26 SpeechAnalyzer + SpeechTranscriber：边说边出字，后面的内容会更正前面的
@available(iOS 26.0, *)
final class AppleLiveTranscriber: LiveTextEngine, @unchecked Sendable {
    var onUpdate: (() -> Void)?

    private struct Piece {
        var start: Double
        var end: Double
        var text: String
        var conf: Double?
    }

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var fedFrames: Int64 = 0                 // 已送入的 16kHz 采样数（用来对时间）
    private var finals: [Piece] = []
    private var volatilePiece: Piece?
    private var segs: [Int: (start: Double, end: Double?)] = [:]
    private var _languageID: String?
    private var generation = 0
    /// 还没启动好的时候收到的声音（先存着，等启动了补给它）
    /// 用户一开口就说的话，听写要下语言包、起引擎，那一下没收到就丢了
    private let inputQueue = DispatchQueue(label: "hear.apple-input")
    private var pendingFeed: [Float] = []
    private var discardedFrames: Int64 = 0
    private var analyzerOffset: Double = 0
    private static let pendingFeedMax = 48_000      // 最多留 3 秒

    private let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16_000, channels: 1, interleaved: false)!

    var languageID: String? { lock.lock(); defer { lock.unlock() }; return _languageID }

    /// 出错时回调上层（在结果流所在的那个线程上）
    var onFailure: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFailure }
        set { lock.lock(); _onFailure = newValue; lock.unlock() }
    }
    private var _onFailure: ((String) -> Void)?

    func start(languageID: String, locale: String) async throws {
        await stop()
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw LiveTextError.unsupportedLanguage
        }
        let transcriber = SpeechTranscriber(locale: loc,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [.transcriptionConfidence])
        // 第一次用这种语言：下载系统语言包（之后系统会一直保留）
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            hearLog("系统听写：下载 \(locale) 语言包…")
            try await request.downloadAndInstall()
            hearLog("系统听写：\(locale) 语言包已就绪")
        }
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LiveTextError.noAudioFormat
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)
        try await analyzer.start(inputSequence: stream)

        let gen: Int = inputQueue.sync {
            lock.lock()
            generation += 1
            let current = generation
            self.analyzer = analyzer
            input = continuation
            format = fmt
            converter = nil
            fedFrames = discardedFrames
            analyzerOffset = Double(discardedFrames) / 16_000
            finals.removeAll()
            volatilePiece = nil
            _languageID = languageID
            let preRoll = pendingFeed
            pendingFeed = []
            discardedFrames = 0
            lock.unlock()

            for start in stride(from: 0, to: preRoll.count, by: 4096) {
                deliver(Array(preRoll[start..<min(start + 4096, preRoll.count)]))
            }
            return current
        }

        resultsTask = Task { [weak self] in
            do {
                for try await r in transcriber.results {
                    let text = String(r.text.characters)
                    let start = r.range.start.seconds
                    let end = CMTimeAdd(r.range.start, r.range.duration).seconds
                    // 平均置信度：用来判断两种语言的听写哪个更可信
                    var sum = 0.0, weight = 0.0
                    for (value, range) in r.text.runs[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                        guard let v = value else { continue }
                        let w = Double(r.text[range].characters.count)
                        sum += Double(v) * w
                        weight += w
                    }
                    self?.ingest(Piece(start: start.isFinite ? start : 0,
                                       end: end.isFinite ? end : 0,
                                       text: text,
                                       conf: weight > 0 ? sum / weight : nil),
                                 isFinal: r.isFinal, gen: gen)
                }
            } catch {
                // 退出/切换语言时正常会取消，不是错误，别刷警告
                let ns = error as NSError
                let cancelled = ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError
                    || (error is CancellationError)
                    || (ns.domain == "kAFErrorDomain" && ns.code == -999)
                if !cancelled {
                    hearLog("系统听写结束：\(error)", .warning)
                    // 告诉上层：这一路的听写坏了，
                    // 上层好赶紧提示用户（或者改用 Whisper 实时预览）
                    self?.onFailure?(error.localizedDescription)
                }
            }
        }
        hearLog("系统听写：开始（\(loc.identifier)，\(Int(fmt.sampleRate)) Hz）")

    }

    func stop() async {
        lock.lock()
        let a = analyzer, c = input, t = resultsTask
        analyzer = nil; input = nil; resultsTask = nil; _languageID = nil
        generation += 1
        lock.unlock()
        c?.finish()
        if let a { try? await a.cancelAndFinishNow() }
        t?.cancel()
    }

    private var now: Double {
        Double(input == nil ? discardedFrames + Int64(pendingFeed.count) : fedFrames) / 16_000
    }

    func markSegmentStart(_ id: Int) {
        lock.lock()
        // 断句检测会晚一点（前置缓冲 + 判断时间），往前留 0.8 秒
        segs[id] = (max(0, now - 0.8), nil)
        for k in segs.keys where k < id - 20 { segs[k] = nil }
        lock.unlock()
    }

    func markSegmentEnd(_ id: Int) {
        lock.lock()
        if let s = segs[id] { segs[id] = (s.start, now) }
        lock.unlock()
    }

    func segmentText(_ id: Int) -> (text: String, confidence: Double) {
        lock.lock(); defer { lock.unlock() }
        guard let seg = segs[id] else { return ("", 0) }
        let lo = seg.start
        let hi = (seg.end ?? .greatestFiniteMagnitude) + 0.4
        var pieces = finals.filter { $0.end > lo && $0.start < hi }
        if let v = volatilePiece, v.end > lo, v.start < hi { pieces.append(v) }
        let cjk = ["zh", "ja", "ko"].contains(_languageID ?? "")
        let joined = pieces.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: cjk ? "" : " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = Fillers.clean(joined)          // 去掉单独的语气词（嗯、啊、um…）
        var sum = 0.0, weight = 0.0
        for p in pieces {
            guard let c = p.conf else { continue }
            let w = Double(max(1, p.text.count))
            sum += c * w
            weight += w
        }
        return (text, weight > 0 ? sum / weight : 0.5)
    }

    func hasFinalText(_ id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let segment = segs[id], let end = segment.end else { return false }
        if let volatilePiece, volatilePiece.end > segment.start, volatilePiece.start < end {
            return false
        }
        // VAD marks the end after its silence window, which is not part of the transcribed range.
        return finals.contains { $0.end > segment.start && $0.start < end && $0.end >= end - 0.8 }
    }

    func feed(_ samples: [Float]) {
        inputQueue.sync { deliver(samples) }
    }

    private func deliver(_ samples: [Float]) {
        lock.lock()
        guard let cont = input, let fmt = format, !samples.isEmpty else {
            // 还没准备好（语言包在下载、引擎在起）：先存着，
            // 等准备好了补给它——不然用户开口的第一句就丢了
            if !samples.isEmpty {
                pendingFeed.append(contentsOf: samples)
                if pendingFeed.count > Self.pendingFeedMax {
                    let excess = pendingFeed.count - Self.pendingFeedMax
                    pendingFeed.removeFirst(excess)
                    discardedFrames += Int64(excess)
                }
            }
            lock.unlock()
            return
        }
        if converter == nil, fmt != srcFormat {
            converter = AVAudioConverter(from: srcFormat, to: fmt)
        }
        let conv = converter
        fedFrames += Int64(samples.count)
        lock.unlock()

        guard let src = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = src.floatChannelData else { return }
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in
            ch[0].update(from: p.baseAddress!, count: samples.count)
        }
        guard let conv else {
            cont.yield(AnalyzerInput(buffer: src))
            return
        }
        let ratio = fmt.sampleRate / srcFormat.sampleRate
        let cap = AVAudioFrameCount(Double(samples.count) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return src
        }
        guard err == nil, out.frameLength > 0 else { return }
        cont.yield(AnalyzerInput(buffer: out))
    }

    private func ingest(_ piece: Piece, isFinal: Bool, gen: Int) {
        lock.lock()
        guard gen == generation else { lock.unlock(); return }
        let timedPiece = Piece(start: piece.start + analyzerOffset, end: piece.end + analyzerOffset,
                               text: piece.text, conf: piece.conf)
        if isFinal {
            finals.append(timedPiece)
            if finals.count > 120 { finals.removeFirst(finals.count - 120) }
            volatilePiece = nil
        } else {
            volatilePiece = piece.text.isEmpty ? nil : timedPiece
        }
        let cb = onUpdate
        lock.unlock()
        cb?()
    }
}
#endif
