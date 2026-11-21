import ActivityKit
import Foundation

struct HearLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var sourceText: String
        var translatedText: String
        var sourceLanguage: String
        var targetLanguage: String
        var speaker: String?
        var isLive: Bool
        var updatedAt: Date
    }

    var conversationTitle: String
}
