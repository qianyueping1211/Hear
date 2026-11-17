import AVFoundation

/// 用系统语音朗读译文（自动挑选已安装的最高音质声音）
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, locale: String) async {
        stop()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            let u = AVSpeechUtterance(string: text)
            u.voice = Self.bestVoice(for: locale)
            u.rate = AVSpeechUtteranceDefaultSpeechRate
            synth.speak(u)
        }
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        finish()
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }

    static func bestVoice(for locale: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(locale.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let exact = voices.filter { $0.language == locale }
        let pool = exact.isEmpty ? voices.filter { $0.language.hasPrefix(prefix) } : exact
        return pool.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: locale)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { finish() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { finish() }
}
