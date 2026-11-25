import SwiftUI

/// iPad 大屏工作台（横屏 / Stage Manager / 宽分屏自动启用，窄分屏或 iPhone 自动回退紧凑界面）。
/// 布局参考 Windows 桌面端：左侧可收起历史栏 + 中间实时双语翻译/详情主区 + 右侧可展开会议纪要面板。
struct IPadWorkbenchView: View {
    @EnvironmentObject var session: LiveSession
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var llm = LLMSettings.shared

    /// 宽窄屏切换时保留的外部共享状态（由 ContentView 持有）
    @Binding var selectedConversationID: UUID?
    @Binding var showSettings: Bool
    @Binding var showGlossary: Bool
    @Binding var askNew: Bool
    @Binding var noLLMAlert: Bool
    var onEditSource: (TranslationItem) -> Void
    var onEditSpeaker: (TranslationItem) -> Void

    private enum SidebarItem: Hashable {
        case live
        case conversation(UUID)
    }

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var searchQuery = ""
    @State private var showSummaryInspector = false
    @State private var inspectorUserToggled = false
    @State private var liveConv: Conversation?
    @State private var selectedTemplateID = SummaryTemplate.defaultID
    @State private var renaming: ConversationMeta?
    @State private var newTitle = ""
    @State private var deleting: ConversationMeta?
    @State private var summaryCopied = false

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: {
                if let id = selectedConversationID {
                    return .conversation(id)
                }
                return .live
            },
            set: { newValue in
                switch newValue {
                case .conversation(let id):
                    selectedConversationID = id
                case .live, .none:
                    selectedConversationID = nil
                }
            }
        )
    }

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
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
                // 重命名弹窗挂在侧栏层，与外层删除弹窗分处不同层级，避免同视图双 .alert 冲突
                .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                    TextField("对话名称", text: $newTitle)
                    Button("取消", role: .cancel) { renaming = nil }
                    Button("保存") {
                        if let m = renaming { store.rename(m.id, to: newTitle) }
                        renaming = nil
                    }
                }
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { reloadLiveConversation() }
        // 仅在总结/模板/同步变化或切换对话时读盘，实时转写期间每 250ms 保存不触发磁盘读取
        .onChange(of: store.summaryRevision) { _, _ in reloadLiveConversation() }
        .onChange(of: session.conversationID) { _, _ in reloadLiveConversation() }
        // 全局外接键盘快捷键（侧栏收起或查看历史详情时同样生效）
        .background {
            Group {
                Button("") { newTapped() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("") { showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                Button("") {
                    selectedConversationID = nil
                    inspectorUserToggled = true
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSummaryInspector.toggle()
                    }
                }
                .keyboardShortcut("\\", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0.001)
            .accessibilityHidden(true)
        }
        .alert(
            "删除这段对话？",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { m in
            Button("删除「\(m.title)」", role: .destructive) {
                let deletingActive = (m.id == session.conversationID)
                if selectedConversationID == m.id { selectedConversationID = nil }
                store.delete(m.id)
                if deletingActive { session.clearPage() }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("对话内容和所有总结都会被删除，无法恢复。")
        }
    }

    private func reloadLiveConversation() {
        let loaded = store.load(session.conversationID)
        liveConv = loaded
        if let activeID = loaded?.activeTemplateID {
            selectedTemplateID = activeID
        }
    }

    // MARK: - 左侧边栏（实时入口 + 历史列表 + 设置）

    private var sidebarContent: some View {
        List(selection: sidebarSelection) {
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
                .help("新建对话 (⌘N)")
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
        if let convID = selectedConversationID {
            ConversationDetailView(id: convID)
                .id(convID)
        } else {
            liveWorkbench
        }
    }

    private var liveWorkbench: some View {
        GeometryReader { geo in
            // 仅当详情区宽度足够（如横屏 / 13 寸 iPad）时默认展开右侧纪要栏，
            // 避免 11 寸竖屏或 2/3 分屏下中间字幕区被挤压
            let canFitSideBySide = geo.size.width >= 760
            let inspectorWidth: CGFloat = geo.size.width >= 960 ? 330 : 285

            HStack(spacing: 0) {
                // 中间实时双语翻译区
                VStack(spacing: 0) {
                    workbenchHeader
                    Divider()
                    Group {
                        if session.phase == .ready || session.isLoadingPhase {
                            TranscriptView(
                                onEdit: onEditSource,
                                onSpeaker: onEditSpeaker
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
                        .frame(width: inspectorWidth)
                        .background(Color(.secondarySystemGroupedBackground))
                }
            }
            .onAppear {
                if !inspectorUserToggled {
                    showSummaryInspector = canFitSideBySide
                }
            }
            .onChange(of: canFitSideBySide) { _, fits in
                if !inspectorUserToggled {
                    showSummaryInspector = fits
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// 顶部桌面风格工具栏：侧边栏开关 + 语言切换 + 声音克隆 + 清空 + 纪要面板开关
    /// （自动朗读已在底部 ControlBar 左下角 SpeakToggle 提供，此处不再重复占用宽度）
    private var workbenchHeader: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation {
                    columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.subheadline.weight(.medium))
                    .padding(8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("展开/收起左侧历史栏")

            HStack(spacing: 8) {
                LanguageMenu(selection: $session.langA)
                Button { session.swapLanguages() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                LanguageMenu(selection: $session.langB)
            }
            .frame(maxWidth: 320)

            Spacer(minLength: 6)

            // 声音克隆快捷开关
            Button {
                session.voiceClone.toggle()
            } label: {
                Label("声音克隆", systemImage: "waveform.badge.mic")
                    .font(.caption.weight(.medium))
                    .fixedSize()
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
                inspectorUserToggled = true
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
            .help(showSummaryInspector ? "收起会议纪要栏 (⌘\\)" : "展开会议纪要栏 (⌘\\)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 右侧实时会议纪要面板（使用 @State liveConv 缓存，不随实时字幕重绘反复读盘）

    private var liveSummaryInspector: some View {
        let activeTemplate = SummaryTemplate.find(liveConv?.activeTemplateID ?? selectedTemplateID)
        let record = liveConv?.summaries[activeTemplate.id]
        let hasDoneSummary = (record?.status == .done && !(record?.content.isEmpty ?? true))

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
                    // 模板选择与一键生成/更新
                    HStack {
                        Menu {
                            ForEach(SummaryTemplate.all) { t in
                                Button {
                                    selectedTemplateID = t.id
                                    session.persist()
                                    store.setActiveTemplate(session.conversationID, templateID: t.id)
                                    reloadLiveConversation()
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
                                    .lineLimit(1)
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
                                // 先同步落盘，确保刚说完的第一句也能立即触发总结
                                session.persist()
                                reloadLiveConversation()
                                SummaryService.shared.generate(
                                    conversationID: session.conversationID,
                                    templateID: activeTemplate.id
                                )
                            } else {
                                noLLMAlert = true
                            }
                        } label: {
                            Label(
                                record?.status == .generating
                                    ? "生成中…"
                                    : (hasDoneSummary ? "更新纪要" : "生成纪要"),
                                systemImage: hasDoneSummary ? "arrow.clockwise" : "wand.and.stars"
                            )
                            .font(.caption.weight(.medium))
                            .fixedSize()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(session.items.isEmpty || record?.status == .generating)
                    }

                    if let record {
                        switch record.status {
                        case .generating:
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("正在整理当前对话纪要…")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                if !record.content.isEmpty {
                                    MarkdownView(text: record.content)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.top, 8)
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
            selectedConversationID = nil
        }
    }
}
