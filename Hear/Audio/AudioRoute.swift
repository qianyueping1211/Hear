import AVFoundation

/// 朗读从哪里出声
enum AudioOutput: String {
    case speaker      // 手机扬声器
    case headphones   // 耳机（有线 / 蓝牙）
}

/// 统一管理音频会话和输出路由
enum AudioRoute {
    static let headphonePorts: Set<AVAudioSession.Port> = [
        .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio,
    ]

    /// 声音来源：false = 手机麦克风（默认），true = 耳机麦克风
    static var useHeadsetMic = false

    /// 用户选的输出方式（扬声器 / 耳机）。
    /// 记下来是为了：重新激活音频会话以后再把它应用回去。
    /// setCategory 会把"输出到哪"重置成 .defaultToSpeaker（扬声器），
    /// 戴着耳机时声音就从手机喇叭出来了，耳机里听不到。
    static private(set) var lastOutput: AudioOutput = .speaker
    /// 上一次真正应用过的输出方式（用来避免重复改路由）
    private static var appliedOutput: AudioOutput?

    /// 正在收音（要麦克风）
    static var capturing = false
    /// 正在放声音（只是播放）
    static var speaking = false

    /// 按当前状态设置音频会话。
    ///
    /// - 正在收音 → .playAndRecord（要麦克风）
    /// - 只是放声音 → .playback（**不占麦克风**）
    ///
    /// 以前不管有没有在收音都用 .playAndRecord，结果只是朗读的时候
    /// 也把麦克风占着：手机上别的 App（录屏、录音机）就录不到声音，
    /// 录屏里的声音会变得又刺又碎。
    ///
    /// 用手机麦克风时，蓝牙耳机走高音质 A2DP（只播放）；
    /// 用耳机麦克风时，需要蓝牙通话模式（HFP），耳机播放会变成单声道通话音质。
    static func updateSession() throws {
        let s = AVAudioSession.sharedInstance()
        if capturing {
            // .defaultToSpeaker：没有耳机时走扬声器（不是听筒）。
            // 插着耳机时系统还是走耳机（除非用 overrideOutputAudioPort(.speaker) 强制）。
            var opts: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
            if useHeadsetMic { opts.insert(.allowBluetooth) }
            // setCategory 会把"输出到哪"重置掉，只有真的改了类别才需要重新应用
            var categoryChanged = (s.category != .playAndRecord || s.categoryOptions != opts)
            if categoryChanged {
                try s.setCategory(.playAndRecord, mode: .default, options: opts)
            }
            try s.setActive(true)
            // 换麦克风也会重置路由
            if applyInput() { categoryChanged = true }
            if categoryChanged { appliedOutput = nil }
            apply(lastOutput)
            return
        }
        if speaking {
            // 正在放声音：不要改类别（改类别会打断正在播的声音），
            // 只保证会话是活的
            try? s.setActive(true)
            apply(lastOutput)
            return
        }
        // 不放声音：类别降回 .playback，不占麦克风。
        // 会话本身的启停交给别的地方管（停用会话要几百毫秒，不能在这里做）。
        let opts: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
        if s.category != .playback || s.categoryOptions != opts {
            try? s.setCategory(.playback, mode: .default, options: opts)
            appliedOutput = nil
        }
        apply(lastOutput)
    }

    /// 设置为“可录音 + 可播放”（旧入口，现在按当前状态来）
    static func activate() throws {
        try updateSession()
    }

    /// 音频会话被停用过几次。
    /// 停会话会把播放引擎也打断，播放之前要用它判断要不要重新启动引擎。
    private static let genLock = NSLock()
    private static var deactivateGen = 0

    static var deactivateGeneration: Int {
        genLock.lock(); defer { genLock.unlock() }; return deactivateGen
    }

