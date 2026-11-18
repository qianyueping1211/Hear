import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var session: LiveSession
    @Environment(\.dismiss) private var dismiss
    @State private var importKind: LiveSession.ModelKind?
    @State private var lastImportKind: LiveSession.ModelKind = .translation
    @State private var confirmKind: LiveSession.ModelKind?
    @ObservedObject private var log = AppLog.shared
    @ObservedObject private var llm = LLMSettings.shared
    @ObservedObject private var cloud = CloudSync.shared
    @State private var showCloudPicker = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: iCloud 同步
                Section {
                    Toggle("iCloud 同步", isOn: cloudBinding)
                    if cloud.enabled, let name = cloud.folderName {
                        LabeledContent("同步位置", value: "iCloud 云盘 / \(name)")
                        LabeledContent("上次同步") {
                            if cloud.syncing {
                                ProgressView()
                            } else {
                                Text(cloud.lastSync.map { Self.timeText($0) } ?? "还没有同步")
                            }
                        }
                        Button("立即同步") { cloud.syncNow() }
                            .disabled(cloud.syncing)
                        Button("更换同步位置") { showCloudPicker = true }
                    }
                    if let m = cloud.message {
                        Text(m).font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("iCloud 同步")
                }

                // MARK: 引擎（语音识别 → 文本翻译 → 声音克隆）
                Section {
                    Picker("语音识别引擎", selection: asrEngineBinding) {
                        Text("未选择").tag("")
                        if session.appleAvailable {
                            Text("苹果自带").tag("apple")
                        }
                        Text("本地极速：SenseVoice").tag("sensevoice")
                        Text("本地最准：Whisper").tag("whisper")
                        Text("SenseVoice + Whisper").tag("hybrid")
                    }
                } header: {
                    Text("语音识别引擎")
                } footer: {
                    Text(session.asrEngine.isEmpty ? "请选择语音识别引擎。" : asrNote)
                }

                Section {
                    Picker("文本翻译引擎", selection: translationEngineBinding) {
                        Text("未选择").tag("")
                        if session.appleAvailable {
                            Text("苹果自带").tag("apple")
                        }
                        Text("本地引擎：MT").tag("local")
                    }
                    if session.translationEngine == "local", !session.isInstalled(.translation) {
                        Text("翻译模型还没下载，选本地后会自动下载").font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("文本翻译引擎")
                } footer: {
                    Text(translationFooter)
                }

                Section {
                    Picker("声音克隆引擎", selection: voiceCloneEngineBinding) {
                        Text("苹果自带").tag("apple")
                        Text("本地引擎：Qwen").tag("local")
                    }
                    if session.voiceClone, !session.isInstalled(.voiceClone) {
                        Text("声音克隆模型还没下载").font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("声音克隆引擎")
                } footer: {
                    Text(voiceCloneFooter)
                }

                // 本地模型加载进度显示在这里（首页不再提示）
                if let msg = session.loadingText {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(msg)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }

                // MARK: 模型管理（语音识别 → 翻译 → 下载源）
                Section {
                    modelRow(.speech, title: "语音识别（Whisper）", icon: "waveform",
                             status: session.speechStatus)
                    modelRow(.senseVoice, title: "语音识别（SenseVoice）", icon: "hare",
                             status: session.senseStatus)
                    modelRow(.translation, title: "翻译模型（MT）", icon: "character.book.closed",
                             status: session.translationStatus)
                    modelRow(.voiceClone, title: "声音克隆（Qwen3-TTS）", icon: "person.wave.2",
                             status: session.cloneStatus)
                    if session.installedGGUFs.count > 1 {
                        Picker("使用的翻译模型", selection: ggufSelection) {
                            ForEach(session.installedGGUFs, id: \.self) { url in
                                Text(url.lastPathComponent).tag(url.lastPathComponent)
                            }
                        }
                    }
                    if let err = session.bgDownloadError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("模型管理")
                }

                // MARK: 语音识别（收音 → 断句 → 运行方式）
                Section {
                    Picker("声音来源", selection: inputBinding) {
                        Text("手机麦克风").tag("phone")
                        Text("耳机麦克风").tag("headset")
                    }
                    Toggle("语音增强（降噪、消除回声）", isOn: $session.voiceProcessing)
                    VStack(alignment: .leading) {
                        Text("说话灵敏度：\(Int(session.sensitivity)) dB")
                        Slider(value: $session.sensitivity, in: 6...24, step: 1)
                        Text("数值越小越灵敏；环境吵的话调大").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text("停顿多久算一句：\(Int(session.silenceMs)) 毫秒")
                        Slider(value: $session.silenceMs, in: 400...1500, step: 50)
                        Text("短：出结果更快；长：句子更完整").font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("语音识别运行在", selection: asrBinding) {
                        Text("GPU（加载快，推荐）").tag(true)
                        Text("神经引擎（省电）").tag(false)
                    }
                } header: {
                    Text("语音识别")
                } footer: {
                    if let inputNote { Text(inputNote) }
                }

                // MARK: 翻译与总结
                Section {
                    Toggle("结合上文翻译（更连贯）", isOn: $session.useContext)
                    NavigationLink {
                        LLMSettingsView()
                    } label: {
                        LabeledContent("大模型 API") {
                            Text(llm.active.map { "\($0.name) · \($0.selectedModel.isEmpty ? "未选模型" : $0.selectedModel)" } ?? "未配置")
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("翻译与总结")
                }

                // MARK: 朗读（出声 → 音色 → 耳机左右耳）
                Section {
                    Toggle("朗读译文", isOn: $session.speakOutput)
                    Picker("朗读从哪里出声", selection: outputBinding) {
                        Text("手机扬声器").tag(AudioOutput.speaker)
                        Text("耳机").tag(AudioOutput.headphones)
                    }
                    if session.outputMode == .headphones {
                        Picker("左耳听", selection: $session.leftEar) {
                            Text(session.langA.name).tag("A")
                            Text(session.langB.name).tag("B")
                            Text("不播放").tag("off")
                        }
                        Picker("右耳听", selection: $session.rightEar) {
                            Text(session.langA.name).tag("A")
                            Text(session.langB.name).tag("B")
                            Text("不播放").tag("off")
                        }
                    }
                } header: {
                    Text("朗读")
                } footer: {
                    Text("朗读用系统声音；在「声音克隆引擎」选本地 Qwen 后，会用说话人的原声朗读。")
                }

                Section {
                    TextEditor(text: $session.glossary)
                        .frame(minHeight: 100)
                        .font(.body.monospaced())
                } header: {
                    Text("术语表")
                } footer: {
                    Text("每行一条，格式：原文=译文\n例如：张伟=Zhang Wei")
                }

                // MARK: 日志
                Section {
                    Toggle("开启日志", isOn: $log.enabled)
                    Picker("最大日志文件大小", selection: $log.maxMB) {
                        ForEach(AppLog.sizeOptions, id: \.self) { mb in
                            Text("\(mb) MB").tag(mb)
                        }
                    }
                    LabeledContent("当前占用", value: ModelManager.format(log.totalBytes))
                    NavigationLink {
                        LogView()
                    } label: {
                        Label("查看日志", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("日志")
                }

                // MARK: 关于
                Section {
                    LabeledContent("版本", value: Self.appVersion)
                } header: {
                    Text("关于")
                }
            }
            .onAppear {
                session.refreshHeadset()
            }
            .sheet(isPresented: $showCloudPicker) {
                CloudFolderPicker { url in cloud.setFolder(url) }
                    .ignoresSafeArea()
            }
            .navigationTitle("功能设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            // 导入：翻译模型选 .gguf 文件，语音识别模型选文件夹
            .fileImporter(isPresented: Binding(get: { importKind != nil },
                                               set: { if !$0 { importKind = nil } }),
                          allowedContentTypes: lastImportKind != .translation
                              ? [UTType.folder]
                              : [UTType(filenameExtension: "gguf") ?? .data, .data]) { result in
                guard case .success(let url) = result else { return }
                let kind = lastImportKind
                Task {
                    switch kind {
                    case .speech: await session.importWhisper(url)
                    case .senseVoice: await session.importSenseVoice(url)
                    case .translation: await session.importModel(url)
                    case .voiceClone: await session.importVoiceClone(url)
                    }
                }
            }
        }
        // 屏幕正中的确认框：背后整页虚化
        .centerDialog(isPresented: Binding(get: { confirmKind != nil },
                                           set: { if !$0 { confirmKind = nil } }),
                      title: dialogTitle,
                      message: dialogMessage,
                      destructive: isInstalled(lastKind)) {
            if let k = confirmKind { Task { await session.redownload(k) } }
        }
        // 选了还缺模型的识别引擎：先问要不要下载
        .centerDialog(isPresented: Binding(get: { pendingEngine != nil },
                                           set: { if !$0 { pendingEngine = nil } }),
                      title: "需要先下载模型",
                      message: engineDownloadMessage) {
            if let e = pendingEngine { session.downloadForEngine(e) }
        }
        // 打开声音克隆但还没下载模型：先问要不要下载
        .centerDialog(isPresented: $askClone,
                      title: "下载声音克隆模型？",
                      message: "声音克隆需要下载 Qwen3-TTS 模型（约 1.4 GB），请连接 Wi‑Fi。下载期间先用系统声音朗读，下载完成后自动改用原声。下载时请保持 App 在前台。") {
            session.voiceClone = true
            session.startBackgroundDownload(kinds: [.voiceClone], switchWhenDone: false)
        }
    }

    @State private var askClone = false

    private var cloudBinding: Binding<Bool> {
        Binding(
            get: { cloud.enabled },
            set: { on in
                if !on { cloud.enabled = false; return }
                if cloud.hasFolder { cloud.enabled = true } else { showCloudPicker = true }
            }
        )
    }

    static func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }

    private var voiceCloneEngineBinding: Binding<String> {
        Binding(
            get: { session.voiceClone ? "local" : "apple" },
            set: { v in
                let on = v == "local"
                if on == session.voiceClone { return }
                if !on { session.voiceClone = false; return }
                if session.isInstalled(.voiceClone) {
                    session.voiceClone = true
                } else if !session.bgDownloading {
                    askClone = true
                }
            }
        )
    }
    /// 选了还缺模型的识别引擎（等确认下载）
    @State private var pendingEngine: String?
    @State private var lastPendingEngine = "sensevoice"

    private var asrEngineBinding: Binding<String> {
        Binding(
            get: { session.asrEngine },
            set: { e in
                guard e != session.asrEngine else { return }
                if session.missingSpeechKinds(for: e).isEmpty {
                    session.asrEngine = e
                } else if !session.bgDownloading {
                    lastPendingEngine = e
                    pendingEngine = e
                }
            }
        )
    }

    private var engineDownloadMessage: String {
        let kinds = session.missingSpeechKinds(for: lastPendingEngine)
        let names = kinds.map { $0 == .senseVoice ? "SenseVoice（约 240 MB）" : "Whisper（约 1.6 GB）" }
        return "这个识别引擎需要 \(names.joined(separator: "、")) 语音识别模型。下载期间继续用现在的引擎，下载完成后自动切换。请连接 Wi‑Fi，并保持 App 在前台。"
    }

    /// 语音识别引擎的说明
    private var asrNote: String {
        switch session.asrEngine {
        case "sensevoice":
            return "本地最快：说完马上出字，不会卡住。只支持中文、英语、日语、韩语。"
        case "hybrid":
            return "先用 SenseVoice 马上出结果，空闲时再用 Whisper 校正；有明显差别就替换并重新翻译。只支持中文、英语、日语、韩语。"
        case "apple":
            return "苹果自带：用 iOS 系统听写逐字显示，说话就出字。"
        case "whisper":
            return "本地最准：标点和长句更好，说完一句后识别，稍慢。"
        default:
            return "请选择语音识别引擎。"
        }
    }

    private var translationFooter: String {
        switch session.translationEngine {
        case "apple": return "苹果自带：用 iOS 系统翻译，不用下载模型；不支持术语表和结合上文。"
        case "local": return "本地引擎：Hy-MT2 在手机本地运行，支持术语表和结合上文。"
        default: return "请选择翻译引擎。"
        }
    }

    private var voiceCloneFooter: String {
        session.voiceClone
            ? "本地 Qwen3-TTS：用说话人的原声朗读。模型约 1.4 GB，加载要几秒；内存不够或生成不了时自动用系统声音。"
            : "苹果自带：用系统声音朗读，不额外占内存。"
    }
    /// 最近一次要下载的模型（确认框收起的动画里文字不会突然变空）
    @State private var lastKind: LiveSession.ModelKind = .translation

    private var dialogTitle: String {
        return (isInstalled(lastKind) ? "重新下载" : "下载") + Self.kindTitle(lastKind) + "？"
    }

    private var dialogMessage: String {
        let size = Self.kindSize(lastKind)
        let head = isInstalled(lastKind) ? "会先删除已下载的文件，再重新下载（\(size)）。" : "文件\(size)。"
        return head + "请连接 Wi‑Fi，下载进度显示在「模型管理」里，下载时请保持 App 在前台。"
    }

    static func kindTitle(_ kind: LiveSession.ModelKind) -> String {
        switch kind {
        case .translation: return "翻译模型（MT）"
        case .speech: return "语音识别模型（Whisper）"
        case .senseVoice: return "语音识别模型（SenseVoice）"
        case .voiceClone: return "声音克隆模型（Qwen3-TTS）"
        }
    }

    static func kindSize(_ kind: LiveSession.ModelKind) -> String {
        switch kind {
        case .translation: return "约 2 GB"
        case .speech: return "约 1.6 GB"
        case .senseVoice: return "约 240 MB"
        case .voiceClone: return "约 1.4 GB"
        }
    }

    /// 例如 “1.1”
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    /// 一种模型一行：名称 + 状态图标 + 下载/重新下载图标 + 导入图标；
    /// 下面一行是具体的模型文件名和大小，下载中显示进度
    @ViewBuilder
    private func modelRow(_ kind: LiveSession.ModelKind, title: String, icon: String,
                          status: LiveSession.ModelStatus) -> some View {
        let downloading = session.bgDownloadKind == kind
        let waiting = !downloading && session.bgDownloading && session.bgQueue.contains(kind)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                // 状态：已下载是绿色对勾；没下载是灰色对勾；下载中（或排队等下载）灰色对勾外面转一圈灰点
                ZStack {
                    if status.installed && !downloading {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                        if downloading || waiting { ProcessingDots() }
                    }
                }
                .font(.title3)
                .frame(width: 34, height: 34)
                .accessibilityLabel(downloading ? "正在下载" : (waiting ? "等待下载" : (status.installed ? "已下载" : "未下载")))
                // 下载 / 重新下载
                Button {
                    lastKind = kind
                    confirmKind = kind
                } label: {
                    // 没有模型（包括正在下载）是下载图标；下载完成后变成刷新（重新下载）图标
                    Image(systemName: status.installed && !downloading ? "arrow.clockwise" : "arrow.down.circle")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderless)
                .disabled(session.isBusyWithModels)
                .accessibilityLabel(status.installed ? "重新下载" : "下载")
                // 导入（声音克隆：选包含主模型和声音编解码器两个文件夹的大文件夹，一次导入）
                Button {
                    lastImportKind = kind
                    importKind = kind
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderless)
                .disabled(session.isBusyWithModels)
                .accessibilityLabel("导入")
            }
            if downloading {
                HStack(spacing: 8) {
                    ProgressView(value: session.bgDownloadProgress)
                    Text(String(format: "%.0f%%", session.bgDownloadProgress * 100))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 38)
            } else if status.installed {
                Text("\(status.name) · \(status.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 38)
            } else if waiting {
                Text("等待下载").font(.caption).foregroundStyle(.secondary).padding(.leading, 38)
            }
        }
        .padding(.vertical, 2)
    }

    private var translationEngineBinding: Binding<String> {
        Binding(
            get: { session.translationEngine },
            set: { e in
                guard e != session.translationEngine else { return }
                session.translationEngine = e
                if e == "local", !session.isInstalled(.translation), !session.bgDownloading {
                    session.startBackgroundDownload(kinds: [.translation], switchWhenDone: true)
                }
            }
        )
    }
    @State private var inputNote: String?

    private var inputBinding: Binding<String> {
        Binding(
            get: { session.inputSource },
            set: { v in
                session.refreshHeadset()
                if v == "headset" && !session.headsetConnected {
                    inputNote = "没有检测到耳机，请先连接耳机再切换。"
                    return
                }
                inputNote = nil
                session.inputSource = v
            }
        )
    }

    private var asrBinding: Binding<Bool> {
        Binding(
            get: { session.asrUseGPU },
            set: { gpu in
                guard gpu != session.asrUseGPU else { return }
                session.asrUseGPU = gpu
                Task { await session.reloadASR() }      // 加载进度显示在「引擎」下方
            }
        )
    }

    private var outputBinding: Binding<AudioOutput> {
        Binding(
            get: { session.outputMode },
            set: { new in if new != session.outputMode { session.cycleOutput() } }
        )
    }

    private func isInstalled(_ kind: LiveSession.ModelKind) -> Bool {
        session.isInstalled(kind)
    }

    private var ggufSelection: Binding<String> {
        Binding(
            get: { session.translationStatus.name },
            set: { name in
                if let u = session.installedGGUFs.first(where: { $0.lastPathComponent == name }) {
                    Task { await session.selectGGUF(u) }
                }
            }
        )
    }
}

/// 状态图标外面一圈不停转动的灰点：表示正在处理（下载中）
private struct ProcessingDots: View {
    @State private var spin = false

    var body: some View {
        Circle()
            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [0.1, 5]))
            .frame(width: 32, height: 32)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
            .accessibilityHidden(true)
    }
}
