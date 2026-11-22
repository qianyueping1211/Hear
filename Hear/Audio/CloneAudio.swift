import Foundation

struct CloneAudio: Sendable {
    var samples: [Float]
    var sampleRate: Int

    /// Keep a little room around speech and leave every pause inside the sentence intact.
    func trimmingEdgeSilence() -> (audio: CloneAudio, leading: Int, trailing: Int)? {
        guard (8_000...96_000).contains(sampleRate), !samples.isEmpty else { return nil }
        let window = sampleRate / 100
        var levels: [Float] = []
        levels.reserveCapacity((samples.count + window - 1) / window)
        for start in stride(from: 0, to: samples.count, by: window) {
            let end = min(start + window, samples.count)
            var sum = 0.0
            var power = 0.0
            for sample in samples[start..<end] {
                guard sample.isFinite else { return nil }
                let amplitude = max(-1, min(1, Double(sample)))
                sum += amplitude
                power += amplitude * amplitude
            }
            let n = Double(end - start)
            let mean = sum / n
            levels.append(Float(sqrt(max(0, power / n - mean * mean))))
        }

        let threshold = max(0.0005, (levels.max() ?? 0) * 0.035)
        var previous: Int?
        var first: Int?
        var last = 0
        for (index, level) in levels.enumerated() where level >= threshold {
            // A lone click in the silence should not become the start or end of a sentence.
            if let previous, index - previous <= 2 {
                if first == nil { first = previous }
                last = index
            }
            previous = index
        }
        guard let first else { return nil }
        let start = max(0, (first - 8) * window)
        let end = min(samples.count, (last + 11) * window)
        let trailing = samples.count - end
        guard start > 0 || trailing > 0 else { return (self, 0, 0) }

        var clipped = Array(samples[start..<end])
        let fade = min(window / 2, clipped.count / 2)
        for i in 0..<fade {
            let gain = Float(i) / Float(fade)
            if start > 0 { clipped[i] *= gain }
            if trailing > 0 { clipped[clipped.count - 1 - i] *= gain }
        }
        return (CloneAudio(samples: clipped, sampleRate: sampleRate), start, trailing)
    }
}
