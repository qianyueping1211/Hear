#if DEBUG || HEAR_SPEECH_REGRESSION
import CryptoKit
import Foundation
import UIKit

/// Runs the same recognizer and VAD as live capture, with fixed input and no microphone.
enum SpeechRegression {
    private static let rate = AudioInputBlock.sampleRate
    private static let fixtureRevision = "2365baeacb507f821a0c8120fcee3d484dba7a07"
    private static let fixtureRoot = "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/"
    private static let sources = [
        ("zh", "开放时间早上9点至下午5点", "b77f1794fe374a0ba1ee1dc458bfaf9349496cbbfc32780c50ba3c5a7ad8e373"),
        ("en", "The tribal chieftain called for the boy and presented him with 50 pieces of gold", "eb1eb008904465b74c304aad8342e8c7d3c6e61ffe9f66adcaca9cf0f76a93f4"),
        ("ja", "うちの中学は弁当制で持っていけない場合は50円の学校販売のパンを買う", "460bd8dccb0d2a5f4e29c628f837be4082d13defc64c3fc21dd1b6bb0e119095"),
        ("ko", "조금만 생각을 하면서 살면 훨씬 편할 거야", "0dc797a5c81ed30fc339d91f3da718ab02854e17ffa37cb93c4c039ac5c6bb9c"),
    ]

    private struct Fixture {
        let id: String
        let language: String?
        let reference: String
        let audio: [Float]
    }

    private struct Recognition: Encodable {
        let text: String
        let language: String?
        let errorRate: Double?
        let milliseconds: Double
    }

    private struct SegmentResult: Encodable {
        let startFrame: Int64
        let endFrame: Int64
        let recognition: Recognition
    }

    private struct Segmentation: Encodable {
        let prerollMs: Int
        let firstPreviewAtMs: Double?
        let firstPreviewInferenceMs: Double?
        let discardedSegments: Int
        let overlappingBoundaries: Int
        let errorRate: Double?
        let missed: Bool
        let falseSpeech: Bool
        let segments: [SegmentResult]
    }

    private struct Result: Encodable {
        let fixture: String
        let expectedLanguage: String?
        let reference: String
        let direct: Recognition?
        let withVAD: [Segmentation]
    }

    private struct Report: Encodable {
        let revision: String
        let fixtureRevision: String
        let device: String
        let operatingSystem: String
        let sampleRate: Int
        let modelReloadMs: Double
        let firstInferenceMs: Double
        let sensitivityDB: Float
        let silenceMs: Int
        let minimumSpeechMs: Int
        let results: [Result]
    }

    struct FixtureError: LocalizedError {
        let id: String
        var errorDescription: String? { "回归录音 \(id) 无法读取或校验失败。" }
    }

