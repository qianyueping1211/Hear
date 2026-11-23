import Foundation

/// 历史列表用的轻量信息（存在 index.json 里，不用打开每个对话文件）
struct ConversationMeta: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var itemCount: Int
    var preview: String
    var langs: String
    var summaryStatus: SummaryRecord.Status?
    var hasPendingWork: Bool? = nil
}

/// 本地存储：
/// Application Support/Conversations/<id>.json   每个对话一个文件（原文、译文、各模板总结）
/// Application Support/Conversations/index.json  历史列表索引
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published private(set) var metas: [ConversationMeta] = []
    /// 任意对话保存后加一，打开的页面据此刷新
    @Published private(set) var revision = 0

    private let dir: URL
    private let indexURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Conversations", isDirectory: true)
        indexURL = dir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: indexURL),
           let list = try? decoder.decode([ConversationMeta].self, from: data) {
            metas = list
        } else {
            rebuildIndex()
        }
        recoverInterrupted()
    }

    private func fileURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    // MARK: 读写

    func load(_ id: UUID) -> Conversation? {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return nil }
        return try? decoder.decode(Conversation.self, from: data)
    }

    @discardableResult
    func save(_ conversation: Conversation) -> Bool {
        var c = conversation
        c.updatedAt = Date()
        do {
            let data = try encoder.encode(c)
            try data.write(to: fileURL(c.id), options: .atomic)
        } catch {
            hearLog("保存对话失败：\(error)", .error)
            return false
        }
        let meta = Self.meta(of: c)
        if let i = metas.firstIndex(where: { $0.id == c.id }) { metas[i] = meta } else { metas.append(meta) }
        metas.sort { $0.updatedAt > $1.updatedAt }
        writeIndex()
        revision += 1
        return true
    }

    func delete(_ id: UUID) {
        // 记下删除过的对话，iCloud 备份时也删掉，不会被同步回来
        var gone = Self.deletedIDs
        gone[id.uuidString] = Date()
        UserDefaults.standard.set(gone, forKey: "deletedConversations")
        try? FileManager.default.removeItem(at: fileURL(id))
        try? FileManager.default.removeItem(at: syncBaseURL(id))
        metas.removeAll { $0.id == id }
        writeIndex()
        revision += 1
        hearLog("删除对话 \(id.uuidString.prefix(8))")
    }

    func rename(_ id: UUID, to title: String) {
        guard var c = load(id) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        c.title = t
        save(c)
    }

    func setActiveTemplate(_ id: UUID, templateID: String) {
        guard var c = load(id) else { return }
        c.activeTemplateID = templateID
        save(c)
    }

    func updateSummary(_ id: UUID, templateID: String, _ record: SummaryRecord) {
        guard var c = load(id) else { return }
        c.summaries[templateID] = record
        save(c)
    }

    // MARK: iCloud 备份用

    /// 删除过的对话（id → 删除时间）
    static var deletedIDs: [String: Date] {
        (UserDefaults.standard.dictionary(forKey: "deletedConversations") as? [String: Date]) ?? [:]
    }

    static func mergeDeleted(_ other: [String: Date]) {
        var gone = deletedIDs
        // 删除时间取较新的那个：
        // 不然一台设备上"删掉"会被另一台设备上"更早的删掉"压住，
        // 已经删掉的对话又被同步回来
        for (k, v) in other {
            if let cur = gone[k] { gone[k] = max(cur, v) } else { gone[k] = v }
        }
        UserDefaults.standard.set(gone, forKey: "deletedConversations")
    }

    /// 所有对话：id → 最后修改时间
    var allUpdated: [UUID: Date] {
        Dictionary(metas.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, b in max(a, b) })
    }

    /// 某个对话文件的原始内容
    func rawData(_ id: UUID) -> Data? { try? Data(contentsOf: fileURL(id)) }

    private func syncBaseURL(_ id: UUID) -> URL {
        dir.appendingPathComponent(".sync-\(id.uuidString).json")
    }

    func rememberSyncBase(_ data: Data, id: UUID) {
        try? data.write(to: syncBaseURL(id), options: .atomic)
    }

    func syncBase(_ id: UUID) -> Conversation? {
        guard let data = try? Data(contentsOf: syncBaseURL(id)) else { return nil }
        return try? decoder.decode(Conversation.self, from: data)
    }

    func mergeSyncChanges(_ remoteData: Data, into id: UUID, base: Conversation) -> Data? {
        guard let local = load(id), let remote = try? decoder.decode(Conversation.self, from: remoteData),
              remote.id == id else { return nil }
        let merged = local.merging(remote, from: base)
        if merged.conflict {
            var alternate = local.updatedAt >= remote.updatedAt ? remote : local
            alternate.id = UUID()
            alternate.title += "（同步冲突副本）"
            guard save(alternate) else { return nil }
        }
        guard save(merged.conversation), let saved = rawData(id) else { return nil }
        // The remote snapshot is now incorporated even if the upload below needs a retry.
        rememberSyncBase(remoteData, id: id)
        return saved
    }

    /// 把 iCloud 里更新的对话放回本地（保留原来的修改时间，不当成新改动）
    @discardableResult
    func importRaw(_ data: Data) -> Bool {
        guard let c = try? decoder.decode(Conversation.self, from: data) else { return false }
        do { try data.write(to: fileURL(c.id), options: .atomic) } catch { return false }
        let meta = Self.meta(of: c)
        if let i = metas.firstIndex(where: { $0.id == c.id }) { metas[i] = meta } else { metas.append(meta) }
        metas.sort { $0.updatedAt > $1.updatedAt }
        writeIndex()
        revision += 1
        return true
    }

    /// iCloud 上已经删除的对话：本地也删掉（不再记一次删除）
    func removeSynced(_ id: UUID) {
        guard metas.contains(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: fileURL(id))
        try? FileManager.default.removeItem(at: syncBaseURL(id))
        metas.removeAll { $0.id == id }
        writeIndex()
        revision += 1
    }

    // MARK: 索引

    private static func meta(of c: Conversation) -> ConversationMeta {
        let first = c.items.first.map { $0.sourceText } ?? ""
        return ConversationMeta(
            id: c.id, title: c.title, createdAt: c.createdAt, updatedAt: c.updatedAt,
            itemCount: c.items.count, preview: String(first.prefix(60)),
            langs: "\(c.langA.name) ⇄ \(c.langB.name)",
            summaryStatus: c.summaries[c.activeTemplateID]?.status
                ?? c.summaries[SummaryTemplate.defaultID]?.status,
            hasPendingWork: c.items.contains { !$0.done } || c.summaries.values.contains { $0.status == .generating }
        )
    }

    private func writeIndex() {
        if let data = try? encoder.encode(metas) { try? data.write(to: indexURL, options: .atomic) }
    }

    /// 索引丢失或损坏时，从对话文件重新生成
    private func rebuildIndex() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        metas = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(Conversation.self, from: $0) } }
            .map(Self.meta(of:))
            .sorted { $0.updatedAt > $1.updatedAt }
        writeIndex()
    }

    /// 收尾工作在进程退出后不能续跑，保留原文和已显示的译文。
    private func recoverInterrupted() {
        var refreshedIndex = false
        for m in metas where m.hasPendingWork != false {
            guard var c = load(m.id) else { continue }
            var changed = false
            for i in c.items.indices where !c.items[i].done {
                c.items[i].applyTranslation("（翻译失败：上次退出时尚未完成）", done: true)
                changed = true
            }
            for (k, r) in c.summaries where r.status == .generating {
                var r2 = r
                r2.status = .failed
                r2.error = "上次生成时 App 被关闭，请重试"
                c.summaries[k] = r2
                changed = true
            }
            if changed {
                // 恢复只是本机任务状态，不应覆盖另一台已完成的结果。
                c.updatedAt = m.updatedAt
                if let data = try? encoder.encode(c) { _ = importRaw(data) }
            } else if let i = metas.firstIndex(where: { $0.id == m.id }) {
                metas[i].hasPendingWork = false
                refreshedIndex = true
            }
        }
        if refreshedIndex { writeIndex() }
    }
}
