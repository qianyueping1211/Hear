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
        try await testCloudInferencePolicy()
        try testVerifiedAddress()
        try await testRecoveryState()
        await testSenseVoiceRecovery()
        await testPreviewPipeline()
        testPreviewCadence()
        try testConversationBubbleSides()
        try testTranslationRevision()
        try testCurrentSegmentTranslation()
        testSpeechGating()
        testSegmentContinuity()
        testPrerollComparison()
        testBoundedAudioAndTimeline()
        testSpeechLanguageResolution()
        testGlossaryAliases()
        testClonePlaybackSilence()
        testClonePlaybackGain()
        testChineseDisplayLanguage()
        testConversationMerge()
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

@MainActor
private func testSenseVoiceRecovery() async {
    let queue = SessionJobQueue<Int>()
    let recovery = SenseVoiceRecovery()
    var processed: [Int] = []
    var overflow: [Int] = []
    var outcomes: [SenseVoiceRecovery.Outcome] = []
    queue.pause()
    for number in 1...4 {
        queue.submit(number, onOverflow: { overflow.append($0) },
                     process: { processed.append($0) }, timedOut: { _ in preconditionFailure() })
    }
    queue.keepPending(SenseVoiceRecovery.bufferedSegments)
    precondition(!queue.isIdle && processed.isEmpty && overflow == [4])
    recovery.start(timeout: .seconds(2), repair: {
        try await Task.sleep(for: .milliseconds(60))
    }) { result in
        outcomes.append(result)
        queue.resume()
    }
    await SessionJobQueueTests.until { queue.isIdle }
    precondition(outcomes == [.recovered] && processed == [1, 2, 3])

    // A continuation ignores Task.cancel like an in-flight Core ML call might.
    let engine = HeldInference()
    queue.pause()
    queue.submit(5, process: { processed.append($0) }, timedOut: { _ in preconditionFailure() })
    recovery.start(timeout: .milliseconds(200), repair: { await engine.wait() }) { result in
        outcomes.append(result)
        queue.cancel()
    }
    await SessionJobQueueTests.until { outcomes.count == 2 }
    precondition(outcomes.last == .timedOut && !recovery.isActive && queue.isIdle)
    precondition(processed == [1, 2, 3])
    await engine.complete()
    await Task.yield()
    precondition(outcomes.count == 2, "A late recovery changed the final state")
}

