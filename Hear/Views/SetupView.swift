import SwiftUI

/// 首次启动：下载 / 加载模型
struct SetupView: View {
    @EnvironmentObject var session: LiveSession
    @ObservedObject private var log = AppLog.shared
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            switch session.phase {
            case .checking:
                ProgressView("检查模型…")

            case .needsModels:
                Image(systemName: "arrow.down.circle").font(.system(size: 54)).foregroundStyle(.tint)
                Text("要下载听见的本地模型吗？").font(.title3.weight(.semibold))
                Text("翻译模型 Hy-MT2-1.8B，约 2 GB\n语音识别模型 Whisper large-v3 turbo，约 1.6 GB\n\n只需下载一次，之后完全离线运行，翻译质量更好、支持的语言更多。请连接 Wi‑Fi。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await session.chooseLocalAndDownload() }
                } label: {
                    Text("下载").frame(maxWidth: 240).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                if session.appleAvailable {
                    Button {
                        session.chooseApple()
                    } label: {
                        Text("先不下载，用苹果自带").frame(maxWidth: 240).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    Text("苹果自带：用 iOS 的系统听写和翻译，马上就能用。选择下载时也会先用它，下载完成后自动切换；可以在 设置 → 引擎 里看下载进度和随时切换。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

            case .downloading(let name, let p):
                Text("正在下载 \(name)").font(.headline)
                ProgressView(value: p).frame(maxWidth: 260)
                Text(String(format: "%.0f%%", p * 100)).monospacedDigit().foregroundStyle(.secondary)
                Text("请保持屏幕常亮、App 在前台").font(.footnote).foregroundStyle(.secondary)

            case .loading(let msg):
                ProgressView()
                Text(msg).multilineTextAlignment(.center).foregroundStyle(.secondary)
                recentLog

            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 44)).foregroundStyle(.orange)
                Text(msg).multilineTextAlignment(.center).padding(.horizontal)
                Button("重试") {
                    Task {
                        if session.modelsInstalled {
                            await session.loadModels()
                        } else {
                            await session.downloadModels()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                recentLog

            case .ready:
                EmptyView()
            }
            Spacer()
        }
        .padding()
        .sheet(isPresented: $showLog) {
            NavigationStack {
                LogView().toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("关闭") { showLog = false } }
                }
            }
        }
    }

    /// 最近几行日志 + 查看全部
    private var recentLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(log.entries.suffix(3)) { e in
                Text(e.line).font(.caption2.monospaced())
                    .foregroundStyle(e.level == .error ? Color.red : (e.level == .warning ? Color.orange : Color.secondary))
                    .lineLimit(2)
            }
            Button("查看运行日志") { showLog = true }.font(.footnote)
        }
        .padding(.top, 8)
        .frame(maxWidth: 320, alignment: .leading)
    }
}
