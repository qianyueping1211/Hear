import SwiftUI

/// 总结模板
struct SummaryTemplate: Identifiable, Equatable {
    struct Tag: Hashable {
        let text: String
        let tint: Color
    }

    let id: String
    let icon: String          // SF Symbols 图标
    let title: String
    let description: String   // 支持 **加粗**
    let tags: [Tag]
    let prompt: String        // 给大模型的写作要求

    static let defaultID = "drucker"

    static func find(_ id: String) -> SummaryTemplate {
        all.first { $0.id == id } ?? all[0]
    }

    static let all: [SummaryTemplate] = [
        SummaryTemplate(
            id: "drucker",
            icon: "text.badge.star",
            title: "高效会议纪要（德鲁克有效会议）",
            description: "源自**“现代管理学之父”**彼得·德鲁克在《卓有成效的管理者》中提出的理念，强调会议应**以贡献为导向**，明确目的并锁定结论与行动承诺。",
            tags: [.init(text: "全面细节", tint: .blue), .init(text: "结构化输出", tint: .purple)],
            prompt: """
            你是一位专业的会议纪要撰写人，遵循彼得·德鲁克《卓有成效的管理者》中“有效会议”的理念：会议应以贡献为导向，明确目的，并锁定结论与行动承诺。
            请根据对话记录撰写会议纪要，使用 Markdown，严格按以下结构：
            # 会议纪要：（为本次会议拟一个简短标题）
            ## 一、会议目的
            ## 二、参与方与语言
            ## 三、讨论要点
            （按议题分组；保留关键细节、数字、时间、观点出自哪一方）
            ## 四、达成的结论
            ## 五、行动承诺
            （用表格：| 事项 | 负责人 | 截止时间 | 备注 |；对话中没有明确的写“待定”）
            ## 六、未决问题与风险
            ## 七、下一步
            要求：全面保留细节；只依据对话内容，不编造；无法确定的写“未提及”。
            """
        ),
        SummaryTemplate(
            id: "brief",
            icon: "text.alignleft",
            title: "简明摘要",
            description: "用**三五句话**说清楚这次对话讲了什么，再列出**最重要的要点**，适合快速回顾。",
            tags: [.init(text: "快速了解", tint: .green), .init(text: "要点提炼", tint: .orange)],
            prompt: """
            请用 Markdown 为这段对话写一份简明摘要：
            # （一句话标题）
            ## 摘要
            （3–5 句话概括对话内容）
            ## 关键要点
            （5 条以内的要点列表）
            只依据对话内容，不编造。
            """
        ),
        SummaryTemplate(
            id: "actions",
            icon: "checklist",
            title: "行动项清单",
            description: "只提取对话中的**待办事项、负责人和期限**，方便跟进落实。",
            tags: [.init(text: "任务追踪", tint: .red), .init(text: "表格输出", tint: .purple)],
            prompt: """
            请从这段对话中提取所有行动项，用 Markdown 输出：
            # 行动项清单
            | 序号 | 事项 | 负责人 | 截止时间 | 依据（对话原话摘要） |
            之后再列出：
            ## 需要确认的问题
            对话中没有明确的负责人或时间写“待定”；不要编造对话里没有的任务。
            """
        ),
        SummaryTemplate(
            id: "bilingual",
            icon: "character.book.closed",
            title: "双语要点对照",
            description: "把对话的核心内容整理成**两种语言对照**的要点，并列出值得学习的**关键表达**。",
            tags: [.init(text: "双语对照", tint: .blue), .init(text: "学习复盘", tint: .green)],
            prompt: """
            请用 Markdown 整理这段对话，输出两部分：
            # 双语要点对照
            ## 要点对照
            （用表格：| 要点（语言 A） | 要点（语言 B） |，8 条以内）
            ## 关键表达
            （列出对话中值得学习的词句：原文 → 译文 → 简短说明）
            只依据对话内容。
            """
        ),
        SummaryTemplate(
            id: "interview",
            icon: "person.2.wave.2",
            title: "沟通 / 访谈记录",
            description: "按**问答顺序**客观整理双方说了什么，保留**原意和语气**，适合存档。",
            tags: [.init(text: "问答整理", tint: .orange), .init(text: "客观记录", tint: .blue)],
            prompt: """
            请用 Markdown 把这段对话整理成沟通记录：
            # 沟通记录：（标题）
            ## 背景
            ## 问答整理
            （按时间顺序，以“**A方：** … / **B方：** …”的形式归纳每一轮的主要内容，保留原意和语气）
            ## 双方立场与关注点
            ## 后续事项
            客观记录，不加评价，不编造。
            """
        ),
    ]
}
