import SwiftUI

/// 历史对话列表：查看、重命名、删除
struct HistoryView: View {
    @EnvironmentObject var session: LiveSession
    @ObservedObject private var store = ConversationStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: ConversationMeta?
    @State private var newTitle = ""
    @State private var deleting: ConversationMeta?
    @State private var query = ""

    private var filteredMetas: [ConversationMeta] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.metas }
        return store.metas.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.preview.localizedCaseInsensitiveContains(q)
                || $0.langs.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredMetas.isEmpty {
                    ContentUnavailableView(
                        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "还没有历史对话"
                            : "没有匹配的对话",
                        systemImage: query.isEmpty ? "clock" : "magnifyingglass",
                        description: Text(
                            query.isEmpty
                                ? "实时翻译的内容会自动保存在这里。"
                                : "试试换一个关键词搜索标题或内容摘要。"
                        )
                    )
                }
                ForEach(filteredMetas) { m in
                    NavigationLink {
                        ConversationDetailView(id: m.id)
                    } label: {
                        HistoryRow(meta: m)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleting = m } label: { Label("删除", systemImage: "trash") }
                        Button { startRename(m) } label: { Label("重命名", systemImage: "pencil") }
                            .tint(.orange)
                    }
                    .contextMenu {
                        Button { startRename(m) } label: { Label("重命名", systemImage: "pencil") }
                        Button(role: .destructive) { deleting = m } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索标题或摘要")
            .navigationTitle("历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("对话名称", text: $newTitle)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    if let m = renaming { store.rename(m.id, to: newTitle) }
                    renaming = nil
                }
            }
            .confirmationDialog("删除这段对话？",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible,
                                presenting: deleting) { m in
                Button("删除「\(m.title)」", role: .destructive) {
                    let deletingActive = (m.id == session.conversationID)
                    store.delete(m.id)
                    if deletingActive {
                        session.clearPage()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("对话内容和所有总结都会被删除，无法恢复。")
            }
        }
    }

    private func startRename(_ m: ConversationMeta) {
        newTitle = m.title
        renaming = m
    }
}

struct HistoryRow: View {
    let meta: ConversationMeta

    private var durationLabel: String? {
        guard let secs = meta.durationSeconds, secs > 0 else { return nil }
        let m = secs / 60
        let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(meta.title).font(.headline).lineLimit(1)
                Spacer()
                statusBadge
            }
            if !meta.preview.isEmpty {
                Text(meta.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                if ConversationStore.shared.hasAudioFile(meta.id) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("含完整录音")
                }
                if let dur = durationLabel {
                    Label(dur, systemImage: "clock")
                }
                Text("\(meta.langs) · \(meta.itemCount) 句 · \(meta.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var statusBadge: some View {
        switch meta.summaryStatus {
        case .some(.generating):
            Label("总结中", systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
        case .some(.done):
            Label("已总结", systemImage: "doc.text").font(.caption).foregroundStyle(.green)
        case .some(.failed):
            Label("总结失败", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
        case .none:
            EmptyView()
        }
    }
}
