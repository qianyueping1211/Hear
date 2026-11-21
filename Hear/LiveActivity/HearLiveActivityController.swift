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
    private var lastSentAt = Date.distantPast

    private init() {
        current = Activity<HearLiveActivityAttributes>.activities.first
    }

    func start(_ state: HearLiveActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        latestState = state
        guard current == nil else {
            update(state, force: true)
            return
        }
        Task {
            do {
                current = try Activity.request(
                    attributes: HearLiveActivityAttributes(conversationTitle: "听见实时翻译"),
                    content: content(state),
                    pushType: nil)
            } catch {
                hearLog("灵动岛启动失败：\(error)", .warning)
            }
        }
    }

    /// 系统限制 Live Activity 的刷新频率。实时译文先节流到约每秒一次，
    /// 定稿句子和结束状态可以强制立即刷新。
    func update(_ state: HearLiveActivityAttributes.ContentState, force: Bool = false) {
        latestState = state
        guard current != nil else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastSentAt) < 1.0 {
            guard pendingTask == nil else { return }
            pendingTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, !Task.isCancelled, let state = self.latestState else { return }
                self.pendingTask = nil
                await self.send(state)
            }
            return
        }
        Task { await send(state) }
    }

    func end(_ state: HearLiveActivityAttributes.ContentState?) {
        pendingTask?.cancel()
        pendingTask = nil
        guard let activity = current else { return }
        current = nil
        Task {
            if let state {
                await activity.end(
                    ActivityContent(state: state, staleDate: nil),
                    dismissalPolicy: .after(Date().addingTimeInterval(5)))
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func send(_ state: HearLiveActivityAttributes.ContentState) async {
        guard let current else { return }
        lastSentAt = Date()
        await current.update(content(state))
    }

    private func content(_ state: HearLiveActivityAttributes.ContentState)
        -> ActivityContent<HearLiveActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(90))
    }
#else
    func start(_ state: HearLiveActivityAttributes.ContentState) {}
    func update(_ state: HearLiveActivityAttributes.ContentState, force: Bool = false) {}
    func end(_ state: HearLiveActivityAttributes.ContentState?) {}
#endif
}
