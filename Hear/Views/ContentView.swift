import SwiftUI
import Translation

struct ContentView: View {
    @EnvironmentObject var session: LiveSession
    @ObservedObject private var llm = LLMSettings.shared
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var askNew = false
    @State private var noLLMAlert = false
    @State private var editingID: UUID?          // 正在修改原文的那一条
    @State private var draft = ""
    @State private var editingSpeaker: TranslationItem?
    @State private var showMenu = false          // 右上角 ⋯ 菜单

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TopBar(onMore: { showMenu = true })
                LanguageBar()
                Divider()
                Group {
                    if session.phase == .ready || session.isLoadingPhase {
                        // 加载模型时也显示对话页；加载进度只在 功能设置 → 引擎 下方显示
                        TranscriptView(onEdit: { item in
                            draft = item.sourceText
                            editingID = item.id
                        }, onSpeaker: { editingSpeaker = $0 })
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
                ControlBar()
            }
            // 弹出键盘时底部的实时翻译区域固定不动
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .toolbar(.hidden, for: .navigationBar)
            // 右上角 ⋯ 菜单：自己画的面板，不跟着页面实时刷新，所以不会闪
            .overlay(alignment: .topTrailing) {
                if showMenu {
                    ZStack(alignment: .topTrailing) {
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .onTapGesture { showMenu = false }
                        MoreMenuPanel(
                            onNew: { showMenu = false; newTapped() },
                            onHistory: { showMenu = false; showHistory = true },
                            onSettings: { showMenu = false; showSettings = true }
                        )
                        .padding(.top, 54)
                        .padding(.trailing, 16)
                        .transition(.scale(scale: 0.6, anchor: .topTrailing).combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(duration: 0.28), value: showMenu)
            .overlay {
                if let id = editingID, let item = session.items.first(where: { $0.id == id }) {
                    SourceEditor(text: $draft, flag: item.source.flag,
                                 translation: item.translated, targetFlag: item.target.flag) {
                        session.editSource(id, to: draft)
                        editingID = nil
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showHistory) { HistoryView() }
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
                }
                Button("不总结，直接新建") { session.newConversation(summarize: false) }
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
        }
        // 用云端模型但本地网络权限没开：弹提示告诉用户去哪儿开。
        // （挂在 NavigationStack 上：里面已经有一个 .alert 了，同一个视图挂两个会互相顶掉）
        .localNetworkHelp($session.localNetworkHelp)
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
            Text("听见：\(session.talkMode ? "对话翻译模式" : "实时翻译模式")")
                .font(.headline)
        }
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

/// 右上角弹出的菜单：窄面板，每行图标 + 文字横向居中，行与行之间不加分隔线
struct MoreMenuPanel: View {
    var onNew: () -> Void
    var onHistory: () -> Void
    var onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            row("新建对话", "square.and.pencil", onNew)
            row("历史记录", "clock.arrow.circlepath", onHistory)
            row("功能设置", "gearshape", onSettings)
        }
        .padding(.vertical, 4)
        .frame(width: 198)
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

/// 加载模型时顶部的小提示
struct LoadingPill: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - 顶部：选择两种语言

struct LanguageBar: View {
    @EnvironmentObject var session: LiveSession

    var body: some View {
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
    var onEdit: (TranslationItem) -> Void = { _ in }
    var onSpeaker: (TranslationItem) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if session.items.isEmpty && session.partial.isEmpty {
                        EmptyHint().padding(.top, 60)
                    }
                    ForEach(session.items) { item in
                        BubbleView(item: item, leading: item.isLeading(left: session.langA, right: session.langB),
                                   reading: session.readingID == item.id,
                                   playing: session.speakingID == item.id,
                                   preparing: session.cloneWorking[item.id] != nil,
                                   showIdleReadingIcon: session.showReadingIcon,
                                   onEdit: { if item.done { onEdit(item) } },
                                   onSpeaker: item.speakerLabel == nil ? nil : { onSpeaker(item) }) {
                            session.tapRead(item)
                        }
                        .id(item.id)
                    }
                    if !session.partial.isEmpty {
                        LiveBubble().id("partial")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: session.items) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.partial) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: session.partialTranslation) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

struct EmptyHint: View {
    @EnvironmentObject var session: LiveSession
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(session.talkMode ? "按住下方对应语言的按钮说话，松开暂停" : "点下方按钮开始，之后直接说话即可")
                .font(.headline)
            Text(session.talkMode
                 ? "左边按钮说\(session.langA.name)，右边按钮说\(session.langB.name)。左右滑动底部可以切回实时翻译模式。"
                 : "\(session.langA.name) 和 \(session.langB.name) 都可以说，App 会自动识别是哪种语言并翻译成另一种。左右滑动底部可以切换到对话翻译模式。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
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
    var reading: Bool = false
    /// 真的在出声：喇叭显示成绿色的（只有正在播的时候才是绿的）
    var playing: Bool = false
    /// 声音（克隆原声）还在生成：喇叭显示成灰色，表示"马上就好"
    var preparing: Bool = false
    var showIdleReadingIcon: Bool = true
    var onEdit: (() -> Void)? = nil      // 有值时：长按修改原文（对话页）；没有时：长按弹出复制菜单（历史页）
    var onSpeaker: (() -> Void)? = nil
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
            if !leading { Spacer(minLength: 40) }
            VStack(alignment: leading ? .leading : .trailing, spacing: 6) {
                if let speaker = item.speakerLabel {
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
                (flagged(item.source.flag, item.sourceText)
                 + (item.corrected == true
                    ? Text(" ") + Text(Image(systemName: "wand.and.stars")).foregroundStyle(Color.accentColor)
                    : Text("")))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if item.sourceProvisional == true {
                    Text("原文待确认").font(.caption).foregroundStyle(.secondary)
                }
                if item.translated.isEmpty {
                    if !item.done { ProgressView().controlSize(.small) }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if showsReadingIcon && !leading { readingIcon }
                        flagged(item.target.flag, item.translated)
                            .font(.title3.weight(.medium))
                        if showsReadingIcon && leading { readingIcon }
                    }
                }
            }
            .multilineTextAlignment(leading ? .leading : .trailing)
            .padding(12)
            .background(leading ? Color(.secondarySystemBackground) : Color.accentColor.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(reading ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { if item.canReadAloud { onSpeak() } }
            .modifier(BubbleLongPress(item: item, onEdit: onEdit, onSpeak: onSpeak))
            if leading { Spacer(minLength: 40) }
        }
    }
}

/// 气泡的长按：对话页是修改原文，历史页是复制菜单
private struct BubbleLongPress: ViewModifier {
    let item: TranslationItem
    let onEdit: (() -> Void)?
    let onSpeak: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onEdit {
            content.onLongPressGesture(minimumDuration: 0.4) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onEdit()
            }
        } else {
            content.contextMenu {
                Button { UIPasteboard.general.string = item.translated } label: {
                    Label("复制译文", systemImage: "doc.on.doc")
                }
                Button { UIPasteboard.general.string = item.sourceText } label: {
                    Label("复制原文", systemImage: "doc.on.doc")
                }
                if item.canReadAloud {
                    Button(action: onSpeak) { Label("朗读译文", systemImage: "speaker.wave.2") }
                }
            }
        }
    }
}

/// 修改原文的编辑框：点编辑框以外的地方就保存，并重新翻译
struct SourceEditor: View {
    @Binding var text: String
    let flag: String
    var translation: String = ""          // 当前译文，只看不改
    var targetFlag: String = ""
    let onDone: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDone() }
            VStack(alignment: .leading, spacing: 10) {
                Text("\(flag) 修改原文").font(.headline)
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
                }
                Text("点空白处保存，并重新翻译").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 16)
            .padding(.top, 110)
        }
        .onAppear { focused = true }
    }
}

