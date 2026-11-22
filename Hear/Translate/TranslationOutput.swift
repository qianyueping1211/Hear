import Foundation

/// 上文只参与恢复分段处的已知词形，翻译引擎只接收整理后的当前段。
enum TranslationSource {
    static func currentSegment(_ text: String, language: Language, after previous: TranslationItem?) -> String {
        guard language.id == "en", let previous, previous.source == language,
              let start = text.range(of: #"^\s*(west(?:ern)?)\b"#, options: [.regularExpression, .caseInsensitive]),
              previous.sourceText.range(of: #"\bmid[\s,\-]*$"#,
                                        options: [.regularExpression, .caseInsensitive]) != nil else { return text }
        let fragment = text[start].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "Mid" + fragment + String(text[start.upperBound...])
    }
}

enum TranslationResultError: LocalizedError {
    case empty
    var errorDescription: String? { "模型未返回译文" }
}

enum TranslationRevision {
    private static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var word = ""
        for character in text {
            let scalar = character.unicodeScalars.first?.value ?? 0
            let canJoinWord = (character.isLetter || character.isNumber)
                && !(0x3000...0x9FFF).contains(scalar) && !(0x20000...0x323AF).contains(scalar)
            if canJoinWord {
                word.append(character)
            } else {
                if !word.isEmpty {
                    result.append(word)
                    word = ""
                }
                result.append(String(character))
            }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }

    static func changes(from previous: String, to current: String) -> [(text: String, changed: Bool)] {
        let updated = tokens(current)
        let inserted = Set(updated.difference(from: tokens(previous)).insertions.compactMap { change -> Int? in
            guard case .insert(let offset, _, _) = change else { return nil }
            return offset
        })
        return updated.enumerated().map { index, token in
            (token, inserted.contains(index) && !token.allSatisfy(\.isWhitespace))
        }
    }
}
