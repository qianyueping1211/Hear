import AVFoundation

/// 麦克风采集 → 重采样到 16kHz 单声道 → 交给 Segmenter 断句
///
/// - 输出路由改变（扬声器/耳机切换、插拔耳机）时，系统会重配音频引擎、麦克风格式也可能变；
///   这里会自动重新接上麦克风，并按实际格式重采样，避免收到变速的“乱码”声音。
/// - 可选“语音增强”：系统自带的回声消除 + 降噪 + 自动增益（和 FaceTime 同一套）。
///
/// 两条铁律（都是踩过坑才定下来的）：
/// 1. **动引擎的活儿全排在 engineQueue 上**：挂 tap、停引擎、重新接麦克风。
///    以前挂 tap 在主线程、停引擎在后台线程，两边同时动同一个输入节点，
///    结果是"引擎在跑却没有声音"——界面还显示正在聆听，其实麦克风早就哑了。
/// 2. **麦克风必须能自己恢复**：接不上就重试，还接不上就看门狗隔几秒再试，
///    绝不能悄悄哑掉（用户只能把实时翻译关掉再打开才恢复）。
final class AudioCapture {
    let segmenter = Segmenter()
    private lazy var speechDetector = SileroSpeechDetector()
    enum Health: Equatable { case normal, backlogged, reconnecting }
    var onHealthChanged: ((Health) -> Void)?

    /// 语音增强（降噪、回声消除）。下次开始聆听时生效
    var voiceProcessing = true

