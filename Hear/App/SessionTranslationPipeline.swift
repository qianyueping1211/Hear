import Foundation

/// Owns outstanding translations and the optional single correction. The session
/// still publishes text and verifies the conversation and item before writing it.
@MainActor
final class SessionTranslationPipeline<Job> {
    private let queue = SessionJobQueue<Job>()
    private var pages: [UUID: UUID] = [:]
    private var correction: Task<Void, Never>?

    var isIdle: Bool { queue.isIdle }
    var pendingPages: [UUID: UUID] { pages }

    func submit(_ job: Job, item: UUID, page: UUID,
                process: @escaping @MainActor (Job) async -> Void,
                timedOut: @escaping @MainActor (Job) -> Void) {
        pages[item] = page
        queue.submit(job, process: process, timedOut: timedOut)
    }

    func submitted(_ item: UUID) -> Bool { pages[item] != nil }

    func finished(_ item: UUID) { pages[item] = nil }

    func startCorrection(_ work: @escaping @MainActor () async -> Void) {
        guard correction == nil else { return }
        correction = Task { [weak self] in
            defer { self?.correction = nil }
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    func cancelCorrection() {
        // A pending correction cleans up its item before a new one starts.
        correction?.cancel()
    }

    func cancelTranslations() {
        queue.cancel()
        pages.removeAll()
    }
}
