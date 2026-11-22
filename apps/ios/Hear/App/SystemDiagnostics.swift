import Foundation
import MetricKit

/// Stores the most recently received crash report on the device.
final class SystemDiagnostics: NSObject, MXMetricManagerSubscriber {
    private static let shared = SystemDiagnostics()
    private let storage = DispatchQueue(label: "Hear.systemDiagnostics")

    static var crashReportURL: URL {
        URL.cachesDirectory.appendingPathComponent("Hear-crash-report.json")
    }

    static func start() {
        _ = registration
    }

    private static let registration: Void = MXMetricManager.shared.add(shared)

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard AppLog.logEnabledNow,
              let report = payloads
                .filter({ $0.crashDiagnostics?.isEmpty == false })
                .max(by: { $0.timeStampEnd < $1.timeStampEnd }) else { return }
        let data = report.jsonRepresentation()
        let count = report.crashDiagnostics?.count ?? 0
        storage.async {
            do {
                try data.write(to: Self.crashReportURL,
                               options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                hearLog("iOS 系统诊断：收到 \(count) 份崩溃记录，可从运行日志菜单导出")
            } catch {
                hearLog("iOS 系统诊断：崩溃报告保存失败", .warning)
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard AppLog.logEnabledNow else { return }
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let foreground = exits.foregroundExitData
            let background = exits.backgroundExitData
            let watchdog = foreground.cumulativeAppWatchdogExitCount + background.cumulativeAppWatchdogExitCount
            let memoryLimit = foreground.cumulativeMemoryResourceLimitExitCount
                + background.cumulativeMemoryResourceLimitExitCount
            let memoryPressure = background.cumulativeMemoryPressureExitCount
            guard watchdog > 0 || memoryLimit > 0 || memoryPressure > 0 else { continue }
            let date = payload.timeStampEnd.formatted(date: .numeric, time: .shortened)
            hearLog("iOS 系统退出统计（截至 \(date)）：无响应 \(watchdog)，超出内存限额 \(memoryLimit)，后台内存压力 \(memoryPressure)")
        }
    }
}
