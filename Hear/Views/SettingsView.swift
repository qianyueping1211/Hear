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

    var body: some View {
        NavigationStack {
            Form {
                // MARK: 引擎
                Section {
                    Picker("引擎", selection: engineBinding) {
                        Text("苹果自带").tag("apple")
                        Text("听见本地模型").tag("local")
                    }
                    .disabled(!session.appleAvailable)
                } header: {
                    Text("引擎")
                } footer: {
                    Text(engineFooter)
                }

                // MARK: 模型（状态 / 下载 / 导入）
                Section {
                    modelRow(.translation, title: "翻译模型（MT）", icon: "character.book.closed",
                             status: session.translationStatus)
                    if session.installedGGUFs.count > 1 {
                        Picker("使用的翻译模型", selection: ggufSelection) {
                            ForEach(session.installedGGUFs, id: \.self) { url in
                                Text(url.lastPathComponent).tag(url.lastPathComponent)
                            }
                        }
                    }
                    modelRow(.speech, title: "语音识别模型（ASR）", icon: "waveform",
                             status: session.speechStatus)
                    Picker("下载源", selection: $session.hfHost) {
                        Text("Hugging Face 官方").tag("huggingface.co")
                        Text("hf-mirror（国内镜像）").tag("hf-mirror.com")
                    }
                    if let err = session.bgDownloadError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("模型")
                } footer: {
                    Text("导入翻译模型：选 .gguf 文件。导入语音识别模型：选 WhisperKit 模型文件夹（里面有 AudioEncoder.mlmodelc 等）。")
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
                    if !session.usingApple {
                        Picker("识别引擎", selection: $session.asrEngine) {
                            Text("Whisper").tag("whisper")
                            Text("iOS 系统听写").tag("apple")
                        }
                        .disabled(!LiveTextEngineFactory.isSupported)
                    }
                } header: {
                    Text("语音识别")
                } footer: {
                    if let inputNote { Text(inputNote) }
                }

                // MARK: 朗读（出声 → 音色 → 耳机左右耳）
                Section {
                    Toggle("朗读译文", isOn: $session.speakOutput)
                    Picker("朗读从哪里出声", selection: outputBinding) {
                        Text("手机扬声器").tag(AudioOutput.speaker)
                        Text("耳机").tag(AudioOutput.headphones)
                    }
                    Picker("朗读音色", selection: $session.voiceStyle) {
                        Text("系统默认").tag("system")
                        Text("接近说话人（性别和音高）").tag("match")
                    }
                    Toggle("用我的“个人声音”朗读我说的话", isOn: personalVoiceBinding)
                    if session.usePersonalVoice {
                        Picker("我说的语言", selection: $session.mySide) {
                            Text(session.langA.name).tag("A")
                            Text(session.langB.name).tag("B")
                        }
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
                    if let personalVoiceNote { Text(personalVoiceNote) }
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
                if session.usePersonalVoice {
                    personalVoiceNote = Self.personalVoiceDescription(Speaker.personalVoices)
                }
            }
            .navigationTitle("功能设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            // 导入：翻译模型选 .gguf 文件，语音识别模型选文件夹
            .fileImporter(isPresented: Binding(get: { importKind != nil },
                                               set: { if !$0 { importKind = nil } }),
                          allowedContentTypes: lastImportKind == .speech
                              ? [UTType.folder]
                              : [UTType(filenameExtension: "gguf") ?? .data, .data]) { result in
                guard case .success(let url) = result else { return }
                let kind = lastImportKind
                Task {
                    if kind == .speech { await session.importWhisper(url) } else { await session.importModel(url) }
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
        .centerDialog(isPresented: $askDownload,
                      title: "下载听见本地模型？",
                      message: "翻译模型约 2 GB、语音识别模型约 1.6 GB，请连接 Wi‑Fi。下载期间继续用苹果自带，下载完成后自动切换。下载时请保持 App 在前台。") {
            session.startBackgroundDownload()
        }
    }

    @State private var personalVoiceNote: String?
    @State private var askDownload = false
    /// 最近一次要下载的模型（确认框收起的动画里文字不会突然变空）
    @State private var lastKind: LiveSession.ModelKind = .translation

    private var dialogTitle: String {
        let name = lastKind == .translation ? "翻译模型（MT）" : "语音识别模型（ASR）"
        return (isInstalled(lastKind) ? "重新下载" : "下载") + name + "？"
    }

    private var dialogMessage: String {
        let size = lastKind == .translation ? "约 2 GB" : "约 1.6 GB"
        let head = isInstalled(lastKind) ? "会先删除已下载的文件，再重新下载（\(size)）。" : "文件\(size)。"
        return head + "请连接 Wi‑Fi，下载进度显示在「模型」里，下载时请保持 App 在前台。"
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
        let waiting = !downloading && session.bgDownloading && session.bgDownloadAll && !status.installed
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
                // 状态
                Group {
                    if downloading {
                        Image(systemName: "arrow.down.circle.dotted").foregroundStyle(.tint)
                    } else if waiting {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                    } else if status.installed {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
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
                    Image(systemName: status.installed ? "arrow.clockwise" : "arrow.down.circle")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderless)
                .disabled(session.isBusyWithModels)
                .accessibilityLabel(status.installed ? "重新下载" : "下载")
                // 导入
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

    private var engineBinding: Binding<String> {
        Binding(
            get: { session.usingApple ? "apple" : "local" },
            set: { v in
                if v == "apple" {
                    session.chooseApple()
                } else if session.modelsInstalled {
                    Task { await session.switchToLocal() }
                } else if !session.bgDownloading {
                    askDownload = true
                }
            }
        )
    }

    private var engineFooter: String {
        if !session.appleAvailable { return "苹果自带需要 iOS 26。" }
        if session.bgDownloading {
            return "正在下载听见本地模型，进度见下方「模型」。"
        }
        if session.usingApple {
            return "苹果自带：用 iOS 的系统听写和翻译，不用下载模型。" +
                (session.modelsInstalled ? "" : "\n选择“听见本地模型”会先下载模型，下载完成后自动切换。")
        }
        return "听见本地模型：Whisper + Hy-MT2，在手机本地运行，支持结合上文和术语表。"
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
                Task { await session.reloadASR() }
                if !session.usingApple { dismiss() }      // 本地模型要重新加载，回到首页看进度
            }
        )
    }

    private var outputBinding: Binding<AudioOutput> {
        Binding(
            get: { session.outputMode },
            set: { new in if new != session.outputMode { session.cycleOutput() } }
        )
    }

    private var personalVoiceBinding: Binding<Bool> {
        Binding(
            get: { session.usePersonalVoice },
            set: { on in
                guard on else { session.usePersonalVoice = false; personalVoiceNote = nil; return }
                Task {
                    let ok = await Speaker.requestPersonalVoiceAccess()
                    guard ok else {
                        session.usePersonalVoice = false
                        personalVoiceNote = "没有获得个人声音的使用权限，可以在 iPhone 设置 → 辅助功能 → 个人声音 里允许。"
                        return
                    }
                    // 已授权就打开；找不到对应语言的个人声音时会自动用普通声音
                    session.usePersonalVoice = true
                    let voices = await Speaker.findPersonalVoices()
                    let names = voices.map { $0.name + "(" + $0.language + ")" }.joined(separator: ", ")
                    hearLog("个人声音：找到 \(voices.count) 个 \(names)")
                    personalVoiceNote = Self.personalVoiceDescription(voices)
                }
            }
        )
    }

    static func personalVoiceDescription(_ voices: [AVSpeechSynthesisVoice]) -> String {
        if voices.isEmpty {
            return "已允许使用，但暂时读不到个人声音。如果是刚刚才允许，把 App 从后台完全划掉后重新打开再试。"
        }
        let langs = Set(voices.map { Locale.current.localizedString(forIdentifier: $0.language) ?? $0.language })
        return "已找到个人声音（\(langs.sorted().joined(separator: "、"))）。个人声音只能说录制时的语言，只有译文是这种语言时才会用它，其他语言用普通声音。"
    }

    private func isInstalled(_ kind: LiveSession.ModelKind) -> Bool {
        kind == .translation ? session.translationStatus.installed : session.speechStatus.installed
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
