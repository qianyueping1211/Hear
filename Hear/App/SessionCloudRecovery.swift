import Foundation

@MainActor
final class SessionCloudRecovery {
    enum Engine: String { case asr, mt }

    private let defaults: UserDefaults
    private let key = "enginePreferredBeforeFallback"
    private var task: Task<Void, Never>?
    private(set) var isApplying = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var hasBackup: Bool { defaults.bool(forKey: key) }

    func preferred(_ engine: Engine) -> String? {
        guard hasBackup else { return nil }
        return defaults.string(forKey: key + "." + engine.rawValue)
    }

    func remember(asr: String, mt: String) {
        if defaults.string(forKey: key + ".asr") == nil { defaults.set(asr, forKey: key + ".asr") }
        if defaults.string(forKey: key + ".mt") == nil { defaults.set(mt, forKey: key + ".mt") }
        defaults.set(true, forKey: key)
    }

    func restored(_ engine: Engine) {
        defaults.removeObject(forKey: key + "." + engine.rawValue)
    }

    func clear() {
        guard hasBackup else { return }
        defaults.removeObject(forKey: key)
        restored(.asr)
        restored(.mt)
    }

    func applying(_ changes: () -> Void) {
        let previous = isApplying
        isApplying = true
        defer { isApplying = previous }
        changes()
    }

    func schedule(refresh: @escaping @MainActor () async -> Void) {
        guard task == nil else { return }
        task = Task { [weak self] in
            defer { self?.task = nil }
            while self?.hasBackup == true {
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                guard self?.hasBackup == true, !Task.isCancelled else { return }
                await refresh()
            }
        }
    }
}
