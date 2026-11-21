import SwiftUI

/// 历史对话详情：「对话」和「总结」两个标签
struct ConversationDetailView: View {
    let id: UUID
    @EnvironmentObject var session: LiveSession
    @ObservedObject private var store = ConversationStore.shared

    @State private var conv: Conversation?
    @State private var tab = 0
    @State private var editing = false
    @State private var draft = ""
    @State private var showTemplates = false
    @State private var confirmRegenerate = false
    @State private var copied = false
    @State private var editingSpeaker: TranslationItem?

    private var template: SummaryTemplate { SummaryTemplate.find(conv?.activeTemplateID ?? SummaryTemplate.defaultID) }
    private var record: SummaryRecord? { conv?.summaries[template.id] }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("对话").tag(0)
                Text("总结").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if let conv {
                if tab == 0 { dialogTab(conv) } else { summaryTab(conv) }
            } else {
                ContentUnavailableView("对话不存在", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(conv?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if tab == 1, record?.status == SummaryRecord.Status.done {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { draft = record?.content ?? ""; editing = true } label: { Label("编辑", systemImage: "pencil") }
                        Button {
                            UIPasteboard.general.string = record?.content
                            copied = true
                        } label: { Label("复制全文", systemImage: "doc.on.doc") }
                        Button(role: .destructive) { confirmRegenerate = true } label: {
                            Label("用此模板重新生成", systemImage: "arrow.clockwise")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .sheet(isPresented: $showTemplates) {
            TemplatePicker(current: template.id) { t in
                editing = false
                store.setActiveTemplate(id, templateID: t.id)   // 只切换，不会自动生成
            }
        }
        .sheet(item: $editingSpeaker) { item in
            SpeakerEditor(item: item, labels: conv?.items.speakerLabels ?? [:]) { change in
                session.editSpeaker(in: id, itemID: item.id, change: change)
            }
        }
        .confirmationDialog("重新生成会覆盖这个模板当前的总结（包括你的修改）",
                            isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("重新生成", role: .destructive) {
                editing = false
                SummaryService.shared.generate(conversationID: id, templateID: template.id)
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear(perform: reload)
        .onChange(of: store.revision) { _, _ in reload() }
    }

    private func reload() { conv = store.load(id) }

    // MARK: 对话

    private func dialogTab(_ c: Conversation) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if c.items.isEmpty {
                    Text("这段对话没有内容").foregroundStyle(.secondary).padding(.top, 40)
                }
                ForEach(c.items) { item in
                    BubbleView(item: item, leading: item.isLeading(left: c.langA, right: c.langB),
                               reading: session.readingID == item.id,
                               playing: session.speakingID == item.id,
                               preparing: session.cloneWorking[item.id] != nil,
                               onSpeaker: item.speakerLabel == nil ? nil : { editingSpeaker = item }) {
                        session.replay(item)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: 总结

    private func summaryTab(_ c: Conversation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button { showTemplates = true } label: {
                    TemplateCard(template: template, inUse: true)
                }
                .buttonStyle(.plain)
                Text("点卡片可以切换模板。每个模板的总结分开保存。")
                    .font(.caption).foregroundStyle(.secondary)

                summaryBody(c)
            }
            .padding()
        }
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder private func summaryBody(_ c: Conversation) -> some View {
        switch record?.status {
        case .none:
            VStack(spacing: 12) {
                Text("这个模板还没有生成总结").foregroundStyle(.secondary)
                Button {
                    SummaryService.shared.generate(conversationID: id, templateID: template.id)
                } label: {
                    Label("用此模板生成总结", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(c.items.isEmpty)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)

        case .some(.generating):
            VStack(spacing: 10) {
                ProgressView()
                Text("正在后台生成总结… 可以离开这个页面，完成后会自动保存。")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)

        case .some(.failed):
            VStack(alignment: .leading, spacing: 10) {
                Label("总结失败", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Text(record?.error ?? "").font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                Button {
                    SummaryService.shared.generate(conversationID: id, templateID: template.id)
                } label: { Label("重试", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderedProminent)
            }

        case .some(.done):
            if editing {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $draft)
                        .font(.body.monospaced())
                        .frame(minHeight: 420)
                        .padding(6)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
                    HStack {
                        Button("取消") { editing = false }
                        Spacer()
                        Button("保存") {
                            var r = record ?? SummaryRecord(status: .done)
                            r.content = draft
                            r.edited = true
                            r.updatedAt = Date()
                            store.updateSummary(id, templateID: template.id, r)
                            editing = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    MarkdownView(text: record?.content ?? "")
                        .padding()
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
                    Text(footer)
                        .font(.caption).foregroundStyle(.secondary)
                    if copied { Text("已复制").font(.caption).foregroundStyle(.green) }
                }
            }
        }
    }

    private var footer: String {
        guard let r = record else { return "" }
        var parts = [r.updatedAt.formatted(date: .abbreviated, time: .shortened)]
        if let m = r.model { parts.append("模型 \(m)") }
        if r.edited { parts.append("已手动修改") }
        return parts.joined(separator: " · ")
    }
}
