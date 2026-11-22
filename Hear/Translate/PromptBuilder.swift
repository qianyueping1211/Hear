import Foundation

/// 按 Hy-MT 官方推荐格式拼装翻译提示词（支持上下文和术语表）
enum PromptBuilder {
    static func build(text: String,
                      from src: Language,
                      to tgt: Language,
                      context: [String],
                      glossary: [(String, String)],
                      strict: Bool = false) -> String {
        let terms = glossary.filter { text.localizedCaseInsensitiveContains($0.0) }
        let involvesChinese = src.id == "zh" || tgt.id == "zh"
        var p = ""

        if involvesChinese {
            if !terms.isEmpty {
                p += "参考下面的翻译：\n"
                p += terms.map { "\($0.0) 翻译成 \($0.1)" }.joined(separator: "\n")
                p += "\n\n"
            }
            if context.isEmpty && !strict {
                p += "将以下文本翻译为\(tgt.zhName)，注意只需要输出翻译后的结果，不要额外解释：\n\n\(text)"
            } else {
                if !context.isEmpty {
                    p += "参考上文（仅用于判断术语、语义和指代）：\n\(context.joined(separator: "\n"))\n\n"
                }
                p += "只将下方本段原文翻译成\(tgt.zhName)。只输出本段译文，不复述、翻译或补写上文，即使本段从半句话开始：\n\n\(text)"
            }
        } else {
            if !terms.isEmpty {
                p += "Refer to the following translations:\n"
                p += terms.map { "\($0.0) translates to \($0.1)" }.joined(separator: "\n")
                p += "\n\n"
            }
            if context.isEmpty && !strict {
                p += "Translate the following segment into \(tgt.enName), without additional explanation.\n\n\(text)"
            } else {
                if !context.isEmpty {
                    p += "Earlier text (for terminology, meaning, and references only):\n\(context.joined(separator: "\n"))\n\n"
                }
                p += "Translate only the current segment below into \(tgt.enName). Output only its translation. Do not repeat, translate, or complete earlier text, even if this segment starts mid-sentence:\n\n\(text)"
            }
        }
        return p
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
