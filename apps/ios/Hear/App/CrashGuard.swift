import Foundation
import UIKit
import os

/// 闪退/被系统杀掉的诊断。
///
/// iOS 上 App "自己没了"有好几种原因，系统都不会告诉我们：
///   · 崩溃（Swift 运行时错误、NSException，比如音频引擎的"required condition is false"）
///   · 内存不够被系统杀掉（jetsam）
///   · 卡死被系统杀掉（watchdog）
/// 崩溃交给系统生成诊断。这里保留内存标记，并在升级后读取旧版写下的崩溃记录。
final class CrashGuard {
    static let shared = CrashGuard()

    /// 这次运行开始的时间。
    /// 用来分辨"标记文件是上次留下的"还是"就是这次启动自己写的"
    /// （回到前台时也会写标记，不然在后台被系统杀掉就看不出来了；
    ///   但那一次正好撞上刚启动，就会误报"上次退出不正常"）
    private static let processStart = Date()

    private let markerURL: URL
    private let crashURL: URL
    private let queue = DispatchQueue(label: "hear.crashguard")

    /// 现在还能用多少内存（MB）。
    private static var freeMBNow: Int { Int(os_proc_available_memory() / 1_048_576) }

    /// 上次退出前记录的状态（写进标记文件，下次打开时读出来告诉用户）
    private struct Marker: Codable {
        var startedAt: Date
        var memoryWarning: Bool = false
        var freeMB: Int = 0
        var note: String = ""
    }

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        markerURL = docs.appendingPathComponent("hear-running.json")
        crashURL = docs.appendingPathComponent("hear-crash.txt")
    }

    // MARK: - 标记文件

    /// App 启动时调用：上次留下标记说明上次是不正常退出的
    /// 返回上次异常退出时记下来的原因（没有则返回 nil）
    func checkPreviousRun() -> String? {
        var m = (try? Data(contentsOf: markerURL)).flatMap { try? JSONDecoder().decode(Marker.self, from: $0) }
        // 上次崩溃时写下的原因（如果有）
        let detail = (((try? String(contentsOf: crashURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines))
        try? FileManager.default.removeItem(at: markerURL)
        if !detail.isEmpty { try? FileManager.default.removeItem(at: crashURL) }
        // 标记文件是这次启动自己写的（回到前台时也会写），
        // 不是上次留下的，不能当成"上次不正常退出"
        if let mm = m, mm.startedAt >= Self.processStart {
            m = nil
        }
        // 光有"上次留下的标记文件"不算异常：
        // 用户从多任务界面把 App 划掉、或者系统回收后台 App，都属正常，
        // 那样每次打开都报"上次退出不正常"就太吵了。
        // 只有下面这些才算有证据：
        //   · 有崩溃记录（真的崩了）
        //   · 退出前收到过内存不足警告（多半是被系统杀掉的）
        //   · 退出前几乎没内存了（也是被系统杀掉的）
        let hasCrash = !detail.isEmpty
        let memWarning = m?.memoryWarning == true
        let free = m?.freeMB ?? 0
        let lowMem = free > 0 && free < 400
        guard hasCrash || memWarning || lowMem else { return nil }

        var text = "上次退出不正常"
        if hasCrash { text += "（崩溃）" } else { text += "（可能是被系统杀掉）" }
        if memWarning { text += "，退出前收到过内存不足警告" }
        if free > 0 { text += "，退出前可用内存 \(free) MB" }
        if !detail.isEmpty { text += "\n\(detail)" }
        return text
    }

    /// 开始一次新的运行：写标记文件
    func markRunning() {
        let m = Marker(startedAt: Date(), freeMB: Self.freeMBNow)
        if let data = try? JSONEncoder().encode(m) {
            try? data.write(to: markerURL, options: .atomic)
        }
    }

    /// 退出前更新标记（比如收到内存警告了）
    func updateMarker(memoryWarning: Bool = false, note: String = "") {
        queue.sync {
            var m = (try? Data(contentsOf: markerURL)).flatMap { try? JSONDecoder().decode(Marker.self, from: $0) }
                ?? Marker(startedAt: Date())
            if memoryWarning { m.memoryWarning = true }
            if !note.isEmpty { m.note = note }
            m.freeMB = Self.freeMBNow
            if let data = try? JSONEncoder().encode(m) {
                try? data.write(to: markerURL, options: .atomic)
            }
        }
    }

    /// 正常结束（退到后台也算正常，系统随时可能回收后台 App，不算异常）
    func clearMarker() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}
