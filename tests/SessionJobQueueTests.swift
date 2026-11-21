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
    static func main() async {
        let queue = SessionJobQueue<Int>(timeout: .milliseconds(250))
        var handled: [Int] = []
        var timedOut: [Int] = []
        var oldWorkerStarted = false
        let process: @MainActor (Int) async -> Void = { handled.append($0) }
        let failure: @MainActor (Int) -> Void = { timedOut.append($0) }

        queue.submit(1) { _ in try? await Task.sleep(for: .seconds(20)) } timedOut: failure
        queue.submit(2, process: process, timedOut: failure)
        await until { queue.isIdle }
        precondition(handled == [2] && timedOut == [1], "A timed-out job blocked the next one")

        queue.submit(3) { _ in
            oldWorkerStarted = true
            try? await Task.sleep(for: .seconds(20))
        } timedOut: failure
        await until { oldWorkerStarted }
        queue.cancel()
        queue.submit(4, process: process, timedOut: failure)
        queue.submit(5, process: process, timedOut: failure)
        await until { queue.isIdle }
        precondition(handled == [2, 4, 5] && timedOut == [1], "Canceled worker changed the replacement queue")
        print("Session queue regressions passed")
    }
}
