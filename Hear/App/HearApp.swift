import SwiftUI

@main
struct HearApp: App {
    @StateObject private var session = LiveSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
        }
    }
}
