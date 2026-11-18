import Foundation
import Translation

extension Language {
    /// 苹果翻译用的语言代码（中文要指明简体）
    var appleLanguage: Locale.Language {
        Locale.Language(identifier: id == "zh" ? "zh-Hans" : tts)
    }
}

/// iOS 自带的翻译引擎（和“翻译”App 共用语言包，在手机本地运行）
final class SystemTranslator {
    enum Availability { case installed, needsDownload, unsupported }

    private var sessions: [String: AnyObject] = [:]

    /// 这两种语言之间能不能用苹果翻译、语言包下载了没有
    static func availability(_ a: Language, _ b: Language) async -> Availability {
        let status = await LanguageAvailability().status(from: a.appleLanguage, to: b.appleLanguage)
        switch status {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
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
                session = TranslationSession(installedSource: src.appleLanguage, target: tgt.appleLanguage)
                sessions[key] = session
            }
            let response = try await session.translate(text)
            return response.targetText
        }
        #endif
        throw LiveTextError.unsupportedLanguage
    }

    /// 语言变了或出错后丢掉旧的会话
    func reset() { sessions.removeAll() }
}
