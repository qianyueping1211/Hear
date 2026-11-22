#if DEBUG || HEAR_SPEECH_REGRESSION
import SwiftUI

struct SpeechRegressionView: View {
    @EnvironmentObject private var session: LiveSession
    @State private var task: Task<Void, Never>?
    @State private var message: String?
    @State private var report: URL?

    var body: some View {
        Form {
            Section {
                Button("运行固定录音对照", action: run)
                    .disabled(task != nil)
                if let message {
                    HStack {
                        Text(message)
                        if task != nil { Spacer(); ProgressView() }
                    }
                }
                if let report {
                    ShareLink(item: report) {
                        Label("导出 JSON 报告", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("下载公开测试录音，在本机对照 300 毫秒和 450 毫秒前置缓冲。")
            }
        }
        .navigationTitle("本机语音回归测试")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { task?.cancel() }
    }

    private func run() {
        report = nil
        message = "准备测试…"
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let file = try await session.runSpeechRegression { message = $0 }
                try Task.checkCancellation()
                report = file
                message = "对照完成"
            } catch is CancellationError {
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
#endif
