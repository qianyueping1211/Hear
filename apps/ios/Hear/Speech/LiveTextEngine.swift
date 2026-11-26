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
    var onAudioLoss: (() -> Void)? { get set }
    /// 正在听的语言（Whisper 语言代码，例如 "zh"）
    var languageID: String? { get }
    /// 按某种语言开始听写；第一次使用某种语言时系统会先下载语言包
    func start(languageID: String, locale: String) async throws
    func stop() async
    /// 16kHz 单声道 Float 采样（音频线程调用）
    func feed(_ block: AudioInputBlock)
    /// 断句检测到第 id 句开始 / 结束（用来把识别结果对到这一句上）
    func markSegmentStart(_ id: Int, frame: Int64)
    func markSegmentEnd(_ id: Int, frame: Int64)
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
    var onAudioLoss: (() -> Void)?

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
    private var inputEndFrame: Int64?
    private var analyzerEnd: CMTime?
    private var finals: [Piece] = []
    private var volatilePiece: Piece?
    private var segs: [Int: (start: Double, end: Double?)] = [:]
    private var _languageID: String?
    private var generation = 0
    /// 还没启动好的时候收到的声音（先存着，等启动了补给它）
    /// 用户一开口就说的话，听写要下语言包、起引擎，那一下没收到就丢了
    private let inputQueue = DispatchQueue(label: "hear.apple-input")
    private var pendingFeed: [AudioInputBlock] = []
    private var pendingFrames = 0
    private var gaps: [Range<Int64>] = []
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
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(128))
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
            inputEndFrame = nil
            analyzerEnd = nil
            finals.removeAll()
            volatilePiece = nil
            _languageID = languageID
            let preRoll = pendingFeed
            pendingFeed = []
            pendingFrames = 0
            lock.unlock()

            for block in preRoll { deliver(block) }
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
        inputEndFrame = nil
        analyzerEnd = nil
        if a != nil {
            pendingFeed.removeAll()
            pendingFrames = 0
            gaps.removeAll()
        }
        lock.unlock()
        c?.finish()
        if let a { try? await a.cancelAndFinishNow() }
        t?.cancel()
    }

    func markSegmentStart(_ id: Int, frame: Int64) {
        lock.lock()
        segs[id] = (Double(frame) / 16_000, nil)
        for k in Array(segs.keys) where k < id - 20 { segs[k] = nil }
        lock.unlock()
    }

    func markSegmentEnd(_ id: Int, frame: Int64) {
        lock.lock()
        if let s = segs[id] { segs[id] = (s.start, Double(frame) / 16_000) }
        lock.unlock()
    }

    // 按时间重叠归属：避免系统听写把词时间戳稍微落在 VAD 预卷/尾音外、或合并尾音静音时把整句丢弃。
    private func belongs(_ piece: Piece, to segment: (start: Double, end: Double?)) -> Bool {
        guard let end = segment.end else {
            return piece.end >= segment.start - 0.25
        }
        let middle = (piece.start + piece.end) / 2
        if middle >= segment.start - 0.15 && middle <= end + 0.35 {
            return true
        }
        let overlap = min(piece.end, end + 0.25) - max(piece.start, segment.start - 0.25)
        let dur = max(0.05, piece.end - piece.start)
        return overlap >= min(0.3, dur * 0.5)
    }

    private func hasGap(_ segment: (start: Double, end: Double?)) -> Bool {
        gaps.contains { Double($0.upperBound) / 16_000 > segment.start
                        && Double($0.lowerBound) / 16_000 < (segment.end ?? .infinity) }
    }

    func segmentText(_ id: Int) -> (text: String, confidence: Double) {
        lock.lock(); defer { lock.unlock() }
        guard let seg = segs[id] else { return ("", 0) }
        var pieces = finals.filter { belongs($0, to: seg) }
        if let v = volatilePiece, belongs(v, to: seg) { pieces.append(v) }
        let cjk = ["zh", "ja", "ko"].contains(_languageID ?? "")
        let joined = pieces.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: cjk ? "" : " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = Fillers.clean(joined)          // 去掉单独的语气词（嗯、啊、um…）
        if text.isEmpty, let segEnd = seg.end {
            let lf = finals.last.map { String(format: "%.2f..%.2f(%d字)", $0.start, $0.end, $0.text.count) } ?? "nil"
            let vp = volatilePiece.map { String(format: "%.2f..%.2f(%d字)", $0.start, $0.end, $0.text.count) } ?? "nil"
            hearLog(String(format: "系统听写空结果(%@)：seg=%.2f..%.2f finals=%d lastFinal=%@ volatile=%@ gaps=%d",
                           _languageID ?? "?", seg.start, segEnd, finals.count, lf, vp, gaps.count), .warning)
        }
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
        if let volatilePiece, belongs(volatilePiece, to: segment) {
            return false
        }
        // VAD marks the end after its silence window, which is not part of the transcribed range.
        return finals.contains { belongs($0, to: segment) && $0.end >= end - 0.8 }
    }

    func feed(_ block: AudioInputBlock) {
        inputQueue.sync { deliver(block) }
    }

    /// Caller holds lock. Merge adjacent losses and bound diagnostic state.
    private func recordGap(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        if let last = gaps.last, last.upperBound == range.lowerBound {
            gaps[gaps.count - 1] = last.lowerBound..<range.upperBound
        } else {
            gaps.append(range)
            if gaps.count > 32 { gaps.removeFirst() }
        }
    }

    private func deliver(_ block: AudioInputBlock) {
        let samples = block.samples
        guard !samples.isEmpty else { return }
        lock.lock()
        // 仅在已经收到过前一帧且中间发生跳跃时才记为断帧；
        // 新建引擎首次接入非零时间轴（例如停止后重开或切换语言）不应误记 0..<startFrame 为缺口。
        if let expected = inputEndFrame, block.startFrame > expected {
            recordGap(expected..<block.startFrame)
            converter = nil
        } else if let expected = inputEndFrame, block.startFrame < expected {
            // A previous capture's queued buffer arrived after a new generation.
            lock.unlock()
            return
        }
        inputEndFrame = block.endFrame
        guard let cont = input, let fmt = format else {
            pendingFeed.append(block)
            pendingFrames += samples.count
            while pendingFrames > Self.pendingFeedMax {
                let dropped = pendingFeed.removeFirst()
                pendingFrames -= dropped.samples.count
                recordGap(dropped.startFrame..<dropped.endFrame)
            }
            lock.unlock()
            return
        }
        if converter == nil, fmt != srcFormat {
            converter = AVAudioConverter(from: srcFormat, to: fmt)
        }
        let conv = converter
        let generation = self.generation
        let start = CMTime(value: block.startFrame, timescale: 16_000)
        let timestamp = analyzerEnd.map { CMTimeMaximum($0, start) } ?? start
        lock.unlock()

        var delivered = false
        defer {
            if !delivered {
                lock.lock()
                if generation == self.generation { recordGap(block.startFrame..<block.endFrame) }
                let stillActive = generation == self.generation
                lock.unlock()
                if stillActive { onAudioLoss?() }
            }
        }
        func submit(_ buffer: AVAudioPCMBuffer) {
            let duration = CMTime(value: Int64(buffer.frameLength),
                                  timescale: Int32(buffer.format.sampleRate))
            if case .enqueued = cont.yield(AnalyzerInput(buffer: buffer, bufferStartTime: timestamp)) {
                lock.lock()
                if generation == self.generation { analyzerEnd = CMTimeAdd(timestamp, duration) }
                lock.unlock()
                delivered = true
            }
        }
        guard let src = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = src.floatChannelData else { return }
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in
            ch[0].update(from: p.baseAddress!, count: samples.count)
        }
        guard let conv else {
            submit(src)
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
        submit(out)
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