// MARK: - 底部：开始/停止

struct ControlBar: View {
    @EnvironmentObject var session: LiveSession

    private var mainColor: Color { Color.accentColor }        // 开始后也用蓝色，只换成停止图标
    private var mainIcon: String { session.isRunning ? "stop.fill" : "mic.fill" }
    private var mainHint: String {
        if session.talkMode {
            if let l = session.holding { return "正在听\(l.name) · 松开暂停" }
            return "按住对应语言的按钮说话"
        }
        guard session.isRunning else { return "点击开始实时翻译" }
        if session.speakOutput && session.outputMode == .speaker {
            return "实时翻译中 · 点击停止后朗读"
        }
        return "实时翻译中 · 点击停止"
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(session.recordingStatus.isEmpty ? " " : session.recordingStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)

            ZStack {
                if session.talkMode {
                    talkControls
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    liveControls
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(height: 140)
            .clipped()

            Text(mainHint)
                .font(.callout.weight(.medium))

            ModeDots()
                .padding(.bottom, 6)
        }
        .padding(.top, 6)
        .contentShape(Rectangle())
        // 左右滑动切换：实时翻译 ⇄ 对话翻译（按着说话时不切换）
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { v in
                let dx = v.translation.width
                guard session.holding == nil, abs(dx) > 50, abs(dx) > abs(v.translation.height) else { return }
                let talk = dx < 0
                guard talk != session.talkMode else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(duration: 0.3)) { session.talkMode = talk }
            }
        )
        // 按钮上方的短暂提示（例如本地模型还在加载）
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                // 正在加载：一直显示到加载完
                if let hint = session.loadingHint {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(hint).font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                }
                if let t = session.toast {
                    Text(t)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .offset(y: -30)
        }
        .animation(.spring(duration: 0.25), value: session.toast)
    }

    /// 实时翻译模式：播报 · 大按钮 · 上下文
    private var liveControls: some View {
        HStack {
            // 点一下：朗读开/关；按住 2 秒：扬声器 ⇄ 耳机
            SpeakToggle()

            Spacer()

            Button { Task { await session.toggle() } } label: {
                MicButton(meter: session.meter, running: session.isRunning,
                          color: mainColor, icon: mainIcon)
            }
            .disabled(!(session.phase == .ready || session.isLoadingPhase))
            .opacity(session.phase == .ready || session.isLoadingPhase ? 1 : 0.4)

            Spacer()

            ContextToggle()
        }
        .padding(.horizontal, 24)
    }

    /// 对话翻译模式：左边按住说语言 A，右边按住说语言 B，中间是播报和上下文
    private var talkControls: some View {
        HStack(spacing: 0) {
            HoldButton(lang: session.langA)
            Spacer(minLength: 4)
            VStack(spacing: 10) {
                SpeakToggle()
                ContextToggle()
            }
            Spacer(minLength: 4)
            HoldButton(lang: session.langB)
        }
        .padding(.horizontal, 16)
    }
}

