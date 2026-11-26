import SwiftUI
import Translation

struct ContentView: View {
    @EnvironmentObject var session: LiveSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var llm = LLMSettings.shared
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showGlossary = false
    @State private var askNew = false
    @State private var noLLMAlert = false
    @State private var editingID: UUID?          // 正在修改原文的那一条
    @State private var draft = ""
    @State private var originalDraft = ""
    @State private var editingSpeaker: TranslationItem?
    @State private var showMenu = false          // 右上角 ⋯ 菜单
    @State private var showQuickModeBar = false  // 底部苹果原生悬浮四模式切换胶囊
    @State private var quickModeDismissTask: Task<Void, Never>?
    @State private var didShowInitialQuickMode = false
    @State private var wasBackgrounded = false
    @State private var ipadSelectedConversationID: UUID?  // iPad 宽窄屏切换时保留当前选中的历史对话

    private var useIPadWorkbench: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    var body: some View {
        ZStack {
            Group {
                if useIPadWorkbench {
                    IPadWorkbenchView(
                        selectedConversationID: $ipadSelectedConversationID,
                        showSettings: $showSettings,
                        showGlossary: $showGlossary,
                        askNew: $askNew,
                        noLLMAlert: $noLLMAlert,
                        onEditSource: beginEditingSource,
                        onEditSpeaker: { editingSpeaker = $0 }
                    )
                } else {
                    compactPhoneBody
                }
            }
            // 本地网络权限提示（内部是 .alert）单独挂在内层，与外层 noLLMAlert 隔开，避免同视图双 .alert 冲突
            .localNetworkHelp($session.localNetworkHelp)
        }
        // 所有弹窗、编辑浮层与引导任务都挂在最外层容器上，
        // iPad 旋转 / 分屏 / Stage Manager 宽窄切换时不丢窗口、不丢编辑草稿、不中断翻译任务
        .overlay {
            if let id = editingID, let item = session.items.first(where: { $0.id == id }) {
                SourceEditor(text: $draft, flag: item.source.flag,
                             translation: item.displayedTranslation(using: session.chineseDisplayLanguage),
                             targetFlag: item.displayedTranslationTarget.flag,
                             onCancel: {
                                 editingID = nil
                             },
                             onDone: {
                                 if draft != originalDraft { session.editSource(id, to: draft) }
                                 editingID = nil
                             })
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showHistory) { HistoryView() }
        .sheet(isPresented: $showGlossary) { GlossaryView() }
        .sheet(item: $editingSpeaker) { item in
            let conversation = session.conversationID
            SpeakerEditor(item: item, labels: session.items.speakerLabels) { change in
                session.editSpeaker(in: conversation, itemID: item.id, change: change)
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
                ipadSelectedConversationID = nil
            }
            Button("不总结，直接新建") {
                session.newConversation(summarize: false)
                ipadSelectedConversationID = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会用默认模板「高效会议纪要」生成报告，可以在 历史 → 总结 中查看和修改。本页内容都会保存在历史里。")
        }
        .alert("还没有配置大模型 API", isPresented: $noLLMAlert) {
            Button("去设置") { showSettings = true }
            Button("好", role: .cancel) {}
        } message: {
            Text("本页已保存到历史。配置好 API 后，可以在 历史 → 总结 里随时生成。")
        }
        .task { await session.bootstrap() }
        // 苹果自带模式：语言包没下载时，由系统弹出下载窗口
        .translationTask(session.translationPrepConfig) { ts in
            do {
                try await ts.prepareTranslation()
                await session.appleTranslationPrepared(true)
            } catch {
                hearLog("苹果翻译语言包准备失败：\(error)", .warning)
                await session.appleTranslationPrepared(false)
            }
        }
    }

    private func beginEditingSource(_ item: TranslationItem) {
        let source = item.displayedSource(using: session.chineseDisplayLanguage)
        draft = source
        originalDraft = source
        editingID = item.id
    }

    private var compactPhoneBody: some View {
        NavigationStack {
            Group {
                if session.talkMode && session.conversationStyle == .faceToFace && (session.phase == .ready || session.isLoadingPhase) {
                    PhoneFaceToFaceView(
                        onOpenMenu: { showMenu = true },
                        onExit: { session.switchTranslationMode(to: .sideBySide) }
                    )
                } else {
                    VStack(spacing: 0) {
                        TopBar(onMore: { showMenu = true })
                        LanguageBar()
                        Divider()
                        Group {
                            if session.phase == .ready || session.isLoadingPhase {
                                // 加载模型时也显示对话页。
                                TranscriptView(
                                    onEdit: beginEditingSource,
                                    onSpeaker: { editingSpeaker = $0 }
                                )
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
                                } else if !session.isRunning && session.conversationInputLanguage == nil {
                                    Button {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        toggleQuickModeBar()
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "arrow.left.arrow.right")
                                                .font(.caption2.weight(.semibold))
                                            Text("切换模式")
                                                .font(.footnote.weight(.medium))
                                        }
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                                    }
                                    .buttonStyle(QuickPillPressStyle())
                                    .accessibilityLabel("切换翻译模式")
                                }
                            }
                            .zIndex(1)
                        ControlBar()
                            .blur(radius: showQuickModeBar ? 10 : 0)
                            .opacity(showQuickModeBar ? 0.35 : 1)
                            .overlay {
                                if showQuickModeBar {
                                    Rectangle()
                                        .fill(.ultraThinMaterial)
                                        .ignoresSafeArea(edges: .bottom)
                                        .transition(.opacity)
                                }
                            }
                            .allowsHitTesting(!showQuickModeBar)
                            .animation(.easeInOut(duration: 0.24), value: showQuickModeBar)
                    }
                    .overlay {
                        if showQuickModeBar {
                            Color.black.opacity(0.001)
                                .ignoresSafeArea()
                                .onTapGesture { dismissQuickModeBar() }
                                .zIndex(4)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if showQuickModeBar {
                            FloatingModeSwitcherBar(
                                onSelect: { enteredFaceToFace in
                                    if enteredFaceToFace {
                                        dismissQuickModeBar()
                                    } else {
                                        scheduleQuickModeDismiss(after: 2.0)
                                    }
                                },
                                onInteract: { scheduleQuickModeDismiss(after: 5.0) }
                            )
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(5)
                        }
                    }
                    .animation(.spring(response: 0.32, dampingFraction: 0.82), value: showQuickModeBar)
                    .onAppear {
                        if !didShowInitialQuickMode {
                            didShowInitialQuickMode = true
                            showQuickModeBarBrieflyOnOpen()
                        }
                    }
                    .onChange(of: scenePhase) { _, phase in
                        switch phase {
                        case .background:
                            wasBackgrounded = true
                        case .active:
                            if wasBackgrounded {
                                wasBackgrounded = false
                                showQuickModeBarBrieflyOnOpen()
                            }
                        default:
                            break
                        }
                    }
                    .onChange(of: session.isRunning) { _, running in
                        if running && showQuickModeBar {
                            dismissQuickModeBar()
                        }
                    }
                    .onChange(of: session.conversationInputLanguage) { _, lang in
                        if lang != nil && showQuickModeBar {
                            dismissQuickModeBar()
                        }
                    }
                    .onDisappear {
                        dismissQuickModeBar()
                    }
                }
            }
            // 弹出键盘时底部的实时翻译区域固定不动
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .toolbar(.hidden, for: .navigationBar)
            // ⋯ 菜单：面对面模式从左下角 ⋯ 上方弹出，其他模式从右上角弹出
            .overlay(alignment: isPhoneFaceToFace ? .bottomLeading : .topTrailing) {
                if showMenu {
                    let faceToFace = isPhoneFaceToFace
                    ZStack(alignment: faceToFace ? .bottomLeading : .topTrailing) {
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .onTapGesture { showMenu = false }
                        MoreMenuPanel(
                            onNew: { showMenu = false; newTapped() },
                            onHistory: { showMenu = false; showHistory = true },
                            onGlossary: { showMenu = false; showGlossary = true },
                            onSettings: { showMenu = false; showSettings = true }
                        )
                        .padding(.top, faceToFace ? 0 : 54)
                        .padding(.trailing, faceToFace ? 0 : 16)
                        .padding(.bottom, faceToFace ? 66 : 0)
                        .padding(.leading, faceToFace ? 16 : 0)
                        .transition(
                            .scale(scale: 0.6, anchor: faceToFace ? .bottomLeading : .topTrailing)
                                .combined(with: .opacity)
                        )
                    }
                }
            }
            .animation(.spring(duration: 0.28), value: showMenu)
        }
    }

    private var isPhoneFaceToFace: Bool {
        session.talkMode && session.conversationStyle == .faceToFace && (session.phase == .ready || session.isLoadingPhase)
    }

    private func showQuickModeBarBrieflyOnOpen() {
        guard !isPhoneFaceToFace, !session.isRunning, session.conversationInputLanguage == nil else { return }
        showQuickModeBar = true
        scheduleQuickModeDismiss(after: 3.0)
    }

    private func toggleQuickModeBar() {
        if showQuickModeBar {
            dismissQuickModeBar()
        } else {
            showQuickModeBar = true
            scheduleQuickModeDismiss(after: 5.0)
        }
    }

    private func scheduleQuickModeDismiss(after seconds: Double) {
        quickModeDismissTask?.cancel()
        quickModeDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            showQuickModeBar = false
        }
    }

