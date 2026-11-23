import Foundation

extension ConversationStore {
    func editSpeaker(conversationID: UUID, itemID: UUID, change: ConversationSpeakerEdit) {
        guard Self.deletedIDs[conversationID.uuidString] == nil,
              var conversation = load(conversationID),
              conversation.items.editSpeaker(itemID: itemID, change: change) else { return }
        save(conversation)
    }

    func saveTranscript(id: UUID, createdAt: Date, langA: Language, langB: Language,
                        items: [TranslationItem]) {
        guard !items.isEmpty, Self.deletedIDs[id.uuidString] == nil else { return }
        var conversation = load(id)
            ?? Conversation(id: id, title: Conversation.defaultTitle(createdAt),
                            createdAt: createdAt, langA: langA, langB: langB)
        conversation.items = items
        conversation.langA = langA
        conversation.langB = langB
        save(conversation)
    }

    @discardableResult
    func commitTranslation(conversationID: UUID, itemID: UUID, expectedSource: String,
                           translation: String, done: Bool) -> Bool {
        guard Self.deletedIDs[conversationID.uuidString] == nil,
              var conversation = load(conversationID),
              let index = conversation.items.firstIndex(where: { $0.id == itemID }),
              conversation.items[index].sourceText == expectedSource else { return false }
        conversation.items[index].applyTranslation(translation, done: done)
        save(conversation)
        return true
    }

    func updateSourceText(conversationID: UUID, itemID: UUID, to newSource: String) -> (source: Language, target: Language, previous: TranslationItem?)? {
        guard Self.deletedIDs[conversationID.uuidString] == nil,
              var conversation = load(conversationID),
              let index = conversation.items.firstIndex(where: { $0.id == itemID }) else { return nil }
        let src = conversation.items[index].source
        let tgt = conversation.items[index].target
        conversation.items[index].sourceText = newSource
        conversation.items[index].done = true
        conversation.items[index].beginTranslationRevision()
        let previous: TranslationItem? = index > 0 ? conversation.items[index - 1] : nil
        save(conversation)
        return (src, tgt, previous)
    }
}
