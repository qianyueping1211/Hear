import SwiftUI

@main
struct HearApp: App {
    @StateObject private var session = LiveSession()

    init() {
        // 崩溃/被杀掉的诊断：越早装上越好
        CrashGuard.shared.install()
        // 退到后台：正常结束，把"正在运行"的标记删掉
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            CrashGuard.shared.clearMarker()
        }
        // 回到前台：重新记上"正在运行"，
        // 这样在后台被系统杀掉（内存不够）也能在下次打开时看出来
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in
            CrashGuard.shared.markRunning()
        }
        // iCloud 同步：iCloud 上的设置比较新就先用上（要在 LiveSession 读设置之前）
        CloudSync.shared.applyCloudSettingsAtLaunch()
        // 在 LiveSession 读设置之前先调整默认值
        let d = UserDefaults.standard
        let a = d.string(forKey: "langA") ?? "zh"
        let b = d.string(forKey: "langB") ?? "en"
        let zh = a == "zh" ? "A" : (b == "zh" ? "B" : "A")      // 中文在哪一侧
        // 耳机左右耳默认都播中文（只设一次，之后按用户自己的选择）
        if d.object(forKey: "earsDefaultZhV1") == nil {
            d.set(true, forKey: "earsDefaultZhV1")
            d.set(zh, forKey: "leftEar")
            d.set(zh, forKey: "rightEar")
        }
        // “我说的语言”不再显示，固定为中文
        d.set(zh, forKey: "mySide")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
        }
    }
}
