import SwiftUI

struct SpeakerEditor: View {
    @Environment(\.dismiss) private var dismiss
    let item: TranslationItem
    let labels: [Int: String]
    let onSave: (ConversationSpeakerEdit) -> Void
    @State private var name = ""
    @State private var gender: SpeakerDetails.Gender?
    @State private var commonLanguage = ""
    @State private var accent: SpeakerDetails.Accent?
    @State private var createsNewSpeaker = false

    var body: some View {
        NavigationStack {
            Form {
                Section(createsNewSpeaker || item.speakerID == nil ? "新说话人" : "说话人资料") {
                    TextField("姓名", text: $name)
                    Picker("性别", selection: $gender) {
                        Text("未设置").tag(nil as SpeakerDetails.Gender?)
                        ForEach(SpeakerDetails.Gender.allCases, id: \.self) { option in
                            Text(option.title).tag(Optional(option))
                        }
                    }
                    Picker("常用语言", selection: $commonLanguage) {
                        ForEach(Language.all) { language in
                            Text(language.zhName).tag(language.id)
                        }
                    }
                    Picker("口音（选填）", selection: $accent) {
                        Text("未设置").tag(nil as SpeakerDetails.Accent?)
                        ForEach(SpeakerDetails.Accent.allCases, id: \.self) { option in
                            Text(option.title).tag(Optional(option))
                        }
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
                    if item.speakerID != nil, !createsNewSpeaker {
                        Button("新建说话人") {
                            createsNewSpeaker = true
                            name = ""
                            gender = nil
                            commonLanguage = item.defaultSpeakerLanguage
                            accent = nil
                        }
                    }
                    Button("设为未分配") { save(.assign(nil)) }
                }
            }
            .navigationTitle("说话人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let details = SpeakerDetails(gender: gender,
                                                     commonLanguage: commonLanguage.isEmpty ? nil : commonLanguage,
                                                     accent: accent)
                        save(.saveProfile(name: name, details: details, newSpeaker: createsNewSpeaker))
                    }
                }
            }
            .onAppear {
                name = item.speakerName ?? ""
                gender = item.speakerDetails?.gender
                commonLanguage = item.speakerDetails?.commonLanguage ?? item.defaultSpeakerLanguage
                accent = item.speakerDetails?.accent
            }
        }
    }

    private func save(_ change: ConversationSpeakerEdit) {
        onSave(change)
        dismiss()
    }
}
