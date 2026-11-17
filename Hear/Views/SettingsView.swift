import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var session: LiveSession
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false

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

                Section {
                    LabeledContent("翻译模型", value: session.currentModelName)
                    Button("从“文件”导入 GGUF 模型…") { importing = true }
                    Picker("下载源", selection: $session.hfHost) {
                        Text("Hugging Face 官方").tag("huggingface.co")
                        Text("hf-mirror（国内镜像）").tag("hf-mirror.com")
                    }
                } header: { Text("模型") } footer: {
                    Text("也可以把 .gguf 文件通过电脑的“访达/iTunes 文件共享”拷进“听见”的文稿目录。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
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
}
