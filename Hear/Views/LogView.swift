import SwiftUI

/// 运行日志页面
struct LogView: View {
    @ObservedObject private var log = AppLog.shared
    @State private var copied = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if log.lines.isEmpty {
                        Text("暂无日志").foregroundStyle(.secondary)
                    }
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.contains("失败") || line.contains("错误") ? .red : .primary)
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .padding()
            }
            .onAppear { proxy.scrollTo(log.lines.count - 1, anchor: .bottom) }
        }
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = log.text
                    copied = true
                }
                Button("清空", role: .destructive) { log.clear() }
            }
        }
    }
}
