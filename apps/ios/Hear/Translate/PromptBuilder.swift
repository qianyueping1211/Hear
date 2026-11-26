import Foundation

/// 翻译提示词只使用当前原文和与之匹配的术语。
enum PromptBuilder {
    struct GlossaryTerm {
        let aliases: [String]
        let translation: String
    }

    static func build(text: String, from src: Language, to tgt: Language,
                      glossary: [GlossaryTerm]) -> String {
        let terms = glossary.compactMap { term -> (String, String)? in
            guard let match = term.aliases.first(where: { matches($0, in: text) }) else { return nil }
            return (match, term.translation)
        }
        if src.id == tgt.id {
            if tgt.id == "zh" {
                let hints = terms.isEmpty ? "" : "参考下面的翻译：\n" +
                    terms.map { "\($0.0) 翻译成 \($0.1)" }.joined(separator: "\n") + "\n\n"
                return hints + "将以下文本中穿插的外语翻译为\(tgt.zhName)，已是\(tgt.zhName)的部分保留不变，只输出完整的\(tgt.zhName)结果，不要额外解释：\n\n\(text)"
            }
            let hints = terms.isEmpty ? "" : "Refer to the following translations:\n" +
                terms.map { "\($0.0) translates to \($0.1)" }.joined(separator: "\n") + "\n\n"
            return hints + "Translate any foreign parts of the following segment into \(tgt.enName) while keeping text already in \(tgt.enName) intact, outputting only the final result without additional explanation.\n\n\(text)"
        }
        if src.id == "zh" || tgt.id == "zh" {
            let hints = terms.isEmpty ? "" : "参考下面的翻译：\n" +
                terms.map { "\($0.0) 翻译成 \($0.1)" }.joined(separator: "\n") + "\n\n"
            return hints + "将以下文本翻译为\(tgt.zhName)，注意只需要输出翻译后的结果，不要额外解释：\n\n\(text)"
        }
        let hints = terms.isEmpty ? "" : "Refer to the following translations:\n" +
            terms.map { "\($0.0) translates to \($0.1)" }.joined(separator: "\n") + "\n\n"
        return hints + "Translate the following segment into \(tgt.enName), without additional explanation.\n\n\(text)"
    }

    private static func matches(_ alias: String, in text: String) -> Bool {
        // For Latin names, a bare substring would match e.g. API inside rapid.
        if alias.range(of: #"^[\p{Latin}\d][\p{Latin}\d ._'-]*$"#, options: .regularExpression) != nil {
            let escaped = NSRegularExpression.escapedPattern(for: alias)
            return text.range(of: "(?<![\\p{Latin}\\d])\(escaped)(?![\\p{Latin}\\d])",
                              options: [.regularExpression, .caseInsensitive]) != nil
        }
        return text.localizedCaseInsensitiveContains(alias)
    }

    /// 每行一条，兼容已有的 “原文=译文”。
    static func parseGlossary(_ raw: String) -> [GlossaryTerm] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            let aliases = parts[0].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !aliases.isEmpty else { return nil }
            return GlossaryTerm(aliases: aliases, translation: parts[1])
        }
    }
}
