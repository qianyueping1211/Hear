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
/// - 在线模型的访问口令跟设置一起同步（重装或换手机后不用再填；泄露时到 Token 管理后台撤销）。
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
            if enabled { scheduleSync(delay: 0.5) } else { closeScopedAccess() }
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

    /// Keep the original keys so the last sync hash can still be compared after upgrading.
    private static let legacySettingKeys = [
        "langA", "langB", "speakOutput", "showReadingIcon",
        "liveActivityOnlyTranslation",
        "useContext", "sensitivity", "silenceMs", "glossary",
        "outputMode", "leftEar", "rightEar", "voiceClone", "asrEngine",
        "voiceProcessing", "inputSource", "llmProviders", "llmActiveID",
        "logEnabled", "logMaxMB",
        // 在线模型（云端服务）
        "cloudAddress", "cloudModelAddress", "cloudASRScheme",
        "voiceCloneCloud", "translationEngine",
        // 下载源、翻译模型选哪个 gguf
        "hfHost", "ggufName",
    ]

    private static let addedSettingKeys = [
        "logContentEnabled", PerformanceLog.enabledKey,
        ChineseDisplayLanguage.preferenceKey, "speakerTrackingEnabled", "manualSpeakerOutput",
        // 在线模型的访问口令：重装 App 或换手机后不用再手动填。
        // 它会和其他设置一起写进 iCloud 云盘「听见」文件夹；口令泄露时到 Token 管理后台撤销即可。
        "cloudAccessToken",
        "saveFullRecording",
    ]
    private static let settingKeys = legacySettingKeys + addedSettingKeys

    private var bag = Set<AnyCancellable>()
    private var pending: Task<Void, Never>?
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
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
    /// iCloud 同步目录内单独存放完整录音的子文件夹
    private static let recordingsFolderName = "recordings"
    /// 正在录制中的对话 ID：录制未结束前不上传也不清理本地缓存，避免写入冲突
    var activeRecordingID: UUID? = nil

    static var syncFolderName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "听见"
    }

    /// 已经找到的同步文件夹（找到一次就记下来，不用每次都去问系统）
    private var cachedFolder: URL?
    /// 正在使用授权的文件夹（访问权限一直开着，不用每次开关）
    private var scopedFolder: URL?
    /// 是不是已经提醒过"没有权限"了（免得每次刷新设置都刷一遍日志）
    private var warnedNoAccess = false
    /// App 自己的 iCloud 云盘文件夹（有 iCloud 权限时才有）。
    /// 系统授权完直接用它：一个文件夹都不用让用户挑。
    private var ownFolder: URL?

    /// 有没有可以放同步数据的地方
    /// （App 自己的 iCloud 容器，或者之前授权过的 iCloud 文件夹）
    var hasFolder: Bool {
        enabled && resolveFolder() != nil
    }

    /// 同步数据所在的文件夹：iCloud 云盘里的「听见」
    ///
    /// 用户不用自己挑地方：
    ///   · App 自己的 iCloud 容器 → 容器里的 Documents 在云盘里就叫 App 名字
    ///   · 之前授权过的 iCloud 文件夹 → 里面固定放一个「听见」
    /// 挨个试，第一个能用的就是它（用不了的说明没权限）。
    private func resolveFolder() -> URL? {
        if let cachedFolder { return cachedFolder }
        openScopedAccess()          // 先把访问权限打开（后面都用同一个 URL 实例）
        for dir in folderCandidates() {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                cachedFolder = dir
                warnedNoAccess = false
                return dir
            } catch {
                continue     // 这个位置没权限，试下一个
            }
        }
        closeScopedAccess()
        return nil
    }

    /// 打开同步文件夹的访问权限，取到文件夹。
    /// 用书签授权过的文件夹时，必须先 startAccessing 才动得了里面的东西。
    @discardableResult
    private func withFolderAccess<T>(_ body: (URL) -> T) -> T? {
        guard let dir = resolveFolder() else { return nil }
        return body(dir)
    }

    /// 打开书签授权的文件夹，并把权限一直开着。
    ///
    /// 关键：同一份书签解析两次会得到两个不同的 URL，
    /// 只有开过权限的那一个能用。之前解析了两次，
    /// 于是每次都以为"没有权限"，又要让用户重新选文件夹。
    private func openScopedAccess() {
        guard scopedFolder == nil, ownFolder == nil,
              let data = UserDefaults.standard.data(forKey: Keys.bookmark) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return }
        scopedFolder = url
        if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Keys.bookmark)
        }
    }

    /// 关掉授权（关掉 iCloud 同步时）
    private func closeScopedAccess() {
        if let s = scopedFolder { s.stopAccessingSecurityScopedResource() }
        scopedFolder = nil
        cachedFolder = nil
    }

    /// 候选的同步文件夹（按优先级排）
    private func folderCandidates() -> [URL] {
        var out: [URL] = []
        // 0. App 自己的 iCloud 云盘文件夹（有 iCloud 权限时，系统授权完就有）
        if let own = ownFolder {
            out.append(own)
        }
        // 1. 之前授权过的 iCloud 文件夹：里面固定放一个「听见」
        //    （老用户的数据已经在里面了，优先用它）
        if let picked = scopedFolder {
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

    /// 请求 iCloud 云盘的访问权限。
    ///
    /// - Returns: true 表示已经拿到权限了（不需要用户再选文件夹）；
    ///   false 表示这台 App 没有 iCloud 云盘的权限（免费账号自签的都没有），
    ///   得让用户在系统的文件选择器里点一下。
    ///
    /// 有权限（付费账号签名、或者在 Xcode 里带 iCloud 能力）时，
    /// 系统会自己弹那个「允许访问 iCloud 云盘」的授权框，
    /// 授权完就直接用 App 自己的云盘文件夹，一个字都不用让用户选。
    @discardableResult
    func requestAuthorization() -> Bool {
        // App 自己的 iCloud 容器（需要 com.apple.developer.ubiquity-container-identifiers 权限）
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            hearLog("iCloud 同步：这版 App 没有 iCloud 云盘权限，需要用户手动授权一个文件夹", .info)
            return false
        }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        let dir = FileManager.default.fileExists(atPath: docs.path) ? docs : container
        hearLog("iCloud 同步：用 App 自己的 iCloud 云盘文件夹（系统授权，不用用户挑）", .info)
        ownFolder = dir
        closeScopedAccess()
        enabled = true
        verifyWritable()
        scheduleSync(delay: 0.3)
        return true
    }

    /// 用户选好 iCloud 云盘里的文件夹后调用（只在完全没有 iCloud 权限时才会用到）
    func setFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            message = "未能访问所选文件夹，请在 iCloud 云盘中重新选择。"
            hearLog("iCloud 同步：未获得所选文件夹的访问权限", .warning)
            return
        }
        do {
            let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Keys.bookmark)
            useFolder(url)
        } catch {
            url.stopAccessingSecurityScopedResource()
            message = "无法使用这个文件夹：\(error.localizedDescription)"
            hearLog("iCloud 同步：保存文件夹失败 \(error)", .error)
        }
    }

    /// 就用这个文件夹同步（权限已经开着了）
    private func useFolder(_ url: URL) {
        ownFolder = nil        // 用户自己挑的，就用它
        closeScopedAccess()
        warnedNoAccess = false
        // 就用这个文件夹（权限已经开着了，后面都拿它操作）
        scopedFolder = url
        // 换了文件夹：重新判断设置该用哪边的
        UserDefaults.standard.removeObject(forKey: Keys.settingsHash)
        hearLog("iCloud 同步：使用 iCloud 云盘里的「\(Self.syncFolderName)」文件夹")
        enabled = true
        // 当场验一下能不能真的写进去（有些位置看得见但写不了）
        verifyWritable()
        scheduleSync(delay: 0.3)
    }


    // MARK: - 启动时：iCloud 的设置更新就先用上（在读设置之前调用）

    /// App 启动时调用（LiveSession 读设置之前）
    func applyCloudSettingsAtLaunch() {
        guard enabled else { return }
        withSyncFolder { dir -> Void in
            migrateLegacyFolder(to: dir)
            guard let manifest = Self.readManifestNow(dir) else { return }
            if decideSettings(manifest) == .pull,
               let cloud = Self.readSettingsNow(dir, hash: manifest.settingsHash) {
                let hasAdditions = applySettings(cloud, hash: manifest.settingsHash)
                hearLog("iCloud 同步：启动时用了 iCloud 上更新的设置")
                if hasAdditions { scheduleSync(delay: 1) }
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

    /// 试一下同步文件夹能不能真的写进去（写不进去就说明位置不对或没权限）
    private func verifyWritable() {
        guard let dir = resolveFolder() else {
            message = "打不开 iCloud 云盘里的「\(Self.syncFolderName)」文件夹，请重新授权一次。"
            return
        }
        let probe = dir.appendingPathComponent(".hear-write-test")
        do {
            try Data("ok".utf8).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            message = nil
        } catch {
            closeScopedAccess()
            message = "iCloud 云盘里的「\(Self.syncFolderName)」文件夹写不进去：\(error.localizedDescription)"
            hearLog("iCloud 同步：写不进去 \(error)", .warning)
        }
    }

    /// 打开 iCloud 同步后检查一下能不能拿到云盘里的文件夹。
    ///
    /// 先试系统的授权（有 iCloud 权限时，iOS 自己会弹「允许访问 iCloud 云盘」，
    /// 用户点一下允许就行，一个文件夹都不用挑）；
    /// 拿不到才在设置里显示「授权 iCloud 云盘」按钮，让用户手动挑一次。
    func checkFolderAccess() {
        guard enabled else { return }
        if !hasFolder {
            _ = requestAuthorization()
        }
        if hasFolder, let m = message, m.hasPrefix("iCloud") { message = nil }
    }

    /// 强制把设置重新写一遍并上传。
    /// 用来对付"文件写进去了但 iCloud 没传上去"的情况：
    /// 重写一次（修改时间变了），系统就会重新传。
    func reuploadSettings() {
        guard enabled, hasFolder else { return }
        forcePushSettings = true
        scheduleSync(delay: 0)
    }

    func scheduleSync(delay: Double) {
        guard enabled else { return }
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

    private func decideSettings(_ cloud: Manifest?, forcePush: Bool = false) -> CloudSettingsSyncPolicy.Action {
        let settings = Self.localSettings()
        let legacy = settings.filter { Self.legacySettingKeys.contains($0.key) }
        return CloudSettingsSyncPolicy.decide(local: Self.settingsHash(settings),
                                             legacyLocal: Self.settingsHash(legacy),
                                             last: UserDefaults.standard.string(forKey: Keys.settingsHash),
                                             remote: cloud?.settingsHash, forcePush: forcePush)
    }

    private func sync() async {
        guard enabled else { return }
        if syncing {
            // 已经有一次同步在跑：等它跑完再来一次。
            // 不这样的话，这次的改动会被漏掉（同步期间改的设置传不上去）。
            scheduleSync(delay: 1)
            return
        }
        guard let dir = resolveFolder() else {
            let detail = "暂时无法访问 iCloud 云盘里的「\(Self.syncFolderName)」文件夹"
            if message != detail { message = detail }
            if !warnedNoAccess, UserDefaults.standard.data(forKey: Keys.bookmark) != nil {
                warnedNoAccess = true
                hearLog("iCloud 同步：\(detail)，下次同步时会重试", .warning)
            }
            return
        }
        syncing = true
        // 退后台同步期间持文件协调锁，必须向系统申请后台任务时间并妥善处理到期回调，避免 0xdead10cc 强杀
        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "icloud-sync") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pending?.cancel()
                if self.bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(self.bgTaskID)
                    self.bgTaskID = .invalid
                }
            }
        }
        defer {
            syncing = false
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
        // 先把老文件夹「听见同步」的内容搬过来，再建 conversations
        migrateLegacyFolder(to: dir)
        let convDir = dir.appendingPathComponent("conversations", isDirectory: true)
        let recordingsDir = dir.appendingPathComponent(Self.recordingsFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        } catch {
            closeScopedAccess()
            message = "iCloud 文件夹不可用：\(error.localizedDescription)"
            hearLog("iCloud 同步：建文件夹失败 \(error)", .error)
            return
        }
        // 清单读不出来的时候，不能拿一份空的当"没有"——
        // 那样一写就把别的设备的数据抹掉了。
        let manifestURL = dir.appendingPathComponent("manifest.json")
        var manifest: Manifest
        if let m = await Self.readManifest(dir) {
            manifest = m
        } else if FileManager.default.fileExists(atPath: manifestURL.path) {
            message = "iCloud 上的同步清单读不出来，这次先不同步"
            hearLog("iCloud 同步：清单读不出来，先不同步（不拿空清单去覆盖）", .error)
            return
        } else if Self.isCloudPlaceholder(manifestURL) {
            message = "iCloud 上的同步清单还没下载到手机，稍后再试"
            hearLog("iCloud 同步：清单还没下载到手机，先不同步", .warning)
            return
        } else {
            manifest = Manifest()          // 真的还没有清单：空的没问题
        }
        var pushed = 0, pulled = 0, removed = 0

        // 1. 设置
        var settingsNote: String?
        var pushedSettings = 0
        var updateSettingsAgain = false
        var settingsReadFailed = false
        let doPush = forcePushSettings
        forcePushSettings = false
        switch decideSettings(manifest, forcePush: doPush) {
        case .push:
            let s = Self.localSettings()
            let plist = Self.plist(s)
            let h = Self.digest(plist)
            let url = dir.appendingPathComponent("settings.plist")
            if await Self.io({ Self.write(plist, to: url) }) {
                manifest.settingsHash = h
                manifest.settingsUpdatedAt = Date()
                UserDefaults.standard.set(h, forKey: Keys.settingsHash)
                pushedSettings = s.count
                hearLog("iCloud 同步：上传了 \(s.count) 项设置")
            }
        case .pull:
            let localBeforeRead = Self.settingsHash(Self.localSettings())
            if let cloud = await Self.readSettings(dir, hash: manifest.settingsHash) {
                if enabled, Self.settingsHash(Self.localSettings()) == localBeforeRead {
                    updateSettingsAgain = applySettings(cloud, hash: manifest.settingsHash)
                    settingsNote = "已从 iCloud 同步设置（\(cloud.count) 项）"
                    hearLog("iCloud 同步：用了 iCloud 上更新的设置（\(cloud.count) 项）")
                } else {
                    updateSettingsAgain = true
                }
            } else {
                settingsReadFailed = true
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
        var hadFileFailure = false
        for key in ids {
            guard let id = UUID(uuidString: key) else { continue }
            let file = convDir.appendingPathComponent("\(key).json")
            let l = local[id], c = manifest.conversations[key]
            if let gone = deleted[key], gone >= max(l ?? .distantPast, c ?? .distantPast) {
                if l != nil { store.removeSynced(id); removed += 1 }
                if c != nil { await Self.io { Self.remove(file) }; manifest.conversations[key] = nil }
                let cloudWav = recordingsDir.appendingPathComponent("\(key).wav")
                if FileManager.default.fileExists(atPath: cloudWav.path) || Self.isCloudPlaceholder(cloudWav) {
                    await Self.io { Self.remove(cloudWav) }
                }
                continue
            }
            if let l, let c, let base = store.syncBase(id),
               l.timeIntervalSince(base.updatedAt) >= 1, c.timeIntervalSince(base.updatedAt) >= 1 {
                guard let remote = await Self.read(file) else { hadFileFailure = true; continue }
                guard store.allUpdated[id] == l,
                      ConversationStore.deletedIDs[key] == deleted[key] else { continue }
                guard let merged = store.mergeSyncChanges(remote, into: id, base: base),
                      let revision = store.allUpdated[id],
                      await Self.io({ Self.write(merged, to: file) }) else {
                    hadFileFailure = true
                    continue
                }
                store.rememberSyncBase(merged, id: id)
                manifest.conversations[key] = revision
                pushed += 1
            } else if let l, c == nil || l > c! + 1 {
                if let data = store.rawData(id), await Self.io({ Self.write(data, to: file) }) {
                    store.rememberSyncBase(data, id: id)
                    manifest.conversations[key] = l
                    pushed += 1
                } else {
                    hadFileFailure = true
                }
            } else if let c, l == nil || c > l! + 1 {
                let deletionBeforeRead = ConversationStore.deletedIDs[key]
                guard let data = await Self.read(file) else {
                    hadFileFailure = true
                    continue
                }
                // The read suspends. Compare optionals so creation and deletion also count as changes.
                guard store.allUpdated[id] == l,
                      ConversationStore.deletedIDs[key] == deletionBeforeRead else { continue }
                if store.importRaw(data) {
                    store.rememberSyncBase(data, id: id)
                    pulled += 1
                }
                else { hadFileFailure = true }
            } else if let l, let c, abs(l.timeIntervalSince(c)) < 1, store.syncBase(id) == nil,
                      let data = store.rawData(id) {
                store.rememberSyncBase(data, id: id)
            }
        }

        // 4. 完整录音：上传到 iCloud 的 recordings/ 子文件夹，上传校验成功后删除本地缓存（离线或失败则保留本地待下次续传）
        var uploadedRecordings = 0
        let localDir = ConversationStore.conversationsDirectory
        let localWavFiles = ((try? FileManager.default.contentsOfDirectory(
            at: localDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension.lowercased() == "wav" }

        for localWav in localWavFiles {
            let key = localWav.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: key) else { continue }
            // 正在录制的对话跳过，避免边写边传或误删本地句柄
            if id == activeRecordingID { continue }
            let cloudWav = recordingsDir.appendingPathComponent("\(key).wav")
            if deleted[key] != nil {
                try? FileManager.default.removeItem(at: localWav)
                if FileManager.default.fileExists(atPath: cloudWav.path) || Self.isCloudPlaceholder(cloudWav) {
                    await Self.io { Self.remove(cloudWav) }
                }
                continue
            }
            let size = ((try? localWav.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard size > 44 else { continue }
            let ok = await Self.io {
                ConversationAudioRecorder.repairWavHeaderIfNeeded(at: localWav)
                return Self.uploadRecordingFile(from: localWav, to: cloudWav)
            }
            if ok && id != activeRecordingID {
                try? FileManager.default.removeItem(at: localWav)
                uploadedRecordings += 1
                hearLog("iCloud 同步：完整录音 \(key.prefix(8)) 已上传至 recordings/ 并清理本地缓存")
            }
        }
        if uploadedRecordings > 0 {
            hearLog("iCloud 同步：本次共上传并清理本地录音缓存 \(uploadedRecordings) 个")
        }

        // 提交：先读一次合并，再写；写完再核对一遍——
        // 两台设备同时同步时，后写的那台可能把前一台的改动盖掉。
        // 核对发现自己刚写的东西不见了，就再合并一次再写（最多三次）。
        var wrote = false
        for attempt in 0..<3 {
            let candidate = manifest
            guard let stored = await Self.io({ Self.publishManifest(candidate, to: manifestURL) }) else { break }
            manifest = stored
            guard let after = await Self.readManifest(dir) else { continue }
            let includesConversations = manifest.conversations.allSatisfy { key, revision in
                max(after.conversations[key] ?? .distantPast, after.deleted[key] ?? .distantPast) >= revision
            }
            let includesDeletions = manifest.deleted.allSatisfy { key, revision in
                (after.deleted[key] ?? .distantPast) >= revision
            }
            let includesSettings = (after.settingsUpdatedAt ?? .distantPast)
                >= (manifest.settingsUpdatedAt ?? .distantPast)
            if includesConversations && includesDeletions && includesSettings {
                wrote = !hadFileFailure
                break
            }
            manifest = Self.mergeManifest(after, manifest)
            hearLog("iCloud 同步：重新核对并合并清单（第 \(attempt + 1) 次）", .info)
        }
        if wrote && !settingsReadFailed {
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: Keys.lastSync)
            message = settingsNote
        } else if settingsReadFailed {
            message = "iCloud 设置文件还未更新到本机，稍后再试"
        } else {
            message = "同步结果没能写回 iCloud（稍后再试一次）"
            hearLog("iCloud 同步：清单没写回去，不记同步时间", .warning)
        }
        if updateSettingsAgain { scheduleSync(delay: 1) }
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

    /// Older clients omit the new fields. Preserve a value already chosen on this
    /// device and publish it again after applying the shared settings.
    private func applySettings(_ s: [String: Any], hash: String?) -> Bool {
        applyingCloud = true
        let d = UserDefaults.standard
        for k in Self.settingKeys { if let v = s[k] { d.set(v, forKey: k) } }
        d.set(hash ?? Self.settingsHash(Self.localSettings()), forKey: Keys.settingsHash)
        // 访问口令马上交给网络层：运行中打开 iCloud 同步时，不用重开 App 就能用上
        if let token = s["cloudAccessToken"] as? String {
            CloudClient.accessToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 告诉 App：新设置已经写好了，直接换上，不用重开
        NotificationCenter.default.post(name: .hearCloudSettingsApplied, object: nil)
        // UserDefaults 的变动通知是异步发的，稍后再恢复监听
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.applyingCloud = false
        }
        return Self.addedSettingKeys.contains { s[$0] == nil && d.object(forKey: $0) != nil }
    }

    private static func plist(_ s: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: s, format: .xml, options: 0)) ?? Data()
    }

    /// XML plist 的键是排好序的，同样的设置得到同样的指纹
    private static func settingsHash(_ s: [String: Any]) -> String {
        digest(plist(s))
    }

    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func parseSettings(_ data: Data?, hash: String?) -> [String: Any]? {
        guard let data, hash == nil || digest(data) == hash else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private nonisolated static func parseManifest(_ data: Data?) -> Manifest? {
        guard let data else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(Manifest.self, from: data)
    }

    private static func readSettings(_ dir: URL, hash: String?) async -> [String: Any]? {
        parseSettings(await read(dir.appendingPathComponent("settings.plist")), hash: hash)
    }
    /// 两份清单合并：每页取更新的那个时间，删除记录也取更新的那个
    private nonisolated static func mergeManifest(_ a: Manifest, _ b: Manifest) -> Manifest {
        var out = a
        for (k, v) in b.conversations {
            if let cur = out.conversations[k] { out.conversations[k] = max(cur, v) }
            else { out.conversations[k] = v }
        }
        for (k, v) in b.deleted {
            if let cur = out.deleted[k] { out.deleted[k] = max(cur, v) }
            else { out.deleted[k] = v }
        }
        if let sa = b.settingsUpdatedAt, sa > (a.settingsUpdatedAt ?? .distantPast) {
            out.settingsHash = b.settingsHash
            out.settingsUpdatedAt = sa
        }
        return out
    }

    private static func readManifest(_ dir: URL) async -> Manifest? {
        parseManifest(await read(dir.appendingPathComponent("manifest.json")))
    }
    private static func readSettingsNow(_ dir: URL, hash: String?) -> [String: Any]? {
        parseSettings(readNow(dir.appendingPathComponent("settings.plist")), hash: hash)
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

    /// Coordinate the read/merge/write as one operation. Each device still verifies
    /// the result after upload, because iCloud can deliver changes later.
    private nonisolated static func publishManifest(_ candidate: Manifest, to url: URL) -> Manifest? {
        var result: Manifest?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordinationError) { path in
            let latest: Manifest
            if FileManager.default.fileExists(atPath: path.path) {
                guard let bytes = try? Data(contentsOf: path), let parsed = parseManifest(bytes) else { return }
                latest = parsed
            } else {
                guard !isCloudPlaceholder(path) else { return }
                latest = Manifest()
            }
            var merged = mergeManifest(latest, candidate)
            // Remove stale conversation entries that are covered by a deletion.
            for (key, timestamp) in merged.deleted where timestamp >= (merged.conversations[key] ?? .distantFuture) {
                merged.conversations[key] = nil
            }
            merged.updatedAt = Date()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(merged),
                  let encodedRevision = parseManifest(data),
                  (try? data.write(to: path, options: .atomic)) != nil else { return }
            // Compare the exact version on disk (ISO 8601 stores whole seconds).
            result = encodedRevision
        }
        return coordinationError == nil ? result : nil
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

    // MARK: - 完整录音 iCloud 管理（recordings/ 子文件夹）

    /// 该对话在 iCloud recordings/ 目录下的录音路径（仅在开启并可用 iCloud 时返回）
    func cloudRecordingURL(for id: UUID) -> URL? {
        guard enabled, let dir = resolveFolder() else { return nil }
        return dir
            .appendingPathComponent(Self.recordingsFolderName, isDirectory: true)
            .appendingPathComponent("\(id.uuidString).wav")
    }

    /// iCloud 中是否存在该对话的完整录音（含尚未下载到本机的 .icloud 占位文件）
    func hasCloudRecording(_ id: UUID) -> Bool {
        guard let url = cloudRecordingURL(for: id) else { return false }
        if FileManager.default.fileExists(atPath: url.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            return size > 44
        }
        return Self.isCloudPlaceholder(url)
    }

    /// 播放前确保 iCloud 上的完整录音已下载到本机，返回可直接供 AVAudioPlayer 读取的 URL
    func prepareCloudRecordingForPlayback(_ id: UUID) async -> URL? {
        guard let url = cloudRecordingURL(for: id) else { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            return url
        }
        guard Self.isCloudPlaceholder(url) else { return nil }
        try? fm.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if fm.fileExists(atPath: url.path) {
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > 44 { return url }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// 同一对话续录时：如果本地缓存已被上传后清理，先把 iCloud 里的录音复制回本地缓存再继续追加，避免覆盖冲突
    func restoreCloudRecordingToLocalIfNeeded(_ id: UUID) {
        let localURL = ConversationStore.audioFileURL(for: id)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: localURL.path),
              let cloudURL = cloudRecordingURL(for: id),
              fm.fileExists(atPath: cloudURL.path) else { return }
        try? fm.createDirectory(at: ConversationStore.conversationsDirectory, withIntermediateDirectories: true)
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: cloudURL, options: [], error: &err) { u in
            try? fm.copyItem(at: u, to: localURL)
        }
    }

    /// 手动删除历史会话时，立即同步删除 iCloud recordings/ 中对应的录音文件
    func deleteCloudRecording(_ id: UUID) {
        guard let url = cloudRecordingURL(for: id) else { return }
        Task {
            await Self.io { Self.remove(url) }
            hearLog("iCloud 同步：已删除云端录音 \(id.uuidString.prefix(8))")
        }
    }

    private nonisolated static func uploadRecordingFile(from localURL: URL, to remoteURL: URL) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: localURL.path),
              let localSize = (attrs[.size] as? NSNumber)?.int64Value,
              localSize > 44 else { return false }
        var ok = false
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: remoteURL, options: .forReplacing, error: &err) { dst in
            do {
                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: dst)
                }
                try fm.copyItem(at: localURL, to: dst)
                let dstAttrs = try fm.attributesOfItem(atPath: dst.path)
                let dstSize = (dstAttrs[.size] as? NSNumber)?.int64Value ?? 0
                ok = (dstSize == localSize)
            } catch {
                hearLog("iCloud 同步：上传录音失败 \(dst.lastPathComponent) \(error)", .warning)
                ok = false
            }
        }
        return err == nil && ok
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

    /// iCloud 云盘的根目录（文件选择器打开时直接定位到这里）
    static func iCloudDriveURL() -> URL? {
        // 1) App 自己的 iCloud 容器（有 iCloud 权限时才有）
        if let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            let docs = container.appendingPathComponent("Documents", isDirectory: true)
            if FileManager.default.fileExists(atPath: docs.path) { return docs }
            return container
        }
        // 2) 系统里 iCloud 云盘挂载的地方（所有 App 的云盘文件夹都在这个共享目录下）。
        //    文件选择器读的是系统自己给的路径，所以这么写不算越权；
        //    万一这个路径变了，定位不到也只是回到「上次的位置」，不会出问题。
        let shared = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/")
        if FileManager.default.fileExists(atPath: shared.path) { return shared }
        return nil
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
