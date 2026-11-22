import Foundation

@main
struct SessionJobQueueTests {
    @MainActor
    static func until(_ predicate: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        precondition(predicate(), "Timed out waiting for queue state")
    }

    @MainActor
    static func main() async throws {
        let queue = SessionJobQueue<Int>(timeout: .milliseconds(250))
        var handled: [Int] = []
        var timedOut: [Int] = []
        var oldWorkerStarted = false
        let process: @MainActor (Int) async -> Void = { handled.append($0) }
        let failure: @MainActor (Int) -> Void = { timedOut.append($0) }

        queue.submit(1, process: { _ in try? await Task.sleep(for: .seconds(20)) }, timedOut: failure)
        queue.submit(2, process: process, timedOut: failure)
        await until { queue.isIdle }
        precondition(handled == [2] && timedOut == [1], "A timed-out job blocked the next one")

        queue.submit(3, process: { _ in
            oldWorkerStarted = true
            try? await Task.sleep(for: .seconds(20))
        }, timedOut: failure)
        await until { oldWorkerStarted }
        queue.cancel()
        queue.submit(4, process: process, timedOut: failure)
        queue.submit(5, process: process, timedOut: failure)
        await until { queue.isIdle }
        precondition(handled == [2, 4, 5] && timedOut == [1], "Canceled worker changed the replacement queue")
        try testSpeakers()
        try testZipVoiceArchive()
        testCloudReadiness()
        try testConversationBubbleSides()
        try testTranslationRevision()
        try testCurrentSegmentTranslation()
        testSpeechGating()
        print("Session queue regressions passed")
    }

    static func testSpeakers() throws {
        var tracker = SpeakerTracker()
        func vector(_ x: Float, _ y: Float) -> [Float] { [x, y] + Array(repeating: 0, count: 30) }
        precondition(tracker.assign(vector(1, 0), after: 0) == 1)
        precondition(tracker.assign(vector(0.99, 0.01), after: 1) == 1)
        precondition(tracker.assign(vector(0.56, 0.83), after: 1) == nil, "Uncertain matches should remain unassigned")
        precondition(tracker.assign(vector(0, 1), after: 1) == 2)
        precondition(tracker.assign(vector(.nan, 1), after: 2) == nil)
        var items = [
            TranslationItem(source: .find("zh"), target: .find("en"), sourceText: "甲", speakerID: 1),
            TranslationItem(source: .find("zh"), target: .find("en"), sourceText: "乙", speakerID: 2),
            TranslationItem(source: .find("en"), target: .find("zh"), sourceText: "A", speakerID: 1),
            TranslationItem(source: .find("en"), target: .find("zh"), sourceText: "Legacy")
        ]
        let profile = SpeakerDetails(gender: .female, commonLanguage: "en", accent: .indian)
        items.editSpeaker(itemID: items[0].id,
                          change: .saveProfile(name: "  林\n经理  ", details: profile, newSpeaker: false))
        items.editSpeaker(itemID: items[1].id,
                          change: .saveProfile(name: "李经理", details: SpeakerDetails(gender: .male), newSpeaker: false))
        precondition(items[2].speakerLabel == "林 经理")
        precondition(items[2].speakerDetails == profile)
        items.editSpeaker(itemID: items[0].id, change: .assign(2))
        precondition(items[0].speakerLabel == "李经理" && items[0].speakerManuallySet == true)
        precondition(items[0].speakerDetails?.gender == .male)
        precondition(items[3].speakerLabel == nil)
        items.editSpeaker(itemID: items[3].id,
                          change: .saveProfile(name: "Taylor", details: profile, newSpeaker: true))
        precondition(items[3].speakerID == 3 && items[3].speakerDetails == profile)
        let data = try JSONEncoder().encode(items)
        let decoded = try JSONDecoder().decode([TranslationItem].self, from: data)
        precondition(decoded == items, "Speaker edits should survive persistence")
    }
}

