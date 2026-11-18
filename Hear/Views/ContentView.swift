import SwiftUI
import Translation

struct ContentView: View {
    @EnvironmentObject var session: LiveSession
    @ObservedObject private var llm = LLMSettings.shared
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var askNew = false
    @State private var noLLMAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TopBar(onNew: newTapped,
                       onHistory: { showHistory = true },
                       onSettings: { showSettings = true })
                LanguageBar()
                Divider()
                Group {
                    if session.phase == .ready || session.isLoadingPhase {
                        // 加载模型时也显示对话页，顶部一行小字提示，不挡住内容
                        TranscriptView()
                            .overlay(alignment: .top) {
                                VStack(spacing: 6) {
                                    if let msg = session.loadingText {
                                        LoadingPill(text: msg)
                                    }
                                    if session.usingApple, let note = session.appleNote {
                                        NotePill(text: note)
                                    }
                                }
                                .padding(.top, 8)
                            }
                    } else {
                        SetupView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ControlBar()
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showHistory) { HistoryView() }
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
    var onNew: () -> Void
    var onHistory: () -> Void
    var onSettings: () -> Void
    @State private var showMenu = false

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

            Button { showMenu = true } label: {
                MoreDots()
            }
            .foregroundStyle(.primary)
            .accessibilityLabel("更多")
            // 紧凑的弹出菜单：宽度只包住图标和文字
            .popover(isPresented: $showMenu, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    menuRow("新建", "square.and.pencil", onNew)
                    Divider()
                    menuRow("历史", "clock.arrow.circlepath", onHistory)
                    Divider()
                    menuRow("设置", "gearshape", onSettings)
                }
                .fixedSize()
                .presentationCompactAdaptation(.popover)
            }
        }
        .overlay {
            Text("听见").font(.headline)
        }
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func menuRow(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button {
            showMenu = false
            // 等菜单收起后再打开下一个页面
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { action() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22)
                Text(title)
            }
            .font(.body)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
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
    @Binding var selection: Language

    var body: some View {
        Menu {
            ForEach(Language.all) { lang in
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if session.items.isEmpty && session.partial.isEmpty {
                        EmptyHint().padding(.top, 60)
                    }
                    ForEach(session.items) { item in
                        BubbleView(item: item, leading: item.source == session.langA,
                                   reading: session.readingID == item.id) {
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
            Text("点下方按钮开始，之后直接说话即可")
                .font(.headline)
            Text("\(session.langA.name) 和 \(session.langB.name) 都可以说，App 会自动识别是哪种语言并翻译成另一种。全部在手机本地完成。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
    }
}

struct BubbleView: View {
    let item: TranslationItem
    let leading: Bool
    var reading: Bool = false
    var onSpeak: () -> Void

    /// 左侧气泡国旗在前，右侧气泡国旗在后（靠外侧）
    private func flagged(_ flag: String, _ text: String) -> Text {
        leading ? Text("\(flag) \(text)") : Text("\(text) \(flag)")
    }

    private var readingIcon: some View {
        Image(systemName: "speaker.wave.2.fill")
            .symbolEffect(.variableColor.iterative)
            .foregroundStyle(Color.accentColor)
    }

    var body: some View {
        HStack {
            if !leading { Spacer(minLength: 40) }
            VStack(alignment: leading ? .leading : .trailing, spacing: 6) {
                flagged(item.source.flag, item.sourceText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if item.translated.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if reading && !leading { readingIcon }
                        flagged(item.target.flag, item.translated)
                            .font(.title3.weight(.medium))
                        if reading && leading { readingIcon }
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
            .onTapGesture { if !item.translated.isEmpty { onSpeak() } }   // 点句子朗读译文
            .contextMenu {
                Button { UIPasteboard.general.string = item.translated } label: {
                    Label("复制译文", systemImage: "doc.on.doc")
                }
                Button { UIPasteboard.general.string = item.sourceText } label: {
                    Label("复制原文", systemImage: "doc.on.doc")
                }
                Button(action: onSpeak) { Label("朗读译文", systemImage: "speaker.wave.2") }
            }
            if leading { Spacer(minLength: 40) }
        }
    }
}

// MARK: - 底部：开始/停止

struct ControlBar: View {
    @EnvironmentObject var session: LiveSession

    private var mainColor: Color { session.isRunning ? Color.red : Color.accentColor }
    private var mainIcon: String { session.isRunning ? "stop.fill" : "mic.fill" }
    private var mainHint: String {
        guard session.isRunning else { return "点击开始实时翻译" }
        if session.speakOutput && session.outputMode == .speaker {
            return "实时翻译中 · 点击停止后朗读"
        }
        return "实时翻译中 · 点击停止"
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(session.activity.isEmpty ? " " : session.activity)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                // 点一下：朗读开/关；按住 2 秒：扬声器 ⇄ 耳机
                SpeakToggle()

                Spacer()

                Button { Task { await session.toggle() } } label: {
                    ZStack {
                        Circle()
                            .fill(mainColor.opacity(0.18))
                            .frame(width: 92 + CGFloat(session.isRunning ? session.level : 0) * 44)
                        Circle()
                            .fill(mainColor)
                            .frame(width: 78)
                        Image(systemName: mainIcon)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 140, height: 140)
                    .animation(.easeOut(duration: 0.12), value: session.level)
                }
                .disabled(!(session.phase == .ready || session.isLoadingPhase))
                .opacity(session.phase == .ready || session.isLoadingPhase ? 1 : 0.4)

                Spacer()

                Button { session.useContext.toggle() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: session.useContext ? "text.bubble.fill" : "text.bubble")
                            .font(.title2)
                        Text(session.useContext ? "上下文开" : "上下文关").font(.caption2)
                    }
                    .frame(width: 70)
                }
            }
            .padding(.horizontal, 24)

            Text(mainHint)
                .font(.callout.weight(.medium))
                .padding(.bottom, 8)
        }
        .padding(.top, 6)
    }
}

// MARK: - 朗读按钮（点按开关，长按 2 秒切换扬声器/耳机）

struct SpeakToggle: View {
    @EnvironmentObject var session: LiveSession
    @State private var showEars = false

    private var icon: String {
        if !session.speakOutput { return "speaker.slash.fill" }
        return session.outputMode == .headphones ? "headphones" : "speaker.wave.2.fill"
    }

    private var label: String {
        guard session.speakOutput else { return "播报关" }
        return session.outputMode == .headphones ? "耳机播报" : "扬声器播报"
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title2)
            Text(label).font(.caption2)
        }
        .frame(width: 76, height: 56)
        .foregroundStyle(Color.accentColor)
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
