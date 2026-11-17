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

    /// 设置为“可录音 + 可播放”。
    /// 用手机麦克风时，蓝牙耳机走高音质 A2DP（只播放）；
    /// 用耳机麦克风时，需要蓝牙通话模式（HFP），耳机播放会变成单声道通话音质。
    static func activate() throws {
        let s = AVAudioSession.sharedInstance()
        var opts: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
        if useHeadsetMic { opts.insert(.allowBluetooth) }
        if s.category != .playAndRecord || s.categoryOptions != opts {
            try s.setCategory(.playAndRecord, mode: .default, options: opts)
        }
        try s.setActive(true)
        applyInput()
    }

    /// 按“声音来源”选择麦克风（已经是想要的就不动）
    static func applyInput() {
        let s = AVAudioSession.sharedInstance()
        let headsetPorts: Set<AVAudioSession.Port> = [.bluetoothHFP, .headsetMic, .usbAudio]
        let inputs = s.availableInputs ?? []
        let want: AVAudioSessionPortDescription?
        if useHeadsetMic {
            want = inputs.first { headsetPorts.contains($0.portType) }
        } else {
            want = inputs.first { $0.portType == .builtInMic }
        }
        guard let want else { return }
        if s.currentRoute.inputs.first?.uid == want.uid { return }
        do {
            try s.setPreferredInput(want)
            hearLog("声音来源：\(want.portName)")
        } catch {
            hearLog("切换声音来源失败：\(error)", .warning)
        }
    }

    private static func routeHasHeadphones() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { headphonePorts.contains($0.portType) }
    }

    /// 检测是否连接了耳机。
    /// 输出被强制到扬声器时，当前路由里看不到耳机，所以临时取消强制再检查一次。
    static func detectHeadphones() -> Bool {
        if routeHasHeadphones() { return true }
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        return routeHasHeadphones()
    }

    /// 按选择的输出方式切换路由。按当前实际路由判断，已经是想要的就不动，
    /// 因为每次改路由都会打断正在播放的声音、让麦克风重新连接。
    static func apply(_ output: AudioOutput) {
        let s = AVAudioSession.sharedInstance()
        let onSpeaker = s.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        switch output {
        case .speaker:
            guard !onSpeaker else { return }
            try? s.overrideOutputAudioPort(.speaker)
        case .headphones:
            guard onSpeaker else { return }
            try? s.overrideOutputAudioPort(.none)
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
