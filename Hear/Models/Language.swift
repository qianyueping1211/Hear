import Foundation

/// 支持的语言（Whisper 语音识别代码 + Hy-MT2 翻译用的语言名 + 系统朗读用的 locale）
struct Language: Identifiable, Hashable, Codable {
    let id: String        // Whisper 语言代码，例如 "zh"、"en"
    let flag: String
    let name: String      // 界面显示
    let zhName: String    // 中文提示词里用的语言名
    let enName: String    // 英文提示词里用的语言名
    let tts: String       // AVSpeechSynthesisVoice 的语言

    static let all: [Language] = [
        .init(id: "zh", flag: "🇨🇳", name: "中文",       zhName: "中文",     enName: "Chinese",    tts: "zh-CN"),
        .init(id: "en", flag: "🇺🇸", name: "English",    zhName: "英语",     enName: "English",    tts: "en-US"),
        .init(id: "ja", flag: "🇯🇵", name: "日本語",      zhName: "日语",     enName: "Japanese",   tts: "ja-JP"),
        .init(id: "ko", flag: "🇰🇷", name: "한국어",      zhName: "韩语",     enName: "Korean",     tts: "ko-KR"),
        .init(id: "ar", flag: "🇦🇪", name: "العربية",    zhName: "阿拉伯语", enName: "Arabic",     tts: "ar-SA"),
        .init(id: "fr", flag: "🇫🇷", name: "Français",   zhName: "法语",     enName: "French",     tts: "fr-FR"),
        .init(id: "de", flag: "🇩🇪", name: "Deutsch",    zhName: "德语",     enName: "German",     tts: "de-DE"),
        .init(id: "es", flag: "🇪🇸", name: "Español",    zhName: "西班牙语", enName: "Spanish",    tts: "es-ES"),
        .init(id: "ru", flag: "🇷🇺", name: "Русский",    zhName: "俄语",     enName: "Russian",    tts: "ru-RU"),
        .init(id: "pt", flag: "🇧🇷", name: "Português",  zhName: "葡萄牙语", enName: "Portuguese", tts: "pt-BR"),
        .init(id: "it", flag: "🇮🇹", name: "Italiano",   zhName: "意大利语", enName: "Italian",    tts: "it-IT"),
        .init(id: "th", flag: "🇹🇭", name: "ไทย",        zhName: "泰语",     enName: "Thai",       tts: "th-TH"),
        .init(id: "vi", flag: "🇻🇳", name: "Tiếng Việt", zhName: "越南语",   enName: "Vietnamese", tts: "vi-VN"),
    ]

    static func find(_ id: String) -> Language {
        all.first { $0.id == id } ?? all[0]
    }
}

/// 一条翻译记录
struct TranslationItem: Identifiable, Equatable {
    let id = UUID()
    let source: Language
    let target: Language
    var sourceText: String
    var translated: String = ""
    var done = false
}
