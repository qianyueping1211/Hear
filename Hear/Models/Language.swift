import Foundation

/// 支持的语言（Whisper 语音识别代码 + Hy-MT2 翻译用的语言名 + 系统朗读用的 locale）
struct Language: Identifiable, Hashable, Codable {
    let id: String        // Whisper 语言代码，例如 "zh"、"en"
    let flag: String
    let name: String      // 界面显示
    let zhName: String    // 中文提示词里用的语言名
    let enName: String    // 英文提示词里用的语言名
    let tts: String       // AVSpeechSynthesisVoice 的语言
    let country: String   // 国家/地区简称

    /// 例如 “العربية（阿联酋）”
    var displayName: String { "\(name)（\(country)）" }

    static let all: [Language] = [
        .init(id: "zh", flag: "🇨🇳", name: "中文",       zhName: "中文",     enName: "Chinese",    tts: "zh-CN", country: "中国"),
        .init(id: "en", flag: "🇺🇸", name: "English",    zhName: "英语",     enName: "English",    tts: "en-US", country: "美国"),
        .init(id: "ja", flag: "🇯🇵", name: "日本語",      zhName: "日语",     enName: "Japanese",   tts: "ja-JP", country: "日本"),
        .init(id: "ko", flag: "🇰🇷", name: "한국어",      zhName: "韩语",     enName: "Korean",     tts: "ko-KR", country: "韩国"),
        .init(id: "ar", flag: "🇦🇪", name: "العربية",    zhName: "阿拉伯语", enName: "Arabic",     tts: "ar-SA", country: "阿联酋"),
        .init(id: "fr", flag: "🇫🇷", name: "Français",   zhName: "法语",     enName: "French",     tts: "fr-FR", country: "法国"),
        .init(id: "de", flag: "🇩🇪", name: "Deutsch",    zhName: "德语",     enName: "German",     tts: "de-DE", country: "德国"),
        .init(id: "es", flag: "🇪🇸", name: "Español",    zhName: "西班牙语", enName: "Spanish",    tts: "es-ES", country: "西班牙"),
        .init(id: "ru", flag: "🇷🇺", name: "Русский",    zhName: "俄语",     enName: "Russian",    tts: "ru-RU", country: "俄罗斯"),
        .init(id: "pt", flag: "🇧🇷", name: "Português",  zhName: "葡萄牙语", enName: "Portuguese", tts: "pt-BR", country: "巴西"),
        .init(id: "it", flag: "🇮🇹", name: "Italiano",   zhName: "意大利语", enName: "Italian",    tts: "it-IT", country: "意大利"),
        .init(id: "th", flag: "🇹🇭", name: "ไทย",        zhName: "泰语",     enName: "Thai",       tts: "th-TH", country: "泰国"),
        .init(id: "vi", flag: "🇻🇳", name: "Tiếng Việt", zhName: "越南语",   enName: "Vietnamese", tts: "vi-VN", country: "越南"),
    ]

    static func find(_ id: String) -> Language {
        all.first { $0.id == id } ?? all[0]
    }
}

struct SpeakerDetails: Codable, Equatable {
    enum Gender: String, Codable, CaseIterable {
        case male, female

        var title: String { self == .male ? "男性" : "女性" }
    }

    enum Accent: String, Codable, CaseIterable {
        case standard, chinese, indian, unknown

        var title: String {
            switch self {
            case .standard: return "标准发音"
            case .chinese: return "中国口音"
            case .indian: return "印度口音"
            case .unknown: return "未知口音"
            }
        }
    }

    var gender: Gender? = nil
    var commonLanguage: String? = nil
    var accent: Accent? = nil
}

/// 一条翻译记录
struct TranslationItem: Identifiable, Equatable, Codable {
    enum SourceSide: String, Codable { case left, right }

    var id = UUID()
    let source: Language
    let target: Language
    var sourceText: String
    var translated: String = ""
    var done = false
    var speakerF0: Float? = nil   // 说话人音高（Hz），用于“接近说话人音色”
    var corrected: Bool? = nil    // SenseVoice 的结果被 Whisper 校正过
    var speakerID: Int? = nil
    var speakerName: String? = nil
    var speakerDetails: SpeakerDetails? = nil
    var speakerTracked: Bool? = nil
    var speakerManuallySet: Bool? = nil
    var sourceProvisional: Bool? = nil
    var sourceSide: SourceSide? = nil
    var recognizedLanguage: String? = nil

    var defaultSpeakerLanguage: String { recognizedLanguage ?? source.id }

    var canReadAloud: Bool { !translated.isEmpty && !translated.hasPrefix("（翻译失败") }

    func isLeading(left: Language, right: Language) -> Bool {
        displayedSide(left: left, right: right) == .left
    }

    mutating func updateSide(from previous: (left: Language, right: Language),
                             to current: (left: Language, right: Language)) {
        sourceSide = matchingSide(left: current.left, right: current.right)
            ?? displayedSide(left: previous.left, right: previous.right)
    }

    private func displayedSide(left: Language, right: Language) -> SourceSide {
        matchingSide(left: left, right: right) ?? sourceSide ?? (target.id == left.id ? .right : .left)
    }

    private func matchingSide(left: Language, right: Language) -> SourceSide? {
        let language = recognizedLanguage ?? source.id
        if language == left.id { return .left }
        if language == right.id { return .right }
        return nil
    }

    var speakerLabel: String? {
        if let speakerID { return speakerName ?? "说话人 \(speakerID)" }
        return speakerTracked == true ? "未分配" : nil
    }
}

enum ConversationSpeakerEdit {
    case saveProfile(name: String, details: SpeakerDetails, newSpeaker: Bool)
    case assign(Int?)
}

extension Array where Element == TranslationItem {
    var speakerLabels: [Int: String] {
        reduce(into: [:]) { labels, item in
            if let id = item.speakerID, let label = item.speakerLabel { labels[id] = label }
        }
    }

    @discardableResult
    mutating func editSpeaker(itemID: UUID, change: ConversationSpeakerEdit, reservedThrough: Int = 0) -> Bool {
        guard let index = firstIndex(where: { $0.id == itemID }) else { return false }
        switch change {
        case let .saveProfile(input, details, newSpeaker):
            let name = Self.cleanSpeakerText(input, limit: 40)
            let id: Int
            if let current = self[index].speakerID, !newSpeaker {
                id = current
            } else {
                id = Swift.max(compactMap(\.speakerID).max() ?? 0, reservedThrough) + 1
                self[index].speakerID = id
                self[index].speakerTracked = true
                self[index].speakerManuallySet = true
            }
            let savedDetails = details == SpeakerDetails() ? nil : details
            for i in indices where self[i].speakerID == id {
                self[i].speakerName = name
                self[i].speakerDetails = savedDetails
            }
        case .assign(let id):
            let speaker = id.flatMap { speakerID in first { $0.speakerID == speakerID } }
            if id != nil, speaker == nil { return false }
            self[index].speakerID = id
            self[index].speakerName = speaker?.speakerName
            self[index].speakerDetails = speaker?.speakerDetails
            self[index].speakerTracked = true
            self[index].speakerManuallySet = true
        }
        return true
    }

    private static func cleanSpeakerText(_ input: String, limit: Int) -> String? {
        let value = String(input.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
        return value.isEmpty ? nil : value
    }
}
