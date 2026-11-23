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
        if seconds >= 0.6 {
            // 超过 10 秒自动截取前 10 秒作为参考音，避免长句直接丢弃样本退回系统朗读
            let clipped = seconds > 10.0 ? Array(samples.prefix(160_000)) : samples
            references[id] = (clipped, text)
            issues[id] = nil
        } else {
            references[id] = nil
            issues[id] = enabled ? "这句太短，尝试复用同语种上一句参考音" : nil
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
        // 0. 若用户录制了「我的固定声纹样本」且开启优先复用，本地 ZipVoice 与云端 Qwen3-TTS 均直接使用该高质样本
        let fixedStore = FixedVoiceSampleStore.shared
        if fixedStore.preferOverLive, let fixed = fixedStore.loadReference() {
            return fixed
        }
        if let own = references[item.id] {
            return (own.samples, hasText(own.text) ? own.text : item.sourceText)
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            // 1. 优先复用同一说话人且同语种的前文参考音
            if let speaker = item.speakerID {
                for earlier in items[..<index].reversed() where earlier.speakerID == speaker && earlier.source == item.source {
                    if let ref = references[earlier.id], hasText(ref.text) { return ref }
                }
            }
            // 2. 未开启说话人区分或同说话人无前文样本时，兜底复用同语种最近一句的参考音（短词如 OK/谢谢 也能克隆）
            for earlier in items[..<index].reversed() where earlier.source == item.source {
                if let ref = references[earlier.id], hasText(ref.text) { return ref }
            }
        }
        // 3. 最终兜底：若用户已录制固定声纹样本，则始终可用，避免退回系统朗读
        if let fixed = fixedStore.loadReference() {
            return fixed
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
