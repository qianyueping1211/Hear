import SwiftUI

struct SpeakerEditor: View {
    @Environment(\.dismiss) private var dismiss
    let item: TranslationItem
    let labels: [Int: String]
    let onSave: (ConversationSpeakerEdit) -> Void
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                if item.speakerID != nil {
                    Section("给这位说话人改名") {
                        TextField("姓名", text: $name)
                        Button("保存姓名") { save(.rename(name)) }
                    }
                }
                Section("这句话是谁说的") {
                    ForEach(labels.keys.sorted(), id: \.self) { id in
                        Button {
                            save(.assign(id))
                        } label: {
                            HStack {
                                Text(labels[id] ?? "说话人 \(id)")
                                if item.speakerID == id {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Button("新建说话人") { save(.add) }
                    Button("设为未分配") { save(.assign(nil)) }
                }
            }
            .navigationTitle("说话人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .onAppear { name = item.speakerName ?? "" }
        }
    }

    private func save(_ change: ConversationSpeakerEdit) {
        onSave(change)
        dismiss()
    }
}
