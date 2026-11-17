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

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?          // 只在音频线程里读写
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16_000, channels: 1, interleaved: false)!
    private let queue = DispatchQueue(label: "hear.audio.segmenter")
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
        try AudioRoute.activate()
        let input = engine.inputNode

        // 语音增强：要在引擎启动前设置
        if input.isVoiceProcessingEnabled != voiceProcessing {
            do { try input.setVoiceProcessingEnabled(voiceProcessing) }
            catch { hearLog("语音增强设置失败：\(error)", .warning) }
        }
        if input.isVoiceProcessingEnabled {
            // 不要因为开了语音增强把朗读声音压低
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        _ = engine.mainMixerNode   // 让引擎有完整的输入输出链路（语音增强需要）

        do {
            try installTapAndStart()
        } catch where input.isVoiceProcessingEnabled {
            // 个别情况下语音增强启动失败：关掉再试一次
            hearLog("开启语音增强后麦克风启动失败（\(error)），改为普通模式", .warning)
            engine.stop()
            try? input.setVoiceProcessingEnabled(false)
            try installTapAndStart()
        }
        queue.async { [segmenter] in segmenter.reset() }
        isRunning = true
        let f = input.outputFormat(forBus: 0)
        hearLog("麦克风已启动：\(Int(f.sampleRate)) Hz，\(f.channelCount) 声道，语音增强\(input.isVoiceProcessingEnabled ? "开" : "关")")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.async { [segmenter] in segmenter.flush() }
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Hear", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法使用麦克风"])
        }
        input.removeTap(onBus: 0)
        // format 传 nil：始终按麦克风当前的真实格式接收，路由变化后也不会错位
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
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
        do {
            try installTapAndStart()
        } catch {
            hearLog("重新连接麦克风失败：\(error)", .error)
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
        queue.async { [segmenter] in
            if isMuted { segmenter.reset() } else { segmenter.feed(samples) }
        }
    }
}
