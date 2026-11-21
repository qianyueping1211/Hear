import SwiftUI

/// 术语与行业热词的统一维护入口。
struct GlossaryView: View {
    @EnvironmentObject var session: LiveSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $session.glossary)
                        .frame(minHeight: 320)
                        .font(.body.monospaced())
                } header: {
                    Text("术语表")
                } footer: {
                    Text("每行一条，格式：原文=译文\n例如：张伟=Zhang Wei\n\n这里会作为后续行业热词和自定义术语的统一维护入口。")
                }
            }
            .navigationTitle("术语配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
