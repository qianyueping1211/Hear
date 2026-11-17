import SwiftUI

/// 简单的 Markdown 显示：标题、列表、表格、分隔线、段落（支持加粗/斜体等行内格式）
struct MarkdownView: View {
    let text: String

    private enum Block: Identifiable {
        case heading(Int, String, Int)
        case bullet(String, String, Int)      // 标记（• 或 1.）、内容
        case table([[String]], Int)
        case rule(Int)
        case paragraph(String, Int)

        var id: Int {
            switch self {
            case .heading(_, _, let i), .bullet(_, _, let i), .table(_, let i), .rule(let i), .paragraph(_, let i): return i
            }
        }
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var table: [[String]] = []
        let lines = text.components(separatedBy: "\n")

        func flushTable(_ i: Int) {
            if !table.isEmpty { out.append(.table(table, -(i + 1))); table = [] }   // 负数 id，避免和段落重复
        }

        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // 跳过 |---|---| 分隔行
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                continue
            }
            flushTable(i)
            if line.isEmpty { continue }
            if line == "---" || line == "***" { out.append(.rule(i)); continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces), i))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                out.append(.bullet("•", String(line.dropFirst(2)), i)); continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
                out.append(.bullet(String(line[...dot]), line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces), i))
                continue
            }
            out.append(.paragraph(line, i))
        }
        flushTable(lines.count)
        return out
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { b in
                switch b {
                case .heading(let level, let s, _):
                    Text(inline(s))
                        .font(level <= 1 ? .title2.bold() : (level == 2 ? .title3.bold() : .headline))
                        .padding(.top, level <= 2 ? 6 : 2)
                case .bullet(let mark, let s, _):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(mark).foregroundStyle(.secondary)
                        Text(inline(s))
                    }
                case .table(let rows, _):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                                GridRow {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                        Text(inline(cell))
                                            .font(r == 0 ? .subheadline.bold() : .subheadline)
                                            .frame(minWidth: 60, maxWidth: 220, alignment: .leading)
                                    }
                                }
                                if r == 0 { Divider() }
                            }
                        }
                        .padding(10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                case .rule:
                    Divider()
                case .paragraph(let s, _):
                    Text(inline(s))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
