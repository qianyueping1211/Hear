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

        let problem: String?
        if settings.active == nil {
            problem = "还没有添加大模型 API：请到 设置 → 大模型 API 添加"
        } else if settings.active!.selectedModel.isEmpty {
            problem = "「\(settings.active!.name)」还没有选择模型：请到 设置 → 大模型 API 里选择"
        } else if (settings.key(for: settings.active!) ?? "").isEmpty
                    && !LLMClient.isLocalEndpoint(settings.active!.baseURL) {
            // 局域网里的自建服务（Ollama、LM Studio）不用 Key 也行
            problem = "「\(settings.active!.name)」没有读到 API Key：请到 设置 → 大模型 API 左滑编辑，重新填写 Key 后保存"
        } else {
            problem = nil
        }
        guard problem == nil, let provider = settings.active, let apiKey = settings.key(for: provider) else {
            store.updateSummary(conversationID, templateID: templateID,
                                SummaryRecord(status: .failed, error: problem ?? "大模型 API 配置不完整"))
            hearLog("总结失败：\(problem ?? "配置不完整")", .warning)
            return
        }
        guard !conv.items.isEmpty else {
            store.updateSummary(conversationID, templateID: templateID,
                                SummaryRecord(status: .failed, error: "这段对话没有内容"))
            return
        }
        // 明文发送（http）的地址：要先在设置里确认过
        // （要确认的是"这次对话正文会明文发到这个地址"）
        if LLMClient.isPlaintextEndpoint(provider.baseURL),
           !settings.isPlaintextConfirmed(provider.baseURL) {
            let msg = "这个地址是用明文（http）发送的：对话正文会明文传到 \(LLMClient.endpointDescription(provider.baseURL))。请到 设置 → 大模型 API 里确认一次再生成总结。"
            store.updateSummary(conversationID, templateID: templateID,
                                SummaryRecord(status: .failed, error: msg))
            hearLog("总结：明文发送还没确认过，不发", .warning)
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

        对标有说话人姓名或编号的发言按记录归属。保留“未分配”，按语言区分的 A 方和 B 方不代表身份。
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
            let side = item.speakerLabel ?? (item.source == c.langA ? "A方" : "B方")
            lines.append("\(i + 1). 【\(side)·\(item.source.zhName)】\(item.sourceText)")
            lines.append("   【译文·\(item.target.zhName)】\(item.translated)")
        }
        return lines.joined(separator: "\n")
    }
}
