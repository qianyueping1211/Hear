import Foundation
import AVFoundation
import CoreMedia
import Speech

/// 说话时“逐字显示原文”的引擎（目前是 iOS 26 自带的系统听写）。
/// 只负责实时显示；一句话说完后仍由 Whisper 做最终识别和语言判断。
protocol LiveTextEngine: AnyObject {
    /// 有新的识别结果（在任意线程回调）；用 segmentText 取某一句的文字
    var onUpdate: (() -> Void)? { get set }
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

    private let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16_000, channels: 1, interleaved: false)!

    var languageID: String? { lock.lock(); defer { lock.unlock() }; return _languageID }

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

        lock.lock()
        generation += 1
        let gen = generation
        self.analyzer = analyzer
        self.input = continuation
        self.format = fmt
        self.converter = nil
        self.fedFrames = 0
        self.finals.removeAll()
        self.volatilePiece = nil
        self.segs.removeAll()
        self._languageID = languageID
        lock.unlock()

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

    private var now: Double { Double(fedFrames) / 16_000 }

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

    func feed(_ samples: [Float]) {
        lock.lock()
        guard let cont = input, let fmt = format, !samples.isEmpty else { lock.unlock(); return }
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
        if isFinal {
            finals.append(piece)
            if finals.count > 120 { finals.removeFirst(finals.count - 120) }
            volatilePiece = nil
        } else {
            volatilePiece = piece.text.isEmpty ? nil : piece
        }
        let cb = onUpdate
        lock.unlock()
        cb?()
    }
}
#endif
