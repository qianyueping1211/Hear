import Foundation

struct AudioInputBlock {
    static let sampleRate = 16_000
    let samples: [Float]
    let startFrame: Int64
    var endFrame: Int64 { startFrame + Int64(samples.count) }
}

/// Used under the owner's lock. A single scheduled consumer drains the bounded
/// buffer, so there is no unbounded DispatchQueue of captured audio arrays.
struct AudioInputBuffer<Value> {
    let capacity: Int
    private var pending: [(value: Value, frames: Int)] = []
    private(set) var frames = 0
    private var scheduled = false

    init(capacity: Int) { self.capacity = capacity }

    mutating func append(_ value: Value, frames count: Int) -> (schedule: Bool, dropped: Bool) {
        var dropped = false
        while frames + count > capacity, !pending.isEmpty {
            frames -= pending.removeFirst().frames
            dropped = true
        }
        guard count <= capacity else { return (false, true) }
        pending.append((value, count))
        frames += count
        if scheduled { return (false, dropped) }
        scheduled = true
        return (true, dropped)
    }

    mutating func pop() -> Value? {
        guard !pending.isEmpty else {
            scheduled = false
            return nil
        }
        let next = pending.removeFirst()
        frames -= next.frames
        return next.value
    }

    mutating func removePending() {
        pending.removeAll(keepingCapacity: true)
        frames = 0
        // A scheduled drainer still owns the handoff until it finds the buffer empty.
    }
}
