import Foundation

/// 按 Hy-MT 官方推荐格式拼装翻译提示词（支持上下文和术语表）
enum PromptBuilder {
    static func build(text: String, from src: Language, to tgt: Language,
                      glossary: [(String, String)]) -> String {
        let terms = glossary.filter { text.localizedCaseInsensitiveContains($0.0) }
        if src.id == "zh" || tgt.id == "zh" {
            let hints = terms.isEmpty ? "" : "参考下面的翻译：\n" +
                terms.map { "\($0.0) 翻译成 \($0.1)" }.joined(separator: "\n") + "\n\n"
            return hints + "将以下文本翻译为\(tgt.zhName)，注意只需要输出翻译后的结果，不要额外解释：\n\n\(text)"
        }
        let hints = terms.isEmpty ? "" : "Refer to the following translations:\n" +
            terms.map { "\($0.0) translates to \($0.1)" }.joined(separator: "\n") + "\n\n"
        return hints + "Translate the following segment into \(tgt.enName), without additional explanation.\n\n\(text)"
    }

    /// 术语表：每行一条，格式 “原文=译文”
    static func parseGlossary(_ raw: String) -> [(String, String)] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }
}
