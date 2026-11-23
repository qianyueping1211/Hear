import AVFoundation

/// 一次朗读请求
struct SpeakRequest {
    var text: String
    var locale: String
    var voice: AVSpeechSynthesisVoice? = nil
    var pitch: Float = 1.0      // 0.5 ~ 2.0
    var pan: Float = 0          // -1 只在左耳，0 两耳，1 只在右耳
}

/// 播一段已经生成好的声音，结果分三种。
enum PlayOutcome {
    case played      // 正常播了
    case failed     // 起不来（引擎、缓冲区的问题）
    case cancelled  // 被人停了（用户停了朗读、或者切到后台）
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
    /// 因为超时被作废的那一代（只在 queue 上读写）。
    /// 超时和"被人停掉"要分开：超时算失败（可以退回系统声音），
    /// 被人停掉算取消（千万别再出声）。
    private var timedOutGen: Int?
    /// 引擎启动时的"会话停用代数"（只在 queue 上读写）
    private var engineGen = -1
    private var currentPan: Float = 0
    private var emittingAudio = false {
        didSet {
            if oldValue != emittingAudio { onAudioActivityChanged?() }
        }
    }

    var isEmittingAudio: Bool { queue.sync { emittingAudio } }
    var onAudioActivityChanged: (() -> Void)?

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
        // 只是放声音：会话用 .playback，不占麦克风
        // （占着麦克风的话，手机上录屏、录音机就录不到了）
        AudioRoute.speaking = true
        // 收音期间不动会话，防止打断正在运行的麦克风
        if !AudioRoute.capturing { try? AudioRoute.updateSession() }
        let u = AVSpeechUtterance(string: req.text)
        u.voice = req.voice ?? Self.bestVoice(for: req.locale)
        u.pitchMultiplier = req.pitch
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        let engineMode = req.pan != 0

