import Foundation

/// Each lane keeps the newest pending input. Invalidated workers can finish
/// late without clearing a replacement worker or taking its snapshot.
@MainActor
final class LatestPreviewWork<Input> {
    private var pending: Input?
    private var task: Task<Void, Never>?
    private var owner: UUID?

    func submit(_ input: Input, consume: @escaping @MainActor (UUID) async -> Void) {
        pending = input
        guard task == nil else { return }
        let id = UUID()
        owner = id
        task = Task { [weak self] in
            defer {
                if self?.owns(id) == true {
                    self?.task = nil
                    self?.owner = nil
                }
            }
            await consume(id)
        }
    }

    func owns(_ id: UUID) -> Bool { owner == id }

    func next(for id: UUID) -> Input? {
        guard owns(id) else { return nil }
        defer { pending = nil }
        return pending
    }

    func cancel() {
        owner = nil
        task?.cancel()
        task = nil
        pending = nil
    }
}

@MainActor
final class SessionPreviewPipeline {
    let recognition = LatestPreviewWork<(id: Int, samples: [Float])>()
    let translation = LatestPreviewWork<(id: Int, text: String, src: Language, tgt: Language)>()
    var textBySegment: [Int: String] = [:]
    var translationRequest: UUID?
    var cloudRecognitionRetryAt: ContinuousClock.Instant?
    var cloudTranslationRetryAt: ContinuousClock.Instant?

    static func merge(_ old: String, _ new: String) -> String {
        if old.isEmpty { return new }
        if new.hasPrefix(old) { return new }          // 新的更长
        if old.hasPrefix(new) { return old }          // 新的更短（截断）
        let maxOverlap = min(old.count, new.count)
        if maxOverlap > 0 {
            for n in stride(from: maxOverlap, through: 2, by: -1) {
                if old.hasSuffix(String(new.prefix(n))) {
                    return old + String(new.dropFirst(n))
                }
            }
        }
        // 实在对不上：标出来，别装作是一句完整的话
        return old + " … " + new
    }
}
