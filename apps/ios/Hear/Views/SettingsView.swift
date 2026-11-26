import SwiftUI
import AVFoundation
import Foundation
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
    @State private var voiceSampleStore = FixedVoiceSampleStore.shared
    @State private var showVoiceSampleRecorder = false
    @State private var showCloudPicker = false
    @State private var showHeadphoneOutputHelp = false
    /// 授权 iCloud 云盘的说明框（系统的授权框弹不出来时才需要）
    @State private var askCloudAuth = false
    /// 模型管理里的页签：0 = 本地模型，1 = 云端模型
    @State private var modelTab = 0
    /// 正在配置哪一项：服务（默认地址）或某个模型
    @State private var cloudEdit: CloudEdit?
    /// 本地网络权限没开：弹提示告诉用户去哪儿开
    @State private var showLocalNetworkHelp = false

    /// 刚选了云端引擎：查一下本地网络权限。
    ///
    /// 系统的授权框只问一次，用户选了「不允许」以后 App 再也弹不出来，
    /// 只能自己去 设置 → 隐私与安全性 → 本地网络 里开。
    /// 大部分人不知道这个开关在哪儿，所以这里主动查一下、弹个提示。
    private func checkLocalNetwork() {
        let usesCloud = session.asrEngine == "cloud"
            || session.translationEngine == "cloud"
            || (session.voiceClone && session.voiceCloneCloud)
        guard usesCloud else { return }
        let addr = session.cloudAddress
        guard !addr.isEmpty else { return }
        Task {
            let d = await CloudClient.diagnose(address: addr)
            if d.localNetworkDenied { showLocalNetworkHelp = true }
        }
    }

    /// 云端模型里的一行：名字 + 状态图标（跟本地模型的状态按钮一样）+ 配置入口
    private func cloudRow(title: String, icon: String, status: String,
                          configured: Bool, onConfig: @escaping () -> Void) -> some View {
        let readiness: String
        if !configured {
            readiness = "未配置"
        } else if status.hasPrefix(LiveSession.cloudStatusOK) {
            readiness = LiveSession.cloudStatusOK
        } else if status == LiveSession.cloudStatusUnset {
            readiness = LiveSession.cloudStatusChecking
        } else {
            readiness = status
        }
        let indicator: (symbol: String, color: Color)
        switch readiness {
        case LiveSession.cloudStatusOK: indicator = ("checkmark.circle.fill", .green)
        case LiveSession.cloudStatusLoading: indicator = ("hourglass", .orange)
        case LiveSession.cloudStatusBad: indicator = ("exclamationmark.circle.fill", .secondary)
        case LiveSession.cloudStatusChecking: indicator = ("ellipsis.circle", .secondary)
        default: indicator = ("questionmark.circle", .secondary)
        }
        return modelManagementRow(title: title, icon: icon) {
            Button(action: onConfig) {
                HStack(spacing: 5) {
                    Image(systemName: indicator.symbol)
                        .font(.title3)
                        .foregroundStyle(indicator.color)
                        .frame(width: 34, height: 34)
                    Text(readiness).lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)，\(configured ? status : "未配置")")
        }
    }

    private func modelManagementRow<Controls: View>(
        title: String, icon: String, @ViewBuilder controls: () -> Controls
    ) -> some View {
        LabeledContent {
            controls()
                .frame(minHeight: 34)
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
        // 本地和云端两页共用这一行，垂直留白比旧版增加 25%
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
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
                    if cloud.enabled && !cloud.hasFolder {
                        // 只有系统还没给过云盘权限时才有这一个按钮（授权一次，以后不用再管）
                        Button("授权 iCloud 云盘") { askCloudAuth = true }
                            .buttonStyle(.bordered)
                    }
                    if let m = cloud.message {
                        Text(m).font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("iCloud 同步")
                }

                // MARK: 引擎管理（语音识别 / 文本翻译 / 声音克隆）
                Section {
                    asrEngineRow
                    translationEngineRow
                    voiceCloneEngineRow
                } header: {
                    Text("引擎管理")
                }

                // MARK: 模型管理（本地模型 / 云端模型）
                Section {
                    // 页签自己画：高度和字号都能自己定
                    // （系统的分段控件高度跟着 controlSize 变，字号又比界面里其它文字小）
                    ModelTabBar(selection: $modelTab, titles: ["本地模型", "云端模型"])
                        // 页签和下面第一行之间不要有横线
                        .listRowSeparator(.hidden)
                        // 顶部多留一点，离"模型管理"这个标题远一点；
                        // 下面不留，跟第一行贴紧
                        .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 0, trailing: 16))

                    if modelTab == 0 {
                        modelRow(.senseVoice, title: "语音识别（SenseVoice）", icon: "hare",
                                 status: session.senseStatus)
                        modelRow(.translation, title: "翻译模型（MT）", icon: "character.book.closed",
                                 status: session.translationStatus)
                        // 本地声音克隆（ZipVoice）代码保留，界面暂隐藏
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
                    Toggle("语音增强", isOn: $session.voiceProcessing)
                    Toggle("保存完整录音", isOn: $session.saveFullRecording)
                    if session.speakerTrackingAvailable {
                        Toggle("实时翻译时区分说话人", isOn: $session.speakerTrackingEnabled)
                    }
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
                } header: {
                    Text("语音识别")
                } footer: {
                    if let inputNote { Text(inputNote) }
                }

                // MARK: 翻译与总结
                Section {
                    Toggle("修复断句处的词", isOn: $session.useContext)
                    Picker("灵动岛与锁屏显示", selection: $session.liveActivityOnlyTranslation) {
                        Text("展示译文").tag(true)
                        Text("展示原文和译文").tag(false)
                    }
                    NavigationLink {
                        LLMSettingsView()
                    } label: {
                        LabeledContent("大模型 API") {
                            Text(llm.active?.name ?? "未配置")
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("翻译与总结")
                }

                // MARK: 朗读
                Section {
                    Toggle("自动朗读译文", isOn: $session.speakOutput)
                    Picker("系统朗读声音", selection: $session.systemVoicePreference) {
                        Text("自动识别").tag("auto")
                        Text("女声").tag("female")
                        Text("男声").tag("male")
                    }
                    Picker("声音输出位置", selection: outputBinding) {
                        Text("手机扬声器").tag(AudioOutput.speaker)
                        Text("耳机").tag(AudioOutput.headphones)
                    }
                    .pickerStyle(.menu)
                    .alert("请先连接耳机", isPresented: $showHeadphoneOutputHelp) {
                        Button("好", role: .cancel) {}
                    } message: {
                        Text("连接后，在「声音输出位置」选择「耳机」。")
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
                    Toggle("显示声音图标", isOn: $session.showReadingIcon)
                    Toggle("声音克隆", isOn: $session.voiceClone)
                    Button {
                        showVoiceSampleRecorder = true
                    } label: {
                        LabeledContent("我的固定声纹样本") {
                            if voiceSampleStore.hasSample {
                                Text(String(format: "已录制 %.1f 秒", voiceSampleStore.durationSeconds))
                                    .foregroundStyle(.green)
                            } else {
                                Text("去录制（3~10 秒）")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    if voiceSampleStore.hasSample {
                        Toggle("克隆时优先使用固定声纹", isOn: $voiceSampleStore.preferOverLive)
                    }
                } header: {
                    Text("朗读")
                } footer: {
                    Text("录制 3~10 秒固定声纹后，云端 Qwen3-TTS 声音克隆可直接使用。")
                }

                // MARK: 语言和日志
                Section {
                    Picker("显示语言", selection: $session.chineseDisplayLanguage) {
                        ForEach(ChineseDisplayLanguage.allCases, id: \.self) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .accessibilityHint("控制中文识别原文和译文的简繁显示")
                    Toggle("开启日志", isOn: $log.enabled)
                    Toggle("记录对话内容（排查问题时用）", isOn: $log.contentEnabled)
                    Toggle("记录推理耗时", isOn: $log.performanceEnabled)
                        .disabled(!log.enabled)
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
#if DEBUG || HEAR_SPEECH_REGRESSION
                    NavigationLink {
                        SpeechRegressionView()
                    } label: {
                        Label("本机语音回归测试", systemImage: "waveform.badge.magnifyingglass")
                    }
#endif
                } header: {
                    Text("语言和日志")
                }

                // MARK: 关于
                Section {
                    LabeledContent("版本", value: Self.appVersion)
                    if let revision = Bundle.main.object(forInfoDictionaryKey: "HearSourceRevision") as? String {
                        LabeledContent("源代码提交", value: String(revision.prefix(12)))
                    }
                } header: {
                    Text("关于")
                }
            }
            .onAppear {
                session.refreshHeadset()
                syncModelTab()
            }
            // 引擎换了，模型管理的页签跟着走
            // （有本地引擎 → 本地模型；都是在线 / 在线+苹果 → 云端模型）
            .onChange(of: session.asrEngine) { _, _ in syncModelTab(); checkLocalNetwork() }
            .onChange(of: session.translationEngine) { _, _ in syncModelTab(); checkLocalNetwork() }
            .onChange(of: session.voiceCloneCloud) { _, _ in syncModelTab(); checkLocalNetwork() }
            .onChange(of: session.voiceClone) { _, _ in
                syncModelTab()
                checkLocalNetwork()
            }
            // 云端模型页每 2 秒自动更新一次状态，不用手动点刷新
            .task(id: shouldRefreshCloudModels) {
                guard shouldRefreshCloudModels else { return }
                while !Task.isCancelled {
                    await session.refreshCloudStatus()
                    do { try await Task.sleep(for: .seconds(2)) }
                    catch { return }
                }
            }
            .sheet(isPresented: $showCloudPicker) {
                CloudFolderPicker { url in cloud.setFolder(url) }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showVoiceSampleRecorder) {
                VoiceSampleRecorderSheet()
            }
            // 授权 iCloud 云盘：先试系统的（自己就弹「允许访问 iCloud 云盘」），
            // 没有权限才让用户在文件里挑一个文件夹。
            .alert("授权 iCloud 云盘", isPresented: $askCloudAuth) {
                Button("继续") {
                    if !cloud.requestAuthorization() {
                        showCloudPicker = true
                    }
                }
                Button("以后再说", role: .cancel) {}
            } message: {
                Text("允许「听见」访问 iCloud 云盘，把设置和对话记录同步到云盘里的「听见」文件夹。\n只需要授权一次，以后不用再管。")
            }
            // 云端模型里某一项的配置
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
                              : [UTType.folder, .zip]) { result in
                guard case .success(let url) = result else { return }
                importSelectedModel(url, kind: lastImportKind)
            }
        }
        // 本地网络权限没开：弹提示告诉用户去哪儿开。
        // （挂在 NavigationStack 上：里面的 Form 上已经有一个 .alert 了，
        //   同一个视图挂两个 alert 会互相顶掉）
        .localNetworkHelp($showLocalNetworkHelp)
        // 屏幕正中的确认框：背后整页虚化
        .centerDialog(isPresented: Binding(get: { confirmKind != nil },
                                           set: { if !$0 { confirmKind = nil } }),
                      title: dialogTitle,
                      message: dialogMessage,
                      destructive: isInstalled(lastKind)) {
            if let k = confirmKind { Task { await session.redownload(k) } }
        }
    }

    /// 打开 iCloud 同步：不用让用户选目录。
    /// 数据固定放在 iCloud 云盘里的「听见」文件夹（就是 App 名字）。
    /// 只有在系统还没给过云盘权限时，下面才会多一个「授权 iCloud 云盘」的按钮（点一次就行）。
    private var cloudBinding: Binding<Bool> {
        Binding(
            get: { cloud.enabled },
            set: { on in
                cloud.enabled = on
                if on { cloud.checkFolderAccess() }
            }
        )
    }

    /// 每次打开设置都重新判断一次：模型管理该显示哪一边
    /// （引擎换了、云端模型配没配，都要跟着变，省得用户自己再点一下）
    private func syncModelTab() {
        let want = session.preferredModelTab
        if modelTab != want {
            modelTab = want
            hearLog("模型管理：默认选中\(want == 1 ? "云端模型" : "本地模型")")
        }
    }

    private var shouldRefreshCloudModels: Bool {
        modelTab == 1 && cloudEdit == nil && localEdit == nil &&
            confirmKind == nil && importKind == nil
    }

    static func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }

    private var asrEngineRow: some View {
        Picker("语音识别", selection: asrEngineBinding) {
            if session.appleAvailable {
                Text("本机：苹果自带").tag("apple")
            }
            Text("本机最快：SenseVoice").tag("sensevoice")
            Text("云端：SenseVoice + Whisper").tag("cloud")
        }
    }

    private var translationEngineRow: some View {
        Picker("文本翻译", selection: translationEngineBinding) {
            if session.appleAvailable {
                Text("本机：苹果自带").tag("apple")
            }
            Text("本机：Hy-MT2").tag("local")
            Text("云端：Hy-MT2").tag("cloud")
        }
    }

    private var voiceCloneEngineRow: some View {
        Picker("声音克隆", selection: voiceCloneEngineBinding) {
            Text("云端：Qwen3-TTS（原声克隆）").tag("qwen3")
            Text("云端：Kokoro-82M（极速神经语音）").tag("kokoro")
        }
    }

    private var asrEngineBinding: Binding<String> {
        Binding(get: { session.asrEngine },
                set: { applyASREngineSelection($0) })
    }

    private var translationEngineBinding: Binding<String> {
        Binding(get: { session.translationEngine },
                set: { applyTranslationEngineSelection($0) })
    }

    private var voiceCloneEngineBinding: Binding<String> {
        Binding(get: { session.cloudCloneModel == "kokoro" ? "kokoro" : "qwen3" },
                set: { applyVoiceCloneEngineSelection($0) })
    }

    private func applyASREngineSelection(_ engine: String) {
        if engine != session.asrEngine {
            session.asrEngine = engine
        }

        if engine == "sensevoice", !session.isInstalled(.senseVoice) {
            openLocalModelConfiguration(.senseVoice)
        } else if engine == "cloud", !isCloudModelConfigured(.asr) {
            openCloudModelConfiguration(.asr)
        }
    }

    private func applyTranslationEngineSelection(_ engine: String) {
        if engine != session.translationEngine {
            session.translationEngine = engine
        }

        if engine == "local", !session.isInstalled(.translation) {
            openLocalModelConfiguration(.translation)
        } else if engine == "cloud", !isCloudModelConfigured(.mt) {
            openCloudModelConfiguration(.mt)
        }
    }

    private func applyVoiceCloneEngineSelection(_ engine: String) {
        if !session.voiceCloneCloud {
            session.voiceCloneCloud = true
        }
        let target = (engine == "kokoro") ? "kokoro" : "qwen3"
        if session.cloudCloneModel != target {
            session.cloudCloneModel = target
        }
        if !isCloudModelConfigured(.clone) {
            openCloudModelConfiguration(.clone)
        }
    }

    private func isCloudModelConfigured(_ model: CloudModel) -> Bool {
        !session.cloudEffectiveAddress(model)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    /// 引擎管理和模型管理共用同一个“未配置”窗口。
    /// 延迟到选择弹窗收起的下一帧再打开，避免两个模态互相抢展示。
    private func openLocalModelConfiguration(_ kind: LiveSession.ModelKind) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            localEdit = .model(kind, Self.modelRowTitle(kind))
        }
    }

    private func openCloudModelConfiguration(_ model: CloudModel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            cloudEdit = .model(model)
        }
    }

    /// 最近一次要下载的模型（确认框收起的动画里文字不会突然变空）
    @State private var lastKind: LiveSession.ModelKind = .translation

    private var dialogTitle: String {
        return (isInstalled(lastKind) ? "重新下载" : "下载") + Self.kindTitle(lastKind) + "？"
    }

    private var dialogMessage: String {
        let size = Self.kindSize(lastKind)
        let head = isInstalled(lastKind) ? "重新下载（\(size)），下载完成后替换模型。" : "文件\(size)。"
        return head + "请连接 Wi‑Fi，下载进度显示在「模型管理」里，下载时请保持 App 在前台。"
    }

    static func kindTitle(_ kind: LiveSession.ModelKind) -> String {
        switch kind {
        case .translation: return "翻译模型（MT）"
        case .senseVoice: return "语音识别模型（SenseVoice）"
        case .voiceClone: return "声音克隆模型（ZipVoice）"
        }
    }

    static func modelRowTitle(_ kind: LiveSession.ModelKind) -> String {
        switch kind {
        case .translation: return "翻译模型（MT）"
        case .senseVoice: return "语音识别（SenseVoice）"
        case .voiceClone: return "声音克隆（ZipVoice）"
        }
    }

    static func kindSize(_ kind: LiveSession.ModelKind) -> String {
        switch kind {
        case .translation: return "约 2 GB"
        case .senseVoice: return "约 240 MB"
        case .voiceClone: return "约 163 MB"
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
        let paused = session.isModelDownloadPaused(kind)
        let waiting = !downloading && session.bgDownloading && session.bgQueue.contains(kind)
        return modelManagementRow(title: title, icon: icon) {
            HStack(spacing: 8) {
                // 状态：已下载是绿色对勾；没配置是灰色圆圈感叹号；下载中转圈
                Group {
                    if paused {
                        Button {
                            session.resumeModelDownload(kind)
                        } label: {
                            Image(systemName: "play.circle.fill")
                        }
                        .disabled(session.bgDownloading)
                        .accessibilityLabel("继续下载")
                    } else if downloading {
                        Button {
                            session.pauseModelDownload(kind)
                        } label: {
                            ZStack {
                                DownloadProgressIcon(progress: session.bgDownloadProgress)
                                Image(systemName: "pause.fill")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .accessibilityLabel("暂停下载")
                    } else if status.installed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("已下载")
                    } else if waiting {
                        ProcessingDots().accessibilityLabel("等待下载")
                    } else {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("未下载")
                    }
                }
                .buttonStyle(.plain)
                .font(.title3)
                .frame(width: 34, height: 34)
                // 配置入口：跟"大模型 API"那一行一样，后面是"已配置 / 未配置"加一个箭头
                Button {
                    localEdit = .model(kind, title)
                } label: {
                    HStack(spacing: 4) {
                        Text(modelRowStatus(status: status,
                                            downloading: downloading,
                                            paused: paused,
                                            waiting: waiting))
                            .lineLimit(1)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func modelRowStatus(status: LiveSession.ModelStatus,
                                downloading: Bool,
                                paused: Bool,
                                waiting: Bool) -> String {
        if downloading {
            return "下载中 \(Int((session.bgDownloadProgress * 100).rounded()))%"
        }
        if paused { return "已暂停" }
        if waiting { return "等待下载" }
        return status.installed ? "已配置" : "未配置"
    }

    /// 本地模型的详情："文件名 · 大小"
    private func detailText(_ kind: LiveSession.ModelKind) -> String {
        let st: LiveSession.ModelStatus
        switch kind {
        case .translation: st = session.translationStatus
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
            if session.isModelDownloadPaused(k) {
                session.resumeModelDownload(k)
                return
            }
            lastKind = k
            confirmKind = k
        case .importFile(let k):
            lastImportKind = k
            importKind = k
        }
    }

    private func importSelectedModel(_ url: URL, kind: LiveSession.ModelKind) {
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
            }
            var prepared: LocalModelImport.Prepared?
            do {
                let input = try await Task.detached(priority: .userInitiated) {
                    try LocalModelImport.prepare(url, for: kind)
                }.value
                prepared = input
                await session.prepareForModelImport(kind)
                switch kind {
                case .senseVoice:
                    await session.importSenseVoice(input.source)
                case .translation:
                    await session.importModel(input.source)
                case .voiceClone:
                    await session.importVoiceClone(input.source)
                }
            } catch {
                session.showToast("模型导入失败：\(error.localizedDescription)", seconds: 5)
                hearLog("模型压缩包导入失败：\(error)", .error)
            }
            if let prepared {
                LocalModelImport.cleanup(prepared)
            }
        }
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

    private var outputBinding: Binding<AudioOutput> {
        Binding(
            get: { session.outputMode },
            set: { output in
                if !session.setAudioOutput(output) { showHeadphoneOutputHelp = true }
            }
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

/// 下载中的动态圆环：实心进度显示已完成多少，外围短弧持续转动，
/// 让用户一眼区分“正在下载”和“暂停”。
private struct DownloadProgressIcon: View {
    let progress: Double
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, progress)))
                .stroke(Color.accentColor,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: 0.18)
                .stroke(Color.accentColor.opacity(0.7),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1.5, 5]))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 1.1).repeatForever(autoreverses: false),
                           value: spin)
        }
        .frame(width: 30, height: 30)
        .onAppear { spin = true }
        .accessibilityHidden(true)
    }
}


private func cloudASRSchemeLabel(_ scheme: String, model: String) -> String {
    let suffix = model.isEmpty ? "" : "（\(model)）"
    switch scheme {
    case "sensevoice": return "云端最快：SenseVoice"
    case "whisper": return "云端最准：Whisper" + suffix
    case "sensevoice+whisper": return "云端综合：SenseVoice + Whisper" + suffix
    default: return scheme
    }
}

/// 云端模型里要配置的那一项：服务（默认地址）或某个模型
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
    @State private var verificationTask: Task<Void, Never>?
    /// 本地网络权限没开：弹提示告诉用户去哪儿开
    @State private var showLocalNetworkHelp = false

    /// 访问口令（电脑上开了"要求口令"才填）
    private var accessTokenBinding: Binding<String> {
        Binding(
            get: { session.cloudAccessToken },
            set: { session.setCloudAccessToken($0) }
        )
    }

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
                        // 选项完全照着电脑上服务报上来的清单来：
                        // 电脑上没装的方案一个都不给（比如没装 SenseVoice 就只有 Whisper）
                        if case .model(let m) = target, m == .asr {
                            Picker("识别方案", selection: $asrScheme) {
                                ForEach(availableSchemes, id: \.self) { scheme in
                                    Text(schemeLabel(scheme)).tag(scheme)
                                }
                            }
                            // 电脑上跑的是什么，一眼能看到；旁边可以随时刷新
                            HStack {
                                Text(cloudModelInfo)
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Button("刷新") {
                                    Task { await session.refreshCloudStatus() }
                                }
                                .font(.caption)
                            }
                            if session.cloudSenseVoiceState == "没装" {
                                Text("这台电脑目前只提供 Whisper。可在电脑上运行新版启动器安装 SenseVoice。")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if session.cloudASRSchemes.isEmpty {
                                Text("还没读到电脑上的模型信息（服务可能是旧版本），先点\"刷新\"试试。")
                                    .font(.caption).foregroundStyle(.secondary)
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
                        SecureField("访问口令（可选）", text: accessTokenBinding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text(target.title)
                }

                // 严格模式配对状态与解绑入口（换电脑或重装服务端时可随时切回兼容模式）
                if case .service = target, session.cloudStrictMode {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("已开启严格模式（只信任已配对的服务身份）", systemImage: "checkmark.shield")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.green)
                            if !session.cloudRootFingerprint.isEmpty {
                                Text("签发根指纹：\(session.cloudRootFingerprint)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Button("解除配对并切回兼容模式", role: .destructive) {
                            session.cloudStrictMode = false
                            status = "已解除严格模式配对，切回兼容模式"
                            Task { await session.refreshCloudStatus() }
                        }
                    } header: {
                        Text("服务身份校验")
                    } footer: {
                        Text("更换电脑、重装服务端或重新签发根证书后，请先解除配对再重新连接。")
                    }
                }

                // 测试连接放最后
                Section {
                    HStack {
                        Button("测试连接") { test() }
                            .disabled(busy)
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
                    Button("完成") {
                        if !verifySpecialAddress(save: true) { save(); dismiss() }
                    }
                    .disabled(busy)
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
                    if m == .asr {
                        asrScheme = session.cloudASRScheme
                        // 当前选的方案电脑上不支持的话，换成能用的
                        fixSchemeIfNeeded()
                        // 顺手刷新一下：要知道电脑上到底跑的是哪个模型、有哪些方案
                        Task { await session.refreshCloudStatus() }
                    }
                }
            }
            // 刷新完才知道电脑上有哪些方案：选中值要是不在里面就换掉
            .onChange(of: session.cloudASRSchemes) { _, _ in fixSchemeIfNeeded() }
            .onChange(of: session.cloudSenseVoiceState) { _, _ in fixSchemeIfNeeded() }
            .onDisappear { verificationTask?.cancel() }
            .onChange(of: useDefault) { _, on in
                // 从"默认"切到"自定义"：把通用服务地址填进去，用户直接改就行
                guard !on, address.isEmpty else { return }
                address = sharedAddressText
            }
            .localNetworkHelp($showLocalNetworkHelp)
        }
    }

    /// 电脑上能用的识别方案：照着服务报上来的清单来，一个都不多给
    /// （服务没报的老版本才退回三种）
    private var availableSchemes: [String] {
        let s = session.cloudASRSchemes
        if !s.isEmpty { return s }
        return ["sensevoice", "whisper", "sensevoice+whisper"]
    }

    /// 方案的名字：Whisper 那一项带上电脑上跑的型号
    private func schemeLabel(_ scheme: String) -> String {
        cloudASRSchemeLabel(scheme, model: session.cloudASRModelName)
    }

    /// 电脑上现在跑着什么（一行小字）
    private var cloudModelInfo: String {
        var parts: [String] = []
        if !session.cloudASRModelName.isEmpty { parts.append("Whisper（\(session.cloudASRModelName)）") }
        if session.cloudSenseVoiceState == "就绪" { parts.append("SenseVoice") }
        if parts.isEmpty { return "电脑上的模型：还不知道" }
        return "电脑上的模型：" + parts.joined(separator: " + ")
    }

    /// 当前选的识别方案电脑上不支持的话，换成一个支持的
    private func fixSchemeIfNeeded() {
        let list = session.cloudASRSchemes
        guard !list.isEmpty else { return }
        if list.contains(asrScheme) { return }
        asrScheme = list.contains("sensevoice+whisper") ? "sensevoice+whisper" : (list.first ?? asrScheme)
        hearLog("云端识别：电脑上只支持 \(list.joined(separator: "、"))，改用 \(asrScheme)")
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
        if verifySpecialAddress(save: false) { return }
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
            var info: CloudClient.ProbeResult?
            var denied = false
            for a in targets {
                let d = await CloudClient.diagnose(address: a, testingEnteredAddress: true)
                let t = d.text
                if CloudClient.looksConnected(t) {
                    okAddr = a
                    info = d.service
                    text = t
                    break
                }
                // 系统把本地网络访问拦下来了：要单独提示，别的错法不一样
                if d.localNetworkDenied { denied = true }
                if text.isEmpty { text = t }
            }
            if let info {
                func modelStatus(_ model: CloudModel) -> String {
                    let readiness: CloudModelReadiness
                    if info.kind == .aggregator {
                        readiness = CloudModelReadiness(reported: info.health[model.rawValue],
                                                        ready: info.health["\(model.rawValue)_ready"])
                    } else {
                        readiness = model == .asr ? .unknown
                            : CloudModelReadiness(reported: info.health["status"], ready: nil)
                    }
                    return "\(model.title) \(readiness.rawValue)"
                }
                switch target {
                case .service where info.kind == .aggregator:
                    text += "\n" + CloudModel.allCases.map(modelStatus).joined(separator: " · ")
                case .model(let model):
                    text += "\n" + modelStatus(model)
                    if okAddr != effectiveAddressText { text += "（通用服务地址）" }
                default: break
                }
            }
            busy = false
            status = text
            // 本地网络权限没开：弹提示告诉用户去哪儿开（系统只问一次）
            if denied { showLocalNetworkHelp = true }
        }
    }

    private func verifySpecialAddress(save: Bool) -> Bool {
        guard address.contains("#") else { return false }
        let pairing: CloudPairingAddress
        do {
            guard case .service = target, let parsed = try CloudPairingAddress.parse(address) else {
                throw CloudPairingAddress.InvalidAddress()
            }
            pairing = parsed
        } catch {
            status = error.localizedDescription
            return true
        }
        guard !busy else { return true }
        busy = true
        status = nil
        verificationTask = Task {
            defer { busy = false }
            do {
                let root = try await CloudClient.verifyPairingAddress(pairing)
                try Task.checkCancellation()
                if save {
                    session.connectVerifiedCloudAddress(pairing.address, root: root)
                    Task { await session.refreshCloudStatus() }
                    dismiss()
                } else {
                    status = "连接正常，已核验服务身份"
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { status = error.localizedDescription }
            }
        }
        return true
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
                    if session.isModelDownloadPaused(kind) {
                        Text("已暂停").foregroundStyle(.secondary)
                    } else if downloading {
                        HStack(spacing: 8) {
                            DownloadProgressIcon(progress: progress)
                            Text("正在下载")
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
                         : "本地导入：可以选择模型文件夹，也可以直接选择 ZIP 压缩包。")
                }

                Section {
                    Button {
                        onPick(true)
                        dismiss()
                    } label: {
                        Label(session.isModelDownloadPaused(kind) ? "继续下载" : (installed ? "重新下载" : "下载"),
                              systemImage: installed ? "arrow.clockwise" : "arrow.down.circle")
                    }
                    .disabled(session.bgDownloading)
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

/// "本地模型 / 云端模型" 两个页签
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
