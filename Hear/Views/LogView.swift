import SwiftUI

/// 运行日志：实时查看，按类型筛选、搜索、复制
struct LogView: View {
    @ObservedObject private var log = AppLog.shared
    @State private var filter: LogLevel? = nil      // nil = 全部
    @State private var keyword = ""
    @State private var follow = true
    @State private var copiedHint = ""

    private var shown: [LogEntry] {
        log.entries.filter {
            (filter == nil || $0.level == filter)
                && (keyword.isEmpty || $0.message.localizedCaseInsensitiveContains(keyword))
        }
    }

    private func count(_ l: LogLevel) -> Int { log.entries.filter { $0.level == l }.count }

    var body: some View {
        VStack(spacing: 0) {
            Picker("类型", selection: $filter) {
                Text("全部").tag(LogLevel?.none)
                ForEach(LogLevel.allCases, id: \.self) { l in
                    Text("\(l.title) \(count(l))").tag(LogLevel?.some(l))
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if !log.enabled {
                Text("日志已关闭，可以在 功能设置 → 语言和日志 里开启")
                    .font(.footnote).foregroundStyle(.orange).padding(.bottom, 6)
            }

            ScrollViewReader { proxy in
                List(shown) { e in
                    LogRow(entry: e).id(e.id)
                }
                .listStyle(.plain)
                .overlay {
                    if shown.isEmpty {
                        Text(log.entries.isEmpty ? "暂无日志" : "没有符合条件的日志")
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear {
                    if let id = shown.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: log.entries.last?.id) { _, _ in
                    guard follow, let id = shown.last?.id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }

            if !copiedHint.isEmpty {
                Text(copiedHint).font(.footnote).foregroundStyle(.secondary).padding(6)
            }
        }
        .searchable(text: $keyword, prompt: "搜索日志")
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("自动滚动到最新", isOn: $follow)
                    Button {
                        UIPasteboard.general.string = shown.map(\.line).joined(separator: "\n")
                        copiedHint = "已复制 \(shown.count) 条"
                    } label: { Label("复制当前显示的日志", systemImage: "doc.on.doc") }
                    if FileManager.default.fileExists(atPath: SystemDiagnostics.crashReportURL.path) {
                        ShareLink(item: SystemDiagnostics.crashReportURL) {
                            Label("导出最近的系统崩溃报告", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(role: .destructive) {
                        log.clear()
                        copiedHint = ""
                    } label: { Label("清空日志", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}

struct LogRow: View {
    let entry: LogEntry

    private var icon: (String, Color) {
        switch entry.level {
        case .info: return ("info.circle", .secondary)
        case .warning: return ("exclamationmark.triangle.fill", .orange)
        case .error: return ("xmark.octagon.fill", .red)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon.0).foregroundStyle(icon.1).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text(entry.message)
                    .font(.caption.monospaced())
                    .foregroundStyle(entry.level == .error ? Color.red : Color.primary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}