/// 底部的两个小圆点：表示当前是哪个模式，点一下也能切换
struct ModeDots: View {
    @EnvironmentObject var session: LiveSession

    var body: some View {
        HStack(spacing: 6) {
            dot(active: !session.talkMode) { session.talkMode = false }
            dot(active: session.talkMode) { session.talkMode = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.talkMode ? "对话翻译模式" : "实时翻译模式")
        .accessibilityHint("左右滑动切换模式")
    }

    private func dot(active: Bool, _ action: @escaping () -> Void) -> some View {
        Capsule()
            .fill(active ? Color.accentColor : Color.secondary.opacity(0.35))
            .frame(width: active ? 16 : 6, height: 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                guard session.holding == nil, !active else { return }
                withAnimation(.spring(duration: 0.3)) { action() }
            }
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
                Text(session.useContext ? "上下文开" : "上下文关").font(.caption2)
            }
            .frame(width: 70)
            .foregroundStyle(session.useContext ? Color.accentColor : Color.secondary)
        }
    }
}

/// 对话翻译模式的按钮：和实时翻译的大按钮同样的样式，中间是这种语言的国旗。
/// 按住时外面一圈圈水波纹不停往外扩，松开就停
struct HoldButton: View {
    @EnvironmentObject var session: LiveSession
    let lang: Language
    @State private var pressing = false
    /// 这次按下时启动的“开始听”任务，以及按了第几次（松开时用来确认没有再按下）
    @State private var beginTask: Task<Void, Never>?
    @State private var pressCount = 0

    var body: some View {
        // 手指一按下就显示按住效果，不等麦克风真正打开
        let active = pressing || session.holding == lang
        let enabled = session.phase == .ready || session.isLoadingPhase
        VStack(spacing: 6) {
            ZStack {
                if active { RippleRings() }
                HoldRing(meter: session.meter, active: active)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 78, height: 78)
                    .shadow(color: Color.accentColor.opacity(active ? 0.5 : 0), radius: 10)
                Text(lang.flag).font(.system(size: 38))
            }
            .frame(width: 116, height: 110)
            .scaleEffect(active ? 1.08 : 1)
            Text(active ? "松开暂停" : "按住说\(lang.name)")
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 116)
        }
        .animation(.spring(duration: 0.2), value: active)
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        // 按下就开始听，松开就暂停。
        // 用“按压状态”而不是拖动手势：拖动手势要等系统判断你是不是在左右滑动切换模式，
        // 会过好一会儿才有反应；按压状态手指一碰到就触发。手势被系统取消（来电等）时也会自动松开
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity, perform: {},
                            onPressingChanged: { p in
            guard p != pressing else { return }
            pressing = p
            if p {
                guard enabled else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                pressCount += 1
                beginTask = Task { await session.holdBegan(lang) }
            } else {
                session.holdEnded()
                // 很快地按一下就松开：松开时“开始听”可能还没来得及开始，等它开始后再松开一次，
                // 否则会一直在听（界面也一直显示“松开暂停”）
                let task = beginTask
                let count = pressCount
                Task {
                    await task?.value
                    if count == pressCount, !pressing { session.holdEnded() }
                }
            }
        })
        .accessibilityLabel("按住说\(lang.name)")
    }
}

/// 未按住时和实时翻译按钮一样的浅色外圈；按住时跟着音量变大
struct HoldRing: View {
    @ObservedObject var meter: LevelMeter
    let active: Bool

    var body: some View {
        Circle()
            .fill(Color.accentColor.opacity(active ? 0.25 : 0.18))
            .frame(width: 92 + CGFloat(active ? meter.level : 0) * 20)
            .animation(.easeOut(duration: 0.12), value: meter.level)
    }
}

/// 按住时的水波纹：三圈从按钮边缘不断往外扩、慢慢变淡
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
                session.cycleOutput()
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
                session.cycleOutput()
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
        let leading = session.partialSource.map { $0 == session.langA } ?? true
        HStack {
            if !leading { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
                    Text(session.partial).italic()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if !session.partialTranslation.isEmpty {
                    Text(session.partialTranslation)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Color.primary.opacity(0.75))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            if leading { Spacer(minLength: 40) }
        }
    }
}
