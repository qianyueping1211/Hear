import Foundation

enum CloudModelReadiness: String {
    case ready = "正常"
    case loading = "加载中"
    case unavailable = "异常"
    case unknown = "状态未知"

    init(reported: String?, ready: String?) {
        let state = reported?.lowercased() ?? ""
        if ready == "true" {
            self = .ready
        } else if state.hasPrefix("加载中") || state.hasPrefix("未加载") || state.contains("loading") {
            self = .loading
        } else if ready == "false" || state.contains("连不上") {
            self = .unavailable
        } else if state.hasPrefix("就绪") || state.hasPrefix("外部服务") || state.hasPrefix("ok") {
            self = .ready
        } else {
            self = state.isEmpty ? .unknown : .unavailable
        }
    }

    static func fields(from data: Data) -> [String: String] {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var fields: [String: String] = [:]
        for (key, value) in body {
            if let text = value as? String {
                fields[key] = text
            } else if key.hasSuffix("_ready"), let ready = value as? Bool {
                fields[key] = ready ? "true" : "false"
            }
        }
        return fields
    }
}