    static func run(sense: SenseVoiceRecognizer, folder: URL, config: Segmenter.Config,
                    reportProgress: @escaping @MainActor (String) -> Void) async throws -> URL {
        await reportProgress("准备固定录音…")
        let fixtures = try await loadFixtures()
        try Task.checkCancellation()
        let started = ContinuousClock.now
        await reportProgress("重新加载本机识别模型…")
        try await sense.recover(folder: folder)
        let modelReloadMs = milliseconds(started.duration(to: .now))
        var direct: [String: Recognition] = [:]
        // Run direct measurements first so VAD variants don't warm the model first.
        for fixture in fixtures where fixture.audio.count <= 15 * rate {
            try Task.checkCancellation()
            direct[fixture.id] = try await recognize(fixture.audio, fixture: fixture, sense: sense)
        }
        var results: [Result] = []
        for (index, fixture) in fixtures.enumerated() {
            try Task.checkCancellation()
            await reportProgress("验证断句 \(index + 1)/\(fixtures.count)…")
            var comparisons: [Segmentation] = []
            for preroll in [300, 450] {
                var config = config
                config.prerollMs = preroll
                comparisons.append(try await segment(fixture, config: config, sense: sense))
            }
            results.append(Result(fixture: fixture.id, expectedLanguage: fixture.language, reference: fixture.reference,
                                  direct: direct[fixture.id], withVAD: comparisons))
        }
        let platform = await MainActor.run {
            (UIDevice.current.model, UIDevice.current.systemVersion)
        }
        let report = Report(revision: Bundle.main.object(forInfoDictionaryKey: "HearSourceRevision") as? String ?? "local",
                            fixtureRevision: fixtureRevision, device: platform.0, operatingSystem: platform.1,
                            sampleRate: rate, modelReloadMs: modelReloadMs,
                            firstInferenceMs: direct[fixtures[0].id]?.milliseconds ?? 0,
                            sensitivityDB: config.sensitivityDB, silenceMs: config.silenceMs,
                            minimumSpeechMs: config.minSpeechMs, results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Hear-Speech-Regression-\(UUID().uuidString.prefix(8)).json")
        try encoder.encode(report).write(to: file, options: .atomic)
        return file
    }

    private static func loadFixtures() async throws -> [Fixture] {
        var fixtures: [Fixture] = []
        var originals: [String: Fixture] = [:]
        for (language, text, sha) in sources {
            let url = URL(string: fixtureRoot + fixtureRevision + "/test_wavs/" + language + ".wav")!
            let (data, response) = try await URLSession.shared.data(from: url)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard (response as? HTTPURLResponse)?.statusCode == 200, actual == sha,
                  let decoded = Wav.decode(data), decoded.sampleRate == rate else { throw FixtureError(id: language) }
            let original = Fixture(id: language + "-clean", language: language, reference: text, audio: decoded.samples)
            fixtures.append(original)
            fixtures.append(Fixture(id: language + "-quiet", language: language,
                                    reference: text, audio: decoded.samples.map { $0 * 0.19 }))
            originals[language] = original
        }
        let silence = [Float](repeating: 0, count: rate * 2)
        fixtures.append(Fixture(id: "no-speaker-silence", language: nil, reference: "", audio: silence))
        fixtures.append(Fixture(id: "no-speaker-noise", language: nil, reference: "", audio: withNoise(silence, gain: 0.01)))
        guard let chinese = originals["zh"], let english = originals["en"], let korean = originals["ko"],
              korean.audio.count >= 22_400 else { throw FixtureError(id: "variants") }
        fixtures.append(Fixture(id: "en-noisy", language: "en", reference: english.reference,
                                audio: withNoise(english.audio, gain: 0.012)))
        fixtures.append(Fixture(id: "zh-en-joined", language: nil, reference: chinese.reference + " " + english.reference,
                                audio: chinese.audio + Array(silence.prefix(rate / 5)) + english.audio))
        fixtures.append(Fixture(id: "short-ko", language: "ko", reference: "조금만",
                                audio: Array(korean.audio[4_800..<22_400])))
        fixtures.append(Fixture(id: "en-long", language: "en", reference: Array(repeating: english.reference, count: 3).joined(separator: " "),
                                audio: english.audio + english.audio + english.audio))
        return fixtures
    }

    private static func withNoise(_ audio: [Float], gain: Float) -> [Float] {
        var state: UInt32 = 42
        return audio.map { sample in
            state = state &* 1_664_525 &+ 1_013_904_223
            let uniform = Float(state >> 8) / Float(1 << 24)
            return sample + (uniform * 2 - 1) * gain
        }
    }

    private static func recognize(_ audio: [Float], fixture: Fixture, sense: SenseVoiceRecognizer,
                                  confirmedSpeech: Bool = false, preview: Bool = false,
                                  score: Bool = true) async throws -> Recognition {
        let candidates: [String]
        switch fixture.language {
        case "ja": candidates = ["ja", "en"]
        case "ko": candidates = ["ko", "en"]
        default: candidates = ["zh", "en"]
        }
        let start = ContinuousClock.now
        let result = try await sense.recognize(audio, candidates: candidates,
                                               fallback: candidates[0], preview: preview,
                                               confirmedSpeech: confirmedSpeech)
        return Recognition(text: result.text, language: result.text.isEmpty ? nil : result.language,
                           errorRate: score ? errorRate(fixture.reference, result.text, language: fixture.language) : nil,
                           milliseconds: milliseconds(start.duration(to: .now)))
    }

    private static func segment(_ fixture: Fixture, config: Segmenter.Config,
                                sense: SenseVoiceRecognizer) async throws -> Segmentation {
        let segmenter = Segmenter()
        guard let detector = SileroSpeechDetector() else { throw FixtureError(id: "Silero") }
        segmenter.speechDetector = detector
        segmenter.config = config
        var starts: [Int: Int64] = [:]
        var chunks: [(start: Int64, end: Int64, audio: [Float], confirmed: Bool)] = []
        var firstPreview: (frame: Int64, samples: [Float])?
        var discarded = 0
        segmenter.onEvent = { event in
            switch event {
            case .started(let id, let start): starts[id] = start
            case .partial(let id, let samples):
                if firstPreview == nil, let start = starts[id] {
                    firstPreview = (start + Int64(samples.count), samples)
                }
            case .ended(let id, let samples, let end, let confirmed):
                if let start = starts[id] { chunks.append((start, end, samples, confirmed)) }
            case .discarded: discarded += 1
            default: break
            }
        }
        for offset in stride(from: 0, to: fixture.audio.count, by: 1_600) {
            try Task.checkCancellation()
            let end = min(fixture.audio.count, offset + 1_600)
            segmenter.feed(Array(fixture.audio[offset..<end]), startingAt: Int64(offset))
        }
        segmenter.flush()
        let previewMs: Double?
        if let firstPreview {
            previewMs = try await recognize(firstPreview.samples, fixture: fixture, sense: sense,
                                            preview: true, score: false).milliseconds
        } else {
            previewMs = nil
        }
        var results: [SegmentResult] = []
        var overlaps = 0
        for chunk in chunks {
            try Task.checkCancellation()
            if let previous = results.last, chunk.start < previous.endFrame { overlaps += 1 }
            let recognized = try await recognize(chunk.audio, fixture: fixture, sense: sense,
                                                  confirmedSpeech: chunk.confirmed, score: false)
            results.append(SegmentResult(startFrame: chunk.start, endFrame: chunk.end, recognition: recognized))
        }
        let text = results.map(\.recognition.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return Segmentation(prerollMs: config.prerollMs,
                            firstPreviewAtMs: firstPreview.map { Double($0.frame) * 1_000 / Double(rate) },
                            firstPreviewInferenceMs: previewMs,
                            discardedSegments: discarded, overlappingBoundaries: overlaps,
                            errorRate: errorRate(fixture.reference, text, language: fixture.language),
                            missed: !fixture.reference.isEmpty && text.isEmpty,
                            falseSpeech: fixture.reference.isEmpty && !text.isEmpty, segments: results)
    }

    private static func milliseconds(_ elapsed: Duration) -> Double {
        let parts = elapsed.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func errorRate(_ reference: String, _ hypothesis: String, language: String?) -> Double? {
        func units(_ text: String) -> [String] {
            let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
            if language == "en" {
                return normalized.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
            }
            return normalized.filter { $0.isLetter || $0.isNumber }.map(String.init)
        }
        let expected = units(reference), observed = units(hypothesis)
        guard !expected.isEmpty else { return nil }
        var previous = Array(0...observed.count)
        for (row, unit) in expected.enumerated() {
            var current = [row + 1]
            for (column, other) in observed.enumerated() {
                current.append(min(current[column] + 1, previous[column + 1] + 1,
                                   previous[column] + (unit == other ? 0 : 1)))
            }
            previous = current
        }
        return Double(previous[observed.count]) / Double(expected.count)
    }
}
#endif
