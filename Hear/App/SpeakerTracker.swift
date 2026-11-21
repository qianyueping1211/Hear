import Foundation

/// Voice vectors are retained only for the current open conversation.
struct SpeakerTracker {
    private var profiles: [Int: [Float]] = [:]
    var lastID: Int { profiles.keys.max() ?? 0 }

    mutating func assign(_ embedding: [Float], after lastSpeakerID: Int) -> Int? {
        guard (32...512).contains(embedding.count), let vector = Self.normalized(embedding) else { return nil }
        let ranked = profiles.compactMap { id, reference -> (id: Int, score: Float)? in
            guard reference.count == vector.count else { return nil }
            let score = zip(reference, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            return (id, score)
        }.sorted { $0.score > $1.score }
        if let best = ranked.first, best.score >= 0.66 {
            if ranked.count > 1, best.score - ranked[1].score < 0.08 { return nil }
            if let reference = profiles[best.id] {
                profiles[best.id] = Self.normalized(zip(reference, vector).map { $0.0 * 0.8 + $0.1 * 0.2 })
            }
            return best.id
        }
        if let best = ranked.first, best.score > 0.45 { return nil }
        guard profiles.count < 16 else { return nil }
        let next = max(lastSpeakerID, lastID) + 1
        profiles[next] = vector
        return next
    }

    private static func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0.0001 else { return nil }
        return vector.map { $0 / norm }
    }
}
