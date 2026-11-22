import Foundation

/// The timer owns the recovery decision. A Core ML call may ignore cancellation,
/// so the UI must be able to leave recovery without awaiting that call's result.
@MainActor
final class SenseVoiceRecovery {
    enum Outcome: Equatable { case recovered, failed, timedOut }

    static let bufferedSegments = 3
    private var run: UUID?
    private var repair: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    var isActive: Bool { run != nil }

    func start(timeout: Duration = .seconds(12),
               repair action: @escaping @Sendable () async throws -> Void,
               finished: @escaping @MainActor (Outcome) -> Void) {
        guard run == nil else { return }
        let id = UUID()
        run = id
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repair = Task { [weak self] in
            let outcome: Outcome
            do {
                try await action()
                outcome = .recovered
            } catch {
                outcome = .failed
            }
            self?.complete(id, outcome: ContinuousClock.now >= deadline ? .timedOut : outcome, finished: finished)
        }
        timer = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: ContinuousClock()) } catch { return }
            self?.complete(id, outcome: .timedOut, finished: finished)
        }
    }

    private func complete(_ id: UUID, outcome: Outcome, finished: @MainActor (Outcome) -> Void) {
        guard run == id else { return }
        cancel()
        finished(outcome)
    }

    func cancel() {
        run = nil
        repair?.cancel()
        timer?.cancel()
        repair = nil
        timer = nil
    }
}
