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

    /// 设置为“可录音 + 可播放”，蓝牙耳机用高音质 A2DP 输出
    static func activate() throws {
        let s = AVAudioSession.sharedInstance()
        if s.category != .playAndRecord {
            try s.setCategory(.playAndRecord, mode: .default,
                              options: [.defaultToSpeaker, .allowBluetoothA2DP])
        }
        try s.setActive(true)
    }

    private static func routeHasHeadphones() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { headphonePorts.contains($0.portType) }
    }

    /// 检测是否连接了耳机。
    /// 输出被强制到扬声器时，当前路由里看不到耳机，所以临时取消强制再检查一次。
    static func detectHeadphones() -> Bool {
        if routeHasHeadphones() { return true }
        let s = AVAudioSession.sharedInstance()
        try? s.overrideOutputAudioPort(.none)
        lastOverride = AVAudioSession.PortOverride.none
        return routeHasHeadphones()
    }

    private static var lastOverride: AVAudioSession.PortOverride?

    /// 按选择的输出方式切换路由。只在需要改变时才调用系统接口，
    /// 因为每次改路由都会让正在播放的声音中断。
    static func apply(_ output: AudioOutput) {
        let want: AVAudioSession.PortOverride = output == .speaker ? .speaker : .none
        guard want != lastOverride else { return }
        lastOverride = want
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(want)
    }

    /// 不改路由的情况下判断是否连着耳机（输出或可用输入里有耳机/蓝牙设备）
    static func headphonesLikelyConnected() -> Bool {
        let s = AVAudioSession.sharedInstance()
        if routeHasHeadphones() { return true }
        let inputs: Set<AVAudioSession.Port> = [.headsetMic, .bluetoothHFP, .usbAudio]
        return (s.availableInputs ?? []).contains { inputs.contains($0.portType) }
    }
}
