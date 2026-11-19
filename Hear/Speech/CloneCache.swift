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
    private let limit = 60

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
        let a = CloneAudio(samples: w.samples, sampleRate: w.sampleRate)
        remember(key, a)
        return a
    }

    /// 存起来
    func put(_ key: String, _ audio: CloneAudio) {
        remember(key, audio)
        let url = dir.appendingPathComponent(fileName(key))
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
