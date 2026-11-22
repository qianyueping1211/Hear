import Foundation

enum CloudInferencePolicy {
    static func canRetryConnection(after code: URLError.Code) -> Bool {
        [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(code)
    }

    static func cloneBudget(forCharacters count: Int) -> Double {
        min(90, 30 + Double(count) * 0.2)
    }

    static func asrBudget(forSamples count: Int) -> Double {
        min(42, max(22, 12 + Double(count) / 8_000))
    }

    // These failures say the connection couldn't be established. A timeout or
    // connection loss may come after the server has already received the POST.
    static func canTryAnotherAddress(after code: URLError.Code) -> Bool {
        switch code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return true
        default:
            return false
        }
    }

    static func canTryAnotherAddress(afterHTTPStatus status: Int) -> Bool {
        [401, 403, 404, 405, 429, 503].contains(status)
    }

    static func before<T: Sendable>(_ deadline: ContinuousClock.Instant,
                                    operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(until: deadline, clock: ContinuousClock())
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}
