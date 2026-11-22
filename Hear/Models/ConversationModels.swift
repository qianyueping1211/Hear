import Foundation

/// 某个模板生成的总结
struct SummaryRecord: Codable, Equatable {
    enum Status: String, Codable { case generating, done, failed }

    var status: Status
    var content: String = ""
    var error: String? = nil
    var model: String? = nil
    var edited = false
    var updatedAt = Date()
}

/// 一次完整的对话（一页）
struct Conversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var updatedAt = Date()
    var langA: Language
    var langB: Language
    var items: [TranslationItem] = []
    /// 每个模板各自的总结结果，key 是模板 id。切换模板不会覆盖别的模板的结果
    var summaries: [String: SummaryRecord] = [:]
    /// 总结页当前选中的模板
    var activeTemplateID: String = SummaryTemplate.defaultID

    static func defaultTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm 的对话"
        return f.string(from: date)
    }
}

extension Conversation {
    /// Merge edits to distinct sentences, speaker assignments and summary templates
    /// against the last synchronized version.
    func merging(_ remote: Conversation, from base: Conversation) -> (conversation: Conversation, conflict: Bool) {
        let localIsNewer = updatedAt >= remote.updatedAt
        var merged = localIsNewer ? self : remote
        var conflict = false
        func choose<Value: Equatable>(_ localValue: Value, _ remoteValue: Value, _ baseValue: Value) -> Value {
            if localValue == remoteValue { return localValue }
            if localValue == baseValue { return remoteValue }
            if remoteValue == baseValue { return localValue }
            conflict = true
            return localIsNewer ? localValue : remoteValue
        }
        merged.title = choose(title, remote.title, base.title)
        let languages = choose([langA, langB], [remote.langA, remote.langB], [base.langA, base.langB])
        merged.langA = languages[0]
        merged.langB = languages[1]
        merged.activeTemplateID = choose(activeTemplateID, remote.activeTemplateID, base.activeTemplateID)
        for key in Set(summaries.keys).union(remote.summaries.keys) {
            merged.summaries[key] = choose(summaries[key], remote.summaries[key], base.summaries[key])
        }
        let localItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteItems = Dictionary(remote.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let baseItems = Dictionary(base.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visited: Set<UUID> = []
        merged.items = (merged.items + (localIsNewer ? remote.items : items)).compactMap { row in
            guard visited.insert(row.id).inserted else { return nil }
            guard let local = localItems[row.id], let cloud = remoteItems[row.id],
                  let original = baseItems[row.id] else {
                return choose(localItems[row.id], remoteItems[row.id], baseItems[row.id])
            }
            // A transcript revision and a speaker edit can both apply to the same row.
            struct SpeakerAssignment: Equatable {
                let id: Int?
                let name: String?
                let details: SpeakerDetails?
                let tracked: Bool?
                let manuallySet: Bool?
                init(_ item: TranslationItem) {
                    id = item.speakerID
                    name = item.speakerName
                    details = item.speakerDetails
                    tracked = item.speakerTracked
                    manuallySet = item.speakerManuallySet
                }
                func apply(to item: inout TranslationItem) {
                    item.speakerID = id
                    item.speakerName = name
                    item.speakerDetails = details
                    item.speakerTracked = tracked
                    item.speakerManuallySet = manuallySet
                }
            }
            let assignment = choose(SpeakerAssignment(local), SpeakerAssignment(cloud), SpeakerAssignment(original))
            let empty = SpeakerAssignment(TranslationItem(source: local.source, target: local.target, sourceText: ""))
            var localText = local, cloudText = cloud, originalText = original
            empty.apply(to: &localText)
            empty.apply(to: &cloudText)
            empty.apply(to: &originalText)
            var result = choose(localText, cloudText, originalText)
            assignment.apply(to: &result)
            return result
        }
        return (merged, conflict)
    }
}
