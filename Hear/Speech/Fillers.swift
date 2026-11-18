import Foundation

/// 口语里的语气词（嗯、啊、呃、um、uh…）过滤。
///
/// 规则（所有语言通用）：
/// 1. 按标点和空格把一句话切成小块，整块都是语气词的就去掉，
///    例如「嗯，我觉得，呃，可以」→「我觉得，可以」、「Um, I think so」→「I think so」。
/// 2. 一句话只剩语气词（「嗯」「啊啊」「嗯嗯嗯」「Uh-huh」）就当成没说话，不显示也不翻译。
/// 3. 只去掉单独成块的语气词：「好啊」「对呀」「Oh my god」里的语气词是句子的一部分，保留。
///    中文开头紧贴着的「嗯」「呃」（「呃我觉得」）也去掉。
enum Fillers {
    /// 只要单独出现就一定是语气词（不受标点限制，空格隔开也去掉）
    private static let pure: Set<String> = [
        // 中文
        "嗯", "恩", "呃", "唔", "嗯哼", "呣",
        // 英文
        "um", "uh", "er", "erm", "hm", "mm", "mhm", "uhm", "uhuh", "uhhuh", "mmhm", "ehm",
        // 日文
        "えー", "えっと", "えーと", "えと", "うーん", "あのー", "んー",
        // 韩文
        "음", "으음",
        // 其他欧洲语言常见的
        "euh", "äh", "ähm", "eh", "ehh", "eeh", "hmm",
    ]
    /// 单独成句、或前后都是标点时才算语气词（例如「啊，」「Oh,」）
    private static let soft: Set<String> = [
        "啊", "哦", "噢", "喔", "哎", "诶", "欸", "唉", "哈", "呀", "哇", "嘿", "额", "嗷", "哟", "呵",
        "哈哈", "呵呵", "嘿嘿", "啊哈", "哎呀", "哎哟", "嗯嗯",
        "oh", "ah", "huh", "ha", "haha", "wow", "ooh", "aha", "hey",
        "あー", "あ", "ん", "へー", "ほう",
        "아", "오", "에", "흠", "어", "그", "저기",
    ]

    /// 中文句首紧贴着的语气词（这几个字基本不会出现在词语开头）
    private static let leadingZH: Set<Character> = ["嗯", "呃", "唔"]

    /// 去掉语气词后的文字；全是语气词时返回空字符串
    static func clean(_ text: String) -> String {
        // 切成小块：每块 = 一串正文 + 后面跟着的分隔符（标点 / 空格）
        var chunks: [(core: String, sep: String)] = []
        var core = "", sep = ""
        for ch in text {
            if isSeparator(ch) {
                sep.append(ch)
            } else {
                if !sep.isEmpty { chunks.append((core, sep)); core = ""; sep = "" }
                core.append(ch)
            }
        }
        if !core.isEmpty || !sep.isEmpty { chunks.append((core, sep)) }

        var kept: [(core: String, sep: String)] = []
        for (i, c) in chunks.enumerated() {
            let key = normalize(c.core)
            if key.isEmpty { kept.append(c); continue }
            // "mm" 合并后只剩 "m"：原文至少两个 m 才算（避免 I'm 之类）
            if pure.contains(key) || (key == "m" && c.core.count >= 2) { continue }
            if soft.contains(key) || isLaugh(key) {
                // 前后都是标点（或在句首/句尾）才去掉；只隔着空格的保留（例如 "oh my god"）
                let before = i == 0 || hasPunct(chunks[i - 1].sep)
                let after = i == chunks.count - 1 || hasPunct(c.sep)
                if before && after { continue }
            }
            kept.append(c)
        }

        var out = kept.map { $0.core + $0.sep }.joined()
        // 中文句首紧贴的「嗯」「呃」：「呃我觉得」→「我觉得」
        while let f = out.first, leadingZH.contains(f), out.count > 1,
              let next = out.dropFirst().first, isCJK(next) {
            out.removeFirst()
        }
        // 去掉开头残留的标点空格，结尾残留的逗号顿号
        while let f = out.first, isSeparator(f) { out.removeFirst() }
        while let l = out.last, l == "，" || l == "," || l == "、" || l == " " || l == "；" { out.removeLast() }
        return out
    }

    /// 是否只有语气词（或什么都没有）
    static func isOnlyFillers(_ text: String) -> Bool {
        clean(text).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
    }

    // MARK: - 工具

    /// 小写、去掉连字符，连续重复的字母合并（"ummm"→"um"，"嗯嗯嗯"→"嗯"，"啊啊"→"啊"）
    private static func normalize(_ s: String) -> String {
        let base = s.lowercased().filter { $0 != "-" && $0 != "‐" && $0 != "~" && $0 != "～" }
        var out = ""
        for ch in base where out.last != ch { out.append(ch) }
        // 「嗯嗯」这类重复整词：合并后是「嗯」；「哈哈」合并后是「哈」，也都在列表里
        return out
    }

    private static func isSeparator(_ ch: Character) -> Bool {
        // 撇号不算分隔（I'm、don't 是一个词）
        if ch == "'" || ch == "’" { return false }
        return ch.isWhitespace || ch.isPunctuation || ch == "…" || ch == "～" || ch == "~"
    }

    /// 笑声：haha、hahaha、hehe
    private static func isLaugh(_ key: String) -> Bool {
        guard key.count >= 3, key.hasPrefix("h") else { return false }
        let set = Set(key)
        return set == ["h", "a"] || set == ["h", "e"]
    }

    private static func hasPunct(_ sep: String) -> Bool {
        sep.contains { $0.isPunctuation || $0 == "…" || $0 == "～" || $0 == "~" }
    }

    private static func isCJK(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
    }
}
