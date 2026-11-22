enum CloudSettingsSyncPolicy {
    enum Action: Equatable { case push, pull, none }

    static func decide(local: String, legacyLocal: String, last: String?, remote: String?,
                       forcePush: Bool = false) -> Action {
        if forcePush { return .push }
        guard let remote else { return .push }
        if remote == local { return .none }
        guard let last else { return .pull }
        // Added keys change the hash even if the user has not edited any settings
        // that the previous release knew about.
        if remote != last, local == last || legacyLocal == last { return .pull }
        return .push
    }
}
