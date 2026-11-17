import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var session: LiveSession
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var confirmKind: LiveSession.ModelKind?

    var body: some View {
        NavigationStack {
            Form {
                Section("翻译") {
                    Toggle("朗读译文", isOn: $session.speakOutput)
                    Toggle("结合上文翻译（更连贯）", isOn: $session.useContext)
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
                    ModelRow(title: "翻译模型", icon: "character.book.closed", status: session.translationStatus)
                    ModelRow(title: "语音识别模型", icon: "waveform", status: session.speechStatus)

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
                        Label(session.translationStatus.installed ? "重新下载翻译模型" : "下载翻译模型",
                              systemImage: "arrow.clockwise")
                    }
                    .disabled(session.isBusyWithModels)
                    Button { confirmKind = .speech } label: {
                        Label(session.speechStatus.installed ? "重新下载语音识别模型" : "下载语音识别模型",
                              systemImage: "arrow.clockwise")
                    }
                    .disabled(session.isBusyWithModels)
                    Button { importing = true } label: {
                        Label("从“文件”导入 GGUF 翻译模型…", systemImage: "folder")
                    }
                    .disabled(session.isBusyWithModels)
                } header: {
                    Text("下载与导入")
                } footer: {
                    Text("模型文件损坏、翻译异常或想换下载源时，可以重新下载。也可以通过电脑的“访达/iTunes 文件共享”把 .gguf 拷进“听见”。")
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
                     ? "翻译模型约 2 GB，请连接 Wi‑Fi。"
                     : "语音识别模型约 1.6 GB，请连接 Wi‑Fi。下载后首次加载需要编译 1–3 分钟。")
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

    private var confirmTitle: String {
        guard let k = confirmKind else { return "" }
        return k == .translation ? "翻译模型" : "语音识别模型"
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
