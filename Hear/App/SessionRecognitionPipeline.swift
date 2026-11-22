import Foundation

/// Coordinates final recognition, model recovery, and priority over previews.
@MainActor
final class SessionRecognitionPipeline<Job> {
    let queue = SessionJobQueue<Job>()
    private let recovery = SenseVoiceRecovery()
    private var finalUses: Set<UUID> = []

    var isRecovering: Bool { recovery.isActive }
    var canPreview: Bool { finalUses.isEmpty && queue.isIdle }

    func beginFinal() -> UUID {
        let id = UUID()
        finalUses.insert(id)
        return id
    }

    func endFinal(_ id: UUID) { finalUses.remove(id) }

    func recover(repair: @escaping @Sendable () async throws -> Void,
                 finished: @escaping @MainActor (SenseVoiceRecovery.Outcome) -> Void) {
        guard !recovery.isActive else { return }
        queue.pause()
        recovery.start(repair: repair) { [weak self] outcome in
            if outcome == .recovered { self?.queue.resume() }
            finished(outcome)
        }
        keepRecoveryBuffer()
    }

    func keepRecoveryBuffer() {
        if recovery.isActive { queue.keepPending(SenseVoiceRecovery.bufferedSegments) }
    }

    func cancel() {
        queue.cancel()
        recovery.cancel()
        finalUses.removeAll()
    }
}
