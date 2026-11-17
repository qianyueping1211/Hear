import Foundation
import UIKit

/// 在后台调用大模型生成总结，结果存进对话文件
@MainActor
final class SummaryService {
    static let shared = SummaryService()
    private var running: Set<String> = []

    /// 用指定模板总结某个对话。已经在生成的不会重复启动。
    func generate(conversationID: UUID, templateID: String) {
        let key = "\(conversationID)-\(templateID)"
        guard !running.contains(key) else { return }

        let store = ConversationStore.shared
        let settings = LLMSettings.shared
        guard let conv = store.load(conversationID) else { return }
        let template = SummaryTemplate.find(templateID)

        guard let provider = settings.active, !provider.selectedModel.isEmpty,
              let apiKey = settings.key(for: provider), !apiKey.isEmpty else {
            store.updateSummary(conversationID, templateID: templateID,
                                SummaryRecord(status: .failed, error: "还没有配置大模型 API：请到 设置 → 大模型 API 添加并选择模型"))
            hearLog("总结失败：未配置大模型 API", .warning)
            return
        }
        guard !conv.items.isEmpty else {
            store.updateSummary(conversationID, templateID: templateID,
                                SummaryRecord(status: .failed, error: "这段对话没有内容"))
            return
        }

        let model = provider.selectedModel
        store.updateSummary(conversationID, templateID: templateID,
                            SummaryRecord(status: .generating, model: model))
        running.insert(key)
        hearLog("总结：开始生成「\(template.title)」，模型 \(provider.name) / \(model)，共 \(conv.items.count) 句")

        // 切到后台时向系统多要一些运行时间
        let bg = UIApplication.shared.beginBackgroundTask(withName: "summary") {}
        let system = """
        \(template.prompt)

        输出语言：\(conv.langA.zhName)。直接输出 Markdown 正文，不要加多余的开场白。
        """
        let user = Self.transcript(conv)
        let t0 = Date()

        Task {
            defer {
                running.remove(key)
                UIApplication.shared.endBackgroundTask(bg)
            }
            do {
                let text = try await LLMClient.complete(provider, key: apiKey, model: model, system: system, user: user)
                store.updateSummary(conversationID, templateID: templateID,
                                    SummaryRecord(status: .done, content: text, model: model))
                hearLog("总结：「\(template.title)」完成，用时 \(Int(Date().timeIntervalSince(t0)))s")
            } catch {
                store.updateSummary(conversationID, templateID: templateID,
                                    SummaryRecord(status: .failed, error: error.localizedDescription, model: model))
                hearLog("总结失败：\(error)", .error)
            }
        }
    }

    /// 把整页对话（原文 + 译文）整理成给大模型的输入
    static func transcript(_ c: Conversation) -> String {
        var lines = [
            "以下是一段由“听见”App 实时翻译的对话记录。",
            "A 方说\(c.langA.zhName)，B 方说\(c.langB.zhName)。时间：\(c.createdAt.formatted(date: .abbreviated, time: .shortened))。",
            "",
        ]
        for (i, item) in c.items.enumerated() {
            let side = item.source == c.langA ? "A方" : "B方"
            lines.append("\(i + 1). 【\(side)·\(item.source.zhName)】\(item.sourceText)")
            lines.append("   【译文·\(item.target.zhName)】\(item.translated)")
        }
        return lines.joined(separator: "\n")
    }
}
