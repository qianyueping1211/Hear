import Foundation
import CryptoKit

/// 声音克隆的缓存。
///
/// 同一句话（同一语言）生成过一次就存下来，下次再播直接放，不用再等模型算一遍。
/// 存在磁盘上，所以重开 App、翻历史记录重播的时候都是秒出。
actor CloneCache {
    static let shared = CloneCache()

    /// 缓存放在 Application Support/CloneCache
    private let dir: URL
    /// 内存里再留一份 recently used 的，命中就不用读盘
    private var memory: [String: CloneAudio] = [:]
    private var order: [String] = []
    // 生成音频还会落盘缓存，内存只保留最近几段；
    // 避免三个本地模型同时运行时再占住几十 MB 音频。
    private let limit = 16

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("CloneCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 文件名用内容的哈希（Swift 自带的 hashValue 每次启动都不一样，不能用）
    private func fileName(_ key: String) -> String {
        let h = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return h + ".wav"
    }

    /// 取缓存里的声音，没有就是 nil
    func get(_ key: String) -> CloneAudio? {
        if let a = memory[key] { return a }
        let url = dir.appendingPathComponent(fileName(key))
        guard let data = try? Data(contentsOf: url),
              let w = Wav.decode(data), !w.samples.isEmpty else { return nil }
        guard let trimmed = checked(CloneAudio(samples: w.samples, sampleRate: w.sampleRate)) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        if trimmed.leading > 0 || trimmed.trailing > 0 { write(trimmed.audio, to: url) }
        remember(key, trimmed.audio)
        return trimmed.audio
    }

    /// 存起来
    func put(_ key: String, _ audio: CloneAudio) -> CloneAudio? {
        guard let trimmed = checked(audio) else { return nil }
        remember(key, trimmed.audio)
        write(trimmed.audio, to: dir.appendingPathComponent(fileName(key)))
        return trimmed.audio
    }

    private func checked(_ audio: CloneAudio) -> (audio: CloneAudio, leading: Int, trailing: Int)? {
        guard let trimmed = audio.trimmingEdgeSilence() else {
            hearLog("声音克隆：音频为空、近似静音或格式无效", .warning)
            return nil
        }
        if trimmed.leading > 0 || trimmed.trailing > 0 {
            let rate = Double(audio.sampleRate)
            let leading = String(format: "%.2f", Double(trimmed.leading) / rate)
            let trailing = String(format: "%.2f", Double(trimmed.trailing) / rate)
            hearLog("声音克隆：裁掉开头 \(leading) 秒、结尾 \(trailing) 秒静音")
        }
        return trimmed
    }

    private func write(_ audio: CloneAudio, to url: URL) {
        let wav = Wav.encode(samples: audio.samples, sampleRate: audio.sampleRate)
        try? wav.write(to: url, options: .atomic)
    }

    /// 清空缓存
    func clear() {
        memory.removeAll()
        order.removeAll()
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for i in items { try? FileManager.default.removeItem(at: i) }
    }

    private func remember(_ key: String, _ a: CloneAudio) {
        if memory[key] == nil { order.append(key) }
        memory[key] = a
        while order.count > limit { memory.removeValue(forKey: order.removeFirst()) }
    }
}
