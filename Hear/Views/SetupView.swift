import SwiftUI

/// 首次启动：下载 / 加载模型
struct SetupView: View {
    @EnvironmentObject var session: LiveSession

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            switch session.phase {
            case .checking:
                ProgressView("检查模型…")

            case .needsModels:
                Image(systemName: "arrow.down.circle").font(.system(size: 54)).foregroundStyle(.tint)
                Text("首次使用需要下载模型").font(.title3.weight(.semibold))
                Text("翻译模型 Hy-MT2-1.8B（约 2 GB）\n语音识别 Whisper large-v3 turbo（约 1.6 GB）\n\n只需下载一次。之后完全离线运行。\n请连接 Wi‑Fi，下载时保持 App 在前台。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await session.downloadModels() }
                } label: {
                    Text("开始下载").frame(maxWidth: 240).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

            case .downloading(let name, let p):
                Text("正在下载 \(name)").font(.headline)
                ProgressView(value: p).frame(maxWidth: 260)
                Text(String(format: "%.0f%%", p * 100)).monospacedDigit().foregroundStyle(.secondary)
                Text("请保持屏幕常亮、App 在前台").font(.footnote).foregroundStyle(.secondary)

            case .loading(let msg):
                ProgressView()
                Text(msg).multilineTextAlignment(.center).foregroundStyle(.secondary)

            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 44)).foregroundStyle(.orange)
                Text(msg).multilineTextAlignment(.center).padding(.horizontal)
                Button("重试") {
                    Task {
                        if ModelManager.currentGGUF() != nil && ModelManager.whisperFolder() != nil {
                            await session.loadModels()
                        } else {
                            await session.downloadModels()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)

            case .ready:
                EmptyView()
            }
            Spacer()
        }
        .padding()
    }
}
