import Foundation
import UIKit
import os

/// 闪退/被系统杀掉的诊断。
///
/// iOS 上 App "自己没了"有好几种原因，系统都不会告诉我们：
///   · 崩溃（Swift 运行时错误、NSException，比如音频引擎的"required condition is false"）
///   · 内存不够被系统杀掉（jetsam）
///   · 卡死被系统杀掉（watchdog）
/// 这里做两件事：
///   1. 装上异常/信号的处理程序，崩之前把原因写进日志文件（同步写，来不及走队列也得写进去）
///   2. 留一个"标记文件"：正常退出会删掉它，下次打开发现还在，就知道上次是不正常结束的
final class CrashGuard {
    static let shared = CrashGuard()

    private let markerURL: URL
    private let crashURL: URL
    private let queue = DispatchQueue(label: "hear.crashguard")

    /// 日志文件的位置（跟 AppLog 写的是同一个文件）
    private static var logFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hear-log.txt")
    }

    /// 现在还能用多少内存（MB）。信号处理程序里也能安全调用
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

    // MARK: - 装上处理器

    /// 在 App 一启动就装上（越早越好，崩了才抓得到）
    func install() {
        installExceptionHandler()
        installSignalHandlers()
    }

    /// ObjC 异常（比如音频引擎的 precondition 失败）走这里
    private func installExceptionHandler() {
        let previous = NSSetUncaughtExceptionHandler { exception in
            let reason = exception.reason ?? "没有原因"
            let name = exception.name.rawValue
            let trace = exception.callStackSymbols.prefix(15).joined(separator: "\n")
            let text = "崩溃：\(name)\n原因：\(reason)\n调用栈：\n\(trace)\n"
            CrashGuard.shared.record(text)
            // 交给原来的处理程序（系统会据此生成崩溃报告）
            if let previous { previous(exception) }
        }
        _ = previous
    }

    /// Swift 运行时的错误（数组越界、强制解包 nil 等）会发 SIGILL/SIGTRAP
    /// 内存访问错误发 SIGSEGV/SIGBUS，主动退出发 SIGABRT
    private func installSignalHandlers() {
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGILL, SIGTRAP, SIGFPE, SIGBUS]
        for sig in signals {
            signal(sig) { signo in
                // 信号处理程序里只能做异步信号安全的操作：写一个固定内容的小文件
                CrashGuard.shared.recordSignal(signo)
                // 恢复默认行为，让系统照常生成崩溃报告
                signal(signo, SIG_DFL)
                raise(signo)
            }
        }
    }

    // MARK: - 写记录

    /// 崩溃信息：直接同步写文件（崩溃时不能再走 AppLog 的队列）
    private func record(_ text: String) {
        queue.sync {
            let line = "[\(Date())] \(text)\n"
            append(line, to: crashURL)
            append(line, to: Self.logFileURL)
        }
    }

    private func recordSignal(_ signo: Int32) {
        queue.sync {
            let line = "[\(Date())] 收到信号 \(signo)（崩溃）\n"
            append(line, to: crashURL)
            append(line, to: Self.logFileURL)
        }
    }

    private func append(_ line: String, to url: URL) {
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        }
    }

    // MARK: - 标记文件

    /// App 启动时调用：上次留下标记说明上次是不正常退出的
    /// 返回上次异常退出时记下来的原因（没有则返回 nil）
    func checkPreviousRun() -> String? {
        guard let data = try? Data(contentsOf: markerURL),
              let m = try? JSONDecoder().decode(Marker.self, from: data) else { return nil }
        // 上次崩溃时写下的原因（如果有）
        var detail = ""
        if let crash = try? String(contentsOf: crashURL, encoding: .utf8), !crash.isEmpty {
            detail = crash
            try? FileManager.default.removeItem(at: crashURL)
        }
        try? FileManager.default.removeItem(at: markerURL)
        var text = "上次退出不正常（可能是崩溃或被系统杀掉）"
        if m.memoryWarning { text += "，退出前收到过内存不足警告" }
        if m.freeMB > 0 { text += "，退出前可用内存 \(m.freeMB) MB" }
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
