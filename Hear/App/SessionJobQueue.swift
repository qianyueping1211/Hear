import Foundation

/// One worker owns a queue generation. Cancellation invalidates ownership before
/// a replacement can start, including when the old engine returns late.
@MainActor
final class SessionJobQueue<Job> {
    private final class Completion {
        var finished = false
    }

    private struct Entry {
        let job: Job
        let timeout: Duration
        let process: @MainActor (Job) async -> Void
        let timedOut: @MainActor (Job) -> Void
    }

    private var pending: [Entry] = []
    private var worker: Task<Void, Never>?
    private var generation = 0
    private let timeout: Duration

    init(timeout: Duration = .seconds(150)) {
        self.timeout = timeout
    }

    var isIdle: Bool { worker == nil }
    var hasPendingJobs: Bool { !pending.isEmpty }
    var pendingCount: Int { pending.count }

    func cancel() {
        generation += 1
        worker?.cancel()
        worker = nil
        pending.removeAll()
    }

    func submit(_ job: Job, timeout: Duration? = nil, process: @escaping @MainActor (Job) async -> Void,
                timedOut: @escaping @MainActor (Job) -> Void) {
        pending.append(Entry(job: job, timeout: timeout ?? self.timeout, process: process, timedOut: timedOut))
        guard worker == nil else { return }
        let round = generation
        worker = Task { [weak self] in
            guard let self else { return }
            await self.drain(round)
        }
    }

    private func drain(_ round: Int) async {
        defer { if generation == round { worker = nil } }
        let clock = ContinuousClock()
        while generation == round, !Task.isCancelled, !pending.isEmpty {
            let entry = pending.removeFirst()
            let completion = Completion()
            let task = Task {
                defer { completion.finished = true }
                await entry.process(entry.job)
            }
            let deadline = clock.now.advanced(by: entry.timeout)
            while !completion.finished, clock.now < deadline, !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { break }
            }
            guard !completion.finished else { continue }
            task.cancel()
            guard generation == round, !Task.isCancelled else { return }
            entry.timedOut(entry.job)
        }
    }
}
