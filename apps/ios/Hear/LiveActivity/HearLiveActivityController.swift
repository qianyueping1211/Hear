import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

@MainActor
final class HearLiveActivityController {
    static let shared = HearLiveActivityController()

#if canImport(ActivityKit)
    private var current: Activity<HearLiveActivityAttributes>?
    private var pendingTask: Task<Void, Never>?
    private var latestState: HearLiveActivityAttributes.ContentState?
    private var latestAutoExpand = false
    private var lastSentAt = Date.distantPast
    private var lastAlertKey = ""
    private var lastAlertAt = Date.distantPast

    private init() {
        dismissAll()
    }

    /// Clear activity tokens still owned by iOS, including those from a previous process.
    func dismissAll() {
        pendingTask?.cancel()
        pendingTask = nil
        latestState = nil
        latestAutoExpand = false
        lastAlertKey = ""
        current = nil
        let activities = Activity<HearLiveActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        Task.detached {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func start(_ state: HearLiveActivityAttributes.ContentState) {
        end(nil)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            current = try Activity.request(
                attributes: HearLiveActivityAttributes(conversationTitle: "听见实时翻译"),
                content: content(state), pushType: nil)
            lastSentAt = Date()
            lastAlertKey = ""
        } catch {
            hearLog("灵动岛启动失败：\(error)", .warning)
        }
    }

    func update(_ state: HearLiveActivityAttributes.ContentState, autoExpand: Bool = false) {
        guard let activity = current, activity.activityState != .ended,
              activity.activityState != .dismissed else { return }
        latestState = state
        latestAutoExpand = autoExpand
        guard pendingTask == nil else { return }
        let delay = max(0, 1 - Date().timeIntervalSince(lastSentAt))
        pendingTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled, self.current?.id == activity.id,
                  let latest = self.latestState else { return }
            self.pendingTask = nil
            self.lastSentAt = Date()
            let alert = self.makeAlertIfNeeded(for: latest, autoExpand: self.latestAutoExpand)
            await activity.update(self.content(latest), alertConfiguration: alert)
        }
    }

    private func makeAlertIfNeeded(for state: HearLiveActivityAttributes.ContentState,
                                   autoExpand: Bool) -> AlertConfiguration? {
        guard autoExpand else { return nil }
        let bodyText = state.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceText = state.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = bodyText.isEmpty ? sourceText : bodyText
        guard !effective.isEmpty, effective != "…" else { return nil }
        let key = "\(sourceText)|\(bodyText)"
        guard key != lastAlertKey else { return nil }
        guard Date().timeIntervalSince(lastAlertAt) >= 2.5 else { return nil }
        lastAlertKey = key
        lastAlertAt = Date()
        let title = state.speaker ?? "\(state.sourceLanguage) → \(state.targetLanguage)"
        return AlertConfiguration(
            title: LocalizedStringResource(stringLiteral: title),
            body: LocalizedStringResource(stringLiteral: effective),
            sound: .named("hear_silent.wav")
        )
    }

    func end(_ state: HearLiveActivityAttributes.ContentState?) {
        pendingTask?.cancel()
        pendingTask = nil
        latestState = nil
        guard let activity = current else { return }
        current = nil
        Task {
            if let state {
                await activity.end(ActivityContent(state: state, staleDate: nil),
                                   dismissalPolicy: .after(Date().addingTimeInterval(5)))
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func content(_ state: HearLiveActivityAttributes.ContentState)
        -> ActivityContent<HearLiveActivityAttributes.ContentState> {
        // Silence is normal while the microphone is still open.
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(180))
    }
#else
    func start(_ state: HearLiveActivityAttributes.ContentState) {}
    func update(_ state: HearLiveActivityAttributes.ContentState, autoExpand: Bool = false) {}
    func end(_ state: HearLiveActivityAttributes.ContentState?) {}
    func dismissAll() {}
#endif
}
