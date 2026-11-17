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
        return routeHasHeadphones()
    }

    /// 按选择的输出方式切换路由
    static func apply(_ output: AudioOutput) {
        let s = AVAudioSession.sharedInstance()
        try? s.overrideOutputAudioPort(output == .speaker ? .speaker : .none)
    }
}
