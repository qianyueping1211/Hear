import Foundation

extension ConversationStore {
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
        conversation.items[index].translated = translation
        conversation.items[index].done = done
        save(conversation)
        return true
    }
}
