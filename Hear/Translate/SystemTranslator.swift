import Foundation
import Translation

/// iOS 自带的翻译引擎（和“翻译”App 共用语言包，在手机本地运行）。
///
/// 两件事必须做对，不然苹果翻译就是用不了：
///  1) 语言标识要用苹果自己的写法（有的语言它写 "en-US"，有的只写 "en"）。
///     写错了它就当“这个语言不支持”，语言包连下载都下不下来。
///  2) 语言包必须装好。装语言包只有一个办法：给视图挂 `.translationTask`，
///     由系统来弹下载框；自己 new 一个 TranslationSession 只能翻译“已经装好”的语言，
///     没装的话翻译时会报 unsupportedSourceLanguage。
final class SystemTranslator {
    enum Availability { case installed, needsDownload, unsupported }

    /// 苹果翻译支持的语言标识（系统自己列出来的，最准）
    private var supportedIDs: [Locale.Language] = []
    private var supportedLoaded = false

    /// 每个语言最后用的标识（找过一次就记下来）
    private var resolved: [String: Locale.Language] = [:]

    /// 已经建好的会话（按方向缓存）
    private var sessions: [String: AnyObject] = [:]

    /// 读一次系统支持的语言列表
    func loadSupportedLanguages() async {
        guard !supportedLoaded else { return }
        supportedLoaded = true
        supportedIDs = await LanguageAvailability().supportedLanguages
    }

    /// 这个语言在苹果翻译里对应哪个写法。
    ///
    /// 我们自己的 tts 是 "en-US" "ja-JP" 这种（给朗读用的），
    /// 苹果翻译用的写法不一定一样：有的带地区，有的不带。
    /// 所以按优先级挨个试，挑系统列表里真的有的那个——
    /// 而且用的是系统那一份（不是我们自己拼的），
    /// 这样万一苹果改写法，我们不用跟着改。
    func canonical(_ lang: Language) async -> Locale.Language {
        let key = lang.id
        if let hit = resolved[key] { return hit }
        await loadSupportedLanguages()
        let cands = candidates(lang)
        // 先找完全一样的（语言、脚本、地区都一样）
        for cand in cands {
            let l = Locale.Language(identifier: cand)
            if let hit = supportedIDs.first(where: { sameLanguage($0, l, exact: true) }) {
                resolved[key] = hit
                return hit
            }
        }
        // 再找语言代码一样的（苹果可能用 "en" 而不是 "en-US"）
        for cand in cands {
            let l = Locale.Language(identifier: cand)
            if let hit = supportedIDs.first(where: { sameLanguage($0, l, exact: false) }) {
                resolved[key] = hit
                return hit
            }
        }
        // 系统列表里一个都没对上：先用我们自己的写法，
        // 下面 availability 会报“不支持”，App 会退回别的引擎。
        let guess = Locale.Language(identifier: cands.first ?? lang.id)
        resolved[key] = guess
        return guess
    }

    /// 这个语言在苹果翻译里可能用的写法（按优先级）
    private func candidates(_ lang: Language) -> [String] {
        if lang.id == "zh" { return ["zh-Hans", "zh-Hans-CN", "zh"] }
        var out: [String] = []
        let t = lang.tts                       // "en-US" 这种
        if !t.isEmpty { out.append(t) }
        if lang.id != t { out.append(lang.id) }  // "en" 这种
        return out
    }

    /// 两个语言算不算同一个：
    /// 语言代码必须一样；脚本也一样（简繁不能混）。
    /// exact = true 时地区也要一样。
    private func sameLanguage(_ a: Locale.Language, _ b: Locale.Language, exact: Bool) -> Bool {
        guard a.languageCode == b.languageCode else { return false }
        if exact {
            return a.script == b.script && a.region == b.region
        }
        // 候选写法里没写脚本时（"en"），就不要求脚本一样
        if let sa = a.script, let sb = b.script { return sa == sb }
        return true
    }

    /// 这两种语言之间能不能用苹果翻译、语言包下载了没有
    func availability(_ a: Language, _ b: Language) async -> Availability {
        let src = await canonical(a)
        let tgt = await canonical(b)
        let status = await LanguageAvailability().status(from: src, to: tgt)
        switch status {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported:
            // 系统有时会误报「不支持」（语言包没装好的时候它就是这么说的），
            // 所以还是按“要下载”处理，让系统去弹下载框；
            // 真下不下来（这个语言方向苹果压根不支持）再退回别的引擎。
            return .needsDownload
        @unknown default: return .needsDownload
        }
    }

    static var isSupported: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    func translate(_ text: String, from src: Language, to tgt: Language) async throws -> String {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let key = src.id + ">" + tgt.id
            let session: TranslationSession
            if let s = sessions[key] as? TranslationSession {
                session = s
            } else {
                let s = await canonical(src)
                let t = await canonical(tgt)
                // 这个初始化要求语言包“已经装好”，没装的话翻译的时候会报错
                // （unsupportedSourceLanguage）。装语言包靠 .translationTask。
                session = TranslationSession(installedSource: s, target: t)
                sessions[key] = session
            }
            let response = try await session.translate(text)
            return response.targetText
        }
        #endif
        throw LiveTextError.unsupportedLanguage
    }

    /// 语言变了或语言包刚装好之后，丢掉旧的会话
    func reset() { sessions.removeAll() }
}
