import Foundation
import CryptoKit

/// 管理本地模型文件：下载、导入、查找
enum ModelManager {
    static let ggufRepo = "tencent/Hy-MT2-1.8B-GGUF"
    /// 按顺序优先选择的量化版本（8bit 质量最好；1.25bit/2bit 需要特殊内核，排除）
    static let preferredQuants = ["Q8_0", "Q6_K", "Q5_K_M", "Q4_K_M"]

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var modelsDir: URL {
        let d = documents.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    // MARK: 翻译模型

    static func installedGGUFs() -> [URL] {
        let fm = FileManager.default
        let dirs = [modelsDir, documents]
        return dirs.flatMap { d in
            ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .filter { $0.pathExtension.lowercased() == "gguf" }
        }
    }

    static func currentGGUF() -> URL? {
        let all = installedGGUFs()
        if let name = UserDefaults.standard.string(forKey: "ggufName"),
           let hit = all.first(where: { $0.lastPathComponent == name }) {
            return hit
        }
        return all.first
    }

    static func select(_ url: URL) {
        UserDefaults.standard.set(url.lastPathComponent, forKey: "ggufName")
    }

    static func stageGGUF(from src: URL) throws -> URL {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        try checkGGUF(src)
        let staging = modelsDir.appendingPathComponent(".import-\(UUID().uuidString).gguf")
        do {
            try FileManager.default.copyItem(at: src, to: staging)
            return staging
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// 确认这个文件真的是 GGUF（不是的话不能拿去替换正在用的模型）
    static func checkGGUF(_ url: URL) throws {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            throw NSError(domain: "Hear", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "读不了这个文件：\(url.lastPathComponent)"])
        }
        defer { try? fh.close() }
        let head = Array((try? fh.read(upToCount: 24)) ?? Data())
        guard head.count == 24, head.prefix(4).elementsEqual([71, 71, 85, 70]),
              [2, 3].contains(head[4]), head[5..<8].allSatisfy({ $0 == 0 }),
              head[8..<16].contains(where: { $0 != 0 }), fileSize(url) > 24 else {
            throw NSError(domain: "Hear", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "这个 GGUF 文件的头部无效或不完整"])
        }
    }

    private struct HFModelInfo: Decodable {
        struct Sibling: Decodable { let rfilename: String }
        let siblings: [Sibling]
    }

    static func downloadGGUF(host: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let api = URL(string: "https://\(host)/api/models/\(ggufRepo)")!
        let (data, _) = try await URLSession.shared.data(from: api)
        let files = try JSONDecoder().decode(HFModelInfo.self, from: data).siblings
            .map(\.rfilename)
            .filter { $0.lowercased().hasSuffix(".gguf") }

        var chosen: String?
        for q in preferredQuants {
            if let f = files.first(where: { $0.uppercased().contains(q) }) { chosen = f; break }
        }
        if chosen == nil {
            chosen = files.first { f in
                let u = f.uppercased()
                return !u.contains("1.25") && !u.contains("2BIT") && !u.contains("IMATRIX")
            }
        }
        guard let file = chosen else {
            throw NSError(domain: "Hear", code: 2, userInfo: [NSLocalizedDescriptionKey: "仓库里没有找到可用的 GGUF 文件"])
        }

        let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        let url = URL(string: "https://\(host)/\(ggufRepo)/resolve/main/\(encoded)")!
        let dst = modelsDir.appendingPathComponent((file as NSString).lastPathComponent)
        let stage = modelsDir.appendingPathComponent(".download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        try await FileDownloader().download(url, to: stage, progress: progress)
        // 下完了先验一验：这到底是不是 GGUF 模型。
        // 有些地址会返回 HTTP 200 但内容是个网页或者一段提示——
        // 那种文件装上去，模型加载时才炸，排查起来很麻烦。
        do {
            try checkGGUF(stage)
        } catch {
            throw NSError(domain: "Hear", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "下下来的不是模型文件（开头不是 GGUF），已经删掉了，没动原来那个模型"])
        }
        try Task.checkCancellation()
        try installModelFile(stage, at: dst)
        select(dst)
        return dst
    }

    static func installModelFile(_ staging: URL, at destination: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: destination)
        }
    }

    /// 删除当前使用的翻译模型文件（用于重新下载）
    static func deleteCurrentGGUF() {
        if let u = currentGGUF() { try? FileManager.default.removeItem(at: u) }
        UserDefaults.standard.removeObject(forKey: "ggufName")
    }

    // MARK: 大小统计

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += fileSize(f) }
        return total
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

}

