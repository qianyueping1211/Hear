import ActivityKit
import Foundation

struct HearLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var itemID: String? = nil
        var sourceText: String
        var translatedText: String
        var translationBaseline: String? = nil
        var sourceLanguage: String
        var targetLanguage: String
        var speaker: String?
        var speakerGender: String?
        var translationOnly: Bool
        var isLive: Bool
        var updatedAt: Date
    }

    var conversationTitle: String
}
