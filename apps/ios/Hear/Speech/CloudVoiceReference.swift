import Foundation

/// 用 llama.cpp 跑 Qwen3-TTS 的声音克隆。
enum CloudVoiceReference {
    static let languageNames: [String: String] = [
        "zh": "chinese", "en": "english", "ja": "japanese", "ko": "korean",
        "de": "german", "fr": "french", "ru": "russian", "pt": "portuguese",
        "es": "spanish", "it": "italian",
    ]

    /// 简单降噪参考音频：
    /// 1) 一阶高通（80 Hz）去掉隆隆声和直流偏置
    /// 2) 按 20 ms 一段估底噪，把比底噪还安静的部分压下去（环境音里的大多是这种）
    /// 语音本身基本不动，所以不会把说话声也削掉。
    static func denoise(_ samples: [Float], sampleRate: Int = 16_000) -> [Float] {
        guard samples.count > 512 else { return samples }
        let origPeak = peak(of: samples)
        var out = [Float](repeating: 0, count: samples.count)

        // 1) 一阶高通（80 Hz）：去掉隆隆声、直流偏置
        //    rc = 1/(2*pi*fc) 是秒，dt = 1/fs 也是秒，两者单位一致
        let dt = 1.0 / Float(sampleRate)
        let rc = 1.0 / (2.0 * Float.pi * 80.0)
        let a = rc / (rc + dt)
        var prevIn: Float = 0
        var prevOut: Float = 0
        for i in samples.indices {
            let x = samples[i]
            let y = a * (prevOut + x - prevIn)
            out[i] = y
            prevIn = x
            prevOut = y
        }

        // 2) 底噪估计：20 ms 一段，取能量较低的 20% 当底噪
        let win = max(1, sampleRate / 50)
        var levels: [Float] = []
        var i = 0
        while i + win <= out.count {
            var sum: Float = 0
            for k in i..<(i + win) { sum += out[k] * out[k] }
            levels.append(sqrt(sum / Float(win)))
            i += win
        }
        guard !levels.isEmpty else { return out }
        let sorted = levels.sorted()
        let idx = max(0, Int(Double(sorted.count) * 0.2) - 1)
        let floorLevel = sorted[idx]
        // 底噪比说话声低很多时才做门限，否则说明一直在说话，别乱压
        let median = sorted[sorted.count / 2]
        if floorLevel > 0, median > floorLevel * 4 {
            let gate = max(floorLevel * 2.0, 0.002)
            var j = 0
            while j + win <= out.count {
                var sum: Float = 0
                for k in j..<(j + win) { sum += out[k] * out[k] }
                let rms = sqrt(sum / Float(win))
                if rms < gate {
                    // 压到底噪的一半，不是一刀切静音（免得把字头也削掉）
                    let k = 0.5 + 0.5 * (rms / gate)
                    for idx2 in j..<(j + win) { out[idx2] *= k }
                }
                j += win
            }
        }

        // 3) 安全检查：处理完不能明显变小，否则说明滤过头了，用原声
        let newPeak = peak(of: out)
        if newPeak < origPeak * 0.5 || newPeak < 0.0001 {
            hearLog("声音克隆：降噪后声音太小，改用原始参考音频", .warning)
            return samples
        }
        return out
    }

    /// 一段声音的最大绝对值
    private static func peak(of samples: [Float]) -> Float {
        var p: Float = 0
        for s in samples { let a = abs(s); if a > p { p = a } }
        return p
    }

}
