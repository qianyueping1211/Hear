import Foundation

enum SpeechTextFilter {
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

    private static func inScript(_ v: UInt32, _ lang: String) -> Bool {
        let han = (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
        switch lang {
        case "zh": return han
        case "ja": return han || (0x3040...0x30FF).contains(v)
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
}
