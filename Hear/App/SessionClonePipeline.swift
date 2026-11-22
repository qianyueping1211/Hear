import Foundation

@MainActor
final class SessionClonePipeline {
    typealias Reference = (samples: [Float], text: String)
    typealias Work = Task<CloneAudio?, Never>

    private var references: [UUID: Reference] = [:]
    private var referenceOrder: [UUID] = []
    private var issues: [UUID: String] = [:]
    private var pending: [UUID: (token: UUID, task: Work)] = [:]
    private var timedOut: Set<UUID> = []
    var onWorkChanged: (([UUID: UUID]) -> Void)?

    func remember(_ id: UUID, samples: [Float], text: String, enabled: Bool) {
        let seconds = Double(samples.count) / 16_000
        if enabled && (1.5...12).contains(seconds) {
            references[id] = (samples, text)
            issues[id] = nil
        } else {
            references[id] = nil
            issues[id] = enabled
                ? (seconds > 12 ? "这句太长，没有完整的参考样本" : "这句太短，没有完整的参考样本")
                : "录音的时候声音克隆开关是关的"
        }
        referenceOrder.removeAll { $0 == id }
        referenceOrder.append(id)
        while referenceOrder.count > 30 {
            let oldest = referenceOrder.removeFirst()
            references[oldest] = nil
            issues[oldest] = nil
            cancel(oldest)
        }
    }

    func reference(for item: TranslationItem, in items: [TranslationItem],
                   hasText: (String) -> Bool) -> Reference? {
        if let own = references[item.id] {
            return (own.samples, hasText(own.text) ? own.text : item.sourceText)
        }
        guard let speaker = item.speakerID, let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        for earlier in items[..<index].reversed() where earlier.speakerID == speaker && earlier.source == item.source {
            if let ref = references[earlier.id], hasText(ref.text) { return ref }
        }
        return nil
    }

    func issue(for id: UUID) -> String? { issues[id] }

    func existing(_ id: UUID) -> Work? { pending[id]?.task }

    func isCurrent(_ id: UUID, token: UUID) -> Bool { pending[id]?.token == token }

    func didTimeOut(_ id: UUID) -> Bool { timedOut.contains(id) }

    func markTimedOut(_ id: UUID, token: UUID) {
        if isCurrent(id, token: token) { timedOut.insert(id) }
    }

    func allowRetry(_ id: UUID) { timedOut.remove(id) }

    func start(_ id: UUID, makeTask: (UUID) -> Work) -> Work {
        if let existing = existing(id) { return existing }
        let token = UUID()
        let work = makeTask(token)
        pending[id] = (token, work)
        notify()
        Task { [weak self] in
            _ = await work.value
            guard let self, self.isCurrent(id, token: token) else { return }
            self.pending[id] = nil
            self.notify()
        }
        return work
    }

    func cancel(_ id: UUID) {
        allowRetry(id)
        guard let removed = pending.removeValue(forKey: id) else { return }
        removed.task.cancel()
        notify()
    }

    func cancelAll() {
        timedOut.removeAll()
        guard !pending.isEmpty else { return }
        for entry in pending.values { entry.task.cancel() }
        pending.removeAll()
        notify()
    }

    func reset() {
        cancelAll()
        references.removeAll()
        referenceOrder.removeAll()
        issues.removeAll()
    }

    private func notify() { onWorkChanged?(pending.mapValues { $0.token }) }
}