    private func dismissQuickModeBar() {
        quickModeDismissTask?.cancel()
        quickModeDismissTask = nil
        showQuickModeBar = false
    }

    private func newTapped() {
        if session.items.contains(where: { $0.done }) {
            askNew = true
        } else {
            session.newConversation(summarize: false)
        }
    }
}

// MARK: - 顶部栏：左边清空，中间标题，右边 ⋯ 菜单（新建 / 历史 / 设置）

struct TopBar: View {
    @EnvironmentObject var session: LiveSession
    var onMore: () -> Void

    private var shortModeName: String {
        switch session.currentTranslationMode {
        case .listening: return "聆听"
        case .singleAuto: return "单侧"
        case .sideBySide: return "并排"
        case .faceToFace: return "面对面"
        }
    }

    var body: some View {
        HStack {
            Button { session.clearPage() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.primary)
            .disabled(session.items.isEmpty && session.partial.isEmpty)
            .accessibilityLabel("清空")

            Spacer()

            Button(action: onMore) { MoreDots() }
                .foregroundStyle(.primary)
                .accessibilityLabel("更多")
        }
        .overlay {
            HStack(spacing: 4) {
                Text("Hear 听见")
                    .font(.headline)
                Text("·")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(shortModeName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .allowsHitTesting(false)
        }
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

/// ⋯ 弹出的菜单（新建 / 历史 / 术语 / 设置）
struct MoreMenuPanel: View {
    var onNew: () -> Void
    var onHistory: () -> Void
    var onGlossary: () -> Void
    var onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            row("新建对话", "square.and.pencil", onNew)
            row("历史记录", "clock.arrow.circlepath", onHistory)
            row("术语配置", "text.book.closed", onGlossary)
            row("功能设置", "gearshape", onSettings)
        }
        .padding(.vertical, 4)
        .frame(width: 214)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 6)
    }

    /// 一行：图标 + 文字，在框内居中
    private func row(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 26)
                Text(title).font(.system(size: 18.5))
            }
            .frame(maxWidth: .infinity, minHeight: 53)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 右上角按钮：和左边清空按钮完全一样的样式，只是图标换成三个点
struct MoreDots: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 19, weight: .medium))
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
            .contentShape(Circle())
    }
}

/// 顶部的提示（例如苹果翻译语言包还没下载）
struct NotePill: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal)
    }
}

/// 加载进度与完成提示都在对话页分隔线上居中显示。
struct ModelStatusPill: View {
    let text: String
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if text.contains("请调整设置") {
                    Image(systemName: "info.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityAddTraits(isLoading ? .updatesFrequently : [])
    }
}

// MARK: - 顶部：实时翻译模式仅选「译为目标语种」；对话翻译模式选双方语言

struct LanguageBar: View {
    @EnvironmentObject var session: LiveSession

