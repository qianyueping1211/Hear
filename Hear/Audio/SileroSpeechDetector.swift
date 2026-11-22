import Foundation
import SherpaOnnx

/// Runs on the same serial queue as the segmenter, away from the audio tap.
final class SileroSpeechDetector: SpeechPresenceDetector {
    private let detector: SherpaOnnxVoiceActivityDetectorWrapper
    private var hasAudio = false

    init?() {
        guard let model = Bundle.main.url(forResource: "silero_vad", withExtension: "onnx") else {
            hearLog("人声检测文件缺失，暂用音量判定", .warning)
            return nil
        }
        let silero = sherpaOnnxSileroVadModelConfig(model: model.path, threshold: 0.5,
                                                   minSilenceDuration: 0.12, minSpeechDuration: 0.064,
                                                   windowSize: 512, maxSpeechDuration: 30)
        var config = sherpaOnnxVadModelConfig(sileroVad: silero)
        detector = SherpaOnnxVoiceActivityDetectorWrapper(config: &config, buffer_size_in_seconds: 32)
    }

    func containsSpeech(_ samples: ArraySlice<Float>) -> Bool {
        detector.acceptWaveform(samples: Array(samples))
        hasAudio = true
        let detected = detector.isSpeechDetected()
        while !detector.isEmpty() { detector.pop() }
        return detected
    }

    func reset() {
        guard hasAudio else { return }
        detector.reset()
        hasAudio = false
    }
}