    /// 停用音频会话：把麦克风让给别的 App。
    ///
    /// 停止实时翻译以后如果不这么做，音频会话还停在"可录音"状态、
    /// 而且是激活的，麦克风就一直被我们占着——手机上别的录音 App
    /// 再也录不到声音（录出来是静音）。
    ///
    /// 必须在后台线程调用：关会话时蓝牙耳机会从通话模式切回音乐模式，
    /// 要好几百毫秒，卡住主线程会让界面发涩。
    static func deactivate() {
        if capturing { return }          // 还在收音，不能停会话
        genLock.lock(); deactivateGen += 1; genLock.unlock()
        let s = AVAudioSession.sharedInstance()
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 按“声音来源”选择麦克风（已经是想要的就不动）。
    /// 返回 true 表示真的换了麦克风（换了的话输出路由也会被重置）。
    @discardableResult
    static func applyInput() -> Bool {
        let s = AVAudioSession.sharedInstance()
        let headsetPorts: Set<AVAudioSession.Port> = [.bluetoothHFP, .headsetMic, .usbAudio]
        let inputs = s.availableInputs ?? []
        let want: AVAudioSessionPortDescription?
        if useHeadsetMic {
            want = inputs.first { headsetPorts.contains($0.portType) }
        } else {
            want = inputs.first { $0.portType == .builtInMic }
        }
        guard let want else { return false }
        if s.currentRoute.inputs.first?.uid == want.uid { return false }
        do {
            try s.setPreferredInput(want)
            hearLog("声音来源：\(want.portName)")
            return true
        } catch {
            hearLog("切换声音来源失败：\(error)", .warning)
            return false
        }
    }

    /// 重新激活一次音频会话：麦克风启动失败时用。
    /// 硬件拒绝启动（'nope'）多半是会话状态和实际路由对不上了，
    /// 彻底关掉再打开一次，麦克风通常就能正常起来。
    static func reset() {
        let s = AVAudioSession.sharedInstance()
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
        try? s.setActive(true)
        applyInput()
        // 会话重置以后输出路由也丢了，再应用一次
        appliedOutput = nil
        apply(lastOutput)
    }

    private static func routeHasHeadphones() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { headphonePorts.contains($0.portType) }
    }

    /// 检测是否连接了耳机。
    /// 输出被强制到扬声器时，当前路由里看不到耳机，所以临时取消强制再检查一次。
    static func detectHeadphones() -> Bool {
        if routeHasHeadphones() { return true }
        let s = AVAudioSession.sharedInstance()
        let was = appliedOutput
        try? s.overrideOutputAudioPort(.none)
        let found = routeHasHeadphones()
        // 恢复原来的设置
        if let was { try? s.overrideOutputAudioPort(was == .speaker ? .speaker : .none) }
        return found
    }

    /// 按选择的输出方式切换路由。
    /// - .speaker：强制走手机扬声器（插着耳机也走扬声器）
    /// - .headphones：取消强制，让系统自己挑（插着耳机就走耳机）
    ///
    /// 每次改路由都会打断正在播放的声音、让麦克风重新连接，已经是对的就别动。
    static func apply(_ output: AudioOutput) {
        lastOutput = output
        guard appliedOutput != output else { return }
        let s = AVAudioSession.sharedInstance()
        switch output {
        case .speaker:
            // 强制走扬声器（插着耳机也走扬声器）
            try? s.overrideOutputAudioPort(.speaker)
            appliedOutput = .speaker
        case .headphones:
            // 取消强制，系统就会走耳机（没插耳机时按 .defaultToSpeaker 走扬声器）
            try? s.overrideOutputAudioPort(.none)
            appliedOutput = .headphones
        }
    }

    /// 不改路由的情况下判断是否连着耳机（输出或可用输入里有耳机/蓝牙设备）
    static func headphonesLikelyConnected() -> Bool {
        let s = AVAudioSession.sharedInstance()
        if routeHasHeadphones() { return true }
        let inputs: Set<AVAudioSession.Port> = [.headsetMic, .bluetoothHFP, .usbAudio]
        return (s.availableInputs ?? []).contains { inputs.contains($0.portType) }
    }
}
