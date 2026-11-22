import Foundation

enum PerformanceLog {
    static let enabledKey = "performanceLogEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey) && AppLog.logEnabledNow
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = start.duration(to: .now).components
        return elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
    }

    static func record(_ stage: String, engine: String, since start: ContinuousClock.Instant?,
                       outcome: String? = nil) {
        guard let start, isEnabled else { return }
        let status = outcome.map { " · \($0)" } ?? ""
        hearLog("耗时 · \(stage) · \(engine) · \(milliseconds(since: start)) ms\(status)")
    }
}
