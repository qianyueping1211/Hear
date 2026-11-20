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
    /// 引擎启动时的"会话停用代数"（只在 queue 上读写）
    private var engineGen = -1
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
        // 换了输出设备（插拔耳机、连上蓝牙）以后，引擎还锁在老路由上，
        // 下次播之前要重新接一次
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
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
        // 重新激活音频会话会把"输出到哪"重置掉（setCategory 会清掉 override），
        // 这里再应用一次，保证声音真的从耳机出来
        try? AudioRoute.activate()
        AudioRoute.apply(AudioRoute.lastOutput)
        guard !samples.isEmpty else { return false }
        // 采样率是 0 的话下面算时长会除出无穷大，Dispatch 会直接崩，这里兜一下
        let sr = sampleRate > 0 ? sampleRate : 24_000

        // 音量过小的话听起来像没声音，放大到能听见的水平
        var boosted = samples
        var pk: Float = 0
        for v in boosted { let a = abs(v); if a > pk { pk = a } }
        if pk > 0.0005, pk < 0.5 {
            let g = 0.85 / pk
            for i in boosted.indices { boosted[i] *= g }
        }
        let out = boosted
        let peak = pk

        let gen: Int = queue.sync {
            generation += 1
            scheduled = 0; played = 0; finished = true
            currentPan = pan
            usingEngine = true
            current = nil
            playStarted = false
            return generation
        }
        let limit = 5 + Double(samples.count) / sr * 1.5
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.sync { continuation = c }
            queue.async { [self] in
                guard gen == generation else { return }
                // 一定要按硬件当前的输出格式来播：耳机是 44.1k、手机是 48k，
                // 蓝牙通话模式还是单声道。格式对不上，引擎就起不来（一片安静）。
                guard let hw = ensureEngine() else {
                    hearLog("朗读：克隆声音的音频引擎启动失败", .error)
                    self.resume(gen)
                    return
                }
                guard let buf = Self.makeBuffer(samples: out, sampleRate: sr, target: hw) else {
                    hearLog("朗读：克隆声音的缓冲区创建失败", .error)
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
            hearLog("朗读：克隆声音 \(String(format: "%.1f", Double(samples.count) / sr)) 秒，\(Int(sr)) Hz，峰值 \(String(format: "%.2f", peak))")
        }
        return started
    }

    /// 现在有没有在出声（用来判断能不能放开麦克风）
    var isPlaying: Bool {
        if synth.isSpeaking { return true }
        return player.isPlaying
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
            // 同样转成硬件的输出格式再放
            guard let hw = ensureEngine() else { return }
            guard let target = Self.convert(f, to: hw) else { return }
            scheduled += 1
            player.scheduleBuffer(target, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async {
                    guard let self, gen == self.generation else { return }
                    self.played += 1
                    self.checkDone(gen)
                }
            }
            if !player.isPlaying { player.play() }
        }
    }

    /// 硬件当前的输出格式。
    /// 耳机（蓝牙 44.1k、有线 48k）和手机扬声器（48k）都不一样，
    /// 换成别的设备还会再变一次，所以每次播之前都要重新问一遍。
    private func hardwareFormat() -> AVAudioFormat {
        let f = engine.outputNode.outputFormat(forBus: 0)
        if f.sampleRate > 0, f.channelCount > 0 { return f }
        // 引擎还没准备好的时候，输出节点给不出格式，用音频会话的来兜底
        let s = AVAudioSession.sharedInstance()
        let rate = s.sampleRate > 0 ? s.sampleRate : 48_000
        // 声道数从当前输出路由里拿（耳机/扬声器/蓝牙都不一样）
        let ch = max(s.currentRoute.outputs.first?.channels?.count ?? 2, 1)
        return AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(ch))!
    }

    /// 接上播放节点并启动引擎。
    /// 返回硬件当前的输出格式（播放的缓冲区必须和它一模一样，不然放不出声音），
    /// 启动失败返回 nil。
    private func ensureEngine() -> AVAudioFormat? {
        // 重新激活音频会话会把"输出到哪"重置掉（setCategory 会清掉 override），
        // 这里再应用一次，保证声音真的从耳机出来
        try? AudioRoute.activate()
        AudioRoute.apply(AudioRoute.lastOutput)
        let hw = hardwareFormat()
        if connectedFormat == nil
            || connectedFormat!.sampleRate != hw.sampleRate
            || connectedFormat!.channelCount != hw.channelCount {
            if engine.isRunning { engine.stop() }
            // 已经接过一次的话要先断开，否则重复连接会出问题
            if connectedFormat != nil { engine.disconnectNodeOutput(player) }
            engine.connect(player, to: engine.mainMixerNode, format: hw)
            connectedFormat = hw
        }
        player.pan = currentPan
        // 音频会话被停用过的话（停止实时翻译以后放开了麦克风），
        // 系统会把播放引擎也打断，得重新起一次才有声音
        let gen = AudioRoute.deactivateGeneration
        if !engine.isRunning || engineGen != gen {
            engine.stop()
            engine.prepare()
            do {
                try engine.start()
            } catch {
                hearLog("朗读：音频引擎启动失败 \(error)", .error)
                return nil
            }
            engineGen = gen
        }
        return engine.isRunning ? hw : nil
    }

    private func checkDone(_ gen: Int) {
        guard finished, played >= scheduled else { return }
        if scheduled == 0 { hearLog("朗读：系统语音没有生成声音（可能没有安装该语言的语音）", .warning) }
        resume(gen)
    }

    /// 一段单声道的声音 → 硬件要的格式（采样率、声道数都可能变）
    private static func makeBuffer(samples: [Float], sampleRate: Double,
                                   target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let src = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = inBuf.floatChannelData else { return nil }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in
            if let base = p.baseAddress { ch[0].update(from: base, count: samples.count) }
        }
        return convert(inBuf, to: target)
    }

    /// 任意格式 → 目标格式（顺便做重采样和声道转换）
    private static func convert(_ src: AVAudioPCMBuffer, to dst: AVAudioFormat) -> AVAudioPCMBuffer? {
        if src.format.sampleRate == dst.sampleRate,
           src.format.channelCount == dst.channelCount,
           src.format.commonFormat == dst.commonFormat {
            return src
        }
        guard let conv = AVAudioConverter(from: src.format, to: dst) else { return nil }
        let ratio = dst.sampleRate / src.format.sampleRate
        let cap = AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap) else { return nil }
        var consumed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return src
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
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
