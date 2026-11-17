import SwiftUI
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
                } footer: {
                    Text("新建对话时可以用大模型在后台总结上一页。翻译本身仍在手机本地离线完成。")
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
                } footer: {
                    Text("戴耳机：译文出来就从耳机朗读，边听边读，不会被麦克风录进去。插上耳机会自动切到耳机。\n扬声器：聆听时不朗读；停止实时翻译后，从上次没读完的那句开始往后读；再开始实时翻译会立刻停止朗读。\n点某一句：从这句开始往后读，再点一下停止。\n按住“朗读”按钮 2 秒可以切换扬声器/耳机（没连耳机时不切换）。耳机模式下可以让左右耳各听一种语言。")
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
                    Text(personalVoiceNote ?? "“接近说话人”会根据说话人的音高自动选男声或女声，并调高低音，不是完全复刻。“个人声音”需要先在 iPhone 设置 → 辅助功能 → 个人声音 里录制，只能用于它支持的语言。")
                }

                // MARK: 语音识别
                Section {
                    Picker("语音识别运行在", selection: asrBinding) {
                        Text("GPU（加载快，推荐）").tag(true)
                        Text("神经引擎（省电）").tag(false)
                    }
                } header: {
                    Text("语音识别")
                } footer: {
                    Text("神经引擎更省电，但第一次加载要先编译模型，可能需要好几分钟。切换后会重新加载语音识别模型。")
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

                // MARK: 模型状态
                Section {
                    ModelRow(title: "翻译模型（MT）", icon: "character.book.closed", status: session.translationStatus)
                    ModelRow(title: "语音识别模型（ASR）", icon: "waveform", status: session.speechStatus)

                    if session.installedGGUFs.count > 1 {
                        Picker("使用的翻译模型", selection: ggufSelection) {
                            ForEach(session.installedGGUFs, id: \.self) { url in
                                Text(url.lastPathComponent).tag(url.lastPathComponent)
                            }
                        }
                    }
                } header: {
                    Text("已下载的模型")
                } footer: {
                    Text(session.isBusyWithModels ? "模型正在下载或加载中…" : "模型保存在本机，覆盖安装 App 不会丢失。")
                }

                Section {
                    Picker("下载源", selection: $session.hfHost) {
                        Text("Hugging Face 官方").tag("huggingface.co")
                        Text("hf-mirror（国内镜像）").tag("hf-mirror.com")
                    }
                    Button { confirmKind = .translation } label: {
                        Label(session.translationStatus.installed ? "重新下载翻译模型（MT）" : "下载翻译模型（MT）",
                              systemImage: "arrow.clockwise")
                    }
                    .disabled(session.isBusyWithModels)
                    Button { confirmKind = .speech } label: {
                        Label(session.speechStatus.installed ? "重新下载语音识别模型（ASR）" : "下载语音识别模型（ASR）",
                              systemImage: "arrow.clockwise")
                    }
                    .disabled(session.isBusyWithModels)
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
                } footer: {
                    Text("记录加载、识别、翻译、朗读的过程和报错，可按信息/警告/错误筛选和搜索。超过上限时会自动删除最早的日志。")
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
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: { kind in
                Text(kind == .translation
                     ? "翻译模型（MT）约 2 GB，请连接 Wi‑Fi。"
                     : "语音识别模型（ASR）约 1.6 GB，请连接 Wi‑Fi。下载后首次加载需要编译 1–3 分钟。")
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
                guard on else { session.usePersonalVoice = false; return }
                Task {
                    let ok = await Speaker.requestPersonalVoiceAccess()
                    if ok && Speaker.hasAnyPersonalVoice {
                        session.usePersonalVoice = true
                        personalVoiceNote = nil
                    } else {
                        session.usePersonalVoice = false
                        personalVoiceNote = ok
                            ? "还没有录制个人声音：请先到 iPhone 设置 → 辅助功能 → 个人声音 里创建，并打开“允许 App 请求使用”。"
                            : "没有获得个人声音的使用权限，可以在 iPhone 设置 → 辅助功能 → 个人声音 里允许。"
                    }
                }
            }
        )
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