private func testSpeechGating() {
    final class FakeSpeechDetector: SpeechPresenceDetector {
        var detectsSpeech = false
        func containsSpeech(_ samples: ArraySlice<Float>) -> Bool { detectsSpeech }
        func reset() { detectsSpeech = false }
    }

    let detector = FakeSpeechDetector()
    let segmenter = Segmenter()
    segmenter.speechDetector = detector
    segmenter.config.holdMode = true
    segmenter.config.minSpeechMs = 200
    var started = 0, ended = 0, previews = 0
    segmenter.onEvent = {
        switch $0 {
        case .started: started += 1
        case .ended: ended += 1
        case .partial: previews += 1
        default: break
        }
    }

    segmenter.feed(Array(repeating: 0.05, count: 16_000))
    precondition(started == 0 && previews == 0 && ended == 0, "Loud noise must not start recognition")
    detector.detectsSpeech = true
    segmenter.feed(Array(repeating: 0.25, count: 3_360))
    detector.detectsSpeech = false
    segmenter.feed(Array(repeating: 0.05, count: 16_000))
    precondition(started == 1 && ended == 1, "Short speech followed by noise should be kept and finalized")
}

private func testTranslationRevision() throws {
    let english = Language.find("en"), chinese = Language.find("zh")
    var item = TranslationItem(source: english, target: chinese, sourceText: "The mayor has arrived.")
    item.applyTranslation("市长刚刚到达。", done: false)
    item.beginTranslationRevision()
    item.applyTranslation(" ", done: false)
    precondition(item.translated == "市长刚刚到达。" && item.translationPending == true)
    item.applyTranslation("", done: true)
    precondition(item.translated == "市长刚刚到达。" && item.translationError != nil && item.done)
    item.beginTranslationRevision()
    item.applyTranslation("市长已经到达。", done: true)
    precondition(item.translationBaseline == "市长刚刚到达。" && item.translationPending == nil && item.translationError == nil)
    let chineseChanges = TranslationRevision.changes(from: item.translationBaseline!, to: item.translated)
    precondition(chineseChanges.filter { $0.changed }.map { $0.text }.joined() == "已经")
    let englishChanges = TranslationRevision.changes(from: "The bus left 👩🏽‍💻.", to: "The train left 👩🏽‍💻.")
    precondition(englishChanges.map { $0.text }.joined() == "The train left 👩🏽‍💻.")
    precondition(englishChanges.filter { $0.changed }.map { $0.text }.joined() == "train")
    item.updateTranscript("市长到了。", source: chinese, target: english, side: .left, recognizedLanguage: "zh")
    precondition(item.translated == "市长已经到达。" && item.displayedTranslationTarget == chinese && !item.canReadAloud)
    item.applyTranslation("The mayor has arrived.", done: true)
    precondition(item.displayedTranslationTarget == english && item.translationBaseline == nil && item.canReadAloud)
}

private func testCurrentSegmentTranslation() throws {
    let english = Language.find("en"), chinese = Language.find("zh")
    let priorSource = "The United States had been assessing the damage caused by severe storms and tornadoes, at least 21 people are now known to have died as the storms ripped through the south and the mid,"
    let source = "west leaving a trail of devastation hardest hit were Tennessee Arkansas and Indiana in Illinois one person was killed when a theater roof collapsed in Chicago"
    let prior = TranslationItem(source: english, target: chinese, sourceText: priorSource, done: true)
    let currentSegment = TranslationSource.currentSegment(source, language: english, after: prior)
    precondition(currentSegment.hasPrefix("Midwest leaving"))
    precondition(TranslationSource.currentSegment(source, language: english, after: nil) == source)
    var finished = prior
    finished.sourceText = "The storm ended in mid."
    precondition(TranslationSource.currentSegment(source, language: english, after: finished) == source)
    let prompt = PromptBuilder.build(text: currentSegment, from: english, to: chinese, glossary: [])
    precondition(!prompt.contains("21") && !prompt.contains(priorSource))
    precondition(prompt.hasSuffix("\n\n" + currentSegment))

}

