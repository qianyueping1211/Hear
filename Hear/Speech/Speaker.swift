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
/// 用 AVSpeechSynthesizer 生成语音数据，再通过 AVAudioEngine 播放，
/// 这样可以把声音放到左耳或右耳（pan）。
final class Speaker: NSObject {
    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "hear.speaker")

    private var continuation: CheckedContinuation<Void, Never>?
    private var generation = 0
    private var scheduled = 0
    private var played = 0
    private var finished = false
    private var connectedFormat: AVAudioFormat?
    private var currentPan: Float = 0

    override init() {
        super.init()
        engine.attach(player)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.connectedFormat = nil }
        }
    }

    func speak(_ req: SpeakRequest) async {
        stop()
        try? AudioRoute.activate()
        let gen: Int = queue.sync {
            generation += 1
            scheduled = 0; played = 0; finished = false
            currentPan = req.pan
            return generation
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.sync { continuation = c }
            let u = AVSpeechUtterance(string: req.text)
            u.voice = req.voice ?? Self.bestVoice(for: req.locale)
            u.pitchMultiplier = req.pitch
            u.rate = AVSpeechUtteranceDefaultSpeechRate
            synth.write(u) { [weak self] buffer in
                self?.receive(buffer, gen: gen)
            }
        }
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        player.stop()
        queue.sync {
            generation += 1
            let c = continuation
            continuation = nil
            c?.resume()
        }
    }

    // MARK: - 播放

    private func receive(_ buffer: AVAudioBuffer, gen: Int) {
        queue.async { [self] in
            guard gen == generation, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {          // 生成结束
                finished = true
                checkDone()
                return
            }
            guard let f = Self.toFloat(pcm) else { return }
            ensureEngine(format: f.format)
            scheduled += 1
            player.scheduleBuffer(f, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async {
                    guard let self, gen == self.generation else { return }
                    self.played += 1
                    self.checkDone()
                }
            }
            if !player.isPlaying { player.play() }
        }
    }

    private func ensureEngine(format: AVAudioFormat) {
        if connectedFormat == nil
            || connectedFormat!.sampleRate != format.sampleRate
            || connectedFormat!.channelCount != format.channelCount {
            if engine.isRunning { engine.stop() }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        player.pan = currentPan
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    private func checkDone() {
        guard finished, played >= scheduled else { return }
        let c = continuation
        continuation = nil
        c?.resume()
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

    static var hasAnyPersonalVoice: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { $0.voiceTraits.contains(.isPersonalVoice) }
    }

    static func requestPersonalVoiceAccess() async -> Bool {
        await withCheckedContinuation { c in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                c.resume(returning: status == .authorized)
            }
        }
    }
}
