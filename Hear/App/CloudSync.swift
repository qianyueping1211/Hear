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
extension Notification.Name {
    /// iCloud 把设置同步过来了：App 里的设置要立刻换新的（不用重开）
    static let hearCloudSettingsApplied = Notification.Name("hear.cloudSettingsApplied")
}

@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            if enabled { scheduleSync(delay: 0.5) }
        }
    }
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    @Published private(set) var message: String?

    private enum Keys {
        static let enabled = "cloudSyncEnabled"
        static let bookmark = "cloudSyncBookmark"
        static let lastSync = "cloudSyncLast"
        static let settingsHash = "cloudSyncSettingsHash"
    }

    /// 要同步的设置（UserDefaults 里的键）。模型文件本身、下载来源、同步自己的状态不同步
    ///
    /// 注意：在线模型（通用服务地址、三个模型各自的地址、识别方案、
    /// 用不用云端翻译/克隆）一定要在这里面，不然换了手机或者重装之后就没了。
    private static let settingKeys = [
        "langA", "langB", "speakOutput", "useContext", "sensitivity", "silenceMs", "glossary",
        "outputMode", "leftEar", "rightEar", "voiceClone", "asrUseGPU", "asrEngine",
        "voiceProcessing", "inputSource", "talkMode", "llmProviders", "llmActiveID",
        "logEnabled", "logMaxMB",
        // 在线模型（云端服务）
        "cloudAddress", "cloudModelAddress", "cloudASRScheme",
        "voiceCloneCloud", "translationEngine",
        // 下载源、翻译模型选哪个 gguf
        "hfHost", "ggufName",
    ]

    private var bag = Set<AnyCancellable>()
    private var pending: Task<Void, Never>?
    private var applyingCloud = false
    /// 下一次同步强制上传设置（不管两边谁新）
    private var forcePushSettings = false

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Keys.enabled)
        lastSync = d.object(forKey: Keys.lastSync) as? Date

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
                    if h != UserDefaults.standard.string(forKey: Keys.settingsHash) { self.scheduleSync(delay: 2) }
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

    /// iCloud 云盘里我们自己的文件夹：就用 App 名字（听见），用户不用选也不用改
    static var syncFolderName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "听见"
    }

    /// 已经找到的同步文件夹（找到一次就记下来，不用每次都去问系统）
    private var cachedFolder: URL?

    /// 有没有可以放同步数据的地方
    /// （App 自己的 iCloud 容器，或者之前授权过的 iCloud 文件夹）
    var hasFolder: Bool {
        if let cachedFolder { return true }
        return withFolderAccess { _ in true } ?? false
    }

    /// 同步数据所在的文件夹：iCloud 云盘里的「听见」
    ///
    /// 用户不用自己挑地方：
    ///   · App 自己的 iCloud 容器 → 容器里的 Documents 在云盘里就叫 App 名字
    ///   · 之前授权过的 iCloud 文件夹 → 里面固定放一个「听见」
    /// 挨个试，第一个能用的就是它（用不了的说明没权限）。
    private func resolveFolder() -> URL? {
        if let cachedFolder { return cachedFolder }
        for dir in folderCandidates() {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                cachedFolder = dir
                return dir
            } catch {
                continue     // 这个位置没权限，试下一个
            }
        }
        return nil
    }

    /// 打开同步文件夹的访问权限，取到文件夹，用完关掉。
    /// 用书签授权过的文件夹时，必须先 startAccessing 才动得了里面的东西。
    @discardableResult
    private func withFolderAccess<T>(_ body: (URL) -> T) -> T? {
        var scoped: URL?
        if let picked = resolveBookmarkFolder(), picked.startAccessingSecurityScopedResource() {
            scoped = picked
        }
        defer { if let scoped { scoped.stopAccessingSecurityScopedResource() } }
        guard let dir = resolveFolder() else { return nil }
        return body(dir)
    }

    /// 候选的同步文件夹（按优先级排）
    private func folderCandidates() -> [URL] {
        var out: [URL] = []
        // 1. 之前授权过的 iCloud 文件夹：里面固定放一个「听见」
        //    （老用户的数据已经在里面了，优先用它）
        if let picked = resolveBookmarkFolder() {
            let name = picked.lastPathComponent
            if name == Self.syncFolderName {
                out.append(picked)                                   // 选的就是「听见」
            } else if name == Self.legacyFolderName {
                // 之前选的是「听见同步」：新位置是它的上一层里的「听见」
                out.append(picked.deletingLastPathComponent()
                    .appendingPathComponent(Self.syncFolderName, isDirectory: true))
                out.append(picked)                                   // 兜底：还在旧文件夹里
            } else {
                out.append(picked.appendingPathComponent(Self.syncFolderName, isDirectory: true))
            }
        }
        // 2. App 自己的 iCloud 容器：iCloud 云盘里显示为 App 名字的那个目录
        if let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            let docs = container.appendingPathComponent("Documents", isDirectory: true)
            out.append(FileManager.default.fileExists(atPath: docs.path) ? docs : container)
        }
        return out
    }

    /// 旧版本用的文件夹名（升级时把里面的数据搬过来）
    private static let legacyFolderName = "听见同步"

    /// 老版本的数据在「听见同步」里，现在改成「听见」：把老文件夹搬过来
    private func migrateLegacyFolder(to dir: URL) {
        let fm = FileManager.default
        // 只在「听见」还没数据的时候搬，避免覆盖新的
        let newManifest = dir.appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: newManifest.path) { return }
        // 老文件夹就在同步目录的上一层（老版本用的是同一个根 + 「听见同步」）
        let parent = dir.deletingLastPathComponent()
        let legacy = parent.appendingPathComponent(Self.legacyFolderName, isDirectory: true)
        guard legacy != dir, fm.fileExists(atPath: legacy.path) else { return }
        do {
            try Self.mergeContents(from: legacy, to: dir)
            try? fm.removeItem(at: legacy)
            hearLog("iCloud 同步：老文件夹「\(Self.legacyFolderName)」已改名为「\(Self.syncFolderName)」")
        } catch {
            hearLog("iCloud 同步：搬老文件夹失败 \(error)", .warning)
        }
    }

    /// 把 from 里的东西并到 to 里：同名的文件不动，文件夹递归合并
    private static func mergeContents(from: URL, to: URL) throws {
        let fm = FileManager.default
        for item in try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) {
            let dst = to.appendingPathComponent(item.lastPathComponent)
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: dst.path, isDirectory: &isDir)
            let srcIsDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !exists {
                try fm.moveItem(at: item, to: dst)
            } else if isDir.boolValue && srcIsDir {
                try mergeContents(from: item, to: dst)
            }
            // 同名的单个文件：保留新的（老的不覆盖）
        }
    }

    /// 老版本授权过的那个文件夹（书签）
    private func resolveBookmarkFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Keys.bookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Keys.bookmark)
        }
        return url
    }

    /// 用户选好 iCloud 云盘里的文件夹后调用（只在完全没有 iCloud 权限时才会用到）
    func setFolder(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Keys.bookmark)
            cachedFolder = nil
            // 换了文件夹：重新判断设置该用哪边的
            UserDefaults.standard.removeObject(forKey: Keys.settingsHash)
            hearLog("iCloud 同步：使用 iCloud 云盘里的「\(Self.syncFolderName)」文件夹")
            enabled = true
            scheduleSync(delay: 0.3)
        } catch {
            message = "无法使用这个文件夹：\(error.localizedDescription)"
            hearLog("iCloud 同步：保存文件夹失败 \(error)", .error)
        }
    }


    // MARK: - 启动时：iCloud 的设置更新就先用上（在读设置之前调用）

    /// App 启动时调用（LiveSession 读设置之前）
    func applyCloudSettingsAtLaunch() {
        guard enabled else { return }
        withSyncFolder { dir -> Void in
            migrateLegacyFolder(to: dir)
            guard let manifest = Self.readManifestNow(dir) else { return }
            if decideSettings(manifest) == .pull, let cloud = Self.readSettingsNow(dir) {
                applySettings(cloud, hash: manifest.settingsHash)
                hearLog("iCloud 同步：启动时用了 iCloud 上更新的设置")
            }
        }
    }

    /// 拿到同步文件夹（iCloud 云盘里的「听见」），并且在需要时开启访问权限
    @discardableResult
    private func withSyncFolder<T>(_ body: (URL) -> T) -> T? {
        withFolderAccess(body)
    }

    // MARK: - 同步

    func syncNow() { scheduleSync(delay: 0) }

    /// 强制把设置重新写一遍并上传。
    /// 用来对付"文件写进去了但 iCloud 没传上去"的情况：
    /// 重写一次（修改时间变了），系统就会重新传。
    func reuploadSettings() {
        guard enabled, hasFolder else { return }
        forcePushSettings = true
        scheduleSync(delay: 0)
    }

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

    private func decideSettings(_ cloud: Manifest?, forcePush: Bool = false) -> SettingsAction {
        if forcePush { return .push }
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
        guard enabled else { return }
        if syncing {
            // 已经有一次同步在跑：等它跑完再来一次。
            // 不这样的话，这次的改动会被漏掉（同步期间改的设置传不上去）。
            scheduleSync(delay: 1)
            return
        }
        syncing = true
        defer { syncing = false }
        // 用书签授权的文件夹：访问期间要 startAccessing
        // （要先开启权限，才能在里面建文件夹）
        var scoped: URL?
        if let picked = resolveBookmarkFolder(), picked.startAccessingSecurityScopedResource() {
            scoped = picked
        }
        defer { if let scoped { scoped.stopAccessingSecurityScopedResource() } }
        guard let dir = resolveFolder() else {
            hearLog("iCloud 同步：找不到 iCloud 云盘里的「\(Self.syncFolderName)」文件夹", .warning)
            message = "iCloud 云盘里找不到「\(Self.syncFolderName)」文件夹，请检查 iCloud 是否已登录"
            return
        }
        // 先把老文件夹「听见同步」的内容搬过来，再建 conversations
        migrateLegacyFolder(to: dir)
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
        var pushedSettings = 0
        let doPush = forcePushSettings
        forcePushSettings = false
        switch decideSettings(manifest, forcePush: doPush) {
        case .push:
            let s = Self.localSettings()
            let h = Self.settingsHash(s)
            let plist = Self.plist(s)
            let url = dir.appendingPathComponent("settings.plist")
            if await Self.io({ Self.write(plist, to: url) }) {
                manifest.settingsHash = h
                manifest.settingsUpdatedAt = Date()
                UserDefaults.standard.set(h, forKey: Keys.settingsHash)
                pushedSettings = s.count
                hearLog("iCloud 同步：上传了 \(s.count) 项设置")
            }
        case .pull:
            if let cloud = await Self.readSettings(dir) {
                applySettings(cloud, hash: manifest.settingsHash)
                settingsNote = "已从 iCloud 同步设置（\(cloud.count) 项）"
                hearLog("iCloud 同步：用了 iCloud 上更新的设置（\(cloud.count) 项）")
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
        message = settingsNote ?? (pushedSettings > 0 ? "已上传 \(pushedSettings) 项设置到 iCloud" : nil)
        if pushed + pulled + removed > 0 || settingsNote != nil || pushedSettings > 0 {
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
        // 告诉 App：新设置已经写好了，直接换上，不用重开
        NotificationCenter.default.post(name: .hearCloudSettingsApplied, object: nil)
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
