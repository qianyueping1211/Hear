import AVFoundation
import Foundation

/// 历史对话完整录音播放器：支持播放、暂停、继续、快进/快退、倍速与进度拖动，
/// 自动优先读本地缓存，本地上传后已清理时直接从 iCloud recordings/ 子文件夹加载播放。
@MainActor
final class ConversationAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var hasAudio = false
    @Published private(set) var isDownloadingFromCloud = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var playbackRate: Float = 1.0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedID: UUID?
    private var loadTask: Task<Void, Never>?

    var isPausedMidway: Bool {
        !isPlaying && currentTime > 0.05 && currentTime < max(0, duration - 0.15)
    }

    func load(conversationID: UUID) {
        if loadedID == conversationID, player != nil { return }
        stop()
        loadTask?.cancel()
        loadTask = nil
        loadedID = conversationID

        // 1. 优先读取本地缓存（尚未上传或正在离线暂存）
        if ConversationStore.shared.hasLocalAudioFile(conversationID) {
            let localURL = ConversationStore.audioFileURL(for: conversationID)
            openPlayer(at: localURL)
            return
        }

        // 2. 本地缓存上传成功后已清理：从 iCloud recordings/ 子文件夹加载或按需拉取
        guard CloudSync.shared.hasCloudRecording(conversationID) else {
            clearPlayer()
            return
        }
        if let cloudURL = CloudSync.shared.cloudRecordingURL(for: conversationID),
           FileManager.default.fileExists(atPath: cloudURL.path) {
            openPlayer(at: cloudURL)
            return
        }

        hasAudio = true
        isDownloadingFromCloud = true
        loadTask = Task { [weak self] in
            let readyURL = await CloudSync.shared.prepareCloudRecordingForPlayback(conversationID)
            guard let self, !Task.isCancelled, self.loadedID == conversationID else { return }
            self.isDownloadingFromCloud = false
            if let readyURL {
                self.openPlayer(at: readyURL)
            } else {
                self.clearPlayer()
            }
        }
    }

    private func openPlayer(at url: URL) {
        ConversationAudioRecorder.repairWavHeaderIfNeeded(at: url)
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.enableRate = true
            p.rate = playbackRate
            p.prepareToPlay()
            player = p
            duration = max(0, p.duration)
            currentTime = 0
            isDownloadingFromCloud = false
            hasAudio = duration > 0.05
            if !hasAudio { clearPlayer() }
        } catch {
            hearLog("加载完整录音失败：\(error)", .warning)
            clearPlayer()
        }
    }

    func play() {
        guard let p = player, hasAudio else { return }
        AudioRoute.speaking = true
        try? AudioRoute.updateSession()
        if currentTime >= duration - 0.08 {
            p.currentTime = 0
            currentTime = 0
        }
        p.rate = playbackRate
        if p.play() {
            isPlaying = true
            startTimer()
        } else {
            AudioRoute.speaking = false
            isPlaying = false
        }
    }

    func pause() {
        guard let p = player else { return }
        p.pause()
        currentTime = p.currentTime
        isPlaying = false
        stopTimer()
        AudioRoute.speaking = false
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to seconds: Double, autoPlay: Bool? = nil) {
        guard let p = player, hasAudio else { return }
        let clamped = max(0, min(duration, seconds))
        p.currentTime = clamped
        currentTime = clamped
        if let autoPlay {
            if autoPlay {
                if !isPlaying { play() }
            } else if isPlaying {
                pause()
            }
        }
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func cycleRate() {
        let rates: [Float] = [1.0, 1.25, 1.5, 2.0]
        if let idx = rates.firstIndex(of: playbackRate) {
            playbackRate = rates[(idx + 1) % rates.count]
        } else {
            playbackRate = 1.0
        }
        if let p = player {
            p.rate = playbackRate
            if isPlaying { p.play() }
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        isDownloadingFromCloud = false
        stopTimer()
        player?.stop()
        if isPlaying { AudioRoute.speaking = false }
        isPlaying = false
        currentTime = 0
    }

    private func clearPlayer() {
        stopTimer()
        player = nil
        hasAudio = false
        isDownloadingFromCloud = false
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let p = self.player, self.isPlaying else { return }
                self.currentTime = p.currentTime
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stopTimer()
            self.isPlaying = false
            self.currentTime = self.duration
            AudioRoute.speaking = false
        }
    }

    static func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
