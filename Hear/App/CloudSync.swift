import Foundation
import Combine
import CryptoKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iCloud 同步：把设置和历史对话同步到用户自己选的 iCloud 云盘文件夹（模型不同步）。
///
/// - 数据始终存在手机本地；同步时写进 iCloud 云盘文件夹，系统在有网络时自动上传，换设备或重装后自动下载。
/// - 每次同步自动判断方向：哪边更新用哪边。对话按每一页的修改时间比较；删掉的对话两边都删。
/// - 设置：只有 iCloud 那边改过、这台手机没改过时才用 iCloud 的；两边都改过时以这台手机为准。
/// - 大模型 API Key 存在钥匙串里，不同步（恢复后需要重新填一次 Key）。
/// - 免费账号自签的 App 用不了 CloudKit，所以用“iCloud 云盘里的文件夹”这种方式，第一次打开时选一次文件夹。
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            if enabled { scheduleSync(delay: 0.5) }
        }
    }
    @Published private(set) var folderName: String?
    /// 显示用的路径：选的是 iCloud 云盘根节点就显示「iCloud 云盘」，
    /// 选了子文件夹就显示「iCloud 云盘/文件夹名」
    @Published private(set) var displayPath: String = ""
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    @Published private(set) var message: String?

    private enum Keys {
        static let enabled = "cloudSyncEnabled"
        static let bookmark = "cloudSyncBookmark"
        static let lastSync = "cloudSyncLast"
        static let settingsHash = "cloudSyncSettingsHash"
    }

    /// 要同步的设置（UserDefaults 里的键）。模型位置、同步自己的状态不同步
    private static let settingKeys = [
        "langA", "langB", "speakOutput", "useContext", "sensitivity", "silenceMs", "glossary",
        "outputMode", "leftEar", "rightEar", "voiceClone", "asrUseGPU", "asrEngine",
        "voiceProcessing", "inputSource", "talkMode", "llmProviders", "llmActiveID",
        "logEnabled", "logMaxMB",
    ]

    private var bag = Set<AnyCancellable>()
    private var pending: Task<Void, Never>?
    private var applyingCloud = false

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Keys.enabled)
        lastSync = d.object(forKey: Keys.lastSync) as? Date
        folderName = resolveFolder()?.lastPathComponent
        displayPath = Self.displayPath(for: resolveFolder())

        // 历史有变动、设置有变动：过几秒同步一次（连续改动只同步一次）
        ConversationStore.shared.$revision
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.scheduleSync(delay: 5) } }
            .store(in: &bag)
        // 设置改了才同步（同步自己写的记录不算）
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.applyingCloud else { return }
                    let h = Self.settingsHash(Self.localSettings())
                    if h != UserDefaults.standard.string(forKey: Keys.settingsHash) { self.scheduleSync(delay: 5) }
                }
            }
            .store(in: &bag)
        // 切到后台时同步一次；回到前台时看看 iCloud 有没有更新
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.scheduleSync(delay: 0) } }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.scheduleSync(delay: 1) } }
            .store(in: &bag)
    }

    // MARK: - 文件夹

    var hasFolder: Bool { UserDefaults.standard.data(forKey: Keys.bookmark) != nil }

    /// 用户选好 iCloud 云盘里的文件夹后调用
    func setFolder(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Keys.bookmark)
            // 换了文件夹：重新判断设置该用哪边的
            UserDefaults.standard.removeObject(forKey: Keys.settingsHash)
            folderName = url.lastPathComponent
            displayPath = Self.displayPath(for: url)
            hearLog("iCloud 同步：使用 \(displayPath)")
            enabled = true
            scheduleSync(delay: 0.3)
        } catch {
            message = "无法使用这个文件夹：\(error.localizedDescription)"
            hearLog("iCloud 同步：保存文件夹失败 \(error)", .error)
        }
    }

    /// iCloud 云盘根节点在不同系统版本下路径不一样：
    /// 有的是 .../com~app~CloudDocuments/...，有的是 .../Mobile Documents/com~app~CloudDocs/...，
    /// 有的直接就是容器的 Documents。都当成「iCloud 云盘」根节点。
    static func isICloudRoot(_ url: URL) -> Bool {
        let path = url.path
        let n = url.lastPathComponent
        // iCloud 云盘根在 App 里显示成 com~apple~CloudDocs（不同系统版本也可能是
        // com~app~CloudDocs），这些容器内部名都当成根节点
        if n.contains("CloudDocs") { return true }
        // 就是容器的 Documents（iCloud 云盘根）
        if n == "Documents" {
            if path.contains("CloudDocs") || path.contains("Mobile Documents") { return true }
            if let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
                if path == container.path || path == container.appendingPathComponent("Documents").path { return true }
            }
        }
        return false
    }

    /// 显示用的路径
    static func displayPath(for url: URL?) -> String {
        guard let url else { return "" }
        if isICloudRoot(url) { return "iCloud 云盘" }
        return "iCloud 云盘 / \(url.lastPathComponent)"
    }

    private func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Keys.bookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Keys.bookmark)
        }
        return url
    }

    // MARK: - 启动时：iCloud 的设置更新就先用上（在读设置之前调用）

    /// App 启动时调用（LiveSession 读设置之前）
    func applyCloudSettingsAtLaunch() {
        guard enabled, let root = resolveFolder() else { return }
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        let dir = root.appendingPathComponent("听见同步", isDirectory: true)
        guard let manifest = Self.readManifestNow(dir) else { return }
        if decideSettings(manifest) == .pull, let cloud = Self.readSettingsNow(dir) {
            applySettings(cloud, hash: manifest.settingsHash)
            hearLog("iCloud 同步：启动时用了 iCloud 上更新的设置")
        }
    }

    // MARK: - 同步

    func syncNow() { scheduleSync(delay: 0) }

    private func scheduleSync(delay: Double) {
        guard enabled, hasFolder else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    private struct Manifest: Codable {
        var updatedAt = Date()
        var settingsHash: String?
        var settingsUpdatedAt: Date?
        var conversations: [String: Date] = [:]
        var deleted: [String: Date] = [:]
    }

    private enum SettingsAction { case push, pull, none }

    private func decideSettings(_ cloud: Manifest?) -> SettingsAction {
        let local = Self.settingsHash(Self.localSettings())
        let last = UserDefaults.standard.string(forKey: Keys.settingsHash)
        guard let cloudHash = cloud?.settingsHash else { return .push }   // iCloud 上还没有设置
        if cloudHash == local { return .none }
        guard let last else { return .pull }                              // 第一次同步：用 iCloud 的（恢复）
        let localChanged = local != last
        let cloudChanged = cloudHash != last
        if cloudChanged && !localChanged { return .pull }
        return .push                                                      // 这台手机改过：以这台为准
    }

    private func sync() async {
        guard enabled, !syncing, let root = resolveFolder() else { return }
        syncing = true
        defer { syncing = false }
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        let dir = root.appendingPathComponent("听见同步", isDirectory: true)
        let convDir = dir.appendingPathComponent("conversations", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)
        } catch {
            message = "iCloud 文件夹不可用：\(error.localizedDescription)"
            hearLog("iCloud 同步：建文件夹失败 \(error)", .error)
            return
        }
        var manifest = await Self.readManifest(dir) ?? Manifest()
        var pushed = 0, pulled = 0, removed = 0

        // 1. 设置
        var settingsNote: String?
        switch decideSettings(manifest) {
        case .push:
            let s = Self.localSettings()
            let h = Self.settingsHash(s)
            let plist = Self.plist(s)
            let url = dir.appendingPathComponent("settings.plist")
            if await Self.io({ Self.write(plist, to: url) }) {
                manifest.settingsHash = h
                manifest.settingsUpdatedAt = Date()
                UserDefaults.standard.set(h, forKey: Keys.settingsHash)
            }
        case .pull:
            if let cloud = await Self.readSettings(dir) {
                applySettings(cloud, hash: manifest.settingsHash)
                settingsNote = "已从 iCloud 同步设置，重新打开 App 后完全生效"
                hearLog("iCloud 同步：用了 iCloud 上更新的设置")
            }
        case .none:
            if let h = manifest.settingsHash { UserDefaults.standard.set(h, forKey: Keys.settingsHash) }
        }

        // 2. 删除过的对话：两边合并
        let store = ConversationStore.shared
        ConversationStore.mergeDeleted(manifest.deleted)
        let deleted = ConversationStore.deletedIDs
        manifest.deleted = deleted

        // 3. 对话：哪边新用哪边
        let local = store.allUpdated
        var ids = Set(local.keys.map(\.uuidString))
        ids.formUnion(manifest.conversations.keys)
        for key in ids {
            guard let id = UUID(uuidString: key) else { continue }
            let file = convDir.appendingPathComponent("\(key).json")
            let l = local[id], c = manifest.conversations[key]
            if let gone = deleted[key], gone >= max(l ?? .distantPast, c ?? .distantPast) {
                if l != nil { store.removeSynced(id); removed += 1 }
                if c != nil { await Self.io { Self.remove(file) }; manifest.conversations[key] = nil }
                continue
            }
            if let l, c == nil || l > c! + 1 {
                if let data = store.rawData(id), await Self.io({ Self.write(data, to: file) }) {
                    manifest.conversations[key] = l
                    pushed += 1
                }
            } else if let c, l == nil || c > l! + 1 {
                if let data = await Self.read(file), store.importRaw(data) {
                    pulled += 1
                }
            }
        }

        manifest.updatedAt = Date()
        if let data = try? Self.encoder.encode(manifest) {
            let url = dir.appendingPathComponent("manifest.json")
            _ = await Self.io { Self.write(data, to: url) }
        }
        lastSync = Date()
        UserDefaults.standard.set(lastSync, forKey: Keys.lastSync)
        message = settingsNote
        if pushed + pulled + removed > 0 || settingsNote != nil {
            hearLog("iCloud 同步：上传 \(pushed) 页，下载 \(pulled) 页，删除 \(removed) 页")
        }
    }

    // MARK: - 设置读写

    private static func localSettings() -> [String: Any] {
        let d = UserDefaults.standard
        var out: [String: Any] = [:]
        for k in settingKeys { if let v = d.object(forKey: k) { out[k] = v } }
        return out
    }

    private func applySettings(_ s: [String: Any], hash: String?) {
        applyingCloud = true
        let d = UserDefaults.standard
        for k in Self.settingKeys { if let v = s[k] { d.set(v, forKey: k) } }
        d.set(hash ?? Self.settingsHash(Self.localSettings()), forKey: Keys.settingsHash)
        // UserDefaults 的变动通知是异步发的，稍后再恢复监听
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.applyingCloud = false
        }
    }

    private static func plist(_ s: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: s, format: .xml, options: 0)) ?? Data()
    }

    /// XML plist 的键是排好序的，同样的设置得到同样的指纹
    private static func settingsHash(_ s: [String: Any]) -> String {
        SHA256.hash(data: plist(s)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func parseSettings(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private nonisolated static func parseManifest(_ data: Data?) -> Manifest? {
        guard let data else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(Manifest.self, from: data)
    }

    private static func readSettings(_ dir: URL) async -> [String: Any]? {
        parseSettings(await read(dir.appendingPathComponent("settings.plist")))
    }
    private static func readManifest(_ dir: URL) async -> Manifest? {
        parseManifest(await read(dir.appendingPathComponent("manifest.json")))
    }
    private static func readSettingsNow(_ dir: URL) -> [String: Any]? {
        parseSettings(readNow(dir.appendingPathComponent("settings.plist")))
    }
    private static func readManifestNow(_ dir: URL) -> Manifest? {
        parseManifest(readNow(dir.appendingPathComponent("manifest.json")))
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    // MARK: - iCloud 云盘文件读写（用文件协调，避免和系统的上传下载冲突）

    /// 读文件；文件还在云端没下载到手机时，先让系统下载，最多等 5 秒（不卡界面）
    private nonisolated static func read(_ url: URL) async -> Data? {
        if let d = await io({ Self.readNow(url) }) { return d }
        guard FileManager.default.fileExists(atPath: url.path) || isCloudPlaceholder(url) else { return nil }
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let d = await io({ Self.coordinatedRead(url) }) { return d }
        }
        return nil
    }

    /// 文件读写放到后台线程做，不卡界面
    private nonisolated static func io<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .utility) { UncheckedBox(work()) }.value.value
    }

    /// 马上读（不等待）；文件还没下载到手机就让系统开始下载，下次再读
    private nonisolated static func readNow(_ url: URL) -> Data? {
        if FileManager.default.fileExists(atPath: url.path), let d = try? Data(contentsOf: url) { return d }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return nil
    }

    /// 还没下载到手机的文件，在文件夹里是 .文件名.icloud 这样的占位文件
    private nonisolated static func isCloudPlaceholder(_ url: URL) -> Bool {
        let p = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: p.path)
    }

    private nonisolated static func coordinatedRead(_ url: URL) -> Data? {
        var out: Data?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
            out = try? Data(contentsOf: u)
        }
        return out
    }

    @discardableResult
    private nonisolated static func write(_ data: Data, to url: URL) -> Bool {
        var ok = false
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
            ok = (try? data.write(to: u, options: .atomic)) != nil
        }
        if !ok { hearLog("iCloud 同步：写入失败 \(url.lastPathComponent) \(err?.localizedDescription ?? "")", .warning) }
        return ok
    }

    private nonisolated static func remove(_ url: URL) {
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
            try? FileManager.default.removeItem(at: u)
        }
    }
}

/// 选 iCloud 云盘里的文件夹（系统的文件选择器，只能选文件夹）
/// 打开时直接定位到 iCloud 云盘，不用手动切过去
struct CloudFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        vc.allowsMultipleSelection = false
        vc.delegate = context.coordinator
        // 定位到 iCloud 云盘
        if let root = Self.iCloudDriveURL() {
            vc.directoryURL = root
        }
        return vc
    }

    /// iCloud 云盘的根目录（容器里的 Documents）
    static func iCloudDriveURL() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        // 容器根下：Documents 就是 iCloud 云盘
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        if FileManager.default.fileExists(atPath: docs.path) { return docs }
        return container
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}

/// 让后台任务把结果带回来
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}
