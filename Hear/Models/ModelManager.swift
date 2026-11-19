import Foundation
import WhisperKit

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
    static var whisperBase: URL {
        documents.appendingPathComponent("huggingface", isDirectory: true)
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

    static func importGGUF(from src: URL) throws -> URL {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        let dst = modelsDir.appendingPathComponent(src.lastPathComponent)
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: src, to: dst)
        select(dst)
        return dst
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
        try await FileDownloader().download(url, to: dst, progress: progress)
        select(dst)
        return dst
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

    // MARK: 语音模型

    /// 删除语音模型（用于重新下载）
    static func deleteWhisper() {
        if let f = whisperFolder() { try? FileManager.default.removeItem(at: f) }
        UserDefaults.standard.removeObject(forKey: "whisperRelPath")
    }

    /// 相对路径保存在 UserDefaults，因为重新安装后 App 沙盒的绝对路径会变
    static func whisperFolder() -> URL? {
        guard let rel = UserDefaults.standard.string(forKey: "whisperRelPath") else { return nil }
        let url = documents.appendingPathComponent(rel, isDirectory: true)
        let marker = url.appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: marker.path) ? url : nil
    }

    /// 导入语音识别模型：选一个 WhisperKit 模型文件夹（里面有 AudioEncoder.mlmodelc 等）。
    /// 复制到 App 里，替换掉原来的语音识别模型。
    static func importWhisper(from src: URL) throws {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let need = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        let missing = need.filter { !fm.fileExists(atPath: src.appendingPathComponent($0).path) }
        guard missing.isEmpty else {
            throw NSError(domain: "Hear", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "这个文件夹不是 WhisperKit 语音识别模型（缺少 \(missing.joined(separator: "、"))）"])
        }
        let dir = whisperBase.appendingPathComponent("imported", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(src.lastPathComponent, isDirectory: true)
        let old = whisperFolder()
        if src.standardizedFileURL.path != dst.standardizedFileURL.path {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
        // 原来的模型删掉，省空间（选的就是原来那个文件夹时不删）
        if let old, old.standardizedFileURL.path != dst.standardizedFileURL.path,
           old.standardizedFileURL.path != src.standardizedFileURL.path {
            try? fm.removeItem(at: old)
        }
        UserDefaults.standard.set("huggingface/imported/" + src.lastPathComponent, forKey: "whisperRelPath")
    }

    static func downloadWhisper(host: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if host != "huggingface.co" { setenv("HF_ENDPOINT", "https://\(host)", 1) }
        let folder = try await WhisperKit.download(
            variant: SpeechRecognizer.modelVariant,
            downloadBase: whisperBase,
            progressCallback: { p in progress(p.fractionCompleted) }
        )
        let docPath = documents.standardizedFileURL.path
        var rel = folder.standardizedFileURL.path
        if rel.hasPrefix(docPath) { rel = String(rel.dropFirst(docPath.count)) }
        rel = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        UserDefaults.standard.set(rel, forKey: "whisperRelPath")
        return folder
    }
}

/// 带进度的大文件下载。
/// 网络断了会自动重试，并且能断点续传（HF 的 CDN 传输大文件时很容易中途断）。
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
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
    /// 续传时已经有的进度（用于合并进度条）
    private var alreadyDone: Double = 0

    func download(_ url: URL, to dst: URL, progress: @escaping (Double) -> Void) async throws {
        destination = dst
        self.progress = progress
        sourceURL = url
        resumeData = nil
        retryCount = 0
        alreadyDone = 0
        // 网络中断（-1005）、超时（-1001）这类错误会自动重试，能续传就从断点继续
        var lastError: Error?
        while retryCount <= maxRetries {
            do {
                try await run()
                return
            } catch {
                lastError = error
                // 这个错误重试也没用（比如 404、没权限）
                let code = (error as NSError).code
                if code == -1005 || code == -1001 || code == -1003 || code == NSURLErrorNetworkConnectionLost {
                    retryCount += 1
                    if retryCount > maxRetries { break }
                    // 退避等待：网络抖一下的话过几秒就好了
                    let wait = min(pow(2.0, Double(retryCount)), 30)
                    hearLog("下载中断，第 \(retryCount) 次重试（\(wait) 秒后）", .warning)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
        throw lastError ?? NSError(domain: "Hear", code: 30,
                                  userInfo: [NSLocalizedDescriptionKey: "下载失败"])
    }

    /// 跑一次下载；失败且还能重试就自动重来
    private func run() async throws {
        // 超时放宽：大文件在网络慢的时候容易触发默认的 60 秒超时
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 60 * 60 * 2      // 整个下载最多 2 小时
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            let task: URLSessionDownloadTask
            if let rd = resumeData {
                // 从断点继续
                task = session.downloadTask(withResumeData: rd)
            } else {
                task = session.downloadTask(with: sourceURL)
            }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        // 续传时 totalBytesWritten 只是本次的部分，要加上之前已下载的
        let done = alreadyDone + Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
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
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error ?? moveError {
            // 拿到系统的续传数据（网络中断时会给），下次从断点继续
            let ns = e as NSError
            if let rd = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, rd.count > 0 {
                resumeData = rd
            }
            // 已经下载了一部分的话，进度要算上
            if let dlTask = task as? URLSessionDownloadTask,
               let resp = dlTask.response as? HTTPURLResponse,
               resp.expectedContentLength > 0 {
                alreadyDone = Double(dlTask.countOfBytesReceived) / Double(resp.expectedContentLength)
            }
            continuation?.resume(throwing: e)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
