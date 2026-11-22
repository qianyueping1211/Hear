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
                    Text("每行一条，可用 | 添加识别别名。\n张伟|章伟=Zhang Wei")
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
