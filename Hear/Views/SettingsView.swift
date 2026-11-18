import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var session: LiveSession
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
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

                Section("翻译") {
                    Toggle("结合上文翻译（更连贯）", isOn: $session.useContext)
                }

                // MARK: 大模型 API（用于总结）
                Section {
                    NavigationLink {
                        LLMSettingsView()
                    } label: {
                        LabeledContent("大模型 API") {
                            Text(llm.active.map { "\($0.name) · \($0.selectedModel.isEmpty ? "未选模型" : $0.selectedModel)" } ?? "未配置")
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("总结")
                }

                // MARK: 收音
                Section {
                    Picker("声音来源", selection: inputBinding) {
                        Text("手机麦克风").tag("phone")
                        Text("耳机麦克风").tag("headset")
                    }
                    Toggle("语音增强（降噪、消除回声）", isOn: $session.voiceProcessing)
                } header: {
                    Text("收音")
                } footer: {
                    Text((inputNote.map { $0 + "\n" } ?? "") + "使用 iPhone 自带的通话级降噪：压低空调、风扇、人群等背景声，只突出说话的人，也能减少没说话时被误识别。下次开始实时翻译时生效。开启后，还可以在聆听时从控制中心的“麦克风模式”里选择“语音突显”，降噪更强。")
                }

                // MARK: 朗读
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
                }

                // MARK: 音色
                Section {
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
                } header: {
                    Text("音色")
                } footer: {
                    if let personalVoiceNote { Text(personalVoiceNote) }
                }

                // MARK: 语音识别
                Section {
                    if !session.usingApple {
                        Picker("识别引擎", selection: $session.asrEngine) {
                            Text("Whisper").tag("whisper")
                            Text("iOS 系统听写").tag("apple")
                        }
                        .disabled(!LiveTextEngineFactory.isSupported)
                    }
                    Picker("语音识别运行在", selection: asrBinding) {
                        Text("GPU（加载快，推荐）").tag(true)
                        Text("神经引擎（省电）").tag(false)
                    }
                } header: {
                    Text("语音识别")
                } footer: {
                    Text("Whisper：自动判断说的是哪种语言，几个字一批显示。iOS 系统听写：说话时逐字显示（需要 iOS 26，第一次使用某种语言会先下载系统语言包），一句说完后仍由 Whisper 校正并判断语言。\n神经引擎更省电，但第一次加载要先编译模型，可能需要好几分钟。切换后会重新加载语音识别模型。")
                }

                Section {
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
                } header: { Text("断句") }

                Section {
                    TextEditor(text: $session.glossary)
                        .frame(minHeight: 100)
                        .font(.body.monospaced())
                } header: {
                    Text("术语表")
                } footer: {
                    Text("每行一条，格式：原文=译文\n例如：张伟=Zhang Wei")
                }

                // MARK: 已下载的模型（只显示下载完成的）
                Section {
                    if !session.translationStatus.installed && !session.speechStatus.installed {
                        Text("暂无").foregroundStyle(.secondary)
                    }
                    if session.translationStatus.installed {
                        ModelRow(title: "翻译模型（MT）", icon: "character.book.closed", status: session.translationStatus)
                    }
                    if session.speechStatus.installed {
                        ModelRow(title: "语音识别模型（ASR）", icon: "waveform", status: session.speechStatus)
                    }

                    if session.installedGGUFs.count > 1 {
                        Picker("使用的翻译模型", selection: ggufSelection) {
                            ForEach(session.installedGGUFs, id: \.self) { url in
                                Text(url.lastPathComponent).tag(url.lastPathComponent)
                            }
                        }
                    }
                } header: {
                    Text("已下载的模型")
                }

                Section {
                    Picker("下载源", selection: $session.hfHost) {
                        Text("Hugging Face 官方").tag("huggingface.co")
                        Text("hf-mirror（国内镜像）").tag("hf-mirror.com")
                    }
                    downloadRow(.translation, name: "翻译模型（MT）", installed: session.translationStatus.installed)
                    downloadRow(.speech, name: "语音识别模型（ASR）", installed: session.speechStatus.installed)
                    if let err = session.bgDownloadError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                    Button { importing = true } label: {
                        Label("从“文件”导入 GGUF 翻译模型（MT）…", systemImage: "folder")
                    }
                    .disabled(session.isBusyWithModels)
                } header: {
                    Text("下载与导入")
                } footer: {
                    Text("模型文件损坏、翻译异常或想换下载源时，可以重新下载。也可以通过电脑的“访达/iTunes 文件共享”把 .gguf 拷进“听见”。")
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
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .confirmationDialog(confirmTitle,
                                isPresented: Binding(get: { confirmKind != nil },
                                                     set: { if !$0 { confirmKind = nil } }),
                                titleVisibility: .visible,
                                presenting: confirmKind) { kind in
                Button(isInstalled(kind) ? "删除并重新下载" : "开始下载",
                       role: isInstalled(kind) ? .destructive : nil) {
                    Task { await session.redownload(kind) }
                }
                Button("取消", role: .cancel) {}
            } message: { kind in
                Text((kind == .translation
                     ? "翻译模型（MT）约 2 GB，请连接 Wi‑Fi。"
                     : "语音识别模型（ASR）约 1.6 GB，请连接 Wi‑Fi。")
                     + "下载进度显示在「下载与导入」里，下载时请保持 App 在前台。")
            }
            .confirmationDialog("下载听见本地模型？", isPresented: $askDownload, titleVisibility: .visible) {
                Button("开始下载") { session.startBackgroundDownload() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("翻译模型约 2 GB、语音识别模型约 1.6 GB，请连接 Wi‑Fi。下载期间继续用苹果自带，下载完成后自动切换。下载时请保持 App 在前台。")
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data, .data]) { result in
                if case .success(let url) = result {
                    Task { await session.importModel(url) }
                    dismiss()
                }
            }
        }
    }

    @State private var personalVoiceNote: String?
    @State private var askDownload = false

    /// 例如 “1.1（第 20 版）”
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "-"
        let b = info?["CFBundleVersion"] as? String ?? "-"
        return "\(v)（第 \(b) 版）"
    }

    /// 下载与导入里的一行：没在下载时是按钮，下载中显示进度，排队时显示“等待下载”
    @ViewBuilder
    private func downloadRow(_ kind: LiveSession.ModelKind, name: String, installed: Bool) -> some View {
        if session.bgDownloadKind == kind {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("正在下载\(name)", systemImage: "arrow.down.circle")
                    Spacer()
                    Text(String(format: "%.0f%%", session.bgDownloadProgress * 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: session.bgDownloadProgress)
            }
            .padding(.vertical, 2)
        } else if session.bgDownloading && session.bgDownloadAll && !installed {
            Label("等待下载\(name)", systemImage: "clock")
                .foregroundStyle(.secondary)
        } else {
            Button { confirmKind = kind } label: {
                Label(installed ? "重新下载\(name)" : "下载\(name)", systemImage: "arrow.clockwise")
            }
            .disabled(session.isBusyWithModels)
        }
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
            return "正在下载听见本地模型，进度见下方「下载与导入」。"
        }
        if session.usingApple {
            return "苹果自带：用 iOS 的系统听写和翻译，不用下载模型。第一次用某种语言时，系统会提示下载语言包。" +
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
                dismiss()
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

    private var confirmTitle: String {
        guard let k = confirmKind else { return "" }
        return k == .translation ? "翻译模型（MT）" : "语音识别模型（ASR）"
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

/// 一行模型状态：名称、文件名、大小、是否已下载
struct ModelRow: View {
    let title: String
    let icon: String
    let status: LiveSession.ModelStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(status.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if status.installed {
                Label(status.detail, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Label("未下载", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}