private actor HeldInference {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func complete() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private func testPreviewCadence() {
    var cadence = PreviewCadence()
    let start = ContinuousClock.now
    let firstEnd = start.advanced(by: .milliseconds(600))
    precondition(cadence.waitUntil(segment: 1, now: start) == nil)
    cadence.completed(segment: 1, started: start, ended: firstEnd)
    precondition(cadence.waitUntil(segment: 1, now: firstEnd) == start.advanced(by: .milliseconds(900)))
    precondition(cadence.waitUntil(segment: 2, now: firstEnd) == nil)
    let slowEnd = start.advanced(by: .milliseconds(1400))
    cadence.completed(segment: 1, started: start, ended: slowEnd)
    precondition(cadence.waitUntil(segment: 1, now: slowEnd) == start.advanced(by: .milliseconds(1600)))
    cadence.completed(segment: 1, started: start, ended: start.advanced(by: .milliseconds(50)))
    precondition(cadence.waitUntil(segment: 1, now: start) == start.advanced(by: .milliseconds(400)))
}

@MainActor
private func testPreviewPipeline() async {
    let lane = LatestPreviewWork<Int>()
    let engine = HeldInference()
    var owner: UUID?
    var seen: [Int] = []
    lane.submit(1) { id in
        owner = id
        seen.append(lane.next(for: id)!)
        await engine.wait()
        precondition(lane.next(for: id) == nil, "Canceled preview took a new snapshot")
    }
    await SessionJobQueueTests.until { owner != nil }
    lane.cancel()
    lane.submit(2) { id in seen.append(lane.next(for: id)!) }
    lane.submit(3) { _ in preconditionFailure("Preview lanes should coalesce pending input") }
    await engine.complete()
    await SessionJobQueueTests.until { seen.count == 2 }
    precondition(seen == [1, 3])
    precondition(SessionPreviewPipeline.merge("the first part", "part is ready") == "the first part is ready")
}

private func testCloudInferencePolicy() async throws {
    precondition(CloudInferencePolicy.canTryAnotherAddress(after: .cannotConnectToHost))
    precondition(!CloudInferencePolicy.canTryAnotherAddress(after: .timedOut))
    precondition(!CloudInferencePolicy.canTryAnotherAddress(after: .networkConnectionLost))
    precondition(CloudInferencePolicy.canTryAnotherAddress(afterHTTPStatus: 503))
    precondition(!CloudInferencePolicy.canTryAnotherAddress(afterHTTPStatus: 504))
    precondition(CloudInferencePolicy.canRetryConnection(after: .cannotConnectToHost))
    precondition(!CloudInferencePolicy.canRetryConnection(after: .notConnectedToInternet))
    precondition(!CloudInferencePolicy.canRetryConnection(after: .networkConnectionLost))
    precondition(!CloudInferencePolicy.canRetryConnection(after: .timedOut))
    precondition(CloudInferencePolicy.cloneBudget(forCharacters: 25) == 35)
    precondition(CloudInferencePolicy.cloneBudget(forCharacters: 500) == 90)
    let started = ContinuousClock.now
    let value = try await CloudInferencePolicy.before(started.advanced(by: .seconds(2))) { 42 }
    precondition(value == 42)
    do {
        _ = try await CloudInferencePolicy.before(ContinuousClock.now.advanced(by: .milliseconds(50))) {
            try await Task.sleep(for: .seconds(5))
            return 42
        }
        preconditionFailure("A slow request completed after its deadline")
    } catch let error as URLError where error.code == .timedOut {
        precondition(started.duration(to: .now) < .seconds(3), "The expired request kept the next job waiting")
    }
}

private func testVerifiedAddress() throws {
    let fingerprint = String(repeating: "aF", count: 32)
    let verified = try CloudPairingAddress.parse("https://192.168.1.30:8000/#hear-root=" + fingerprint)
    precondition(verified?.address == "https://192.168.1.30:8000")
    precondition(verified?.expectedRootSHA256 == fingerprint.lowercased())
    let ordinary = try CloudPairingAddress.parse("192.168.1.30:8000")
    precondition(ordinary == nil)
    for input in ["http://192.168.1.30#hear-root=" + fingerprint,
                  "https://example.com/path#hear-root=" + fingerprint,
                  "https://192.168.1.30#hear-root=short"] {
        do {
            _ = try CloudPairingAddress.parse(input)
            preconditionFailure("Accepted an invalid verified address")
        } catch is CloudPairingAddress.InvalidAddress {}
    }
}

@MainActor
private func testRecoveryState() async throws {
    let suite = "hear.recovery.tests." + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("No test defaults") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let cloud = SessionCloudRecovery(defaults: defaults)
    cloud.remember(asr: "cloud", mt: "cloud")
    cloud.remember(asr: "apple", mt: "local")
    cloud.applying {
        precondition(cloud.isApplying)
        cloud.restored(.asr)
    }
    precondition(cloud.preferred(.asr) == nil && cloud.preferred(.mt) == "cloud")
    precondition(!cloud.isApplying)
    cloud.clear()
    precondition(!cloud.hasBackup)

    let clones = SessionClonePipeline()
    let id = UUID()
    var oldToken: UUID?, newToken: UUID?
    let old = clones.start(id) { token in
        oldToken = token
        return Task { try? await Task.sleep(for: .seconds(2)); return nil }
    }
    _ = clones.start(id) { _ in preconditionFailure("Duplicate clone should be reused") }
    clones.cancel(id)
    _ = clones.start(id) { token in
        newToken = token
        return Task { try? await Task.sleep(for: .seconds(2)); return nil }
    }
    _ = await old.value
    await Task.yield()
    precondition(oldToken != newToken && clones.isCurrent(id, token: newToken!))
    clones.markTimedOut(id, token: oldToken!)
    precondition(!clones.didTimeOut(id))
    clones.markTimedOut(id, token: newToken!)
    precondition(clones.didTimeOut(id))
    clones.allowRetry(id)
    precondition(!clones.didTimeOut(id))
    clones.reset()
    precondition(clones.existing(id) == nil)

    let queue = SessionJobQueue<Int>(timeout: .seconds(5))
    var timedOut = false
    var nextRan = false
    queue.submit(1, timeout: .milliseconds(65)) { _ in
        try? await Task.sleep(for: .seconds(5))
    } timedOut: { _ in timedOut = true }
    queue.submit(2) { _ in nextRan = true } timedOut: { _ in preconditionFailure() }
    await SessionJobQueueTests.until { queue.isIdle }
    precondition(timedOut && nextRan)
}

private func testClonePlaybackSilence() {
    let rate = 24_000
    let tone = (0..<(rate / 2)).map { Float(sin(Double($0) * 2 * .pi * 210 / Double(rate))) * 0.12 }
    let pause = [Float](repeating: 0, count: rate / 4)
    let speech = tone + pause + tone
    let quiet = (0..<(rate * 5)).map { $0.isMultiple(of: 2) ? Float(0.00015) : -0.00015 }
    var leading = quiet
    leading[rate] = 0.9
    let clip = CloneAudio(samples: leading + speech + quiet, sampleRate: rate)
    guard let trimmed = clip.trimmingEdgeSilence() else { preconditionFailure("Rejected a sentence with silent edges") }
    precondition(trimmed.leading == rate * 5 - rate * 8 / 100)
    precondition(trimmed.trailing == rate * 5 - rate / 10)
    let voicedStart = leading.count - trimmed.leading
    precondition(Array(trimmed.audio.samples[voicedStart..<(voicedStart + speech.count)]) == speech,
                 "Trimming edges changed speech or its internal pause")
    let cached = trimmed.audio.trimmingEdgeSilence()
    precondition(cached?.leading == 0 && cached?.trailing == 0, "Reopening prepared audio changed its length")
    precondition(CloneAudio(samples: quiet, sampleRate: rate).trimmingEdgeSilence() == nil)
    precondition(CloneAudio(samples: [.nan] + tone, sampleRate: rate).trimmingEdgeSilence() == nil)
    let short = CloneAudio(samples: tone, sampleRate: rate).trimmingEdgeSilence()
    precondition(short?.audio.samples == tone && short?.leading == 0 && short?.trailing == 0)
}

private func testClonePlaybackGain() {
    let rate = 24_000
    let quiet = (0..<4_800).map { $0.isMultiple(of: 2) ? Float(0.002) : -0.002 }
    guard let level = CloneAudio(samples: quiet, sampleRate: rate).playbackGain() else {
        preconditionFailure("Rejected a quiet recording with sustained signal")
    }
    precondition(level.gain == 8)
    let silence = [Float](repeating: 0, count: quiet.count)
    var click = silence
    click[450] = 0.6
    precondition(CloneAudio(samples: silence, sampleRate: rate).playbackGain() == nil)
    precondition(CloneAudio(samples: click, sampleRate: rate).playbackGain() == nil)
    precondition(CloneAudio(samples: [.infinity] + quiet, sampleRate: rate).playbackGain() == nil)
    let loud = quiet.map { $0 * 500 }
    let peak = CloneAudio(samples: loud, sampleRate: rate).playbackGain()
    precondition(peak.map { $0.gain * $0.peak <= 0.85 } == true)
}

private func testChineseDisplayLanguage() {
    let simplified = ChineseDisplayLanguage.simplified
    let traditional = ChineseDisplayLanguage.traditional
    let original = "中文語音識別與翻譯"
    let converted = "中文语音识别与翻译"
    precondition(simplified.display(original, languageID: "zh") == converted)
    precondition(traditional.display(converted, languageID: "zh") == original)
    let japanese = "翻訳と図書"
    precondition(simplified.display(japanese, languageID: "ja") == japanese)
    let item = TranslationItem(source: .find("ja"), target: .find("en"),
                               sourceText: original, translated: "Speech recognition",
                               recognizedLanguage: "zh")
    precondition(item.displayedSource(using: simplified) == converted)
    precondition(item.displayedTranslation(using: simplified) == "Speech recognition")
    precondition(item.sourceText == original, "Changing the display script must not edit conversation history")
}

private func testConversationMerge() {
    let chinese = Language.find("zh"), english = Language.find("en")
    let item = TranslationItem(source: chinese, target: english, sourceText: "好",
                               translated: "Okay", done: true, speakerID: 1)
    let base = Conversation(title: "测试对话", langA: chinese, langB: english, items: [item])
    var local = base, remote = base
    local.items[0].speakerName = "小林"
    remote.items[0].translated = "All right"
    remote.summaries["example"] = SummaryRecord(status: .done, content: "Meeting recap")
    let merged = local.merging(remote, from: base)
    precondition(!merged.conflict && merged.conversation.items[0].speakerName == "小林")
    precondition(merged.conversation.items[0].translated == "All right")
    precondition(merged.conversation.summaries["example"]?.content == "Meeting recap")
    remote.items[0].speakerName = "小王"
    precondition(local.merging(remote, from: base).conflict, "Both edits to the same speaker must be preserved as a conflict")
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

private func testSegmentContinuity() {
    func segments(for audio: [Float]) -> [[Float]] {
        let segmenter = Segmenter()
        var results: [[Float]] = []
        segmenter.onEvent = {
            if case .ended(_, let samples, _, _) = $0 { results.append(samples) }
        }
        for start in stride(from: 0, to: audio.count, by: 1_613) {
            segmenter.feed(Array(audio[start..<min(start + 1_613, audio.count)]))
        }
        segmenter.flush()
        return results
    }
    let rate = 16_000
    let first = (0..<(rate * 12)).map { 0.04 + Float($0) / Float(rate * 1_000) }
    let pause = [Float](repeating: 0, count: 6 * 480)
    let second = [Float](repeating: 0.07, count: rate + 97)
    let natural = segments(for: first + pause + second)
    precondition(natural.count == 2 && natural[0] == first + pause && natural[1] == second,
                 "A natural pause near the limit should split without dropping or reusing audio")
    let continuous = (0..<(rate * 15 + 6 * 480 + 29)).map { 0.04 + Float($0) / Float(rate * 1_000) }
    let hardLimit = segments(for: continuous)
    precondition(hardLimit.count == 2 && hardLimit[0].count == rate * 15,
                 "Continuous speech should keep a short remainder after the hard limit")
    precondition(hardLimit.flatMap { $0 } == continuous, "The hard split changed the audio stream")
}

private func testBoundedAudioAndTimeline() {
    var buffer = AudioInputBuffer<Int>(capacity: 8)
    precondition(buffer.append(1, frames: 4).schedule)
    precondition(!buffer.append(2, frames: 4).schedule)
    precondition(buffer.append(3, frames: 4).dropped)
    precondition(buffer.frames == 8 && buffer.pop() == 2 && buffer.pop() == 3 && buffer.pop() == nil)
    precondition(buffer.append(4, frames: 8).schedule)
    buffer.removePending()
    precondition(buffer.frames == 0 && buffer.pop() == nil)

    let segmenter = Segmenter()
    var starts: [Int64] = []
    var ends: [Int64] = []
    var discarded = 0
    segmenter.onEvent = {
        switch $0 {
        case .started(_, let start): starts.append(start)
        case .ended(_, _, let end, _): ends.append(end)
        case .discarded: discarded += 1
        default: break
        }
    }
    segmenter.feed(Array(repeating: 0.08, count: 9_600), startingAt: 0)
    segmenter.feed(Array(repeating: 0.08, count: 9_600), startingAt: 32_000)
    segmenter.flush()
    precondition(starts == [0, 32_000] && ends == [41_600] && discarded == 1,
                 "A dropped interval must not stitch two sides into one sentence")
}

private func testPrerollComparison() {
    func boundaries(preroll: Int) -> (start: Int64?, end: Int64?, preview: Int64?) {
        let segmenter = Segmenter()
        segmenter.config.prerollMs = preroll
        var start: Int64?, end: Int64?, preview: Int64?
        segmenter.onEvent = { event in
            switch event {
            case .started(_, let position): start = position
            case .partial(_, let samples):
                if preview == nil, let start { preview = start + Int64(samples.count) }
            case .ended(_, _, let position, _): end = position
            default: break
            }
        }
        segmenter.feed(Array(repeating: 0, count: 16_320))
        segmenter.feed(Array(repeating: 0.08, count: 16_320))
        segmenter.flush()
        return (start, end, preview)
    }
    let regular = boundaries(preroll: 300), longer = boundaries(preroll: 450)
    precondition(regular.start != nil && longer.start != nil && regular.start! - longer.start! == 2_400)
    precondition(regular.end == 32_640 && longer.end == regular.end)
    precondition(regular.preview != nil && longer.preview == regular.preview)
}

private func testGlossaryAliases() {
    let entries = PromptBuilder.parseGlossary("张伟|章伟|zhang wei=Zhang Wei\nAPI=接口\n旧术语=legacy")
    let text = "章伟 rapid 旧术语"
    let prompt = PromptBuilder.build(text: text, from: .find("zh"), to: .find("en"), glossary: entries)
    precondition(prompt.contains("章伟 翻译成 Zhang Wei") && prompt.contains("旧术语 翻译成 legacy"))
    precondition(!prompt.contains("API 翻译成") && prompt.hasSuffix("\n\n" + text))
    let mixed = PromptBuilder.build(text: "讨论API", from: .find("zh"), to: .find("en"), glossary: entries)
    precondition(mixed.contains("API 翻译成 接口"))
}

private func testSpeechLanguageResolution() {
    let pair = ["zh", "en"]
    precondition(SpeechTextFilter.resolveLanguage("明天 meeting 讨论 API design", detected: "en",
                                                  candidates: pair, fallback: "en") == "zh")
    precondition(SpeechTextFilter.resolveLanguage("Schedule the API meeting", detected: "zh",
                                                  candidates: pair, fallback: "zh") == "en")
    precondition(SpeechTextFilter.resolveLanguage("今天開會", detected: "zh",
                                                  candidates: ["ja", "en"], fallback: "en") == "ja")
    precondition(SpeechTextFilter.resolveLanguage("今日は API を使います", detected: "zh",
                                                  candidates: ["zh", "ja"], fallback: "zh") == "ja")
    precondition(SpeechTextFilter.resolveLanguage("오늘 API를 봅니다", detected: "en",
                                                  candidates: ["ko", "en"], fallback: "en") == "ko")
    precondition(SpeechTextFilter.resolveLanguage("это не речь", detected: "zh", candidates: pair, fallback: "zh") == nil)
    precondition(SpeechTextFilter.retryLanguage("это не речь", detected: "zh", candidates: pair) == nil)
    precondition(SpeechTextFilter.retryLanguage("робот API", detected: "ja", candidates: pair) == nil)
    precondition(SpeechTextFilter.retryLanguage("робот API", detected: "ja", candidates: pair, confirmedSpeech: true) == "en")
    precondition(SpeechTextFilter.retryLanguage("明天 到场 API", detected: "ja", candidates: pair, confirmedSpeech: true) == nil)
    precondition(!SpeechTextFilter.isMeaningful("嗯，嗯。"))
    precondition(!SpeechTextFilter.isMeaningful("Thank you for watching"))
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
    precondition(item.canRetryTranslation)
    var missingSource = TranslationItem(source: english, target: chinese, sourceText: "（没听清）")
    missingSource.applyTranslation("（翻译失败：识别未完成）", done: true)
    precondition(!missingSource.canRetryTranslation)
    item.beginTranslationRevision()
    precondition(!item.canRetryTranslation, "A retry in progress must not start another retry")
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
