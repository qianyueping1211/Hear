import Foundation

/// 估计说话人的基频（音高），用于“接近说话人音色”的朗读
enum VoiceAnalyzer {
    /// 输入 16kHz 单声道采样，返回中位基频（Hz），无法判断时返回 nil
    static func estimateF0(_ x: [Float], sampleRate: Float = 16_000) -> Float? {
        let frame = 640                                   // 40ms
        let minLag = Int(sampleRate / 400)                // 最高 400Hz
        let maxLag = Int(sampleRate / 70)                 // 最低 70Hz
        var f0s: [Float] = []
        var i = 0
        x.withUnsafeBufferPointer { p in
            while i + frame + maxLag < p.count && f0s.count < 120 {
                var energy: Float = 0
                for k in 0..<frame { energy += p[i + k] * p[i + k] }
                if energy / Float(frame) > 1e-4 {
                    var best: Float = 0
                    var bestLag = 0
                    for lag in minLag...maxLag {
                        var s: Float = 0
                        for k in 0..<frame { s += p[i + k] * p[i + k + lag] }
                        if s > best { best = s; bestLag = lag }
                    }
                    if bestLag > 0, best / energy > 0.5 {
                        f0s.append(sampleRate / Float(bestLag))
                    }
                }
                i += frame
            }
        }
        guard f0s.count >= 5 else { return nil }
        f0s.sort()
        return f0s[f0s.count / 2]
    }
}