    /// 同时把 16kHz 采样交给系统听写（音频线程调用；静音时给的是静音采样）
    private var _onSamples: ((AudioInputBlock) -> Void)?
    var onSamples: ((AudioInputBlock) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onSamples }
        set { lock.lock(); _onSamples = newValue; lock.unlock() }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?          // 只在音频线程里读写
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16_000, channels: 1, interleaved: false)!
    private let queue = DispatchQueue(label: "hear.audio.segmenter")
    /// 送样本给别的识别引擎用（不在音频线程上做）
    private let feedQueue = DispatchQueue(label: "hear.audio.feed", qos: .userInitiated)
    /// 停止音频引擎放在后台做：戴蓝牙耳机时，关麦克风会让系统把耳机从通话模式切回音乐模式，
    /// 要好几百毫秒，放在主线程会让界面（例如切换模式的动画）卡住
    private let engineQueue = DispatchQueue(label: "hear.audio.engine", qos: .userInitiated)
    private let lock = NSLock()
    private var _muted = false
    private var running = false
    private var pendingStart: Int?
    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }
    private var configObserver: NSObjectProtocol?

    // MARK: - 麦克风"活着"的自我检测（下面这些都只在 engineQueue 上读写）

    /// tap 是否已经挂在输入节点上
    private var tapInstalled = false
    /// 挂 tap 时的输入格式：路由没变就别白折腾一次（折腾有可能把正在用的 tap 弄掉）
    private var installedFormat: (rate: Double, ch: AVAudioChannelCount) = (0, 0)
    /// 正在重新接麦克风，别重入
    private var rearming = false
    /// 看门狗定时器
    private var watchdog: DispatchSourceTimer?
    /// 系统中断中（来电、别的 App 抢音频）：这时候别去折腾麦克风
    private var interrupted = false
    /// 连续几次没收到声音（看门狗每 3 秒数一次）
    private var silentTicks = 0

    // MARK: - 收尾用的小账本（跨线程读写，走 lock）

    private var _gen = 0
    /// 每开一次麦换一个号：收尾的时候好知道"这一轮已经有人接手了"
    private var gen: Int { lock.lock(); defer { lock.unlock() }; return _gen }
    private func requestStart() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !running, pendingStart == nil else { return nil }
        _gen += 1
        pendingStart = _gen
        speechFeed.removePending()
        lastOverflowAt = nil
        return _gen
    }

    private func finishStart(_ round: Int, running: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pendingStart == round else { return false }
        pendingStart = nil
        self.running = running
        return true
    }

    private func requestStop() -> (wasRunning: Bool, round: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard running || pendingStart != nil else { return nil }
        let wasRunning = running
        if pendingStart != nil { _gen += 1 }
        pendingStart = nil
        running = false
        return (wasRunning, _gen)
    }

    private var hasCaptureIntent: Bool {
        lock.lock(); defer { lock.unlock() }
        return running || pendingStart != nil
    }

    private func acceptsAudio(for round: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _gen == round && (running || pendingStart == round)
    }

    private var _lastSample = Date()
    /// 最近一次收到声音的时间（看门狗用它判断麦克风是不是哑了）
    private var lastSampleAt: Date {
        get { lock.lock(); defer { lock.unlock() }; return _lastSample }
        set { lock.lock(); _lastSample = newValue; lock.unlock() }
    }

    private var _lastDelivered = Date()
    /// 送进识别队列、还没被消费的声音块数。
    /// 积压说明"麦克风是好的，但识别那边不消费了"——
    /// 这跟"麦克风断了"是两回事，不能混在一起说。
    private struct CaptureBlock {
        let audio: AudioInputBlock
        let muted: Bool
    }

    // Keep one timeline across route restarts. A live speech analyzer can
    // outlive an AVAudioEngine restart in the same conversation.
    private var inputPosition: Int64 = 0
    private var speechFeed = AudioInputBuffer<(CaptureBlock, (AudioInputBlock) -> Void)>(capacity: 48_000)
    private var segmentFeed = AudioInputBuffer<CaptureBlock>(capacity: 80_000)
    private var lastOverflowAt: Date?
    private var health: Health = .normal

    private var isBacklogged: Bool {
        lock.lock(); defer { lock.unlock() }
        let recentlyDropped = lastOverflowAt.map { Date().timeIntervalSince($0) < 5 } ?? false
        return recentlyDropped || speechFeed.frames > 32_000 || segmentFeed.frames > 64_000
    }

    func noteSpeechInputLoss() {
        lock.lock()
        lastOverflowAt = Date()
        lock.unlock()
    }

    private func enqueue(_ samples: [Float], round: Int) {
        lock.lock(); defer { lock.unlock() }
        guard _gen == round, running || pendingStart == round else { return }
        let audio = AudioInputBlock(samples: samples, startFrame: inputPosition)
        inputPosition = audio.endFrame
        let block = CaptureBlock(audio: audio, muted: _muted)
        var dropped = false
        if let feed = _onSamples {
            let result = speechFeed.append((block, feed), frames: samples.count)
            dropped = result.dropped
            if result.schedule { feedQueue.async { [weak self] in self?.drainSpeechFeed() } }
        }
        let result = segmentFeed.append(block, frames: samples.count)
        if result.dropped || dropped { lastOverflowAt = Date() }
        if result.schedule { queue.async { [weak self] in self?.drainSegmentFeed() } }
    }

    private func drainSpeechFeed() {
        while true {
            lock.lock()
            let next = speechFeed.pop()
            lock.unlock()
            guard let (block, feed) = next else { return }
            let audio = block.audio
            if block.muted {
                feed(AudioInputBlock(samples: Array(repeating: 0, count: audio.samples.count),
                                     startFrame: audio.startFrame))
            } else {
                feed(audio)
            }
        }
    }

    private func drainSegmentFeed() {
        while true {
            lock.lock()
            let next = segmentFeed.pop()
            lock.unlock()
            guard let block = next else { return }
            if block.muted { segmenter.seek(to: block.audio.endFrame) }
            else { segmenter.feed(block.audio.samples, startingAt: block.audio.startFrame) }
        }
    }

    private func reportHealth(_ next: Health) {
        guard health != next else { return }
        health = next
        let round = gen
        DispatchQueue.main.async { [weak self] in
            guard let self, self.gen == round else { return }
            self.onHealthChanged?(next)
        }
    }

    /// 最近一次"真的把声音送到识别那里"的时间。
    /// 麦克风回调有声音、但转换失败（或者送不出去）的时候，
    /// 光看回调时间会以为一切正常——其实识别早就哑了，
    /// 界面上还显示"正在聆听"，用户说什么都没反应。
    private var lastDeliveredAt: Date {
        get { lock.lock(); defer { lock.unlock() }; return _lastDelivered }
        set { lock.lock(); _lastDelivered = newValue; lock.unlock() }
    }

    /// 朗读译文时静音麦克风，避免把喇叭声音又识别一遍
    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _muted }
        set { lock.lock(); _muted = newValue; lock.unlock() }
    }

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // 通知是在主线程收到的，但动引擎的活儿一律交给 engineQueue，
            // 和 stop()/start() 排成一条线，不会互相踩
            self?.restartAfterConfigChange()
        }
        // 来电、别的 App 抢音频：系统会把引擎停掉。
        // 这时候不要自己去抢麦克风，等中断结束再重新接上。
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                ?? AVAudioSession.InterruptionType.began.rawValue
            let began = type == AVAudioSession.InterruptionType.began.rawValue
            self.engineQueue.async {
                self.interrupted = began
                if !began {
                    hearLog("系统中断结束，重新连接麦克风", .warning)
                    self.rearmMic(reason: "系统中断结束")
                }
            }
        }
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func updateConfig(_ c: Segmenter.Config) {
        queue.async { [segmenter] in segmenter.config = c }
    }

    @MainActor
    func start() async throws {
        // 已经在跑就别再开一次：AVAudioEngine 一个输入只能挂一个 tap，
        // 重复挂会直接崩（"required condition is false: !engine.isRunning"）。
        if isRunning { return }
        try Task.checkCancellation()
        guard let round = requestStart() else { throw CancellationError() }
        let processing = voiceProcessing
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            engineQueue.async { [self] in
                do {
                    guard gen == round else { throw CancellationError() }
                    // A preceding stop flushes here before we reset the detector.
                    let detector = speechDetector
                    queue.sync { [segmenter] in
                        segmenter.speechDetector = detector
                        segmenter.reset()
                    }
                    try prepareAndStart(round: round, voiceProcessing: processing)
                    guard finishStart(round, running: true) else { throw CancellationError() }
                    startWatchdog()
                    let f = engine.inputNode.outputFormat(forBus: 0)
                    hearLog("麦克风已启动：\(Int(f.sampleRate)) Hz，\(f.channelCount) 声道，语音增强\(engine.inputNode.isVoiceProcessingEnabled ? "开" : "关")")
                    completion.resume()
                } catch {
                    removeTap()
                    engine.stop()
                    AudioRoute.capturing = false
                    try? AudioRoute.updateSession()
                    let current = finishStart(round, running: false)
                    completion.resume(throwing: current ? error : CancellationError())
                }
            }
        }
    }

    @MainActor
    func stop(onFlushed: (() -> Void)? = nil) {
        guard let stopped = requestStop() else {
            if let onFlushed {
                engineQueue.async { DispatchQueue.main.async { onFlushed() } }
            }
            return
        }
        stopWatchdog()
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.removeTap()
            self.engine.stop()
            // 引擎停了再把最后一句交出去，后面不会再有声音进来
            self.queue.sync {
                if stopped.wasRunning { self.segmenter.flush() }
                else { self.segmenter.reset() }
            }
            if let onFlushed { DispatchQueue.main.async { onFlushed() } }
            // 引擎真的停了，才告诉音频会话"不收音了"。
            // 早一步改类别（.playAndRecord → .playback）会把还在跑的引擎的输入抽走，
            // 系统重新配置引擎，麦克风就断在半路上（以后再也没有声音进来）。
            // 这期间要是已经又开了一轮新的收音，就别动会话了，交给 start() 处理。
            guard self.gen == stopped.round else { return }
            AudioRoute.capturing = false
            try? AudioRoute.updateSession()
        }
    }

    /// 放开麦克风：停用音频会话，别占着麦克风不让别的 App 用。
    ///
    /// 排在 engineQueue 后面执行，保证引擎已经停了才停会话
    /// （引擎还在跑的时候停会话，麦克风会被系统打断）。
    func releaseSession() {
        engineQueue.async { [weak self] in
            // 真正要停会话这一刻再核对一遍：
            // 判断"没在出声"到现在，可能刚好开始播下一句——
            // 那就不能停（会把声音切断）。
            if self?.hasCaptureIntent == true { return }
            if self?.isSpeakingNow?() == true { return }
            AudioRoute.deactivate()
        }
    }

    /// 现在有没有在出声（真正停会话之前问一次，别把声音切断）
    var isSpeakingNow: (() -> Bool)?

    // MARK: - 打开麦克风（一定在 engineQueue 上跑）

    /// 语音增强 → 音频会话 → 挂 tap → 起引擎
    private func prepareAndStart(round: Int, voiceProcessing: Bool) throws {
        let input = engine.inputNode

        // 语音增强：系统的语音处理单元，改它之前必须先把音频会话停掉（Apple 的要求）。
        // 开着会话改，轻则直接报错（以前只在日志里留一行，看不出来）、
        // 重则把输入节点搞成半坏状态、麦克风根本起不来。
        // 所以顺序是：停会话 → 设语音增强 → 再按"要麦克风"把会话激活。
        if input.isVoiceProcessingEnabled != voiceProcessing {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            do { try input.setVoiceProcessingEnabled(voiceProcessing) }
            catch { hearLog("语音增强设置失败：\(error)", .warning) }
        }
        // 正在收音：会话用 .playAndRecord（要麦克风）
        AudioRoute.capturing = true
        do {
            try AudioRoute.updateSession()
        } catch {
            AudioRoute.capturing = false
            throw error
        }
        if input.isVoiceProcessingEnabled {
            // 不要因为开了语音增强把朗读声音压低
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        _ = engine.mainMixerNode   // 让引擎有完整的输入输出链路（语音增强需要）

        // 麦克风起不来时重试几次：
        // 刚加载完模型（内存紧张）、或音频会话状态和实际路由对不上时，
        // 硬件会拒绝启动（'nope'），重新激活一次音频会话通常就能恢复。
        var lastError: Error?
        for attempt in 1...3 {
            guard gen == round else { throw CancellationError() }
            do {
                try installTapAndStart(round: round)
                lastError = nil
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                hearLog("麦克风启动失败（第 \(attempt)/3 次）：\(error)", .warning)
                engine.stop()
                removeTap()
                if input.isVoiceProcessingEnabled {
                    // 个别情况下语音增强启动失败：关掉再试一次
                    try? input.setVoiceProcessingEnabled(false)
                }
                AudioRoute.reset()
                Thread.sleep(forTimeInterval: 0.3 * Double(attempt))
            }
        }
        if let lastError {
            // 起不来就别占着麦克风
            AudioRoute.capturing = false
            try? AudioRoute.updateSession()
            throw lastError
        }
    }

    private func installTapAndStart(round: Int) throws {
        let input = engine.inputNode
        // 刚激活音频会话时，硬件有时还没准备好，输入格式会短暂地是 0×0。
        // 这时候直接报错就"麦克风起不来"了，用户看着像是整个实时翻译坏了。
        // 等一小会儿再看，最多等 0.5 秒。
        var inFormat = input.outputFormat(forBus: 0)
        var waited = 0
        while inFormat.sampleRate <= 0 || inFormat.channelCount <= 0, waited < 10 {
            guard acceptsAudio(for: round) else { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.05)
            inFormat = input.outputFormat(forBus: 0)
            waited += 1
        }
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Hear", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法使用麦克风"])
        }
        // 每次取整 100 毫秒的声音（16 kHz 正好 1600 个采样）。
        // 采样数要是不能被整除，转成 16 kHz 时就会攒零头，
        // 转换器偶尔会错开一小截，听起来就是"刺刺"的杂音。
        let size = AVAudioFrameCount(max(256, (inFormat.sampleRate / 10).rounded()))
        // 引擎在跑的时候不能换 tap，必须先停下来（AVFAudio 的硬性要求，
        // 违反会直接 crash：'required condition is false: !engine.isRunning'）
        if engine.isRunning { engine.stop() }
        // 挂新 tap 之前一定要先把旧的摘掉：重复挂会直接崩。
        input.removeTap(onBus: 0)
        tapInstalled = false
        // format 传 nil：始终按麦克风当前的真实格式接收，路由变化后也不会错位
        input.installTap(onBus: 0, bufferSize: size, format: nil) { [weak self] buffer, _ in
            guard let self, self.acceptsAudio(for: round) else { return }
            self.handle(buffer, round: round)
        }
        tapInstalled = true
        installedFormat = (inFormat.sampleRate, inFormat.channelCount)
        lastSampleAt = Date()
        lastDeliveredAt = Date()
        engine.prepare()
        guard acceptsAudio(for: round) else { throw CancellationError() }
        try engine.start()
    }

    /// 把 tap 摘掉（只摘一次，摘两次会出问题）
    private func removeTap() {
        guard tapInstalled else { return }
        tapInstalled = false
        engine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - 重新接麦克风（一定在 engineQueue 上跑）

    /// 切换扬声器/耳机、插拔耳机后，系统会停掉引擎：重新接上麦克风继续聆听
    private func restartAfterConfigChange() {
        guard isRunning else { return }
        engineQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            let f = self.engine.inputNode.outputFormat(forBus: 0)
            // 输入格式没变的话，这次变化跟麦克风无关（比如只是输出路由变了）。
            // 白折腾一次反而容易把正在用的 tap 弄掉，不用管。
            if self.tapInstalled, self.engine.isRunning,
               abs(f.sampleRate - self.installedFormat.rate) < 1,
               f.channelCount == self.installedFormat.ch {
                return
            }
            hearLog("音频路由变化，重新连接麦克风（\(Int(f.sampleRate)) Hz）", .warning)
            self.rearmMic(reason: "路由变化")
        }
    }

    /// 重新接一次麦克风。接不上就重试几次；
    /// 全失败了也别悄悄哑掉——看门狗下一轮还会再来一次。
    private func rearmMic(reason: String) {
        // 现在不需要麦克风了（比如来电的时候用户已经停了收音）：
        // 不要再把它抢回来——用户以为已经停了呢
        guard isRunning else {
            hearLog("现在不需要麦克风了（\(reason)），不重新连接", .info)
            return
        }
        guard !rearming else { return }
        rearming = true
        defer { rearming = false }
        hearLog("重新连接麦克风（\(reason)）", .warning)
        engine.stop()
        removeTap()
        let round = gen
        for attempt in 1...3 {
            do {
                try installTapAndStart(round: round)
                silentTicks = 0
                return
            } catch is CancellationError {
                removeTap()
                return
            } catch {
                hearLog("重新连接麦克风失败（第 \(attempt)/3 次）：\(error)", .error)
                engine.stop()
                removeTap()
                AudioRoute.reset()
                Thread.sleep(forTimeInterval: 0.25 * Double(attempt))
            }
        }
        // 还是不行：引擎现在是停的、tap 也没挂，麦克风等于哑了。
        // 看门狗会隔几秒再来一次，这里如实记一笔，别让日志里什么都没有。
        hearLog("麦克风暂时接不上，过几秒会自动再试", .error)
    }

    // MARK: - 看门狗：麦克风哑了自己能发现

    private func startWatchdog() {
        engineQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning, self.watchdog == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.engineQueue)
            t.schedule(deadline: .now() + 3, repeating: 3)
            t.setEventHandler { [weak self] in self?.checkMicAlive() }
            self.watchdog = t
            t.resume()
        }
    }

    private func stopWatchdog() {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.watchdog?.cancel()
            self.watchdog = nil
            self.silentTicks = 0
            self.reportHealth(.normal)
        }
    }

    /// 引擎在跑却好几秒没有声音进来，说明 tap 掉了、或者输入被系统掐了。
    ///
    /// 以前这种情况没人管：界面还显示"正在聆听"，其实麦克风早就哑了，
    /// 用户说什么都没反应，只有把实时翻译关掉再打开才恢复。
    /// 引擎每 100 毫秒都会给一次缓冲区（哪怕全是静音），所以"没声音"就是出问题了。
    private func checkMicAlive() {
        guard isRunning, !interrupted else { return }
        if !tapInstalled || !engine.isRunning {
            reportHealth(.reconnecting)
            hearLog("麦克风没有声音了（引擎停了或 tap 掉了），自动重新接上", .warning)
            silentTicks = 0
            rearmMic(reason: "看门狗")
            return
        }
        // 两个都看：
        //   · 回调都没了 → 麦克风真的断了
        //   · 回调有、但声音没送到识别那里 → 转换坏了，识别是哑的
        // 只看回调时间的话，后一种情况永远发现不了
        // 积压：声音送进去了，识别那边却不消费（后端卡住了）。
        // 这跟麦克风断了不是一回事：重接麦克风没有用，得让用户知道。
        let backlog = isBacklogged
        if backlog, health != .backlogged { hearLog("音频积压，部分录音可能未识别", .warning) }
        if Date().timeIntervalSince(lastSampleAt) > 4 || Date().timeIntervalSince(lastDeliveredAt) > 4 {
            silentTicks += 1
            reportHealth(.reconnecting)
            // 连续两次（大约 6 秒）没有声音才动手，避免打断正常的短暂卡顿
            if silentTicks >= 2 {
                silentTicks = 0
                hearLog("麦克风 6 秒没有收到声音，自动重新接上", .warning)
                rearmMic(reason: "看门狗")
            }
        } else {
            silentTicks = 0
            reportHealth(backlog ? .backlogged : .normal)
        }
    }

    // MARK: - 收声音

    private func handle(_ buffer: AVAudioPCMBuffer, round: Int) {
        // 收到声音了：看门狗靠这个判断麦克风还活着
        lastSampleAt = Date()
        // 按这一块声音的真实格式重采样（格式变了就重建转换器）
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
        }
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return }
        // 真的转换出来了：更新"送到识别那边"的时间
        lastDeliveredAt = Date()
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        enqueue(samples, round: round)
    }
}
