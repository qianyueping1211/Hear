import SwiftUI

@main
struct HearApp: App {
    @StateObject private var session = LiveSession()

    init() {
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