private func testConversationBubbleSides() throws {
    let japanese = Language.find("ja"), english = Language.find("en"), chinese = Language.find("zh")
    let original = TranslationItem(source: japanese, target: english, sourceText: "先试一下")
    let legacy = try JSONDecoder().decode(TranslationItem.self, from: JSONEncoder().encode(original))
    precondition(legacy.isLeading(left: japanese, right: english))
    precondition(legacy.isLeading(left: chinese, right: english), "Legacy rows without a matching language keep their inferred side")
    precondition(legacy.defaultSpeakerLanguage == "ja")
    var detected = legacy
    detected.recognizedLanguage = "zh"
    precondition(detected.defaultSpeakerLanguage == "zh", "The detected language sets the profile default")
    detected.updateSide(from: (japanese, english), to: (english, chinese))
    precondition(!detected.isLeading(left: english, right: chinese), "The recognized language moves to the matching right side")
    detected.updateSide(from: (english, chinese), to: (japanese, english))
    precondition(!detected.isLeading(left: japanese, right: english), "When neither side matches, keep the last displayed side")
    detected.updateSide(from: (japanese, english), to: (chinese, english))
    precondition(detected.isLeading(left: chinese, right: english))
    let reply = TranslationItem(source: english, target: japanese, sourceText: "Hello", sourceSide: .right)
    let stored = try JSONDecoder().decode(TranslationItem.self, from: JSONEncoder().encode(reply))
    precondition(stored.isLeading(left: english, right: japanese), "A matching language takes priority over the stored side")
}

private func testCloudReadiness() {
    let data = Data(#"{"asr":"未加载","asr_ready":true,"mt":"加载中","mt_ready":false,"clone":"外部服务连不上","clone_ready":false}"#.utf8)
    let fields = CloudModelReadiness.fields(from: data)
    func readiness(_ key: String) -> CloudModelReadiness {
        CloudModelReadiness(reported: fields[key], ready: fields["\(key)_ready"])
    }
    precondition(readiness("asr") == .ready)
    precondition(readiness("mt") == .loading)
    precondition(readiness("clone") == .unavailable)
    precondition(CloudModelReadiness(reported: nil, ready: nil) == .unknown)
    precondition(CloudModelReadiness(reported: "就绪（small）", ready: nil) == .ready)
}

private func testZipVoiceArchive() throws {
    // Fixtures contain a padded model file, voice data and an ignored sample, or an unsafe path.
    let fixtures = [
        "QlpoOTFBWSZTWeCM5WUAAL1/gMmABABAA/2AAoAgAO6v38AIKDAAuSGUE1PKaeKZAB6Qaeg9UMAMmmgyGCGmI0YEVE1BppoxAAyaNNA/YY/KRkSgI4SjlRErqs9MGgZolLQ5hzwUCIMAuv8X3VGMNzOITsBW222QNWSLsmrlZBwbYplHHsHYGBc5ZrNZVfcs46Co95/te/x9RtkwUpKb3tZGMNMsS03W2QPDJM5cZhCgid1qjsQsG/reg1EVjWoED+LuSKcKEhwRnKyg",
        "QlpoOTFBWSZTWcnZvxQAAH15gMmAAAFAA+0A7qneAAgIIAB0GUTNJoA000aMmgklGgDR6gAA+ysJEIOYIQiXp6BqoTIEMDG3DjmrHmFOiiHqBElkL5z4SVyF85rlVk+hAUjFyd1qxopjZVnNS0CSB+LuSKcKEhk7N+KA"
    ]
    let fm = FileManager.default
    let stage = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = stage.appendingPathComponent("model")
    try fm.createDirectory(at: model, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: stage) }
    let archive = stage.appendingPathComponent("model.tar.bz2")
    try Data(base64Encoded: fixtures[0])!.write(to: archive)
    try ZipVoiceArchive.extract(archive, into: model, root: "root", modelFiles: ["model.onnx"])
    let weight = try Data(contentsOf: model.appendingPathComponent("model.onnx"))
    let dictionary = try Data(contentsOf: model.appendingPathComponent("espeak-ng-data/en_dict"))
    precondition(weight == Data(repeating: 120, count: 513) && dictionary == Data("dict".utf8))
    precondition(!fm.fileExists(atPath: model.appendingPathComponent("test_wavs").path))

    try Data(base64Encoded: fixtures[1])!.write(to: archive)
    do {
        try ZipVoiceArchive.extract(archive, into: model, root: "root", modelFiles: [])
        preconditionFailure("Unsafe archive path was accepted")
    } catch ZipVoiceArchive.Failure.invalidArchive { }
}
