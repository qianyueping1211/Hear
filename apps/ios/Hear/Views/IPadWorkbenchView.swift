import SwiftUI

/// iPad 大屏工作台（横屏 / Stage Manager / 宽分屏自动启用，窄分屏或 iPhone 自动回退紧凑界面）。
/// 布局参考 Windows 桌面端：左侧可收起历史栏 + 中间实时双语翻译/详情主区 + 右侧可展开会议纪要面板。
struct IPadWorkbenchView: View {
    @EnvironmentObject var session: LiveSession
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var llm = LLMSettings.shared

    private enum SidebarItem: Hashable {
        case live
        case conversation(UUID)
    }

    @State private var selection: SidebarItem? = .live
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var searchQuery = ""
    @State private var showSummaryInspector = true
    @State private var showSettings = false
    @State private var showGlossary = false
    @State private var askNew = false
    @State private var noLLMAlert = false
    @State private var editingID: UUID?
    @State private var draft = ""
    @State private var originalDraft = ""
    @State private var editingSpeaker: TranslationItem?
    @State private var renaming: ConversationMeta?
    @State private var newTitle = ""
    @State private var deleting: ConversationMeta?
    @State private var summaryCopied = false

    private var filteredMetas: [ConversationMeta] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.metas }
        return store.metas.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.preview.localizedCaseInsensitiveContains(q)
                || $0.langs.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 350)
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showGlossary) { GlossaryView() }
        .sheet(item: $editingSpeaker) { item in
            let conversation = session.conversationID
            SpeakerEditor(item: item, labels: session.items.speakerLabels) { change in
                session.editSpeaker(in: conversation, itemID: item.id, change: change)
            }
        }
        .overlay {
            if let id = editingID, let item = session.items.first(where: { $0.id == id }) {
                SourceEditor(
                    text: $draft,
                    flag: item.source.flag,
                    translation: item.displayedTranslation(using: session.chineseDisplayLanguage),
                    targetFlag: item.displayedTranslationTarget.flag,
                    onCancel: { editingID = nil },
                    onDone: {
                        if draft != originalDraft { session.editSource(id, to: draft) }
                        editingID = nil
                    }
                )
            }
        }
        .confirmationDialog("是否需要把本页内容进行后台总结？", isPresented: $askNew, titleVisibility: .visible) {
            Button("总结并新建") {
                if llm.isReady {
                    session.newConversation(summarize: true)
                } else {
                    session.newConversation(summarize: false)
                    noLLMAlert = true
                }
                selection = .live
            }
            Button("不总结，直接新建") {
                session.newConversation(summarize: false)
                selection = .live
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会用默认模板「高效会议纪要」生成报告，之后可在左侧历史或右侧纪要栏查看和编辑。")
        }
        .alert("还没有配置大模型 API", isPresented: $noLLMAlert) {
            Button("去设置") { showSettings = true }
            Button("好", role: .cancel) {}
        } message: {
            Text("本页已保存到历史。配置好大模型 API 后，即可一键生成结构化会议纪要。")
        }
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("对话名称", text: $newTitle)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let m = renaming { store.rename(m.id, to: newTitle) }
                renaming = nil
            }
        }
        .confirmationDialog(
            "删除这段对话？",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { m in
            Button("删除「\(m.title)」", role: .destructive) {
                let deletingActive = (m.id == session.conversationID)
                if selection == .conversation(m.id) { selection = .live }
                store.delete(m.id)
                if deletingActive { session.clearPage() }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("对话内容和所有总结都会被删除，无法恢复。")
        }
    }

    // MARK: - 左侧边栏（实时入口 + 历史列表 + 设置）

    private var sidebarContent: some View {
        List(selection: $selection) {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: session.isRunning ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.title3)
                        .foregroundStyle(session.isRunning ? .red : .accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前实时翻译")
                            .font(.subheadline.weight(.semibold))
                        Text(session.isRunning ? "正在实时收音翻译…" : "点击进入工作台")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !session.items.isEmpty {
                        Text("\(session.items.count)")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                .padding(.vertical, 4)
                .tag(SidebarItem.live)
            }

            Section("历史记录 (\(filteredMetas.count))") {
                if filteredMetas.isEmpty {
                    Text(searchQuery.isEmpty ? "暂无历史对话" : "无匹配记录")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredMetas) { m in
                    HistoryRow(meta: m)
                        .tag(SidebarItem.conversation(m.id))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleting = m } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                newTitle = m.title
                                renaming = m
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button {
                                newTitle = m.title
                                renaming = m
                            } label: { Label("重命名", systemImage: "pencil") }
                            Button(role: .destructive) { deleting = m } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchQuery, placement: .sidebar, prompt: "搜索标题或内容")
        .navigationTitle("听见 Hear")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    newTapped()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("新建对话")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { showGlossary = true } label: {
                    Label("术语表", systemImage: "character.book.closed")
                }
                Spacer()
                Button { showSettings = true } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
    }

    // MARK: - 中间主工作区 + 右侧纪要栏

    @ViewBuilder
    private var detailContent: some View {
        switch selection ?? .live {
        case .live:
            liveWorkbench
        case .conversation(let convID):
            ConversationDetailView(id: convID)
                .id(convID)
        }
    }

    private var liveWorkbench: some View {
        HStack(spacing: 0) {
            // 中间实时双语翻译区
            VStack(spacing: 0) {
                workbenchHeader
                Divider()
                Group {
                    if session.phase == .ready || session.isLoadingPhase {
                        TranscriptView(
                            onEdit: { item in
                                let source = item.displayedSource(using: session.chineseDisplayLanguage)
                                draft = source
                                originalDraft = source
                                editingID = item.id
                            },
                            onSpeaker: { editingSpeaker = $0 }
                        )
                        .frame(maxWidth: 880)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .top) {
                            if session.usingAppleTranslation, let note = session.appleNote {
                                NotePill(text: note).padding(.top, 8)
                            }
                        }
                    } else {
                        SetupView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                    .overlay {
                        let loading = session.loadingHint
                        if let hint = loading ?? session.modelReadyHint {
                            ModelStatusPill(text: hint, isLoading: loading != nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .allowsHitTesting(false)
                        }
                    }
                    .zIndex(1)

                ControlBar()
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)

            // 右侧会议纪要面板（参考 Windows 桌面端右侧总结栏）
            if showSummaryInspector {
                Divider()
                liveSummaryInspector
                    .frame(width: 330)
                    .background(Color(.secondarySystemGroupedBackground))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// 顶部桌面风格工具栏：语言切换 + 自动朗读 + 声音克隆 + 纪要面板开关
    private var workbenchHeader: some View {
        HStack(spacing: 10) {
            if columnVisibility == .detailOnly {
                Button {
                    withAnimation { columnVisibility = .all }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.subheadline.weight(.medium))
                        .padding(8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                .help("展开左侧历史栏")
            }

            LanguageBar()
                .frame(maxWidth: 360)

            Spacer(minLength: 8)

            // 自动朗读快捷开关
            Button {
                session.speakOutput.toggle()
            } label: {
                Label("自动朗读", systemImage: session.speakOutput ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        session.speakOutput ? Color.green.opacity(0.16) : Color(.secondarySystemBackground),
                        in: Capsule()
                    )
                    .foregroundStyle(session.speakOutput ? .green : .secondary)
            }
            .buttonStyle(.plain)

            // 声音克隆快捷开关
            Button {
                session.voiceClone.toggle()
            } label: {
                Label("声音克隆", systemImage: "waveform.badge.mic")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        session.voiceClone ? Color.blue.opacity(0.16) : Color(.secondarySystemBackground),
                        in: Capsule()
                    )
                    .foregroundStyle(session.voiceClone ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            // 清空当前页
            Button {
                session.clearPage()
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .padding(7)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(session.items.isEmpty && session.partial.isEmpty)
            .help("清空当前页")

            // 展开/收起右侧会议纪要栏
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSummaryInspector.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.subheadline.weight(.medium))
                    .padding(7)
                    .background(
                        showSummaryInspector ? Color.accentColor.opacity(0.16) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(showSummaryInspector ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)
            .help(showSummaryInspector ? "收起会议纪要栏" : "展开会议纪要栏")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 右侧实时会议纪要面板

    private var liveSummaryInspector: some View {
        let conv = store.load(session.conversationID)
        let activeTemplate = SummaryTemplate.find(conv?.activeTemplateID ?? SummaryTemplate.defaultID)
        let record = conv?.summaries[activeTemplate.id]

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("会议纪要", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let content = record?.content, !content.isEmpty {
                    Button {
                        UIPasteboard.general.string = content
                        summaryCopied = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.5))
                            summaryCopied = false
                        }
                    } label: {
                        Image(systemName: summaryCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    ShareLink(item: content) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 模板选择与一键生成
                    HStack {
                        Menu {
                            ForEach(SummaryTemplate.all) { t in
                                Button {
                                    store.setActiveTemplate(session.conversationID, templateID: t.id)
                                } label: {
                                    if t.id == activeTemplate.id {
                                        Label(t.title, systemImage: "checkmark")
                                    } else {
                                        Text(t.title)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(activeTemplate.title)
                                    .font(.caption.weight(.medium))
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                        }

                        Spacer()

                        Button {
                            if llm.isReady {
                                SummaryService.shared.generate(
                                    conversationID: session.conversationID,
                                    templateID: activeTemplate.id
                                )
                            } else {
                                noLLMAlert = true
                            }
                        } label: {
                            Label(
                                record?.status == .generating ? "生成中…" : "生成纪要",
                                systemImage: "wand.and.stars"
                            )
                            .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(session.items.isEmpty || record?.status == .generating)
                    }

                    if let record {
                        switch record.status {
                        case .generating:
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在整理当前对话纪要…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 12)
                        case .failed:
                            Text(record.error ?? "总结生成失败，请检查大模型 API 配置后重试。")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        case .done:
                            if !record.content.isEmpty {
                                MarkdownView(text: record.content)
                                    .textSelection(.enabled)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("实时翻译过程中，点击右上角「生成纪要」即可按所选模板整理会议要点与行动项。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if !llm.isReady {
                                Button("去配置大模型 API") {
                                    showSettings = true
                                }
                                .font(.footnote)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(14)
            }
        }
    }

    private func newTapped() {
        if session.items.contains(where: { $0.done }) {
            askNew = true
        } else {
            session.newConversation(summarize: false)
            selection = .live
        }
    }
}
