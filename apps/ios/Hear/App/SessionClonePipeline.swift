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
    var fixedReferenceProvider: (() -> (reference: Reference, preferOverLive: Bool)?)?

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
        let fixedEntry = fixedReferenceProvider?()
        let itemUsesFixed = item.speakerDetails?.useFixedVoiceSample == true
        let anySpeakerBoundToFixed = items.contains { $0.speakerDetails?.useFixedVoiceSample == true }
        let distinctSpeakerCount = Set(items.compactMap(\.speakerID)).count

        // 0. 若该说话人显式开启了「使用我的固定声纹」，直接使用用户录制的固定声纹（本地 ZipVoice + 云端 Qwen3-TTS 通用）
        if itemUsesFixed, let fixedEntry {
            return fixedEntry.reference
        }
        // 单人对话且未单独指定说话人时，遵循设置里的「克隆时优先使用固定声纹」
        if !anySpeakerBoundToFixed, distinctSpeakerCount <= 1, let fixedEntry, fixedEntry.preferOverLive {
            return fixedEntry.reference
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
            // 2. 兜底复用同语种最近一句的参考音（多人对话且已指定固定声纹说话人时，避开固定声纹说话人以免串音）
            for earlier in items[..<index].reversed() where earlier.source == item.source {
                if anySpeakerBoundToFixed && earlier.speakerDetails?.useFixedVoiceSample == true { continue }
                if let ref = references[earlier.id], hasText(ref.text) { return ref }
            }
        }
        // 3. 最终兜底：仅在未把固定声纹绑定给其他说话人时，用固定声纹兜底避免退回系统朗读
        if !anySpeakerBoundToFixed, let fixedEntry {
            return fixedEntry.reference
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
