import Foundation

/// 识别把连续发言切成几段时，模型有时会把上一段也重新翻一遍。
struct TranslationOutput: Sendable {
    enum Invalid: LocalizedError {
        case empty, earlierSegment

        var errorDescription: String? {
            switch self {
            case .empty: return "模型未返回译文"
            case .earlierSegment: return "模型返回了上一段内容"
            }
        }
    }

    private let earlierClauses: [String]

    init(source: String, target: Language, previous: [TranslationItem]) {
        let sourceClauses = Self.clauses(source)
        earlierClauses = previous.flatMap { item -> [String] in
            guard item.translationError == nil,
                  item.displayedTranslationTarget == target, item.canReadAloud else { return [] }
            let earlierSource = Self.clauses(item.sourceText)
            // 用户确实重复了同一句或同一个分句时，允许相同的译文。
            guard !sourceClauses.contains(where: { current in
                current.count >= 12 && earlierSource.contains { Self.similar(current, $0, threshold: 0.45) }
            }) else { return [] }
            return Self.clauses(item.translated).filter { $0.count >= 16 }
        }
    }

    func validated(_ translation: String) throws -> String {
        let value = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw Invalid.empty }
        guard !repeatsEarlier(Self.clauses(value)) else { throw Invalid.earlierSegment }
        return value
    }

    func acceptsPartial(_ translation: String) -> Bool {
        if earlierClauses.isEmpty { return !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let clauses = Self.clauses(translation)
        guard let last = clauses.last else { return false }
        return !repeatsEarlier(clauses) && !earlierClauses.contains { $0.hasPrefix(last) }
    }

    private func repeatsEarlier(_ clauses: [String]) -> Bool {
        clauses.contains { current in
            current.count >= 16 && earlierClauses.contains { Self.similar(current, $0, threshold: 0.72) }
        }
    }

    private static func clauses(_ text: String) -> [String] {
        text.replacingOccurrences(of: #"(?<=[.!?;])\s+|[。！？；\n]+"#, with: "\n", options: .regularExpression)
            .split(separator: "\n")
            .map { String($0.lowercased().filter { $0.isLetter || $0.isNumber }) }
            .filter { !$0.isEmpty }
    }

    private static func similar(_ a: String, _ b: String, threshold: Double) -> Bool {
        if a == b { return true }
        let shorter = min(a.count, b.count)
        guard shorter >= 8 else { return false }
        if a.contains(b) || b.contains(a) { return true }
        func trigrams(_ text: String) -> Set<String> {
            let characters = Array(text)
            return Set((0..<(characters.count - 2)).map { String(characters[$0...($0 + 2)]) })
        }
        let first = trigrams(a), second = trigrams(b)
        return Double(first.intersection(second).count * 2) / Double(first.count + second.count) >= threshold
    }
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
