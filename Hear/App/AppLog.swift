import Foundation

enum LogLevel: String, CaseIterable {
    case info = "I"
    case warning = "W"
    case error = "E"

    var title: String {
        switch self {
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }
}

struct LogEntry: Identifiable {
    let id: Int
    let time: String
    let level: LogLevel
    let message: String

    var line: String { "[\(time)] [\(level.rawValue)] \(message)" }
}

/// 运行日志：可在“设置 → 日志”开关、设置最大文件大小，并在 App 内实时查看和筛选
@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()
    static let sizeOptions = [10, 50, 100, 500]   // MB

    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var fileBytes: Int64 = 0
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "logEnabled") }
    }
    @Published var maxMB: Int {
        didSet { UserDefaults.standard.set(maxMB, forKey: "logMaxMB"); rotateIfNeeded() }
    }

    private let maxInMemory = 3000
    private var nextID = 0
    private let fileURL: URL
    private let oldURL: URL
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("hear-log.txt")
        oldURL = docs.appendingPathComponent("hear-log.old.txt")
        enabled = UserDefaults.standard.object(forKey: "logEnabled") as? Bool ?? true
        maxMB = UserDefaults.standard.object(forKey: "logMaxMB") as? Int ?? 100
        loadTail()
    }

    // MARK: 写入

    func add(_ message: String, level: LogLevel = .info) {
        guard enabled else { return }
        let e = LogEntry(id: nextID, time: formatter.string(from: Date()), level: level, message: message)
        nextID += 1
        entries.append(e)
        if entries.count > maxInMemory { entries.removeFirst(entries.count - maxInMemory) }
        write(e.line + "\n")
    }

    /// 写文件在后台队列做，别在主线程上做磁盘 IO（不然会影响交互流畅度）
    private let writeQueue = DispatchQueue(label: "hear.log.write", qos: .utility)

    private func write(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        let n = Int64(data.count)
        let url = fileURL
        let old = oldURL
        let limit = Int64(maxMB) * 1_000_000 / 2
        writeQueue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
            // 超过一半就转成"旧日志"，顺手清掉更老的
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            if size > limit {
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
        }
        fileBytes += n
    }

    /// 当前文件超过上限的一半时，把它变成“旧日志”，旧的旧日志删除。
    /// 这样两份文件加起来不会超过设置的最大值。
    private func rotateIfNeeded() {
        let limit = Int64(maxMB) * 1_000_000 / 2
        guard fileBytes > limit else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: oldURL)
        try? fm.moveItem(at: fileURL, to: oldURL)
        fileBytes = 0
    }

    // MARK: 读取

    /// 启动时读入最近约 1MB 日志，闪退后也能看到之前发生了什么
    private func loadTail() {
        guard let h = try? FileHandle(forReadingFrom: fileURL) else { return }
        let size = (try? h.seekToEnd()) ?? 0
        fileBytes = Int64(size)
        let start: UInt64 = size > 1_000_000 ? size - 1_000_000 : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        try? h.close()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // 第一行可能不完整
        entries = lines.suffix(maxInMemory).compactMap { parse($0) }
    }

    /// 解析 “[MM-dd HH:mm:ss] [E] 内容”
    private func parse(_ line: String) -> LogEntry? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let time = String(line[line.index(after: line.startIndex)..<close])
        var rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        var level = LogLevel.info
        let chars = Array(rest)
        if chars.count >= 3, chars[0] == "[", chars[2] == "]", let l = LogLevel(rawValue: String(chars[1])) {
            level = l
            rest = String(chars.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        let e = LogEntry(id: nextID, time: time, level: level, message: rest)
        nextID += 1
        return e
    }

    var totalBytes: Int64 {
        let old = (try? oldURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return fileBytes + Int64(old)
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: oldURL)
        fileBytes = 0
    }
}

/// 任何线程都可以调用
func hearLog(_ message: String, _ level: LogLevel = .info) {
    Task { @MainActor in AppLog.shared.add(message, level: level) }
}
