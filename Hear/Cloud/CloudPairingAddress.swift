import Foundation

struct CloudPairingAddress {
    let address: String
    let expectedRootSHA256: String

    struct InvalidAddress: LocalizedError {
        var errorDescription: String? { "此专用服务地址无效，请从电脑启动窗口重新复制。" }
    }

    static func parse(_ value: String) throws -> Self? {
        guard value.contains("#") else { return nil }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = value.contains("://") ? value : "https://" + value
        guard var parts = URLComponents(string: source), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.path.isEmpty || parts.path == "/",
              let fragment = parts.fragment, fragment.hasPrefix("hear-root=") else { throw InvalidAddress() }
        let fingerprint = fragment.dropFirst("hear-root=".count).lowercased()
        guard fingerprint.count == 64, fingerprint.allSatisfy({ "0123456789abcdef".contains($0) })
        else { throw InvalidAddress() }
        parts.fragment = nil
        parts.path = ""
        guard let address = parts.string else { throw InvalidAddress() }
        return Self(address: address, expectedRootSHA256: fingerprint)
    }
}
