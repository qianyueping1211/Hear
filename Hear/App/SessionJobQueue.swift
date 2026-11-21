import Foundation

/// One worker owns a queue generation. Cancellation invalidates ownership before
/// a replacement can start, including when the old engine returns late.
@MainActor
final class SessionJobQueue<Job> {
    private final class Completion {
        var finished = false
    }

    private var pending: [Job] = []
    private var worker: Task<Void, Never>?
    private var generation = 0
    private let timeout: Duration

    init(timeout: Duration = .seconds(150)) {
        self.timeout = timeout
    }

    var isIdle: Bool { worker == nil }
    var hasPendingJobs: Bool { !pending.isEmpty }

    func cancel() {
        generation += 1
        worker?.cancel()
        worker = nil
        pending.removeAll()
    }

    func submit(_ job: Job, process: @escaping @MainActor (Job) async -> Void,
                timedOut: @escaping @MainActor (Job) -> Void) {
        pending.append(job)
        guard worker == nil else { return }
        let round = generation
        worker = Task { [weak self] in
            guard let self else { return }
            await self.drain(round, process: process, timedOut: timedOut)
        }
    }

    private func drain(_ round: Int, process: @escaping @MainActor (Job) async -> Void,
                       timedOut: @escaping @MainActor (Job) -> Void) async {
        defer { if generation == round { worker = nil } }
        let clock = ContinuousClock()
        while generation == round, !Task.isCancelled, !pending.isEmpty {
            let job = pending.removeFirst()
            let completion = Completion()
            let task = Task {
                defer { completion.finished = true }
                await process(job)
            }
            let deadline = clock.now.advanced(by: timeout)
            while !completion.finished, clock.now < deadline, !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { break }
            }
            guard !completion.finished else { continue }
            task.cancel()
            guard generation == round, !Task.isCancelled else { return }
            timedOut(job)
        }
    }
}
