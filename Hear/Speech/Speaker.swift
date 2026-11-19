import AVFoundation

/// 一次朗读请求
struct SpeakRequest {
    var text: String
    var locale: String
    var voice: AVSpeechSynthesisVoice? = nil
    var pitch: Float = 1.0      // 0.5 ~ 2.0
    var pan: Float = 0          // -1 只在左耳，0 两耳，1 只在右耳
}

/// 朗读译文。
/// - 两耳都播（pan = 0）：直接用 AVSpeechSynthesizer.speak，最稳定
/// - 只在左耳或右耳（pan ≠ 0）：先生成语音数据，再用 AVAudioEngine 按左右声道播放
/// 两种方式都有超时保护：系统语音没有回调时也会结束，不会卡住后面的流程。
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "hear.speaker")

    // 以下状态只在 queue 上读写
    private var continuation: CheckedContinuation<Void, Never>?
    private var generation = 0
    private var scheduled = 0
    private var played = 0
    private var finished = false
    private var usingEngine = false
    private var current: AVSpeechUtterance?
    private var connectedFormat: AVAudioFormat?
    /// 这次播放有没有真的开始（只在 queue 上读写）
    private var playStarted = false
    private var currentPan: Float = 0

    override init() {
        super.init()
        synth.delegate = self
        engine.attach(player)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.connectedFormat = nil }
        }
    }

    /// 朗读一段文字，读完（或被 stop 打断）后返回
    func speak(_ req: SpeakRequest) async {
        stop()
        try? AudioRoute.activate()
        let u = AVSpeechUtterance(string: req.text)
        u.voice = req.voice ?? Self.bestVoice(for: req.locale)
        u.pitchMultiplier = req.pitch
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        let engineMode = req.pan != 0

        let gen: Int = queue.sync {
            generation += 1
            scheduled = 0; played = 0; finished = false
            currentPan = req.pan
            usingEngine = engineMode
            current = u
            return generation
        }
        // 超时：按字数估一个很宽松的时长
        let limit = 5 + Double(req.text.count) * 0.45

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.sync { continuation = c }
            if engineMode {
                synth.write(u) { [weak self] buffer in
                    self?.receive(buffer, gen: gen)
                }
            } else {
                synth.speak(u)
            }
            queue.asyncAfter(deadline: .now() + limit) { [weak self] in
                guard let self, gen == self.generation, self.continuation != nil else { return }
                hearLog("朗读：超过 \(Int(limit)) 秒没有结束，自动跳过", .warning)
                self.resume(gen)
            }
        }
    }

    /// 播放一段已经生成好的声音（声音克隆朗读用），播完（或被 stop 打断）后返回。
    /// 返回 false 表示没能播出来（引擎起不来之类），调用方可以退回系统声音。
    func play(samples: [Float], sampleRate: Double, pan: Float) async -> Bool {
        stop()
        try? AudioRoute.activate()
        guard !samples.isEmpty else { return false }

        // 接到主混音器上的话，输入声道数要跟主混音器一致（一般是双声道）。
        // 用单声道格式接上去，有的系统版本会直接拒掉，放出来就是一片安静。
        let outFmt = engine.outputNode.outputFormat(forBus: 0)
        let channels = max(Int(outFmt.channelCount), 2)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                      channels: AVAudioChannelCount(channels)),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData else {
            hearLog("朗读：克隆声音的缓冲区创建失败", .error)
            return false
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in
            if let base = p.baseAddress {
                for c in 0..<channels { ch[c].update(from: base, count: samples.count) }
            }
        }
        // 音量过小的话听起来像没声音，放大到能听见的水平
        var peak: Float = 0
        for v in samples { let a = abs(v); if a > peak { peak = a } }
        if peak > 0.0005, peak < 0.5 {
            let g = 0.85 / peak
            for c in 0..<channels {
                for i in 0..<samples.count { ch[c][i] *= g }
            }
        }

        let gen: Int = queue.sync {
            generation += 1
            scheduled = 0; played = 0; finished = true
            currentPan = pan
            usingEngine = true
            current = nil
            playStarted = false
            return generation
        }
        let limit = 5 + Double(samples.count) / sampleRate * 1.5
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.sync { continuation = c }
            queue.async { [self] in
                guard gen == generation else { return }
                if !ensureEngine(format: fmt) {
                    hearLog("朗读：克隆声音的音频引擎启动失败", .error)
                    self.resume(gen)
                    return
                }
                self.playStarted = true
                scheduled = 1
                player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    self?.queue.async {
                        guard let self, gen == self.generation else { return }
                        self.played += 1
                        self.checkDone(gen)
                    }
                }
                if !player.isPlaying { player.play() }
            }
            queue.asyncAfter(deadline: .now() + limit) { [weak self] in
                guard let self, gen == self.generation, self.continuation != nil else { return }
                hearLog("朗读：克隆声音播放超时，自动跳过", .warning)
                self.resume(gen)
            }
        }
        let started = queue.sync { playStarted }
        if started {
            hearLog("朗读：克隆声音 \(String(format: "%.1f", Double(samples.count) / sampleRate)) 秒，\(Int(sampleRate)) Hz，峰值 \(String(format: "%.2f", peak))")
        }
        return started
    }

    /// 立即停止当前朗读
    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        player.stop()
        queue.sync {
            generation += 1
            current = nil
            let c = continuation
            continuation = nil
            c?.resume()
        }
    }

    /// 在 queue 上调用
    private func resume(_ gen: Int) {
        guard gen == generation else { return }
        let c = continuation
        continuation = nil
        c?.resume()
    }

    // MARK: - speak() 方式的回调

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        queue.async { [self] in
            guard !usingEngine, utterance === current else { return }
            resume(generation)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        queue.async { [self] in
            guard !usingEngine, utterance === current else { return }
            resume(generation)
        }
    }

    // MARK: - write() 方式：按左右声道播放

    private func receive(_ buffer: AVAudioBuffer, gen: Int) {
        queue.async { [self] in
            guard gen == generation, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {          // 生成结束
                finished = true
                checkDone(gen)
                return
            }
            guard let f = Self.toFloat(pcm) else { return }
            ensureEngine(format: f.format)
            scheduled += 1
            player.scheduleBuffer(f, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async {
                    guard let self, gen == self.generation else { return }
                    self.played += 1
                    self.checkDone(gen)
                }
            }
            if !player.isPlaying { player.play() }
        }
    }

    /// 接上播放节点并启动引擎。返回 false 表示没启动起来
    @discardableResult
    private func ensureEngine(format: AVAudioFormat) -> Bool {
        if connectedFormat == nil
            || connectedFormat!.sampleRate != format.sampleRate
            || connectedFormat!.channelCount != format.channelCount {
            if engine.isRunning { engine.stop() }
            // 已经接过一次的话要先断开，否则重复连接会出问题
            if connectedFormat != nil { engine.disconnectNodeOutput(player) }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        player.pan = currentPan
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                hearLog("朗读：音频引擎启动失败 \(error)", .error)
                return false
            }
        }
        return engine.isRunning
    }

    private func checkDone(_ gen: Int) {
        guard finished, played >= scheduled else { return }
        if scheduled == 0 { hearLog("朗读：系统语音没有生成声音（可能没有安装该语言的语音）", .warning) }
        resume(gen)
    }

    /// 语音合成输出可能是 Int16，播放器需要 Float32
    private static func toFloat(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if pcm.format.commonFormat == .pcmFormatFloat32 && !pcm.format.isInterleaved { return pcm }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: pcm.format.sampleRate,
                                      channels: pcm.format.channelCount),
              let conv = AVAudioConverter(from: pcm.format, to: fmt),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: pcm.frameLength) else { return nil }
        do { try conv.convert(to: out, from: pcm) } catch { return nil }
        return out
    }

    // MARK: - 选择声音

    /// 选已安装的最高音质声音；可指定男声/女声
    static func bestVoice(for locale: String, gender: AVSpeechSynthesisVoiceGender? = nil) -> AVSpeechSynthesisVoice? {
        let prefix = String(locale.prefix(2))
        let all = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isPersonalVoice) && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        let exact = all.filter { $0.language == locale }
        var pool = exact.isEmpty ? all.filter { $0.language.hasPrefix(prefix) } : exact
        if let gender {
            let g = pool.filter { $0.gender == gender }
            if !g.isEmpty { pool = g }
        }
        return pool.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: locale)
    }

    /// 用户在 iPhone“设置 → 辅助功能 → 个人声音”里录制的声音
    static func personalVoice(for locale: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(locale.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().first {
            $0.voiceTraits.contains(.isPersonalVoice) && $0.language.hasPrefix(prefix)
        }
    }

    static var hasAnyPersonalVoice: Bool { !personalVoices.isEmpty }

    static var personalVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.voiceTraits.contains(.isPersonalVoice) }
    }

    /// 已经授权就直接返回，不再弹窗；否则请求授权
    static func requestPersonalVoiceAccess() async -> Bool {
        if AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized { return true }
        let status: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus = await withCheckedContinuation { c in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { c.resume(returning: $0) }
        }
        hearLog("个人声音授权结果：\(status.rawValue)")
        return status == .authorized
    }

    /// 刚授权时系统的声音列表可能还没刷新：最多等 3 秒再找
    static func findPersonalVoices() async -> [AVSpeechSynthesisVoice] {
        for _ in 0..<10 {
            let v = personalVoices
            if !v.isEmpty { return v }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return personalVoices
    }
}
