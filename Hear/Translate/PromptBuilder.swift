import Foundation

/// 按 Hy-MT 官方推荐格式拼装翻译提示词（支持上下文和术语表）
enum PromptBuilder {
    static func build(text: String,
                      from src: Language,
                      to tgt: Language,
                      context: [String],
                      glossary: [(String, String)]) -> String {
        let terms = glossary.filter { text.localizedCaseInsensitiveContains($0.0) }
        let involvesChinese = src.id == "zh" || tgt.id == "zh"
        var p = ""

        if involvesChinese {
            if !terms.isEmpty {
                p += "参考下面的翻译：\n"
                p += terms.map { "\($0.0) 翻译成 \($0.1)" }.joined(separator: "\n")
                p += "\n\n"
            }
            if context.isEmpty {
                p += "将以下文本翻译为\(tgt.zhName)，注意只需要输出翻译后的结果，不要额外解释：\n\n\(text)"
            } else {
                p += context.joined(separator: "\n")
                p += "\n参考上面的信息，把下面的文本翻译成\(tgt.zhName)，注意不需要翻译上文，也不要额外解释：\n\(text)"
            }
        } else {
            if !terms.isEmpty {
                p += "Refer to the following translations:\n"
                p += terms.map { "\($0.0) translates to \($0.1)" }.joined(separator: "\n")
                p += "\n\n"
            }
            if context.isEmpty {
                p += "Translate the following segment into \(tgt.enName), without additional explanation.\n\n\(text)"
            } else {
                p += context.joined(separator: "\n")
                p += "\nUsing the information above as context, translate the following segment into \(tgt.enName). Do not translate the context and do not add any explanation:\n\(text)"
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
