import Foundation

enum SpeechTextFilter {
    /// Model labels break ties when the writing systems overlap. Kana and Hangul
    /// identify their own languages; Latin product names can be part of Chinese.
    static func resolveLanguage(_ text: String, detected: String?, candidates: [String],
                                fallback: String) -> String? {
        let scalars = text.unicodeScalars
        if candidates.contains("ja"), scalars.contains(where: { $0.properties.isAlphabetic && isKana($0.value) }) {
            return "ja"
        }
        if candidates.contains("ko"), scalars.contains(where: { $0.properties.isAlphabetic && inScript($0.value, "ko") }) {
            return "ko"
        }

        if candidates.contains("zh"), candidates.contains("en") {
            var han = 0
            var latinRuns = 0
            var inLatin = false
            for scalar in scalars {
                if inScript(scalar.value, "zh") { han += 1 }
                let latin = scalar.properties.isAlphabetic && isLatin(scalar.value)
                if latin && !inLatin { latinRuns += 1 }
                inLatin = latin
            }
            if han >= 2, latinRuns > 0, han >= latinRuns || detected == "zh" { return "zh" }
        }

        if let detected, candidates.contains(detected), matchesLanguage(text, detected) { return detected }
        if candidates.contains(fallback), matchesLanguage(text, fallback) { return fallback }
        return candidates.first { matchesLanguage(text, $0) }
    }

    static func retryLanguage(_ text: String, detected: String?, candidates: [String],
                              confirmedSpeech: Bool = false) -> String? {
        guard let detected, detected != "nospeech" else { return nil }
        // Retry only when part of a plausibly spoken result supports the model's
        // label, even though the full text didn't pass the script check.
        func supports(_ language: String, minimum: Int) -> Bool {
            text.unicodeScalars.lazy.filter { $0.properties.isAlphabetic && inScript($0.value, language) }
                .prefix(minimum).count == minimum
        }
        if candidates.contains(detected) { return supports(detected, minimum: 2) ? detected : nil }
        guard confirmedSpeech else { return nil }
        let supported = candidates.filter { supports($0, minimum: 3) }
        return supported.count == 1 ? supported.first : nil
    }

    static func matchesLanguage(_ text: String, _ lang: String) -> Bool {
        var total = 0, hit = 0
        var inLatinRun = false
        let cjkLang = ["zh", "ja", "ko"].contains(lang)
        for s in text.unicodeScalars {
            guard s.properties.isAlphabetic else { inLatinRun = false; continue }
            let latin = isLatin(s.value)
            if cjkLang && latin {
                if inLatinRun { continue }      // 一串英文字母只算一个
                inLatinRun = true
            } else {
                inLatinRun = false
            }
            total += 1
            if inScript(s.value, lang) { hit += 1 }
        }
        guard total > 0 else {
            // 一个字母都没有（纯数字、订单号、"2026"这种）：
            // 判断不了语言，但也不能因为这个把用户说的话丢掉
            return true
        }
        return Double(hit) / Double(total) >= 0.6
    }

    private static func isLatin(_ v: UInt32) -> Bool {
        (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) ||
        (0xC0...0x24F).contains(v) || (0x1E00...0x1EFF).contains(v)
    }

    private static func isKana(_ v: UInt32) -> Bool {
        (0x3040...0x30FF).contains(v)
    }

    private static func inScript(_ v: UInt32, _ lang: String) -> Bool {
        let han = (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
        switch lang {
        case "zh": return han
        case "ja": return han || isKana(v)
        case "ko": return (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v)
        case "ru": return (0x0400...0x04FF).contains(v)
        case "ar": return (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v)
        case "th": return (0x0E00...0x0E7F).contains(v)
        default:   return isLatin(v)            // 英、法、德、西、葡、意、越 等拉丁字母语言
        }
    }

    /// 过滤 Whisper 在噪声/静音上常见的“幻觉”句子
    static func isMeaningful(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if t.count < 1 { return false }
        if Fillers.isOnlyFillers(t) { return false }        // 只有「嗯」「啊」这类语气词
        let junk = ["字幕", "订阅", "點贊", "点赞", "打赏", "Amara", "谢谢观看", "感谢观看",
                    "Thank you for watching", "Thanks for watching", "Subtitles by", "明镜", "请不吝",
                    "Продолжение следует", "Субтитры", "Редактор субтитров", "ご視聴ありがとうございました",
                    "MBC 뉴스", "시청해주셔서"]
        if junk.contains(where: { t.localizedCaseInsensitiveCompare($0) == .orderedSame }) { return false }
        if t.hasPrefix("[") || t.hasPrefix("(") || t.hasPrefix("（") { return false }
        // 背景声的描述，例如 *Humming*、♪音乐♪、(笑声)
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("*") || raw.hasPrefix("♪") || raw.hasPrefix("[") || raw.hasPrefix("(") || raw.hasPrefix("（") {
            return false
        }
        if raw.contains("*") || raw.contains("♪") { return false }      // 例如 “Burz*.”
        return true
    }

    /// 扬声器外放文本级回声兜底过滤：
    /// 仅拦截“极短时间窗口内（默认 2.5s）与刚播完的译文几乎完全一致”的复录，
    /// 绝不用字符集/词袋/短子串匹配，避免把对方的正常短回复（如 "Sure"、"12点"）误判为回声。
    static func isLikelySpokenEcho(
        _ recognized: String,
        recentSpoken: [(text: String, at: Date)],
        now: Date = Date(),
        window: TimeInterval = 2.5
    ) -> Bool {
        func normalize(_ s: String) -> String {
            s.unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map { Character($0).lowercased() }
                .joined()
        }
        let a = normalize(recognized)
        guard !a.isEmpty else { return false }
        for entry in recentSpoken {
            let dt = now.timeIntervalSince(entry.at)
            guard dt >= -0.5, dt <= window else { continue }
            let b = normalize(entry.text)
            guard !b.isEmpty else { continue }
            if a == b { return true }
            let minLen = min(a.count, b.count)
            let maxLen = max(a.count, b.count)
            guard minLen >= 8 else { continue }
            let maxDist = max(1, Int(Double(maxLen) * 0.12))
            if abs(a.count - b.count) <= maxDist, editDistance(a, b, limit: maxDist) <= maxDist {
                return true
            }
        }
        return false
    }

    private static func editDistance(_ s1: String, _ s2: String, limit: Int) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            var rowMin = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                let v = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
                curr[j] = v
                if v < rowMin { rowMin = v }
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
