import Foundation

/// 运行日志：在“设置 → 运行日志”里查看，方便排查卡住或报错
@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()

    @Published private(set) var lines: [String] = []

    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("hear-log.txt")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    private init() {
        // 读入上次运行的日志（最多 300 行），这样闪退后也能看到之前发生了什么
        if let s = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = Array(s.split(separator: "\n").suffix(300).map(String.init))
        }
    }

    func add(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: fileURL) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    var text: String { lines.joined(separator: "\n") }

    func clear() {
        lines.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// 任何线程都可以调用
func hearLog(_ message: String) {
    Task { @MainActor in AppLog.shared.add(message) }
}
