import SwiftUI
import UniformTypeIdentifiers

/// 惰性生成导出文件（.md / .srt）：仅在用户点击分享时才拼装内容并写出临时文件，
/// 避免每次界面刷新都重复拼接全文，同时确保分享到“文件”或剪辑软件时保留正确扩展名。
private struct ExportTextFile: Transferable {
    let filename: String
    let buildContent: @Sendable () -> String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { item in
            let safeName = item.filename
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(safeName)
            let data = Data(item.buildContent().utf8)
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

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
            if let conv, !conv.items.isEmpty {
                let lang = session.chineseDisplayLanguage
                let baseName = conv.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "听见对话记录"
                    : conv.title.trimmingCharacters(in: .whitespacesAndNewlines)
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ShareLink(
                            item: ExportTextFile(filename: "\(baseName).md") {
                                Self.exportMarkdown(for: conv, displayLanguage: lang)
                            },
                            preview: SharePreview("\(baseName).md")
                        ) {
                            Label("分享双语记录 (.md)", systemImage: "doc.richtext")
                        }
                        ShareLink(
                            item: ExportTextFile(filename: "\(baseName).srt") {
                                Self.exportSrt(for: conv, displayLanguage: lang)
                            },
                            preview: SharePreview("\(baseName).srt")
                        ) {
                            Label("分享字幕文件 (.srt)", systemImage: "captions.bubble")
                        }
                        if let content = record?.content, !content.isEmpty {
                            ShareLink(
                                item: ExportTextFile(filename: "\(baseName)-纪要.md") { content },
                                preview: SharePreview("\(baseName)-纪要.md")
                            ) {
                                Label("分享当前总结 (.md)", systemImage: "text.document")
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
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

    /// 导出双语记录为 Markdown 文本，便于通过系统分享发送至微信、备忘录或文件
    private static func exportMarkdown(for c: Conversation, displayLanguage lang: ChineseDisplayLanguage) -> String {
        var lines: [String] = []
        let title = c.title.isEmpty ? "听见对话记录" : c.title
        lines.append("# \(title)")
        lines.append("")
        func singleLine(_ s: String) -> String {
            s.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for item in c.items {
            let src = singleLine(item.sourceText)
            let tr = singleLine(item.displayedTranslation(using: lang))
            if src.isEmpty && tr.isEmpty { continue }
            let ts = item.audioStartSec.map { formatMmSs($0) } ?? ""
            let spk = item.speakerLabel ?? ""
            var headerParts: [String] = []
            if !ts.isEmpty { headerParts.append("[\(ts)]") }
            if !spk.isEmpty { headerParts.append("**\(spk)**") }
            let prefix = headerParts.isEmpty ? "" : headerParts.joined(separator: " ") + " "
            if !src.isEmpty {
                lines.append("- \(prefix)\(src)")
            }
            if !tr.isEmpty && tr != src {
                lines.append("  > \(tr)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 导出双语记录为标准 SRT 字幕文本
    private static func exportSrt(for c: Conversation, displayLanguage lang: ChineseDisplayLanguage) -> String {
        var blocks: [String] = []
        var idx = 1
        var fallbackSec: Double = 0
        for item in c.items {
            let src = item.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let tr = item.displayedTranslation(using: lang).trimmingCharacters(in: .whitespacesAndNewlines)
            if src.isEmpty && tr.isEmpty { continue }
            let start = item.audioStartSec ?? fallbackSec
            let end = max(start + 0.8, item.audioEndSec ?? (start + 3.0))
            fallbackSec = end
            var textLines: [String] = []
            if !src.isEmpty { textLines.append(src) }
            if !tr.isEmpty && tr != src { textLines.append(tr) }
            blocks.append("\(idx)\n\(formatSrtTime(start)) --> \(formatSrtTime(end))\n\(textLines.joined(separator: "\n"))")
            idx += 1
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func formatMmSs(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func formatSrtTime(_ seconds: Double) -> String {
        let ms = max(0, Int((seconds * 1000.0).rounded()))
        let h = ms / 3_600_000
        let m = (ms % 3_600_000) / 60_000
        let s = (ms % 60_000) / 1000
        let rem = ms % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, rem)
    }

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

                HStack(spacing: 0) {
                    Button {
                        player.cycleRate()
                    } label: {
                        Text(rateLabel)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .frame(width: 42, height: 34)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("播放倍速 \(rateLabel)")

                    Spacer(minLength: 6)

                    HStack(spacing: 10) {
                        Button {
                            player.skip(by: -10)
                        } label: {
                            Image(systemName: "gobackward.10")
                                .font(.system(size: 22, weight: .medium))
                                .frame(width: 42, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("快退 10 秒")

                        Button {
                            if !player.isPlaying { onBeforePlay() }
                            player.togglePlayPause()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: playButtonIcon)
                                    .font(.system(size: 17, weight: .bold))
                                Text(playButtonTitle)
                                    .font(.headline)
                            }
                            .frame(minWidth: 112, minHeight: 46)
                            .padding(.horizontal, 8)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(playButtonTitle)

                        Button {
                            player.skip(by: 10)
                        } label: {
                            Image(systemName: "goforward.10")
                                .font(.system(size: 22, weight: .medium))
                                .frame(width: 42, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("快进 10 秒")
                    }

                    Spacer(minLength: 6)

                    // 右侧占位与左侧倍速等宽，保证播放按钮组严格居中且绝不撑宽整页
                    Color.clear.frame(width: 42, height: 1)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }
}
