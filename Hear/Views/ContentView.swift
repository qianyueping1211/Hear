import SwiftUI

struct ContentView: View {
    @EnvironmentObject var session: LiveSession
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LanguageBar()
                if session.outputMode == .headphones {
                    EarBar()
                }
                Divider()
                Group {
                    if session.phase == .ready {
                        TranscriptView()
                    } else {
                        SetupView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ControlBar()
            }
            .navigationTitle("听见")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { session.clear() } label: { Image(systemName: "trash") }
                        .disabled(session.items.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .task { await session.bootstrap() }
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
                        Label("\(lang.flag) \(lang.name)", systemImage: "checkmark")
                    } else {
                        Text("\(lang.flag) \(lang.name)")
                    }
                }
            }
        } label: {
            HStack {
                Text(selection.flag)
                Text(selection.name).fontWeight(.semibold)
                Image(systemName: "chevron.down").font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
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
                        BubbleView(item: item, leading: item.source == session.langA) {
                            session.replay(item)
                        }
                        .id(item.id)
                    }
                    if !session.partial.isEmpty {
                        HStack {
                            Text(session.partial)
                                .italic()
                                .foregroundStyle(.secondary)
                                .padding(12)
                                .background(Color(.tertiarySystemBackground),
                                            in: RoundedRectangle(cornerRadius: 16))
                            Spacer(minLength: 40)
                        }
                        .id("partial")
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
    var onSpeak: () -> Void

    var body: some View {
        HStack {
            if !leading { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Text("\(item.source.flag) \(item.sourceText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if item.translated.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(item.target.flag) \(item.translated)")
                        .font(.title3.weight(.medium))
                }
            }
            .padding(12)
            .background(leading ? Color(.secondarySystemBackground) : Color.accentColor.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 16))
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
                            .fill((session.isRunning ? Color.red : Color.accentColor).opacity(0.18))
                            .frame(width: 92 + CGFloat(session.isRunning ? session.level : 0) * 44)
                        Circle()
                            .fill(session.isRunning ? Color.red : Color.accentColor)
                            .frame(width: 78)
                        Image(systemName: session.isRunning ? "stop.fill" : "mic.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 140, height: 140)
                    .animation(.easeOut(duration: 0.12), value: session.level)
                }
                .disabled(session.phase != .ready)
                .opacity(session.phase == .ready ? 1 : 0.4)

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

            Text(session.isRunning ? "实时翻译中 · 点击停止" : "点击开始实时翻译")
                .font(.callout.weight(.medium))
                .padding(.bottom, 8)
        }
        .padding(.top, 6)
    }
}

// MARK: - 朗读按钮（点按开关，长按 2 秒切换扬声器/耳机）

struct SpeakToggle: View {
    @EnvironmentObject var session: LiveSession

    private var icon: String {
        if !session.speakOutput { return "speaker.slash.fill" }
        return session.outputMode == .headphones ? "headphones" : "speaker.wave.2.fill"
    }

    private var label: String {
        let where_ = session.outputMode == .headphones ? "耳机" : "朗读"
        return session.speakOutput ? "\(where_)开" : "\(where_)关"
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title2)
            Text(label).font(.caption2)
        }
        .frame(width: 70, height: 56)
        .foregroundStyle(Color.accentColor)
        .contentShape(Rectangle())
        .onTapGesture { session.speakOutput.toggle() }
        .onLongPressGesture(minimumDuration: 2) { session.cycleOutput() }
        .accessibilityLabel("朗读")
        .accessibilityHint("点按开关朗读，按住两秒切换扬声器或耳机")
    }
}

// MARK: - 耳机模式：左右耳分别听哪种语言

struct EarBar: View {
    @EnvironmentObject var session: LiveSession

    var body: some View {
        HStack(spacing: 10) {
            EarMenu(title: "左耳", symbol: "l.circle.fill", selection: $session.leftEar)
            EarMenu(title: "右耳", symbol: "r.circle.fill", selection: $session.rightEar)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

struct EarMenu: View {
    @EnvironmentObject var session: LiveSession
    let title: String
    let symbol: String
    @Binding var selection: String

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                Text(session.langA.name).tag("A")
                Text(session.langB.name).tag("B")
                Text("不播放").tag("off")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).foregroundStyle(.secondary)
                Text(session.earLabel(selection)).fontWeight(.medium)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        .foregroundStyle(.primary)
    }
}
