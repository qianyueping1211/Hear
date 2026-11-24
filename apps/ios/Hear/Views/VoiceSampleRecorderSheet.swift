import AVFoundation
import SwiftUI

struct VoiceSampleRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = FixedVoiceSampleStore.shared

    private struct PromptOption: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    private let prompts: [PromptOption] = [
        PromptOption(
            id: "zh",
            title: "中文（推荐 · 约 5~7 秒）",
            text: "你好，欢迎使用听见实时翻译，今天天气很好，希望我们的交流顺畅愉快。"
        ),
        PromptOption(
            id: "en",
            title: "English（约 5~7 秒）",
            text: "Hello, welcome to Hear real-time translation. Today is a great day, and I hope our conversation goes smoothly."
        ),
    ]

    private let minDuration: Double = 3.0
    private let maxDuration: Double = 10.0

    @State private var selectedPromptID: String = "zh"
    @State private var isRecording: Bool = false
    @State private var elapsedSec: Double = 0
    @State private var level: Double = 0
    @State private var recordedTempURL: URL?
    @State private var recordedDuration: Double = 0
    @State private var isPreviewPlaying: Bool = false
    @State private var errorMessage: String?

    @State private var recorder: AVAudioRecorder?
    @State private var player: AVAudioPlayer?
    @State private var timer: Timer?

    private var currentPrompt: PromptOption {
        prompts.first { $0.id == selectedPromptID } ?? prompts[0]
    }

    private var isDurationValid: Bool {
        recordedTempURL != nil && recordedDuration >= minDuration
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 模型要求说明
                    VStack(alignment: .leading, spacing: 6) {
                        Label("声纹录制要求（本地 + 云端通用）", systemImage: "waveform.badge.mic")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                        Text("· 时长需在 3 ~ 10 秒之间（最佳 4 ~ 8 秒），满 10 秒自动停止。")
                        Text("· 请在安静环境用自然语速逐字朗读下方指定文本，确保声音与参考文本完全一致。")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                    // 语言选择
                    Picker("朗读语言", selection: $selectedPromptID) {
                        ForEach(prompts) { p in
                            Text(p.title).tag(p.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isRecording)
                    .onChange(of: selectedPromptID) { _, _ in
                        resetDraft()
                    }

                    // 指定朗读文本
                    VStack(alignment: .leading, spacing: 8) {
                        Text("请朗读以下指定文本：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("「\(currentPrompt.text)」")
                            .font(.title3.weight(.medium))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                    // 时长进度与音量条
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(format: "%.1fs / %.0fs", elapsedSec, maxDuration))
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(elapsedSec >= minDuration ? .green : .primary)
                            Spacer()
                            Text(statusHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color(.systemGray5))
                                Capsule()
                                    .fill(elapsedSec >= minDuration ? Color.green : Color.blue)
                                    .frame(width: geo.size.width * min(1, elapsedSec / maxDuration))
                                // 3 秒最低达标刻度线
                                Rectangle()
                                    .fill(Color.green.opacity(0.85))
                                    .frame(width: 2)
                                    .offset(x: geo.size.width * (minDuration / maxDuration))
                            }
                        }
                        .frame(height: 8)

                        if isRecording {
                            HStack(spacing: 8) {
                                Image(systemName: "mic.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color(.systemGray5))
                                        Capsule()
                                            .fill(Color.green)
                                            .frame(width: geo.size.width * level)
                                    }
                                }
                                .frame(height: 6)
                            }
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    } else if isDurationValid {
                        Label(
                            String(format: "录制完成（%.1f 秒），建议试听清晰无杂音后保存。", recordedDuration),
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }

                    // 录制与试听按钮
                    HStack(spacing: 12) {
                        Button {
                            if isRecording {
                                stopRecording()
                            } else {
                                startRecording()
                            }
                        } label: {
                            Label(
                                isRecording ? "停止录制" : (recordedTempURL == nil ? "开始录制" : "重新录制"),
                                systemImage: isRecording ? "stop.fill" : "mic.fill"
                            )
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isRecording ? .orange : .red)

                        if recordedTempURL != nil && !isRecording {
                            Button {
                                togglePreview()
                            } label: {
                                Label(isPreviewPlaying ? "停止" : "试听",
                                      systemImage: isPreviewPlaying ? "stop.fill" : "play.fill")
                                    .font(.headline)
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 16)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if store.hasSample && recordedTempURL == nil && !isRecording {
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(format: "当前已保存固定声纹（%.1f 秒）", store.durationSeconds))
                                    .font(.footnote.weight(.medium))
                                Text("本地 ZipVoice 与云端 Qwen3-TTS 均可直接使用")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("试听当前") {
                                playSavedSample()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("清除", role: .destructive) {
                                stopPreview()
                                store.clear()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("录制我的固定声纹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        cleanup()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveRecording()
                    }
                    .disabled(!isDurationValid || isRecording)
                }
            }
            .onDisappear {
                cleanup()
            }
        }
    }

    private var statusHint: String {
        if isRecording {
            if elapsedSec < minDuration {
                return String(format: "还需至少 %.1f 秒", minDuration - elapsedSec)
            }
            return "已达标，读完即可停止"
        }
        if isDurationValid {
            return "时长合格（16kHz 单声道 WAV）"
        }
        return "准备就绪"
    }

    private func resetDraft() {
        stopPreview()
        recordedTempURL = nil
        recordedDuration = 0
        elapsedSec = 0
        errorMessage = nil
    }

    private func startRecording() {
        stopPreview()
        errorMessage = nil
        recordedTempURL = nil
        recordedDuration = 0
        elapsedSec = 0

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try audioSession.setActive(true)
        } catch {
            errorMessage = "无法配置录音会话：\(error.localizedDescription)"
            return
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hear-voice-sample-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let rec = try AVAudioRecorder(url: tmpURL, settings: settings)
            rec.isMeteringEnabled = true
            guard rec.record() else {
                errorMessage = "无法启动麦克风录制，请检查系统麦克风权限。"
                return
            }
            recorder = rec
            recordedTempURL = tmpURL
            isRecording = true

            let startedAt = Date()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
                Task { @MainActor in
                    guard self.isRecording, let r = self.recorder else { return }
                    r.updateMeters()
                    let db = r.averagePower(forChannel: 0)
                    let norm = max(0.0, min(1.0, Double((db + 55.0) / 50.0)))
                    self.level = norm
                    let sec = Date().timeIntervalSince(startedAt)
                    self.elapsedSec = min(self.maxDuration, sec)
                    if sec >= self.maxDuration {
                        self.stopRecording()
                    }
                }
            }
        } catch {
            errorMessage = "初始化录音器失败：\(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        timer?.invalidate()
        timer = nil
        let dur = elapsedSec
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0
        recordedDuration = dur

        if dur < minDuration {
            errorMessage = String(format: "当前仅录制了 %.1f 秒，不足 3 秒，请重新录制 3~10 秒。", dur)
        } else {
            errorMessage = nil
        }
    }

    private func togglePreview() {
        if isPreviewPlaying {
            stopPreview()
            return
        }
        guard let url = recordedTempURL else { return }
        playURL(url)
    }

    private func playSavedSample() {
        if isPreviewPlaying {
            stopPreview()
            return
        }
        playURL(store.wavURL)
    }

    private func playURL(_ url: URL) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            player = p
            isPreviewPlaying = true
            p.play()
            let dur = max(0.2, p.duration)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(dur + 0.15))
                if self.player === p && !p.isPlaying {
                    self.isPreviewPlaying = false
                }
            }
        } catch {
            errorMessage = "试听失败：\(error.localizedDescription)"
            isPreviewPlaying = false
        }
    }

    private func stopPreview() {
        player?.stop()
        player = nil
        isPreviewPlaying = false
    }

    private func saveRecording() {
        guard let url = recordedTempURL else { return }
        stopPreview()
        do {
            try store.saveRecordedWav(from: url, referenceText: currentPrompt.text)
            try? FileManager.default.removeItem(at: url)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        stopPreview()
        isRecording = false
        // 录完或关闭声纹弹窗后交还给 AudioRoute 统一恢复音频会话与蓝牙耳机路由
        try? AudioRoute.updateSession()
    }
}