/// 带进度的大文件下载。
/// 网络断了会自动重试，并且能断点续传（HF 的 CDN 传输大文件时很容易中途断）。
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private final class DownloadCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private let saving = DispatchGroup()
        private var task: URLSessionDownloadTask?
        private var cancelled = false

        func start(_ running: URLSessionDownloadTask) {
            lock.lock()
            task = running
            let alreadyCancelled = cancelled
            if !alreadyCancelled { running.resume() }
            lock.unlock()
            if alreadyCancelled { running.cancel() }
        }

        func cancel(savingTo url: URL) {
            lock.lock()
            cancelled = true
            let running = task
            if running != nil { saving.enter() }
            lock.unlock()
            running?.cancel(byProducingResumeData: { [saving] data in
                if let data, !data.isEmpty { try? data.write(to: url, options: .atomic) }
                saving.leave()
            })
        }

        func waitForResumeData() async {
            await withCheckedContinuation { continuation in
                saving.notify(queue: .global(qos: .utility)) { continuation.resume() }
            }
        }
    }

    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL!
    private var progress: ((Double) -> Void)?
    private var moveError: Error?
    /// 上次失败时系统给的续传数据（断点续传用）
    private var resumeData: Data?
    /// 已经重试了几次
    private var retryCount = 0
    private let maxRetries = 8
    private var sourceURL: URL!

    private static func resumeFile(for url: URL) -> URL {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearModelTransfers", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return cache.appendingPathComponent(key)
    }

    func download(_ url: URL, to dst: URL, progress: @escaping (Double) -> Void) async throws {
        destination = dst
        self.progress = progress
        sourceURL = url
        let savedResume = Self.resumeFile(for: url)
        resumeData = try? Data(contentsOf: savedResume)
        retryCount = 0
        // 网络中断（-1005）、超时（-1001）这类错误会自动重试，能续传就从断点继续
        var lastError: Error?
        var retriedWithoutSavedData = false
        while retryCount <= maxRetries {
            try Task.checkCancellation()
            let wasResuming = resumeData != nil
            do {
                try await run(savingResumeTo: savedResume)
                try? FileManager.default.removeItem(at: savedResume)
                return
            } catch {
                try Task.checkCancellation()
                lastError = error
                // 这个错误重试也没用（比如 404、没权限）
                let code = (error as NSError).code
                if code == -1005 || code == -1001 || code == -1003 || code == NSURLErrorNetworkConnectionLost {
                    retryCount += 1
                    if retryCount > maxRetries { break }
                    // 退避等待：网络抖一下的话过几秒就好了
                    let wait = min(pow(2.0, Double(retryCount)), 30)
                    hearLog("下载中断，第 \(retryCount) 次重试（\(wait) 秒后）", .warning)
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                if wasResuming, !retriedWithoutSavedData {
                    retriedWithoutSavedData = true
                    resumeData = nil
                    try? FileManager.default.removeItem(at: savedResume)
                    continue
                }
                throw error
            }
        }
        throw lastError ?? NSError(domain: "Hear", code: 30,
                                  userInfo: [NSLocalizedDescriptionKey: "下载失败"])
    }

    /// 跑一次下载；失败且还能重试就自动重来
    private func run(savingResumeTo url: URL) async throws {
        // 超时放宽：大文件在网络慢的时候容易触发默认的 60 秒超时
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 60 * 60 * 2      // 整个下载最多 2 小时
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let cancellation = DownloadCancellation()
        moveError = nil
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    continuation = c
                    let task = resumeData.map { session.downloadTask(withResumeData: $0) }
                        ?? session.downloadTask(with: sourceURL)
                    cancellation.start(task)
                }
            } onCancel: {
                cancellation.cancel(savingTo: url)
            }
        } catch {
            if Task.isCancelled { await cancellation.waitForResumeData() }
            throw error
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let done = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progress?(min(done, 1.0))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moveError = NSError(domain: "Hear", code: http.statusCode,
                                userInfo: [NSLocalizedDescriptionKey: "下载失败（HTTP \(http.statusCode)）"])
            return
        }
        do {
            // 换名替换：原来那个先挪到一边，新的放到位了再删它
            // （直接删掉再移动的话，中途失败就两头都没了）
            let fm = FileManager.default
            let tmp = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).downloading")
            try? fm.removeItem(at: tmp)
            try fm.moveItem(at: location, to: tmp)
            let old = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).old")
            try? fm.removeItem(at: old)
            if fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: destination, to: old)
            }
            do {
                try fm.moveItem(at: tmp, to: destination)
            } catch {
                if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: destination) }
                try? fm.removeItem(at: tmp)
                throw error
            }
            try? fm.removeItem(at: old)
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error ?? moveError {
            // 拿到系统的续传数据（网络中断时会给），下次从断点继续
            let ns = e as NSError
            if let rd = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, rd.count > 0 {
                resumeData = rd
            }
            continuation?.resume(throwing: e)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
