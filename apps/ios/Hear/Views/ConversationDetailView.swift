import SwiftUI

/// 历史对话详情：「对话」和「总结」两个标签
struct ConversationDetailView: View {
    let id: UUID
    @EnvironmentObject var session: LiveSession
    @ObservedObject private var store = ConversationStore.shared
    @StateObject private var player = ConversationAudioPlayer()

    @State private var conv: Conversation?
    @State private var tab = 0
    @State private var editing = false
    @State private var draft = ""
    @State private var showTemplates = false
    @State private var confirmRegenerate = false
    @State private var copied = false
    @State private var editingSpeaker: TranslationItem?
    @State private var editingSource: TranslationItem?
    @State private var sourceDraft = ""

    private var template: SummaryTemplate { SummaryTemplate.find(conv?.activeTemplateID ?? SummaryTemplate.defaultID) }
    private var record: SummaryRecord? { conv?.summaries[template.id] }

    /// 根据当前完整录音播放进度找到正在播放的那一条原文
    private func activePlaybackID(in c: Conversation) -> UUID? {
        guard player.hasAudio, player.isPlaying || player.currentTime > 0.05 else { return nil }
        let t = player.currentTime
        if let exact = c.items.first(where: { item in
            guard let start = item.audioStartSec, let end = item.audioEndSec else { return false }
            return t >= max(0, start - 0.1) && t <= end + 0.25
        }) {
            return exact.id
        }
        return nil
    }

    var body: some View {
        ZStack {
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

            if let item = editingSource {
                SourceEditor(
                    text: $sourceDraft,
                    flag: item.source.flag,
                    translation: item.displayedTranslation(using: session.chineseDisplayLanguage),
                    targetFlag: item.displayedTranslationTarget.flag,
                    onCancel: { editingSource = nil },
                    onDone: {
                        let targetID = item.id
                        let text = sourceDraft
                        editingSource = nil
                        session.editSource(in: id, itemID: targetID, to: text)
                    }
                )
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
        .onAppear {
            reload()
            player.load(conversationID: id)
        }
        .onDisappear {
            player.stop()
        }
        .onChange(of: store.revision) { _, _ in reload() }
    }

    private func reload() { conv = store.load(id) }

    // MARK: 对话

    private func dialogTab(_ c: Conversation) -> some View {
        let activeID = activePlaybackID(in: c)
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if c.items.isEmpty {
                            Text("这段对话没有内容").foregroundStyle(.secondary).padding(.top, 40)
                        }
                        ForEach(c.items) { item in
                            BubbleView(
                                item: item,
                                leading: item.isLeading(left: c.langA, right: c.langB),
                                displayLanguage: session.chineseDisplayLanguage,
                                reading: session.readingID == item.id,
                                audioHighlighted: activeID == item.id,
                                playing: session.speakingID == item.id,
                                preparing: session.cloneWorking[item.id] != nil,
                                showIdleReadingIcon: session.showReadingIcon,
                                useContextMenu: true,
                                onEdit: {
                                    editingSource = item
                                    sourceDraft = item.sourceText
                                },
                                onSpeaker: item.speakerLabel == nil ? nil : { editingSpeaker = item },
                                onTap: {
                                    // 历史页点击框图：不自动播译文，有完整录音时直接定位并播放原文
                                    if player.hasAudio, let start = item.audioStartSec {
                                        session.stopReading()
                                        player.seek(to: start, autoPlay: true)
                                    }
                                },
                                onSpeak: {
                                    // 长按菜单里的「播放译文」：暂停原文回放，改播译文
                                    if player.isPlaying { player.pause() }
                                    session.replay(item)
                                }
                            )
                            .id(item.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: activeID) { _, newID in
                    guard player.isPlaying, let newID else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }

            if player.hasAudio {
                Divider()
                ConversationAudioBar(player: player) {
                    session.stopReading()
                }
            }
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
            if let partial = record?.content, !partial.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在实时生成总结…").font(.caption).foregroundStyle(.secondary)
                    }
                    MarkdownView(text: partial)
                        .padding()
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在后台生成总结… 可以离开这个页面，完成后会自动保存。")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            }

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

/// 历史对话底部的完整录音播放条：播放 / 暂停 / 继续 / 快退 / 快进 / 进度条 / 倍速
private struct ConversationAudioBar: View {
    @ObservedObject var player: ConversationAudioPlayer
    var onBeforePlay: () -> Void

    @State private var isDragging = false
    @State private var dragTime: Double = 0

    private var displayedTime: Double { isDragging ? dragTime : player.currentTime }

    private var playButtonTitle: String {
        if player.isPlaying { return "暂停" }
        if player.isPausedMidway { return "继续" }
        return "播放"
    }

    private var playButtonIcon: String {
        player.isPlaying ? "pause.fill" : "play.fill"
    }

    private var rateLabel: String {
        player.playbackRate == floor(player.playbackRate)
            ? "\(Int(player.playbackRate))x"
            : String(format: "%.2gx", player.playbackRate)
    }

    var body: some View {
        VStack(spacing: 8) {
            if player.isDownloadingFromCloud {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在从 iCloud 加载录音…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                HStack(spacing: 8) {
                    Text(ConversationAudioPlayer.formatTime(displayedTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 42, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { displayedTime },
                            set: { newVal in dragTime = newVal }
                        ),
                        in: 0...max(player.duration, 0.01),
                        onEditingChanged: { editing in
                            isDragging = editing
                            if !editing {
                                player.seek(to: dragTime)
                            } else {
                                dragTime = player.currentTime
                            }
                        }
                    )
                    .tint(Color.accentColor)

                    Text(ConversationAudioPlayer.formatTime(player.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 42, alignment: .trailing)
                }

                HStack(spacing: 16) {
                    Button {
                        player.cycleRate()
                    } label: {
                        Text(rateLabel)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("播放倍速 \(rateLabel)")

                    Spacer()

                    Button {
                        player.skip(by: -10)
                    } label: {
                        Image(systemName: "gobackward.10")
                            .font(.title3)
                            .frame(width: 40, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("快退 10 秒")

                    Button {
                        if !player.isPlaying { onBeforePlay() }
                        player.togglePlayPause()
                    } label: {
                        Label(playButtonTitle, systemImage: playButtonIcon)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 9)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playButtonTitle)

                    Button {
                        player.skip(by: 10)
                    } label: {
                        Image(systemName: "goforward.10")
                            .font(.title3)
                            .frame(width: 40, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("快进 10 秒")

                    Spacer()

                    // 右侧占位，让中间播放按钮组保持视觉居中
                    Color.clear.frame(width: 44, height: 1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
