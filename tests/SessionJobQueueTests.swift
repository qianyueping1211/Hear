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
        items.editSpeaker(itemID: items[0].id, change: .rename("  林\n经理  "))
        items.editSpeaker(itemID: items[1].id, change: .rename("李经理"))
        precondition(items[2].speakerLabel == "林 经理")
        items.editSpeaker(itemID: items[0].id, change: .assign(2))
        precondition(items[0].speakerLabel == "李经理" && items[0].speakerManuallySet == true)
        precondition(items[3].speakerLabel == nil)
        let data = try JSONEncoder().encode(items)
        let decoded = try JSONDecoder().decode([TranslationItem].self, from: data)
        precondition(decoded == items, "Speaker edits should survive persistence")
    }
}