        // 超时：按字数估一个很宽松的时长
        let limit = 5 + Double(req.text.count) * 0.45
        var gen = 0

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            // 递增代数、重置状态与安装 continuation 合并到同一同步队列块，消除间隙内 stop() 导致挂起
            gen = queue.sync {
                generation += 1
                scheduled = 0; played = 0; finished = false
                currentPan = req.pan
                usingEngine = engineMode
                current = u
                timedOutGen = nil
                continuation = c
                return generation
            }
            let currentGen = gen
            if engineMode {
                synth.write(u) { [weak self] buffer in
                    self?.receive(buffer, gen: currentGen)
                }
            } else {
                synth.speak(u)
            }
            queue.asyncAfter(deadline: .now() + limit) { [weak self] in
                guard let self, currentGen == self.generation, self.continuation != nil else { return }
                hearLog("朗读：超过 \(Int(limit)) 秒没有结束，自动跳过", .warning)
                // 先把等待方叫醒（作废会把代数改掉，顺序反了 resume 就叫不醒了），
                // 再把这一次播放作废、声音停掉。
                self.resume(currentGen)
                self.stopPlayback(gen: currentGen, timedOut: true)
            }
        }
        // 仅当本次朗读仍是最新一代时才清理 speaking 并回调停用会话，防止旧播报截断新播报
        let stillCurrent = queue.sync { gen == generation }
        guard stillCurrent else { return }
        AudioRoute.speaking = false
        // 还在收音的时候不要动音频会话：改会话类别/路由会把正在跑的麦克风打断，
        // 麦克风一断，后面的话就再也识别不到了（以前就是这样：读一句、断一句）。
        if !AudioRoute.capturing { try? AudioRoute.updateSession() }
        stopEngineIfIdle()
        onPlaybackFinished?()
    }

    /// 播放一段已经生成好的声音（声音克隆朗读用），播完（或被 stop 打断）后返回。
    /// 返回 .failed 表示没能播出来（引擎起不来之类），调用方可以退回系统声音；
    /// 返回 .cancelled 表示这次是被停掉的——这时候千万别再出声。
    func play(samples: [Float], sampleRate: Double, pan: Float) async -> PlayOutcome {
        let sr = (8_000...96_000).contains(sampleRate) ? sampleRate : 24_000
        guard let level = CloneAudio(samples: samples, sampleRate: Int(sr)).playbackGain() else {
            hearLog("朗读：克隆音频没有持续可用的声音", .warning)
            return .failed
        }
        stop()
        // 重新激活音频会话会把"输出到哪"重置掉（setCategory 会清掉 override），
        // 这里再应用一次，保证声音真的从耳机出来
        // 只是放声音：不占麦克风
        AudioRoute.speaking = true
        // 收音的时候不动会话：会话一改，正在跑的麦克风会被打断
        if !AudioRoute.capturing { try? AudioRoute.updateSession() }
        AudioRoute.apply(AudioRoute.lastOutput)
        let out = level.gain == 1 ? samples : samples.map { $0 * level.gain }
        let peak = level.peak

        let gen: Int = queue.sync {
            generation += 1
            scheduled = 0; played = 0; finished = true
            currentPan = pan
            usingEngine = true
            current = nil
            playStarted = false
            timedOutGen = nil
            return generation
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard gen == generation else { c.resume(); return }
                continuation = c
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
                player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    self?.queue.async {
                        guard let self, gen == self.generation, self.continuation != nil else { return }
                        if self.playStarted || (self.engine.isRunning && self.player.isPlaying) {
                            self.finishClonePlayback(gen)
                        } else {
                            self.failClonePlayback(gen, reason: "音频输出未启动")
                        }
                    }
                }
                if !player.isPlaying { player.play() }
                let session = AVAudioSession.sharedInstance()
                let tailLatency = max(0.05, session.outputLatency + session.ioBufferDuration * 2 + 0.05)
                observeClonePlayback(gen, frames: AVAudioFramePosition(buf.frameLength), tailLatency: tailLatency,
                                     lastFrame: 0, lastProgress: .now)
            }
        }
        // 结果分三种：正常播了 / 超时或起不来（失败，可以退回系统声音）/
        // 被人中途停掉（取消，千万别再出声）
        let outcome: PlayOutcome = queue.sync {
            if timedOutGen == gen {
                AudioRoute.speaking = false
                return .failed
            }
            if gen != generation { return .cancelled }
            AudioRoute.speaking = false
            return playStarted ? .played : .failed
        }
        let started = outcome == .played
        if started {
            hearLog("朗读：克隆声音 \(String(format: "%.1f", Double(samples.count) / sr)) 秒，\(Int(sr)) Hz，峰值 \(String(format: "%.2f", peak))")
        }
        if outcome != .cancelled {
            if !AudioRoute.capturing { try? AudioRoute.updateSession() }
            stopEngineIfIdle()
            onPlaybackFinished?()
        }
        return outcome
    }

    /// Observe the player timeline; isPlaying alone only means it has been commanded to start.
    /// Only the speaker queue calls this method.
    private func observeClonePlayback(_ gen: Int, frames: AVAudioFramePosition, tailLatency: TimeInterval,
                                      lastFrame: AVAudioFramePosition, lastProgress: ContinuousClock.Instant) {
        guard gen == generation, continuation != nil else { return }
        let now = ContinuousClock.now
        let time = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }
        let frame = time.flatMap { $0.isSampleTimeValid ? $0.sampleTime : nil } ?? 0
        let advanced = frame > lastFrame
        if advanced && !playStarted {
            playStarted = true
            emittingAudio = true
        }
        if frame >= frames {
            // Prefer the device completion callback. Use the route's presentation latency
            // as a fallback when the buffer rendered but its callback is late or missing.
            queue.asyncAfter(deadline: .now() + tailLatency) { [weak self] in
                self?.finishClonePlayback(gen)
            }
            return
        }
        if !advanced, lastProgress.duration(to: now) > .seconds(1.2 + tailLatency) {
            failClonePlayback(gen, reason: playStarted ? "音频输出已停滞" : "音频输出未启动")
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
            self?.observeClonePlayback(gen, frames: frames, tailLatency: tailLatency,
                                       lastFrame: max(frame, lastFrame), lastProgress: advanced ? now : lastProgress)
        }
    }

    private func finishClonePlayback(_ gen: Int) {
        guard gen == generation, continuation != nil else { return }
        playStarted = true
        resume(gen)
        player.stop()
    }

    private func failClonePlayback(_ gen: Int, reason: String) {
        hearLog("朗读：克隆声音\(reason)，尝试使用系统声音", .warning)
        resume(gen)
        stopPlayback(gen: gen, timedOut: true)
    }

    /// 现在有没有在出声（用来判断能不能放开麦克风）
    var isPlaying: Bool {
        if synth.isSpeaking { return true }
        return player.isPlaying
    }

    /// 立即停止当前朗读
    func stop() {
        queue.sync {
            generation += 1
            current = nil
            if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
            player.stop()
            emittingAudio = false
            let c = continuation
            continuation = nil
            c?.resume()
        }
        AudioRoute.speaking = false
        stopEngineIfIdle()
    }

    /// 停一会儿以后把播放引擎也停掉。
    /// 引擎一直开着就会一直占着音频输出：别的 App 放声音会跟我们互相干扰，
    /// 录屏里的声音也容易出现杂音。
    private func stopEngineIfIdle() {
        queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            guard !self.synth.isSpeaking, !self.player.isPlaying else { return }
            // 还在收音的时候别停：停引擎会让系统重新配置音频路由，
            // 正在跑的麦克风会被打断，实时翻译就再也听不到下一句了。
            guard !AudioRoute.capturing else { return }
            self.engine.stop()
        }
    }

    /// 播放结束/被打断以后叫醒外面：外面好知道"现在没在出声了"，
    /// 可以考虑放开麦克风（不然音频会话一直占着）。
    var onPlaybackFinished: (() -> Void)?

    /// 把这一次播放作废：声音停掉、后面的缓冲回调也作废。
    ///
    /// 只能在 queue 上调用。
    ///
    /// **代数要改**：单耳朗读是用 synth.write 合成声音的，
    /// 合成是异步的——超时以后迟到的缓冲还会送过来。
    /// 不作废这一代，那些缓冲照样进播放器，声音就又冒出来了。
    /// 超时和"被人停掉"用 timedOutGen 分开：
    /// 超时算失败（外面可以退回系统声音），被停掉算取消（千万别再出声）。
    private func stopPlayback(gen: Int, timedOut: Bool = false) {
        guard gen == generation else { return }
        if timedOut { timedOutGen = gen }
        generation += 1
        current = nil
        playStarted = false
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        player.stop()
        player.reset()
    }

    /// 在 queue 上调用
    private func resume(_ gen: Int) {
        guard gen == generation else { return }
        emittingAudio = false
        let c = continuation
        continuation = nil
        c?.resume()
    }

    // MARK: - speak() 方式的回调

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        queue.async { [self] in
            guard !usingEngine, utterance === current, continuation != nil else { return }
            emittingAudio = true
        }
    }

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
            emittingAudio = player.isPlaying
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
        AudioRoute.speaking = true
        // 收音的时候不要重新激活会话：会话一改，正在跑的麦克风会被打断，
        // 麦克风一断就再也听不到下一句了。
        if !AudioRoute.capturing { try? AudioRoute.updateSession() }
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
        guard played >= scheduled else { return }
        emittingAudio = false
        guard finished else { return }
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
