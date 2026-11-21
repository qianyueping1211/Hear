import Foundation

@main
struct SessionJobQueueTests {
    @MainActor
    static func main() async {
        let queue = SessionJobQueue<Int>(timeout: .milliseconds(100))
        var handled: [Int] = []
        var timedOut: [Int] = []
        queue.submit(1) { job in
            if job == 1 { try? await Task.sleep(for: .seconds(1)); return }
            handled.append(job)
        } timedOut: { timedOut.append($0) }
        queue.submit(2) { _ in preconditionFailure("The active worker owns the callbacks") }
            timedOut: { _ in preconditionFailure("Unexpected timeout callback") }
        try? await Task.sleep(for: .milliseconds(350))
        precondition(handled == [2] && timedOut == [1] && queue.isIdle)

        queue.submit(3) { _ in try? await Task.sleep(for: .seconds(1)) }
            timedOut: { _ in preconditionFailure("Canceled work must not time out") }
        await Task.yield()
        queue.cancel()
        let process: @MainActor (Int) async -> Void = { handled.append($0) }
        let failure: @MainActor (Int) -> Void = { _ in preconditionFailure("Replacement work timed out") }
        queue.submit(4, process: process, timedOut: failure)
        queue.submit(5, process: process, timedOut: failure)
        try? await Task.sleep(for: .milliseconds(150))
        precondition(handled == [2, 4, 5] && queue.isIdle)
        print("Session queue regressions passed")
    }
}