    var body: some View {
        if !session.talkMode {
            // 实时翻译（会议）模式：自动识别多国语种，只需选择「译为」哪种目标语言（默认中文）
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                    Text("自动识别多国语种")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(Language.all) { lang in
                        Button { session.meetingTargetLang = lang } label: {
                            if lang == session.meetingTargetLang {
                                Label("\(lang.flag) \(lang.displayName)", systemImage: "checkmark")
                            } else {
                                Text("\(lang.flag) \(lang.displayName)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("译为").font(.subheadline).foregroundStyle(.secondary)
                        Text(session.meetingTargetLang.flag)
                        Text(session.meetingTargetLang.name).fontWeight(.semibold).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .foregroundStyle(.primary)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        } else {
            HStack(spacing: 12) {
                LanguageMenu(selection: $session.langA)
                Button { session.swapLanguages() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                LanguageMenu(selection: $session.langB)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }
}

struct LanguageMenu: View {
    @EnvironmentObject var session: LiveSession
    @Binding var selection: Language

    var body: some View {
        Menu {
            // 只列出当前识别引擎支持的语言，避免选了识别不了的语言
            ForEach(session.supportedLanguages) { lang in
                Button { selection = lang } label: {
                    if lang == selection {
                        Label("\(lang.flag) \(lang.displayName)", systemImage: "checkmark")
                    } else {
                        Text("\(lang.flag) \(lang.displayName)")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection.flag)
                Text(selection.name).fontWeight(.semibold).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .foregroundStyle(.primary)
    }
}

// MARK: - 中间：对话记录

struct TranscriptView: View {
    @EnvironmentObject var session: LiveSession
    @State private var followsLatest = true
    var onEdit: (TranslationItem) -> Void = { _ in }
    var onSpeaker: (TranslationItem) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(session.items) { item in
                        BubbleView(item: item,
                                   leading: !session.talkMode ? true : item.isLeading(left: session.langA, right: session.langB),
                                   fullWidth: !session.talkMode,
                                   displayLanguage: session.chineseDisplayLanguage,
                                   reading: session.readingID == item.id,
                                   playing: session.speakingID == item.id,
                                   preparing: session.cloneWorking[item.id] != nil,
                                   showIdleReadingIcon: session.showReadingIcon,
                                   onEdit: { if item.done { onEdit(item) } },
                                   onRetry: item.canRetryTranslation ? { session.retryTranslation(item.id) } : nil,
                                   onSpeaker: (item.speakerLabel == nil && session.talkMode) ? nil : { onSpeaker(item) }) {
                            session.tapRead(item)
                        }
                        .id(item.id)
                    }
                    if !session.partial.isEmpty {
                        LiveBubble().id("partial")
                    }
                    // 底部保留约 120pt 缓冲区域，确保最新原文和译文始终处于视口中下部、不被底部操作栏或状态胶囊遮挡
                    Color.clear.frame(height: 120).id("bottom")
                }
                .padding(.horizontal)
                .padding(.top)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 140
            } action: { _, atBottom in
                followsLatest = atBottom
            }
            .overlay {
                if session.items.isEmpty && session.partial.isEmpty {
                    EmptyHint()
                        .padding(.horizontal, 28)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Label("回到底部", systemImage: "arrow.down")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(20)
                }
            }
            .onChange(of: session.items.last?.id) { _, _ in
                if followsLatest { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: session.items.last?.sourceText) { _, _ in
                if followsLatest { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.items.last?.translated) { _, _ in
                if followsLatest { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.partial) { _, _ in
                if followsLatest { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.partialTranslation) { _, _ in
                if followsLatest { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

struct EmptyHint: View {
    @EnvironmentObject var session: LiveSession

    private var waitingForText: Bool {
        session.isRunning || session.isAnyModelLoading || session.conversationInputLanguage != nil
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: session.talkMode ? "bubble.left.and.bubble.right" : "waveform")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            if waitingForText {
                Text("原文和译文会显示在这里")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    Text(session.usesDualConversationButtons ? "点击语言圆圈开始" : "点击麦克风开始")
                        .font(.title3.weight(.semibold))
                    Text(emptySubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .multilineTextAlignment(.center)
    }

    private var emptySubtitle: String {
        if !session.talkMode {
            return "自动识别多国语种，统一译为\(session.meetingTargetLang.name)"
        }
        if session.usesDualConversationButtons {
            return "再点同一个圆圈停止"
        }
        return "自动识别双方语言并互译"
    }
}

/// 半圈一直在转的加载圈。
///
/// 声音克隆要等电脑那边算完（好几秒），这时候气泡里的喇叭显示成这个，
/// 一眼就知道"还在生成，马上就好"。
struct HalfCircleSpinner: View {
    var size: CGFloat = 17
    /// 转过的角度
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.5)                 // 只要半圈
            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

struct BubbleView: View {
    let item: TranslationItem
    let leading: Bool
    /// 实时翻译（会议）模式下通栏左对齐卡片展示，不区分左右气泡
    var fullWidth: Bool = false
    let displayLanguage: ChineseDisplayLanguage
    var reading: Bool = false
    /// 历史完整录音回放时，当前正在播到这一句（高亮框图）
    var audioHighlighted: Bool = false
    /// 真的在出声：喇叭显示成绿色的（只有正在播的时候才是绿的）
    var playing: Bool = false
    /// 声音（克隆原声）还在生成：喇叭显示成灰色，表示"马上就好"
    var preparing: Bool = false
    var showIdleReadingIcon: Bool = true
    var useContextMenu: Bool = false
    var onEdit: (() -> Void)? = nil      // 对话页直接长按修改原文；历史页配合 useContextMenu 放进弹出菜单
    var onRetry: (() -> Void)? = nil
    var onSpeaker: (() -> Void)? = nil
    /// 自定义点击行为（历史页用于点气泡播放原文录音）；为 nil 时沿用点击朗读译文
    var onTap: (() -> Void)? = nil
    var onSpeak: () -> Void

    private var speakerAvatarColor: Color {
        switch item.speakerDetails?.gender {
        case .male: return Color(red: 0.49, green: 0.74, blue: 0.98)
        case .female: return Color(red: 0.97, green: 0.57, blue: 0.62)
        case nil: return .secondary
        }
    }

    /// 左侧气泡国旗在前，右侧气泡国旗在后（靠外侧）
    private func flagged(_ flag: String, _ text: String) -> Text {
        leading ? Text("\(flag) \(text)") : Text("\(text) \(flag)")
    }

    private var translatedText: Text {
        let flag = item.displayedTranslationTarget.flag
        let translated = item.displayedTranslation(using: displayLanguage)
        guard let baseline = item.translationBaseline else { return flagged(flag, translated) }
        let displayedBaseline = displayLanguage.display(baseline, languageID: item.displayedTranslationTarget.id)
        let revised = TranslationRevision.changes(from: displayedBaseline, to: translated)
            .reduce(Text("")) { rendered, part in
                rendered + (part.changed ? Text(part.text).bold().foregroundColor(.accentColor) : Text(part.text))
            }
        return leading ? Text("\(flag) ") + revised : revised + Text(" \(flag)")
    }

    @ViewBuilder
    private var readingIcon: some View {
        if preparing && !playing {
            // 等待克隆声音生成时转圈。
            HalfCircleSpinner()
                .accessibilityLabel("正在准备朗读")
        } else {
            PlaybackSpeakerIcon(playing: playing)
                .foregroundStyle(playing ? Color.green : Color.secondary)
                .accessibilityLabel(playing ? "正在播放" : "可朗读")
        }
    }

    private var showsReadingIcon: Bool {
        item.canReadAloud && (playing || (item.done && (preparing || showIdleReadingIcon)))
    }

    var body: some View {
        HStack {
            if !fullWidth && !leading { Spacer(minLength: 40) }
            VStack(alignment: (fullWidth || leading) ? .leading : .trailing, spacing: 6) {
                if let speaker = item.speakerLabel ?? (fullWidth ? "发言人" : nil) {
                    if let onSpeaker {
                        Button(action: onSpeaker) {
                            Label {
                                Text(speaker)
                            } icon: {
                                Image(systemName: "person.crop.circle.fill")
                                    .foregroundStyle(speakerAvatarColor)
                            }
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("修改说话人资料")
                    } else {
                        Text(speaker).font(.caption.weight(.semibold))
                    }
                }
                // 被 Whisper 校正过的句子，原文后面带一个魔法棒小图标
                (flagged(item.source.flag, item.displayedSource(using: displayLanguage))
                 + (item.corrected == true
                    ? Text(" ") + Text(Image(systemName: "wand.and.stars")).foregroundStyle(Color.accentColor)
                    : Text("")))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if item.translated.isEmpty {
                    if !item.done { ProgressView().controlSize(.small) }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if showsReadingIcon && !leading { readingIcon }
                        translatedText
                            .font(.title3.weight(.medium))
                        if showsReadingIcon && leading { readingIcon }
                    }
                }
                if let error = item.translationError {
                    Text(item.translated.isEmpty ? error : "翻译未完成 · 保留已显示译文")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let onRetry {
                        Button("重试翻译", action: onRetry)
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.semibold))
                    }
                } else if item.translationPending == true {
                    if !item.translated.isEmpty {
                        Text("正在修正译文…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if item.done {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .multilineTextAlignment((fullWidth || leading) ? .leading : .trailing)
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
            .padding(12)
            .background(
                audioHighlighted
                    ? Color.accentColor.opacity(0.22)
                    : ((fullWidth || leading) ? Color(.secondarySystemBackground) : Color.accentColor.opacity(0.15)),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        audioHighlighted ? Color.accentColor : (reading ? Color.accentColor : Color.clear),
                        lineWidth: audioHighlighted ? 2.2 : 1.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture {
                if let onTap {
                    onTap()
                } else if item.canReadAloud {
                    onSpeak()
                }
            }
            .modifier(BubbleLongPress(item: item, displayLanguage: displayLanguage,
                                      useContextMenu: useContextMenu, onEdit: onEdit, onSpeak: onSpeak))
            if !fullWidth && leading { Spacer(minLength: 40) }
        }
    }
}

/// 气泡的长按：对话页是修改原文，历史页是四按钮弹出菜单（修改原文 / 复制原文 / 播放译文 / 复制译文）
private struct BubbleLongPress: ViewModifier {
    let item: TranslationItem
    let displayLanguage: ChineseDisplayLanguage
    let useContextMenu: Bool
    let onEdit: (() -> Void)?
    let onSpeak: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if !useContextMenu, let onEdit {
            content.onLongPressGesture(minimumDuration: 0.4) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onEdit()
            }
        } else {
            content.contextMenu {
                if let onEdit {
                    Button(action: onEdit) {
                        Label("修改原文", systemImage: "pencil")
                    }
                }
                Button { UIPasteboard.general.string = item.displayedSource(using: displayLanguage) } label: {
                    Label("复制原文", systemImage: "doc.on.doc")
                }
                if item.canReadAloud {
                    Button(action: onSpeak) { Label("播放译文", systemImage: "speaker.wave.2") }
                }
                Button { UIPasteboard.general.string = item.displayedTranslation(using: displayLanguage) } label: {
                    Label("复制译文", systemImage: "doc.on.doc")
                }
            }
        }
    }
}

/// 修改原文的编辑框：提供显式取消与保存重译按钮，适配小屏键盘与无障碍焦点
struct SourceEditor: View {
    @Binding var text: String
    let flag: String
    var translation: String = ""          // 当前译文，只看不改
    var targetFlag: String = ""
    let onCancel: () -> Void
    let onDone: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(flag) 修改原文").font(.headline)
                        Spacer()
                        Button("取消", action: onCancel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    TextField("原文", text: $text, axis: .vertical)
                        .lineLimit(2...8)
                        .focused($focused)
                        .padding(10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    // 最新译文：方便对照，不能修改
                    if !translation.isEmpty {
                        Text("\(targetFlag) 最新译文").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Text(translation)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(.secondarySystemBackground).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            .textSelection(.enabled)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = translation
                                } label: {
                                    Label("复制译文", systemImage: "doc.on.doc")
                                }
                            }
                    }
                    HStack(spacing: 12) {
                        Button(action: onCancel) {
                            Text("取消")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .foregroundStyle(.primary)
                        Button(action: onDone) {
                            Text("保存并重译")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .foregroundStyle(.white)
                    }
                    .padding(.top, 4)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 16)
                .padding(.top, 56)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityAddTraits(.isModal)
        .onAppear { focused = true }
    }
}

// MARK: - 底部：开始/停止

struct ControlBar: View {
    @EnvironmentObject var session: LiveSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mainColor: Color { Color.accentColor }        // 开始后也用蓝色，只换成停止图标
    private var mainIcon: String { session.isRunning ? "stop.fill" : "mic.fill" }

    var body: some View {
        VStack(spacing: 8) {
            Text(session.recordingStatus.isEmpty ? " " : session.recordingStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)

            ZStack {
                if session.usesDualConversationButtons {
                    talkControls
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    liveControls
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(height: 140)
            .clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: session.usesDualConversationButtons)
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
        // 临时提示与分隔线上常驻的模型进度分开。
        .overlay(alignment: .top) {
            if let t = session.toast {
                Text(t)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .offset(y: session.loadingHint == nil ? -30 : 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.spring(duration: 0.25), value: session.toast)
    }

    /// 实时翻译模式：播报 · 大按钮 · 上下文
    private var liveControls: some View {
        HStack {
            // 点一下：朗读开/关；按住 2 秒：扬声器 ⇄ 耳机
            SpeakToggle()

            Spacer()

            liveMicrophone

            Spacer()

            ContextToggle()
        }
        .padding(.horizontal, 24)
    }

    private var liveMicrophone: some View {
        let enabled = session.isRunning || session.phase == .ready
        return Button {
            Task { await session.toggle() }
        } label: {
            MicButton(meter: session.meter, running: session.isRunning, color: mainColor, icon: mainIcon)
                .contentShape(.interaction, Circle().inset(by: 24))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(session.isRunning
            ? (session.talkMode ? "停止对话翻译" : "停止实时翻译")
            : (session.talkMode ? "开始对话翻译" : "开始实时翻译"))
        .opacity(enabled || session.isLoadingPhase ? 1 : 0.4)
    }

    /// 对话翻译模式：左右圆圈分别负责两种语言。
    private var talkControls: some View {
        HStack(spacing: 0) {
            ConversationInputButton(lang: session.langA)
            Spacer(minLength: 4)
            VStack(spacing: 10) {
                SpeakToggle()
                ContextToggle()
            }
            Spacer(minLength: 4)
            ConversationInputButton(lang: session.langB)
        }
        .padding(.horizontal, 16)
    }
}

/// 上下文开关（关闭时灰色）
struct ContextToggle: View {
    @EnvironmentObject var session: LiveSession

    var body: some View {
        Button { session.useContext.toggle() } label: {
            VStack(spacing: 4) {
                Image(systemName: session.useContext ? "text.bubble.fill" : "text.bubble")
                    .font(.title2)
                Text(session.useContext ? "断词修复开" : "断词修复关").font(.caption2)
            }
            .frame(width: 70)
            .foregroundStyle(session.useContext ? Color.accentColor : Color.secondary)
        }
    }
}

/// 只点圆圈操作，圆圈下面的语言名称用于辨认左右两侧。
struct ConversationInputButton: View {
    @EnvironmentObject var session: LiveSession
    let lang: Language

    var body: some View {
        let selected = session.conversationInputLanguage == lang
        let active = session.isRunning && selected
        let enabled = selected || session.phase == .ready
        VStack(spacing: 6) {
            ZStack {
                if active { RippleRings().allowsHitTesting(false) }
                ConversationInputRing(meter: session.meter, active: active)
                    .allowsHitTesting(false)
                Button {
                    Task { await session.toggleConversationInput(lang) }
                } label: {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 78, height: 78)
                        .shadow(color: Color.accentColor.opacity(active ? 0.5 : 0), radius: 10)
                        .overlay {
                            if selected {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 27, weight: .bold))
                                    .foregroundStyle(.white)
                                    .allowsHitTesting(false)
                            } else {
                                Text(lang.flag)
                                    .font(.system(size: 38))
                                    .allowsHitTesting(false)
                            }
                        }
                        .contentShape(.interaction, Circle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel(selected ? "停止收听\(lang.name)" : "开始收听\(lang.name)")
            }
            .frame(width: 116, height: 110)
            .scaleEffect(active ? 1.08 : 1)
            Text(lang.name)
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 116)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(.spring(duration: 0.2), value: active)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// 录音时外圈随音量变化。
struct ConversationInputRing: View {
    @ObservedObject var meter: LevelMeter
    let active: Bool

    var body: some View {
        Circle()
            .fill(Color.accentColor.opacity(active ? 0.25 : 0.18))
            .frame(width: 92 + CGFloat(active ? meter.level : 0) * 20)
            .animation(.easeOut(duration: 0.12), value: meter.level)
    }
}

/// 录音时的水波纹：三圈从按钮边缘不断往外扩、慢慢变淡
struct RippleRings: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let p = (t / 1.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(Color.accentColor.opacity(0.6 * (1 - p)), lineWidth: 3)
                        .frame(width: 90 * (1 + 0.35 * p), height: 90 * (1 + 0.35 * p))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 中间的大按钮：外圈跟着音量变大（只有它跟着音量刷新）
struct MicButton: View {
    @ObservedObject var meter: LevelMeter
    let running: Bool
    let color: Color
    let icon: String

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 92 + CGFloat(running ? meter.level : 0) * 44)
            Circle()
                .fill(color)
                .frame(width: 78)
            Image(systemName: icon)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 140, height: 140)
        .animation(.easeOut(duration: 0.12), value: meter.level)
    }
}

// MARK: - 朗读按钮（点按开关，长按 2 秒切换扬声器/耳机）

private struct PlaybackSpeakerIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let playing: Bool

    var body: some View {
        Image(systemName: "speaker.wave.2.fill")
            .symbolEffect(.variableColor.iterative.reversing, isActive: playing && !reduceMotion)
    }
}

struct SpeakToggle: View {
    @EnvironmentObject var session: LiveSession
    @State private var showEars = false

    private var label: String {
        guard session.speakOutput else { return "播报关" }
        return session.outputMode == .headphones ? "耳机播报" : "扬声器播报"
    }

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if !session.speakOutput {
                    Image(systemName: "speaker.slash.fill")
                } else if session.outputMode == .headphones {
                    Image(systemName: "headphones")
                } else {
                    PlaybackSpeakerIcon(playing: session.speakingID != nil)
                }
            }
            .font(.title2)
            Text(label).font(.caption2)
        }
        .frame(width: 76, height: 56)
        .foregroundStyle(session.speakOutput ? Color.accentColor : Color.secondary)   // 关闭时灰色
        .contentShape(Rectangle())
        .onTapGesture { session.speakOutput.toggle() }
        // 按住 2 秒：耳机播报时弹出左右耳设置；扬声器播报时切换到耳机（没连耳机不切换）
        .onLongPressGesture(minimumDuration: 2) {
            if session.outputMode == .headphones {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showEars = true
            } else {
                session.setAudioOutput(.headphones)
            }
        }
        .sheet(isPresented: $showEars) {
            EarSheet()
                .presentationDetents([.height(330)])
                .presentationDragIndicator(.visible)
        }
        .accessibilityLabel("播报")
        .accessibilityHint("点按开关播报；按住两秒设置耳机左右耳，或切换到耳机")
    }
}

// MARK: - 耳机播报：左右耳分别听哪种语言（长按播报按钮弹出）

struct EarSheet: View {
    @EnvironmentObject var session: LiveSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("耳机播报").font(.headline).padding(.top, 22)

            HStack(spacing: 0) {
                EarColumn(title: "左耳", symbol: "airpod.left", selection: $session.leftEar)
                Divider().frame(height: 120)
                EarColumn(title: "右耳", symbol: "airpod.right", selection: $session.rightEar)
            }
            .padding(.horizontal, 24)

            Button {
                session.setAudioOutput(.speaker)
                dismiss()
            } label: {
                Label("改用手机扬声器播报", systemImage: "speaker.wave.2")
                    .font(.subheadline)
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct EarColumn: View {
    @EnvironmentObject var session: LiveSession
    let title: String
    let symbol: String
    @Binding var selection: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(selection == "off" ? Color.secondary : Color.accentColor)
                .frame(height: 56)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Menu {
                Picker(title, selection: $selection) {
                    Text("\(session.langA.flag) \(session.langA.name)").tag("A")
                    Text("\(session.langB.flag) \(session.langB.name)").tag("B")
                    Text("不播放").tag("off")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(session.earLabel(selection)).fontWeight(.medium).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 说话中的实时气泡（识别和译文会不断更正）

struct LiveBubble: View {
    @EnvironmentObject var session: LiveSession

    var body: some View {
        let fullWidth = !session.talkMode
        let leading = fullWidth ? true : (session.partialSource.map { $0 == session.langA } ?? true)
        HStack {
            if !fullWidth && !leading { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
                    Text(session.displayedPartial).italic()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if !session.partialTranslation.isEmpty {
                    Text(session.displayedPartialTranslation)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Color.primary.opacity(0.75))
                }
            }
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            if !fullWidth && leading { Spacer(minLength: 40) }
        }
    }
}

// MARK: - iPhone 对话翻译「面对面」上下分屏视图（对标苹果翻译面对面效果）

struct PhoneFaceToFaceView: View {
    @EnvironmentObject var session: LiveSession
    var onOpenMenu: () -> Void
    var onExit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 上半屏：整体旋转 180° 面向桌子对面的对方（langB）
            halfPane(lang: $session.langB, targetLang: session.langA, isOpponent: true)
                .rotationEffect(.degrees(180))

            // 中间横线 + 中心翻转/互换语种按钮（若有横线状态/语种提醒则叠加显示在横线上）
            ZStack {
                Divider()
                    .padding(.horizontal, 16)
                if let hint = session.loadingHint ?? session.modelReadyHint {
                    ModelStatusPill(text: hint, isLoading: session.loadingHint != nil)
                        .allowsHitTesting(false)
                } else {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        session.swapLanguages()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("互换双方语言")
                }
            }
            .frame(height: 44)

            // 下半屏：正向面向自己（langA），底部左右带 ⋯ 菜单与 × 退出面对面
            ZStack(alignment: .bottom) {
                halfPane(lang: $session.langA, targetLang: session.langB, isOpponent: false)
                HStack(spacing: 12) {
                    Button(action: onOpenMenu) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("展示方式与更多")

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        session.speakOutput.toggle()
                    } label: {
                        Image(systemName: session.speakOutput ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(session.speakOutput ? Color.accentColor : Color.secondary)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.speakOutput ? "关闭自动播报" : "开启自动播报")

                    Spacer()

                    Button(action: onExit) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("退出面对面")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
        }
        .background(Color(.systemBackground))
    }

    private func halfPane(lang: Binding<Language>, targetLang: Language, isOpponent: Bool) -> some View {
        let myLang = lang.wrappedValue
        let selected = session.conversationInputLanguage == myLang
        let active = session.isRunning && selected
        let enabled = selected || session.phase == .ready
        let displayLang = session.chineseDisplayLanguage

        return VStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        // 语种选择胶囊 + 轻点说话引导
                        HStack {
                            if !isOpponent { Spacer(minLength: 0) }
                            VStack(alignment: isOpponent ? .leading : .trailing, spacing: 6) {
                                Menu {
                                    ForEach(session.supportedLanguages) { option in
                                        Button { lang.wrappedValue = option } label: {
                                            if option == myLang {
                                                Label("\(option.flag) \(option.displayName)", systemImage: "checkmark")
                                            } else {
                                                Text("\(option.flag) \(option.displayName)")
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text("\(myLang.flag) \(myLang.displayName)")
                                            .font(.caption.weight(.semibold))
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption2)
                                    }
                                    .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)

                                if session.items.isEmpty && session.partial.isEmpty {
                                    Text(myLang.id == "zh" ? "轻点麦克风来说话" : "Tap mic to speak")
                                        .font(.title3.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                            if isOpponent { Spacer(minLength: 0) }
                        }

                        ForEach(session.items.suffix(20)) { item in
                            let isMine = item.source.id == myLang.id
                            let primaryText = isMine
                                ? item.displayedSource(using: displayLang)
                                : item.displayedTranslation(using: displayLang)
                            let secondaryText = isMine
                                ? item.displayedTranslation(using: displayLang)
                                : item.displayedSource(using: displayLang)
                            VStack(alignment: .leading, spacing: 4) {
                                if !primaryText.isEmpty {
                                    Text(primaryText)
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(.primary)
                                }
                                if !secondaryText.isEmpty {
                                    Text(secondaryText)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                isMine ? Color.accentColor.opacity(0.16) : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .onTapGesture {
                                if item.canReadAloud { session.tapRead(item) }
                            }
                            .id(item.id)
                        }

                        if !session.partial.isEmpty {
                            let isMine = session.partialSource?.id == myLang.id
                            let liveText = isMine ? session.displayedPartial : (session.partialTranslation.isEmpty ? session.displayedPartial : session.displayedPartialTranslation)
                            Text(liveText)
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                )
                                .id("face-partial")
                        }

                        Color.clear.frame(height: 16).id("face-bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                .onChange(of: session.items.last?.id) { _, _ in
                    withAnimation { proxy.scrollTo("face-bottom", anchor: .bottom) }
                }
                .onChange(of: session.items.last?.translated) { _, _ in
                    proxy.scrollTo("face-bottom", anchor: .bottom)
                }
                .onChange(of: session.partial) { _, _ in
                    proxy.scrollTo("face-bottom", anchor: .bottom)
                }
            }

            // 本侧独立圆形麦克风按钮（对标苹果青蓝圆钮）
            Button {
                Task { await session.toggleConversationInput(myLang) }
            } label: {
                ZStack {
                    if active {
                        Circle()
                            .fill(Color.accentColor.opacity(0.24))
                            .frame(width: 78, height: 78)
                    }
                    Circle()
                        .fill(active ? Color.red : Color.accentColor)
                        .frame(width: 62, height: 62)
                        .overlay {
                            Image(systemName: selected ? "stop.fill" : "mic.fill")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white)
                        }
                }
                .frame(width: 80, height: 74)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .padding(.bottom, isOpponent ? 6 : 8)
            .accessibilityLabel(selected ? "停止收听\(myLang.name)" : "开始收听\(myLang.name)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 4 种翻译模式线框示意图（滑动底部模式栏时浮动预览使用）

private struct ModePreviewDiagram: View {
    let mode: AppTranslationMode

    var body: some View {
        let accent = Color.accentColor
        let cardBg = Color.primary.opacity(0.11)
        switch mode {
        case .listening:
            // 通栏说话人卡片 + 底部单个麦克风
            VStack(spacing: 6) {
                VStack(spacing: 5) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                        RoundedRectangle(cornerRadius: 3).fill(cardBg).frame(height: 10)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.orange.opacity(0.8)).frame(width: 6, height: 6)
                        RoundedRectangle(cornerRadius: 3).fill(cardBg).frame(height: 10)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.purple.opacity(0.8)).frame(width: 6, height: 6)
                        RoundedRectangle(cornerRadius: 3).fill(cardBg).frame(height: 10)
                    }
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 2)
                Circle()
                    .fill(accent)
                    .frame(width: 22, height: 22)
                    .overlay(Image(systemName: "mic.fill").font(.system(size: 10)).foregroundStyle(.white))
            }
            .padding(.vertical, 8)

        case .singleAuto:
            // 左右对话气泡 + 底部单个自动麦克风
            VStack(spacing: 6) {
                VStack(spacing: 5) {
                    HStack {
                        RoundedRectangle(cornerRadius: 5).fill(cardBg).frame(width: 56, height: 13)
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 5).fill(accent.opacity(0.28)).frame(width: 56, height: 13)
                    }
                    HStack {
                        RoundedRectangle(cornerRadius: 5).fill(cardBg).frame(width: 46, height: 11)
                        Spacer()
                    }
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 2)
                Circle()
                    .fill(accent)
                    .frame(width: 22, height: 22)
                    .overlay(Image(systemName: "mic.fill").font(.system(size: 10)).foregroundStyle(.white))
            }
            .padding(.vertical, 8)

        case .sideBySide:
            // 左右对话气泡 + 底部左右两个语言麦克风
            VStack(spacing: 6) {
                VStack(spacing: 5) {
                    HStack {
                        RoundedRectangle(cornerRadius: 5).fill(cardBg).frame(width: 56, height: 13)
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 5).fill(accent.opacity(0.28)).frame(width: 56, height: 13)
                    }
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 2)
                HStack(spacing: 24) {
                    Circle()
                        .fill(accent)
                        .frame(width: 22, height: 22)
                        .overlay(Text("中").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white))
                    Circle()
                        .fill(accent)
                        .frame(width: 22, height: 22)
                        .overlay(Text("En").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white))
                }
            }
            .padding(.vertical, 8)

        case .faceToFace:
            // 顶部倒置麦克风 + 上半区 + 中间横线与翻转钮 + 下半区 + 底部正向麦克风
            VStack(spacing: 4) {
                Circle()
                    .fill(accent)
                    .frame(width: 19, height: 19)
                    .overlay(Image(systemName: "mic.fill").font(.system(size: 8.5)).foregroundStyle(.white))
                    .rotationEffect(.degrees(180))
                HStack {
                    RoundedRectangle(cornerRadius: 4).fill(cardBg).frame(width: 54, height: 10)
                    Spacer()
                }
                .padding(.horizontal, 14)
                ZStack {
                    Rectangle().fill(Color.primary.opacity(0.18)).frame(height: 1)
                    Circle()
                        .fill(Color(.secondarySystemGroupedBackground))
                        .frame(width: 15, height: 15)
                        .overlay(Image(systemName: "arrow.up.arrow.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.secondary))
                }
                .padding(.horizontal, 10)
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.28)).frame(width: 54, height: 10)
                }
                .padding(.horizontal, 14)
                Circle()
                    .fill(accent)
                    .frame(width: 19, height: 19)
                    .overlay(Image(systemName: "mic.fill").font(.system(size: 8.5)).foregroundStyle(.white))
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - 底部快捷模式切换栏（仿 Apple 原生悬浮胶囊 + 滑动手势 + 浮动效果图预览）

private struct QuickPillPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .opacity(configuration.isPressed ? 0.82 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct FloatingModeSwitcherBar: View {
    @EnvironmentObject var session: LiveSession
    @Environment(\.colorScheme) private var colorScheme
    var onSelect: (_ enteredFaceToFace: Bool) -> Void
    var onInteract: () -> Void

    @Namespace private var pillNS
    @State private var draggingMode: AppTranslationMode?
    @State private var isPressing = false
    @State private var showPreview = false

    private struct ModeItem: Identifiable {
        let mode: AppTranslationMode
        let title: String
        let fullTitle: String
        let subtitle: String
        let icon: String
        var id: AppTranslationMode { mode }
    }

    private let items: [ModeItem] = [
        ModeItem(mode: .listening, title: "聆听", fullTitle: "聆听翻译模式",
                 subtitle: "多语种会议 → 统一译为目标语言", icon: "waveform"),
        ModeItem(mode: .singleAuto, title: "单侧", fullTitle: "单侧自动模式",
                 subtitle: "单按钮自动识别双方语种", icon: "mic.fill"),
        ModeItem(mode: .sideBySide, title: "并排", fullTitle: "并排双键模式",
                 subtitle: "左右双按钮，同向看屏", icon: "person.2.fill"),
        ModeItem(mode: .faceToFace, title: "面对面", fullTitle: "面对面模式",
                 subtitle: "上下分屏，对方画面倒置", icon: "rectangle.split.1x2.fill"),
    ]

    private var committedMode: AppTranslationMode {
        session.currentTranslationMode
    }

    private var highlightedMode: AppTranslationMode {
        draggingMode ?? committedMode
    }

    private var highlightedItem: ModeItem {
        items.first(where: { $0.mode == highlightedMode }) ?? items[0]
    }

    private var highlightedIndex: Int {
        items.firstIndex(where: { $0.mode == highlightedMode }) ?? 0
    }

    private func mode(at x: CGFloat, totalWidth: CGFloat) -> AppTranslationMode {
        guard totalWidth > 0 else { return committedMode }
        let ratio = min(max(x / totalWidth, 0), 0.9999)
        let idx = min(max(Int(ratio * CGFloat(items.count)), 0), items.count - 1)
        return items[idx].mode
    }

    var body: some View {
        GeometryReader { geo in
            let innerWidth = max(geo.size.width - 8, 1)
            let cardWidth: CGFloat = 176
            let segWidth = innerWidth / CGFloat(items.count)
            let rawCenter = 4 + segWidth * (CGFloat(highlightedIndex) + 0.5)
            let clampedCenter = min(max(rawCenter, cardWidth / 2), max(cardWidth / 2, geo.size.width - cardWidth / 2))
            let cardOffsetX = clampedCenter - geo.size.width / 2

            HStack(spacing: 0) {
                ForEach(items) { item in
                    let isSelected = highlightedMode == item.mode
                    let isPressedItem = isPressing && isSelected
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 19, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .frame(height: 22)
                        Text(item.title)
                            .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.82))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(
                                    colorScheme == .dark
                                        ? Color.black.opacity(0.46)
                                        : Color(.systemBackground).opacity(0.92)
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(
                                            Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06),
                                            lineWidth: 0.5
                                        )
                                )
                                .shadow(
                                    color: .black.opacity(colorScheme == .dark ? 0.25 : 0.08),
                                    radius: 4, y: 1
                                )
                                .matchedGeometryEffect(id: "floatingModeActivePill", in: pillNS)
                        }
                    }
                    .scaleEffect(isPressedItem ? 0.94 : 1.0)
                    .animation(.spring(response: 0.24, dampingFraction: 0.76), value: isPressedItem)
                    .contentShape(Capsule())
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10),
                        lineWidth: 0.6
                    )
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.14), radius: 16, y: 6)
            // 按住、滑动或点击选中模式后，在对应按钮正上方持续浮动展示该模式的线框效果图（随底部栏 2 秒后一同自动退出）
            .overlay(alignment: .bottom) {
                if showPreview {
                    let preview = highlightedItem
                    VStack(spacing: 8) {
                        ModePreviewDiagram(mode: preview.mode)
                            .frame(height: 98)
                            .frame(maxWidth: .infinity)
                            .background(
                                Color(.tertiarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.72 : 0.90),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                        VStack(spacing: 2) {
                            Text(preview.fullTitle)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(preview.subtitle)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(10)
                    .frame(width: cardWidth)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08), lineWidth: 0.6)
                    )
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 18, y: 6)
                    .offset(x: cardOffsetX, y: -74)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 0.86, anchor: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.80), value: showPreview)
            .animation(.spring(response: 0.26, dampingFraction: 0.80), value: highlightedMode)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let target = mode(at: value.location.x - 4, totalWidth: innerWidth)
                        if !isPressing {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.78)) {
                                isPressing = true
                                showPreview = true
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } else if draggingMode != target {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        if draggingMode != target {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                draggingMode = target
                            }
                        }
                        onInteract()
                    }
                    .onEnded { value in
                        let target = mode(at: value.location.x - 4, totalWidth: innerWidth)
                        let changed = target != committedMode
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                            session.switchTranslationMode(to: target)
                            draggingMode = nil
                            isPressing = false
                            showPreview = true
                        }
                        if changed {
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                        onSelect(target == .faceToFace)
                    }
            )
        }
        .frame(height: 62)
        .onDisappear {
            draggingMode = nil
            isPressing = false
            showPreview = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("快捷模式切换栏")
    }
}
