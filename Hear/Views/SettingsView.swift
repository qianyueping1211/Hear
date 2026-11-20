import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var session: LiveSession
    @Environment(\.dismiss) private var dismiss
    @State private var importKind: LiveSession.ModelKind?
    @State private var lastImportKind: LiveSession.ModelKind = .translation
    @State private var confirmKind: LiveSession.ModelKind?
    /// 正在配置哪个本地模型
    @State private var localEdit: LocalEdit?
    /// 配置窗口里选了什么（下载 / 本地导入）
    @State private var localEditAction: LocalEditAction?
    @ObservedObject private var log = AppLog.shared
    @ObservedObject private var llm = LLMSettings.shared
    @ObservedObject private var cloud = CloudSync.shared
    @State private var showCloudPicker = false
    /// 模型管理里的页签：0 = 本地模型，1 = 在线模型
    @State private var modelTab = 0
    /// 正在配置哪一项：服务（默认地址）或某个模型
    @State private var cloudEdit: CloudEdit?
    /// 本地引擎互斥的提示
    @State private var conflictMessage: String?

    /// 有云端引擎选了，但地址还没填
    private var cloudMissingAddress: Bool {
        for m in CloudModel.allCases where session.cloudEnabled(m) {
            if session.cloudEffectiveAddress(m).isEmpty { return true }
        }
        return false
    }

    /// 在线模型里的一行：名字 + 状态图标（跟本地模型的状态按钮一样）+ 配置入口
    private func cloudRow(title: String, icon: String, status: String,
                          configured: Bool, onConfig: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                // 状态图标：跟本地模型那一行的圆圈打勾一样
                Image(systemName: Self.cloudStatusIcon(status, configured: configured))
                    .font(.title3)
                    .foregroundStyle(Self.cloudStatusColor(status, configured: configured))
                    .frame(width: 34, height: 34)
                // 配置：已配置 / 未配置，后面跟一个箭头
                Button(action: onConfig) {
                    HStack(spacing: 4) {
                        Text(configured ? "已配置" : "未配置")
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                Text(title)
            }
        }
    }

    /// 状态图标：没配置是灰圆圈感叹号，配好了是灰圆圈打勾，正常是绿圆圈打勾
    private static func cloudStatusIcon(_ status: String, configured: Bool) -> String {
        if !configured { return "exclamationmark.circle" }
        if status == "正常" { return "checkmark.circle.fill" }
        if status == "异常" { return "exclamationmark.circle.fill" }
        return "checkmark.circle"
    }

    private static func cloudStatusColor(_ status: String, configured: Bool) -> Color {
        if !configured { return .secondary }
        if status == "正常" { return .green }
        return .secondary          // 异常也是灰色，不要黄色
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: iCloud 同步
                Section {
                    Toggle("iCloud 同步", isOn: cloudBinding)
                    if cloud.enabled {
                        LabeledContent("上次同步") {
                            if cloud.syncing {
                                ProgressView()
                            } else {
                                Text(cloud.lastSync.map { Self.timeText($0) } ?? "还没有同步")
                            }
                        }
                        HStack {
                            Button("立即同步") { cloud.syncNow() }
                            Spacer()
                            // 文件写进去了但 iCloud 没传上去的时候用这个重传一遍
                            Button("重新上传设置") { cloud.reuploadSettings() }
                                .disabled(cloud.syncing)
                        }
                    }
                    if let m = cloud.message {
                        Text(m).font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("iCloud 同步")
                }

                // MARK: 引擎管理（语音识别 / 文本翻译 / 声音克隆）
                Section {
                    Picker("语音识别", selection: asrEngineBinding) {
                        if session.appleAvailable {
                            Text("苹果自带").tag("apple")
                        }
                        Text("本地极速：SenseVoice").tag("sensevoice")
                        Text("本地最准：Whisper").tag("whisper")
                        Text("SenseVoice + Whisper").tag("hybrid")
                        Text("云端服务引擎").tag("cloud")
                    }
                    Picker("文本翻译", selection: translationEngineBinding) {
                        if session.appleAvailable {
                            Text("苹果自带").tag("apple")
                        }
                        Text("本地引擎：MT").tag("local")
                        Text("云端服务引擎").tag("cloud")
                    }
                    Picker("声音克隆", selection: voiceCloneEngineBinding) {
                        Text("苹果自带").tag("apple")
                        Text("本地引擎：Qwen").tag("local")
                        Text("云端服务引擎").tag("cloud")
                    }
                    if session.translationEngine == "local", !session.isInstalled(.translation) {
                        Text("翻译模型还没下载，选本地后会自动下载").font(.footnote).foregroundStyle(.orange)
                    }
                    if session.voiceClone, !session.voiceCloneCloud, !session.isInstalled(.voiceClone) {
                        Text("声音克隆模型还没下载").font(.footnote).foregroundStyle(.orange)
                    }
                    if cloudMissingAddress {
                        Text("选了云端引擎，但还没填云端模型地址").font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("引擎管理")
                }

                // MARK: 模型管理（本地模型 / 在线模型）
                Section {
                    // 页签自己画：高度和字号都能自己定
                    // （系统的分段控件高度跟着 controlSize 变，字号又比界面里其它文字小）
                    ModelTabBar(selection: $modelTab, titles: ["本地模型", "在线模型"])
                        // 页签和下面第一行之间不要有横线
                        .listRowSeparator(.hidden)
                        // 顶部多留一点，离"模型管理"这个标题远一点；
                        // 下面不留，跟第一行贴紧
                        .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 0, trailing: 16))
                        .onChange(of: modelTab) { _, newValue in
                            if newValue == 1 { Task { await session.refreshCloudStatus() } }
                        }

                    if modelTab == 0 {
                        modelRow(.speech, title: "语音识别（Whisper）", icon: "waveform",
                                 status: session.speechStatus)
                        modelRow(.senseVoice, title: "语音识别（SenseVoice）", icon: "hare",
                                 status: session.senseStatus)
                        modelRow(.translation, title: "翻译模型（MT）", icon: "character.book.closed",
                                 status: session.translationStatus)
                        modelRow(.voiceClone, title: "声音克隆（Qwen-TTS-VC）", icon: "person.wave.2",
                                 status: session.cloneStatus)
                        // 选哪个 .gguf、清缓存，都放到各自的"配置"窗口里
                    } else {
                        // 通用服务地址（三个模型共用的地址）
                        cloudRow(title: "通用服务地址", icon: "server.rack",
                                 status: session.cloudServiceStatusText,
                                 configured: !session.cloudAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            cloudEdit = .service
                        }
                        // 三个模型各自的接口
                        ForEach(CloudModel.allCases) { m in
                            cloudRow(title: m.title, icon: m.icon,
                                     status: session.cloudStatusText(m),
                                     configured: !session.cloudEffectiveAddress(m).isEmpty) {
                                cloudEdit = .model(m)
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
                if modelTab == 1 { Task { await session.refreshCloudStatus() } }
            }
            // 在线模型页每 2 秒自动更新一次状态，不用手动点刷新
            .task(id: modelTab) {
                guard modelTab == 1 else { return }
                while !Task.isCancelled {
                    await session.refreshCloudStatus()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            .sheet(isPresented: $showCloudPicker) {
                CloudFolderPicker { url in cloud.setFolder(url) }
                    .ignoresSafeArea()
            }
            // 在线模型里某一项的配置
            .sheet(item: $cloudEdit) { e in
                CloudEditSheet(target: e)
                    .environmentObject(session)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            // 本地模型的配置窗口（下载 / 本地导入）
            .sheet(item: $localEdit, onDismiss: { applyLocalEditAction() }) { e in
                LocalModelSheet(kind: e.kind, title: e.title,
                                installed: isInstalled(e.kind),
                                detail: detailText(e.kind),
                                downloading: session.bgDownloadKind == e.kind,
                                progress: session.bgDownloadProgress,
                                gguf: ggufSelection,
                                onClearCache: { Task { await CloneCache.shared.clear() } },
                                onPick: { download in
                                    localEditAction = download
                                        ? .download(e.kind) : .importFile(e.kind)
                                })
                    .environmentObject(session)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .alert("设置冲突", isPresented: Binding(get: { conflictMessage != nil },
                                                   set: { if !$0 { conflictMessage = nil } })) {
                Button("知道了", role: .cancel) { conflictMessage = nil }
            } message: {
                Text(conflictMessage ?? "")
            }

            .navigationTitle("功能设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            // 导入：翻译模型选 .gguf 文件，语音识别模型选文件夹
            .fileImporter(isPresented: Binding(get: { importKind != nil },
                                               set: { if !$0 { importKind = nil } }),
                          allowedContentTypes: lastImportKind == .translation
                              ? [UTType(filenameExtension: "gguf") ?? .data, .data]
                              : [UTType.folder]) { result in
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
                      message: "声音克隆需要下载 Qwen3-TTS 模型（GGUF，约 760 MB），请连接 Wi‑Fi。下载期间先用系统声音朗读，下载完成后自动改用原声。下载时请保持 App 在前台。") {
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
            get: { session.voiceCloneCloud ? "cloud" : (session.voiceClone ? "local" : "apple") },
            set: { v in
                if v == "cloud" {
                    session.voiceCloneCloud = true
                    session.voiceClone = true
                    return
                }
                // 选本地克隆：别的本地引擎开着的话不行（会互相抢内存导致崩溃）
                if v == "local", let msg = session.conflictWithOtherLocals() {
                    conflictMessage = msg
                    return
                }
                session.voiceCloneCloud = false
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
                // 本地声音克隆和别的本地引擎互斥
                if let msg = session.conflictWithClone(e) { conflictMessage = msg; return }
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
        case .voiceClone: return "声音克隆模型（Qwen-TTS-VC）"
        }
    }

    static func kindSize(_ kind: LiveSession.ModelKind) -> String {
        switch kind {
        case .translation: return "约 2 GB"
        case .speech: return "约 1.6 GB"
        case .senseVoice: return "约 240 MB"
        case .voiceClone: return "约 760 MB"
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
        // 跟在线模型那一行一模一样的结构，两个页签高度才一样
        LabeledContent {
            HStack(spacing: 8) {
                // 状态：已下载是绿色对勾；没配置是灰色圆圈感叹号；下载中转圈
                ZStack {
                    if status.installed && !downloading {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                        if downloading || waiting { ProcessingDots() }
                    }
                }
                .font(.title3)
                .frame(width: 34, height: 34)
                .accessibilityLabel(downloading ? "正在下载" : (waiting ? "等待下载" : (status.installed ? "已下载" : "未下载")))
                // 配置入口：跟"大模型 API"那一行一样，后面是"已配置 / 未配置"加一个箭头
                Button {
                    localEdit = .model(kind, title)
                } label: {
                    HStack(spacing: 4) {
                        Text(status.installed ? "已配置" : "未配置")
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(session.isBusyWithModels)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    /// 本地模型的详情："文件名 · 大小"
    private func detailText(_ kind: LiveSession.ModelKind) -> String {
        let st: LiveSession.ModelStatus
        switch kind {
        case .translation: st = session.translationStatus
        case .speech: st = session.speechStatus
        case .senseVoice: st = session.senseStatus
        case .voiceClone: st = session.cloneStatus
        }
        return "\(st.name) · \(st.detail)"
    }

    /// 配置窗口关掉之后再做动作（免得跟窗口打架）
    private func applyLocalEditAction() {
        guard let a = localEditAction else { return }
        localEditAction = nil
        switch a {
        case .download(let k):
            lastKind = k
            confirmKind = k
        case .importFile(let k):
            lastImportKind = k
            importKind = k
        }
    }

    private var translationEngineBinding: Binding<String> {
        Binding(
            get: { session.translationEngine },
            set: { e in
                guard e != session.translationEngine else { return }
                // 本地声音克隆和别的本地引擎互斥
                if let msg = session.conflictWithClone(e) { conflictMessage = msg; return }
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


/// 在线模型里要配置的那一项：服务（默认地址）或某个模型
enum CloudEdit: Identifiable, Hashable {
    case service
    case model(CloudModel)

    var id: String {
        switch self {
        case .service: return "service"
        case .model(let m): return m.rawValue
        }
    }

    var title: String {
        switch self {
        case .service: return "通用服务地址"
        case .model(let m): return m.title
        }
    }
}

/// 配置窗口：填地址、测一下通不通
struct CloudEditSheet: View {
    @EnvironmentObject var session: LiveSession
    @Environment(\.dismiss) private var dismiss
    let target: CloudEdit

    /// 自己填的地址
    @State private var address: String = ""
    /// 单个模型：是不是用通用服务地址（"默认"）
    @State private var useDefault = true
    /// 语音识别的方案
    @State private var asrScheme = "sensevoice+whisper"
    @State private var status: String? = nil
    @State private var busy = false

    /// 配的是某个模型（才有"默认 / 自定义"）
    private var isModel: Bool {
        if case .model = target { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isModel {
                        // 第一行"默认"：选了是，下面"自定义"就不能填了
                        Toggle("默认", isOn: $useDefault)
                        HStack {
                            Text("自定义")
                            Spacer(minLength: 8)
                            // 选了"默认"时，这一行显示通用服务地址（也就是实际会用的那个）；
                            // 不选"默认"时显示自己填的地址。
                            // 不再有单独的"实际地址"一行了。
                            TextField("https://192.168.1.10:8000", text: addressBinding)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                // 选了"默认"就不能改这一行，要单独填地址先把它关掉
                                .disabled(useDefault)
                        }
                        // 语音识别：在"自定义"下面选识别方案
                        if case .model(let m) = target, m == .asr {
                            Picker("识别方案", selection: $asrScheme) {
                                Text("最快：SenseVoice").tag("sensevoice")
                                Text("最准：Whisper").tag("whisper")
                                Text("SenseVoice + Whisper").tag("sensevoice+whisper")
                            }
                        }
                        // 自己填的地址不通时，通用服务地址（8000）能顶上：
                        // 给个一键切回去，省得手动改地址
                        if !useDefault, !sharedAddressText.isEmpty {
                            Button("改用通用服务地址") {
                                useDefault = true
                                address = ""
                            }
                            .font(.footnote)
                        }
                    } else {
                        TextField("https://192.168.1.10:8000", text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                } header: {
                    Text(target.title)
                }

                // 测试连接放最后
                Section {
                    HStack {
                        Button("测试连接") { test() }
                        if busy { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let s = status {
                        Text(s).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
            }
            .navigationTitle("配置 · \(target.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { save(); dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                switch target {
                case .service:
                    // 打开就显示整理过的地址（补上 https://、去掉结尾的 /）
                    address = normalized(session.cloudAddress)
                    useDefault = true
                case .model(let m):
                    let own = session.cloudOwnAddress(m)
                    // 自己没填地址 = 用默认（通用服务地址）
                    useDefault = own.isEmpty
                    address = normalized(own)
                    if m == .asr { asrScheme = session.cloudASRScheme }
                }
            }
            .onChange(of: useDefault) { _, on in
                // 从"默认"切到"自定义"：把通用服务地址填进去，用户直接改就行
                guard !on, address.isEmpty else { return }
                address = sharedAddressText
            }
        }
    }

    /// 通用服务地址（8000 那个，三个模型都能用它）
    /// 显示时统一补上 https://（老版本存的可能没写协议）
    private var sharedAddressText: String {
        normalized(session.cloudAddress)
    }

    /// 真正会拿去连的地址：补上 https://、去掉结尾的 "/"
    /// （用户只填 "192.168.1.10:8000" 也能用）
    private func normalized(_ s: String) -> String {
        CloudClient.cleanURL(s)
    }

    /// 「自定义」那一行显示的地址：
    /// 选了"默认"就显示通用服务地址，没选就显示自己填的（都带 https://）
    private var addressBinding: Binding<String> {
        Binding(
            get: { useDefault ? sharedAddressText : address },
            set: { address = $0 }
        )
    }

    /// 这个模型实际会用的地址（补上 https:// 之后的）
    private var effectiveAddressText: String {
        switch target {
        case .service:
            return normalized(sharedAddressText)
        case .model:
            return normalized(useDefault ? sharedAddressText : address)
        }
    }

    private func save() {
        // 存之前先补上 https://（用户只填 IP:端口 也能存）
        let v = normalized(address)
        address = v
        switch target {
        case .service:
            session.cloudAddress = v
        case .model(let m):
            // 选了"默认"就把自己填的清掉，用通用服务地址；
            // 没选就存自己填的（这样填 8081 / 8082 就能单独用那个模型服务）
            session.setCloudOwnAddress(m, useDefault ? "" : v)
            if m == .asr { session.cloudASRScheme = asrScheme }
        }
        Task { await session.refreshCloudStatus() }
    }

    /// 测一下这个地址通不通
    private func test() {
        busy = true
        status = nil
        // 用户只填了 IP:端口 的话，这里自动补上 https://，
        // 并且把补好之后的地址回显出来
        let own = normalized(address)
        if own != address.trimmingCharacters(in: .whitespacesAndNewlines) {
            address = own
        }
        let shared = sharedAddressText
        // 要试的地址：
        //   服务地址 = 就这一个
        //   模型地址 = 先试它实际会用的那个；不通的话再试通用服务地址
        //            （通用服务 8000 会把请求转发给真正干活的模型服务，
        //              所以单独填的 8081 / 8082 不通时，它照样能用）
        var targets: [String] = []
        switch target {
        case .service:
            if !own.isEmpty { targets.append(own) }
        case .model:
            let primary = useDefault ? shared : own
            if !primary.isEmpty { targets.append(primary) }
            if !shared.isEmpty && !targets.contains(shared) { targets.append(shared) }
        }
        Task {
            if targets.isEmpty {
                busy = false
                status = "还没填地址"
                return
            }
            var text = ""
            var okAddr = ""
            for a in targets {
                let t = await CloudClient.diagnose(address: a)
                if t.hasPrefix("连接正常") || t.hasPrefix("服务在加载") {
                    okAddr = a
                    text = t
                    break
                }
                if text.isEmpty { text = t }
            }
            // 连上了的话，把这个模型自己的状态也带出来
            if !okAddr.isEmpty, case .model(let m) = target,
               let info = await CloudClient.probe(address: okAddr) {
                switch info.kind {
                case .llamaServer:
                    // 单独的模型服务（8081 / 8082）：就绪就是就绪
                    text += "，\(m.title)：\(info.health["status"] ?? "就绪")"
                case .aggregator:
                    text += "，\(m.title)：\(info.health[m.rawValue] ?? "就绪")"
                }
                // 不是用的自己填的那个地址，而是通用服务地址顶上的，说清楚
                if okAddr != self.effectiveAddressText {
                    text += "（现在走的是通用服务地址）"
                }
            }
            busy = false
            status = text
        }
    }
}

// MARK: - 本地模型的配置窗口

/// 要配置哪个本地模型
enum LocalEdit: Identifiable, Hashable {
    case model(LiveSession.ModelKind, String)

    var id: String {
        switch self {
        case .model(let k, _): return String(describing: k)
        }
    }
    var kind: LiveSession.ModelKind {
        switch self {
        case .model(let k, _): return k
        }
    }
    var title: String {
        switch self {
        case .model(_, let t): return t
        }
    }
}

/// 配置窗口里选了什么
enum LocalEditAction {
    case download(LiveSession.ModelKind)
    case importFile(LiveSession.ModelKind)
}

/// 本地模型的配置：下载 / 重新下载、本地导入
struct LocalModelSheet: View {
    @EnvironmentObject var session: LiveSession
    @Environment(\.dismiss) private var dismiss
    let kind: LiveSession.ModelKind
    let title: String
    /// 已经下载或导入过
    let installed: Bool
    /// 已有模型的详情："文件名 · 大小"
    let detail: String
    let downloading: Bool
    let progress: Double
    /// 翻译模型：装了好几个 .gguf 时选一个
    let gguf: Binding<String>
    /// 声音克隆：清缓存
    let onClearCache: () -> Void
    /// true = 下载 / 重新下载，false = 本地导入 / 重新导入
    let onPick: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if installed {
                        // 已经有模型了：最上面写清楚是哪个、多大
                        LabeledContent("本地模型") {
                            Text(detail)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if downloading {
                        HStack(spacing: 8) {
                            ProgressView(value: progress)
                            Text(String(format: "%.0f%%", progress * 100))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    if kind == .translation, session.installedGGUFs.count > 1 {
                        Picker("使用的翻译模型", selection: gguf) {
                            ForEach(session.installedGGUFs, id: \.self) { url in
                                Text(url.lastPathComponent).tag(url.lastPathComponent)
                            }
                        }
                    }
                } header: {
                    Text(title)
                } footer: {
                    Text(kind == .translation
                         ? "本地导入：选一个 .gguf 模型文件。"
                         : "本地导入：选这个模型的文件夹。")
                }

                Section {
                    Button {
                        onPick(true)
                        dismiss()
                    } label: {
                        Label(installed ? "重新下载" : "下载",
                              systemImage: installed ? "arrow.clockwise" : "arrow.down.circle")
                    }
                    Button {
                        onPick(false)
                        dismiss()
                    } label: {
                        Label(installed ? "重新导入" : "本地导入",
                              systemImage: "square.and.arrow.up")
                    }
                    if kind == .voiceClone {
                        Button("清空声音克隆缓存", role: .destructive) {
                            onClearCache()
                        }
                    }
                }
            }
            .navigationTitle("配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}


// MARK: - 模型管理的页签

/// "本地模型 / 在线模型" 两个页签
///
/// 自己画，不用系统的分段控件：
///   - 高度可以自己定（比系统默认高一点，好点得着）
///   - 字号用 .body，跟界面里其它文字一样大（系统的分段控件字偏小，看着不统一）
///   - 深色模式下也是浅色圆角块，不会变成黑块
struct ModelTabBar: View {
    @Binding var selection: Int
    let titles: [String]
    @Environment(\.colorScheme) private var scheme

    /// 整条页签的底色
    private var trackColor: Color {
        scheme == .dark ? Color(white: 0.13) : Color(white: 0.92)
    }
    /// 选中那一块的底色
    private var pillColor: Color {
        scheme == .dark ? Color(white: 0.32) : Color.white
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(titles.indices, id: \.self) { i in
                Text(titles[i])
                    .font(.body)
                    .foregroundStyle(i == selection ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 37)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(i == selection ? pillColor : Color.clear)
                            .shadow(color: Color.black.opacity(i == selection && scheme != .dark ? 0.12 : 0),
                                    radius: 1, x: 0, y: 0.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) { selection = i }
                    }
                    .accessibilityLabel(titles[i])
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(i == selection ? "已选中" : "")
            }
        }
        .padding(2)
        // 弧度跟"模型管理"那一整块的圆角一致
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(trackColor))
    }
}
