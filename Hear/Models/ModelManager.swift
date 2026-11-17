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

/// 带进度的大文件下载
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL!
    private var progress: ((Double) -> Void)?
    private var moveError: Error?

    func download(_ url: URL, to dst: URL, progress: @escaping (Double) -> Void) async throws {
        destination = dst
        self.progress = progress
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
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
        if let e = error ?? moveError { continuation?.resume(throwing: e) } else { continuation?.resume() }
        continuation = nil
    }
}
