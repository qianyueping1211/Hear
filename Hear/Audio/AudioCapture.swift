import AVFoundation

/// 麦克风采集 → 重采样到 16kHz 单声道 → 交给 Segmenter 断句
///
/// - 输出路由改变（扬声器/耳机切换、插拔耳机）时，系统会重配音频引擎、麦克风格式也可能变；
///   这里会自动重新接上麦克风，并按实际格式重采样，避免收到变速的“乱码”声音。
/// - 可选“语音增强”：系统自带的回声消除 + 降噪 + 自动增益（和 FaceTime 同一套）。
final class AudioCapture {
    let segmenter = Segmenter()

    /// 语音增强（降噪、回声消除）。下次开始聆听时生效
    var voiceProcessing = true

    /// 同时把 16kHz 采样交给系统听写（音频线程调用；静音时给的是静音采样）
    private var _onSamples: (([Float]) -> Void)?
    var onSamples: (([Float]) -> Void)? {
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
    private(set) var isRunning = false
    private var configObserver: NSObjectProtocol?

    /// 朗读译文时静音麦克风，避免把喇叭声音又识别一遍
    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _muted }
        set { lock.lock(); _muted = newValue; lock.unlock() }
    }

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigChange()
        }
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func updateConfig(_ c: Segmenter.Config) {
        queue.async { [segmenter] in segmenter.config = c }
    }

    func start() throws {
        // 已经在跑就别再开一次：AVAudioEngine 一个输入只能挂一个 tap，
        // 重复挂会直接崩（"required condition is false: !engine.isRunning"）。
        if isRunning { return }
        engineQueue.sync {}            // 等上一次的停止做完
        let input = engine.inputNode

        // 语音增强：系统的语音处理单元，改它之前必须先把音频会话停掉（Apple 的要求）。
        // 开着会话改，轻则直接报错（以前只在日志里留一行，看不出来）、
        // 重则行为不对（录出来的声音发闷、发杂）。
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
            do {
                try installTapAndStart()
                lastError = nil
                break
            } catch {
                lastError = error
                hearLog("麦克风启动失败（第 \(attempt)/3 次）：\(error)", .warning)
                engine.stop()
                if input.isVoiceProcessingEnabled {
                    // 个别情况下语音增强启动失败：关掉再试一次
                    try? input.setVoiceProcessingEnabled(false)
                }
                AudioRoute.reset()
                Thread.sleep(forTimeInterval: 0.3 * Double(attempt))
            }
        }
        if let lastError = lastError {
            // 起不来就别占着麦克风
            AudioRoute.capturing = false
            try? AudioRoute.updateSession()
            throw lastError
        }
        queue.async { [segmenter] in segmenter.reset() }
        isRunning = true
        let f = input.outputFormat(forBus: 0)
        hearLog("麦克风已启动：\(Int(f.sampleRate)) Hz，\(f.channelCount) 声道，语音增强\(input.isVoiceProcessingEnabled ? "开" : "关")")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        // 不收音了：会话降回 .playback（只是朗读的时候不占麦克风）
        AudioRoute.capturing = false
        let engine = self.engine
        engineQueue.async { [queue, segmenter] in
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            // 引擎停了再把最后一句交出去，后面不会再有声音进来
            queue.async { segmenter.flush() }
            try? AudioRoute.updateSession()
        }
    }

    /// 放开麦克风：停用音频会话，别占着麦克风不让别的 App 用。
    ///
    /// 排在 engineQueue 后面执行，保证引擎已经停了才停会话
    /// （引擎还在跑的时候停会话，麦克风会被系统打断）。
    func releaseSession() {
        engineQueue.async {
            AudioRoute.deactivate()
        }
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        // 刚激活音频会话时，硬件有时还没准备好，输入格式会短暂地是 0×0。
        // 这时候直接报错就"麦克风起不来"了，用户看着像是整个实时翻译坏了。
        // 等一小会儿再看，最多等 0.5 秒。
        var inFormat = input.outputFormat(forBus: 0)
        var waited = 0
        while inFormat.sampleRate <= 0 || inFormat.channelCount <= 0, waited < 10 {
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
        input.removeTap(onBus: 0)
        // format 传 nil：始终按麦克风当前的真实格式接收，路由变化后也不会错位
        input.installTap(onBus: 0, bufferSize: size, format: nil) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// 切换扬声器/耳机、插拔耳机后，系统会停掉引擎：重新接上麦克风继续聆听
    private func restartAfterConfigChange() {
        guard isRunning else { return }
        let f = engine.inputNode.outputFormat(forBus: 0)
        hearLog("音频路由变化，重新连接麦克风（\(Int(f.sampleRate)) Hz）", .warning)
        engine.stop()
        // 路由刚变，硬件有时还没准备好，失败就重新激活会话再来一次
        for attempt in 1...2 {
            do {
                try installTapAndStart()
                return
            } catch {
                hearLog("重新连接麦克风失败（第 \(attempt)/2 次）：\(error)", .error)
                engine.stop()
                AudioRoute.reset()
            }
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
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
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        let isMuted = muted
        // 送样本的活儿放到后台线程做：
        // 这个回调跑在音频线程上（实时线程），在这儿做转换、拷贝、
        // 喂系统听写，哪一下没赶上就会漏音，听起来是「刺刺」的杂音。
        if let feed = onSamples {
            let input = isMuted ? [Float](repeating: 0, count: samples.count) : samples
            feedQueue.async { feed(input) }
        }
        queue.async { [segmenter] in
            if isMuted { segmenter.reset() } else { segmenter.feed(samples) }
        }
    }
}
