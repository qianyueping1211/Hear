import Foundation
import Security
import CryptoKit

/// 大模型接口类型
enum LLMKind: String, Codable, CaseIterable, Identifiable {
    case openai      // OpenAI 兼容（OpenAI、DeepSeek、通义千问、Kimi、OpenRouter、Ollama 等）
    case anthropic   // Anthropic Claude

    var id: String { rawValue }
    var title: String { self == .openai ? "OpenAI 兼容" : "Anthropic" }
}

/// 一个已配置的大模型 API
struct LLMProvider: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: LLMKind
    var baseURL: String
    var models: [String] = []
    var selectedModel: String = ""

    /// 常用服务的预设
    static let presets: [LLMProvider] = [
        .init(name: "OpenAI", kind: .openai, baseURL: "https://api.openai.com/v1"),
        .init(name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com"),
        .init(name: "DeepSeek", kind: .openai, baseURL: "https://api.deepseek.com/v1"),
        .init(name: "Qwen", kind: .openai, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
        .init(name: "MiniMax", kind: .openai, baseURL: "https://api.minimaxi.com/v1"),
        .init(name: "Kimi", kind: .openai, baseURL: "https://api.moonshot.cn/v1"),
        .init(name: "OpenRouter", kind: .openai, baseURL: "https://openrouter.ai/api/v1"),
        .init(name: "自定义", kind: .openai, baseURL: "https://"),
    ]
}

/// API Key 优先存在钥匙串里。
/// 自签名安装的 App 有时没有钥匙串权限（保存会失败），这时改存到 App 自己的加密文件里，
/// 文件只在手机解锁后可读，不会进入 iCloud 备份。
enum Keychain {
    private static let service = "com.hear.llm"

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { FileKeyStore.set(nil, account: account); return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess, get(account: account, keychainOnly: true) == value {
            FileKeyStore.set(nil, account: account)
            hearLog("API Key 已保存到钥匙串")
        } else {
            FileKeyStore.set(value, account: account)
            hearLog("钥匙串不可用（\(status)），API Key 改为保存在 App 的加密文件里", .warning)
        }
    }

    static func get(account: String, keychainOnly: Bool = false) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty {
            return s
        }
        return keychainOnly ? nil : FileKeyStore.get(account: account)
    }

    static func delete(account: String) { set("", account: account) }
}

/// 钥匙串不可用时的备用存储
enum FileKeyStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("llm-keys.json")
    }

    private static func load() -> [String: String] {
        guard let d = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }

    static func get(account: String) -> String? { load()[account] }

    static func set(_ value: String?, account: String) {
        var m = load()
        guard m[account] != value else { return }
        m[account] = value
        guard let d = try? JSONEncoder().encode(m) else { return }
        try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var u = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }
}

/// 大模型配置（保存在 UserDefaults，Key 在钥匙串）
@MainActor
final class LLMSettings: ObservableObject {
    static let shared = LLMSettings()

    @Published private(set) var providers: [LLMProvider] = []
    @Published var activeID: UUID? { didSet { persist() } }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "llmProviders"),
           let list = try? JSONDecoder().decode([LLMProvider].self, from: data) {
            providers = list.map { item in
                var p = item
                if p.name == "通义千问" { p.name = "Qwen" }   // 旧名称改为英文
                return p
            }
        }
        if let s = UserDefaults.standard.string(forKey: "llmActiveID") { activeID = UUID(uuidString: s) }
        if activeID == nil { activeID = providers.first?.id }
    }

    var active: LLMProvider? { providers.first { $0.id == activeID } ?? providers.first }

    /// iCloud 同步过来的设置：直接换上，不用重开 App
    func reloadFromDefaults() {
        if let data = UserDefaults.standard.data(forKey: "llmProviders"),
           let list = try? JSONDecoder().decode([LLMProvider].self, from: data) {
            providers = list.map { item in
                var p = item
                if p.name == "通义千问" { p.name = "Qwen" }   // 旧名称改为英文
                return p
            }
        } else {
            providers = []
        }
        if let s = UserDefaults.standard.string(forKey: "llmActiveID") {
            activeID = UUID(uuidString: s)
        } else {
            activeID = providers.first?.id
        }
    }

    /// 已选好模型并填了 Key，可以用来总结
    var isReady: Bool {
        guard let p = active else { return false }
        return !p.selectedModel.isEmpty &&
            (!(key(for: p) ?? "").isEmpty || LLMClient.isLocalEndpoint(p.baseURL))
    }

    func key(for p: LLMProvider) -> String? { Keychain.get(account: p.id.uuidString) }

    func upsert(_ p: LLMProvider, key: String) {
        if let i = providers.firstIndex(where: { $0.id == p.id }) { providers[i] = p } else { providers.append(p) }
        Keychain.set(key, account: p.id.uuidString)
        if activeID == nil { activeID = p.id }
        persist()
    }

    func remove(_ p: LLMProvider) {
        providers.removeAll { $0.id == p.id }
        Keychain.delete(account: p.id.uuidString)
        if activeID == p.id { activeID = providers.first?.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: "llmProviders")
        }
        UserDefaults.standard.set(activeID?.uuidString, forKey: "llmActiveID")
    }
}

enum LLMError: LocalizedError {
    case badURL, http(Int, String), empty
    /// 公网地址用了 http（明文）：正文和 API Key 都会明文传出去
    case plaintextBlocked
    /// 局域网自建服务用了 http：还没在设置里确认过明文发送
    case plaintextNotApproved
    case plaintextKeyNotApproved
    var errorDescription: String? {
        switch self {
        case .badURL: return "接口地址不正确"
        case .http(let code, let body): return "接口返回错误 \(code)：\(body.prefix(300))"
        case .empty: return "模型没有返回内容"
        case .plaintextBlocked:
            return "这个公网地址用的是 http（明文）：对话内容和 API Key 都会明文传出去。公网服务请换成 https 地址。"
        case .plaintextKeyNotApproved:
            return "请在大模型 API 设置中单独确认以明文发送当前 API Key"
        case .plaintextNotApproved:
            return "这个地址是用明文（http）发送的：对话内容和 API Key 都会明文传出去。请到 设置 → 大模型 API 里确认一次再试。"
        }
    }
}

/// 跨主机的重定向一律不跟：正文和 API Key 不能被转发到别的地方
final class LLMRedirectGuard: NSObject, URLSessionTaskDelegate {
    static let shared = LLMRedirectGuard()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // 换主机、换协议、换端口，一律不跟：
        // 正文和凭据不能被转发到别的地方去
        // （只比主机名是不够的：同一台机器上换个端口、或者从 https 掉到 http，
        //   一样会把内容交到不该交的地方）
        guard let old = task.originalRequest?.url, let new = request.url else {
            completionHandler(nil)
            return
        }
        let sameOrigin = old.scheme?.lowercased() == new.scheme?.lowercased()
            && old.host?.lowercased() == new.host?.lowercased()
            && Self.effectivePort(old) == Self.effectivePort(new)
        if !sameOrigin {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    /// 端口没写出来的时候按协议算默认端口
    private static func effectivePort(_ u: URL) -> Int? {
        if let p = u.port { return p }
        switch u.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// 调用大模型
enum LLMClient {
    private static func url(_ base: String, _ path: String) throws -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        // 兼容用户在 Anthropic 等地址末尾多填了 /v1（避免拼出 /v1/v1/messages）
        if path.hasPrefix("/v1/"), b.lowercased().hasSuffix("/v1") {
            b.removeLast(3)
            while b.hasSuffix("/") { b.removeLast() }
        }
        guard let u = URL(string: b + path) else { throw LLMError.badURL }
        return u
    }

    /// 推理系模型（o1/o3/o4/gpt-5 等）不接受自定义 temperature 参数，传了会返回 HTTP 400
    private static func isReasoningModel(_ model: String) -> Bool {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = lower.split(separator: "/").last.map(String.init) ?? lower
        return base.hasPrefix("o1") || base.hasPrefix("o3") || base.hasPrefix("o4") || base.hasPrefix("gpt-5")
    }

    /// 发请求用的会话：跨主机的重定向由 LLMRedirectGuard 拦下来
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: LLMRedirectGuard.shared, delegateQueue: nil)
    }()

    /// 这个地址是不是局域网里的服务（Ollama、LM Studio 这种）
    static func isLocalEndpoint(_ base: String) -> Bool {
        guard let u = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = u.host else { return false }
        return LocalServerTrust.isLocalHost(host)
    }

    /// 是不是"明文发送"的地址（http）
    static func isPlaintextEndpoint(_ base: String) -> Bool {
        guard let u = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return u.scheme?.lowercased() == "http"
    }

    /// 实际接收内容的是哪个地址（提示用户的时候给他看这个）
    static func endpointDescription(_ base: String) -> String {
        let s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), let host = u.host else { return s }
        let port = u.port.map { ":\($0)" } ?? ""
        var path = u.path
        while path.hasSuffix("/") { path.removeLast() }
        return "\(host)\(port)\(path)"
    }

    private static func approvalID(_ provider: LLMProvider, secret: String? = nil) -> String {
        let base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [provider.id.uuidString, provider.kind.rawValue, base, secret ?? ""]
        return SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func isPlaintextBodyApproved(_ provider: LLMProvider) -> Bool {
        let approved = UserDefaults.standard.dictionary(forKey: "llmPlaintextProviders") as? [String: String]
        return approved?[provider.id.uuidString] == approvalID(provider)
    }

    static func approvePlaintextBody(_ provider: LLMProvider) {
        guard isPlaintextEndpoint(provider.baseURL), isLocalEndpoint(provider.baseURL) else { return }
        var approved = UserDefaults.standard.dictionary(forKey: "llmPlaintextProviders") as? [String: String] ?? [:]
        approved[provider.id.uuidString] = approvalID(provider)
        UserDefaults.standard.set(approved, forKey: "llmPlaintextProviders")
    }

    static func isPlaintextKeyApproved(_ provider: LLMProvider, key: String) -> Bool {
        let approved = UserDefaults.standard.dictionary(forKey: "llmPlaintextKeys") as? [String: String]
        return approved?[provider.id.uuidString] == approvalID(provider, secret: key)
    }

    static func approvePlaintextKey(_ provider: LLMProvider, key: String) {
        guard !key.isEmpty, isPlaintextEndpoint(provider.baseURL), isLocalEndpoint(provider.baseURL) else { return }
        var approved = UserDefaults.standard.dictionary(forKey: "llmPlaintextKeys") as? [String: String] ?? [:]
        approved[provider.id.uuidString] = approvalID(provider, secret: key)
        UserDefaults.standard.set(approved, forKey: "llmPlaintextKeys")
    }

    private static func checkCredentials(_ provider: LLMProvider, key: String) throws {
        try checkEndpoint(provider)
        if !key.isEmpty, isPlaintextEndpoint(provider.baseURL), !isPlaintextKeyApproved(provider, key: key) {
            throw LLMError.plaintextKeyNotApproved
        }
    }

    /// 发送前的检查：公网地址必须用 https；
    /// 局域网里的自建服务可以用 http，但要先在设置里确认过
    /// （确认之前一个字节都不发——连"取模型列表"也不行，
    ///   那一次请求里带着 API Key 呢）。
    private static func checkEndpoint(_ provider: LLMProvider) throws {
        let s = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased() else {
            throw LLMError.badURL
        }
        if scheme == "https" { return }
        if scheme == "http" {
            if isLocalEndpoint(s) {
                // 局域网里的自建服务：允许，但要用户确认过
                guard isPlaintextBodyApproved(provider) else { throw LLMError.plaintextNotApproved }
                return
            }
            throw LLMError.plaintextBlocked       // 公网的明文地址，不给发
        }
        throw LLMError.badURL
    }

    private static func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, String(decoding: data, as: UTF8.self))
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// 获取模型列表
    static func listModels(_ p: LLMProvider, key: String) async throws -> [String] {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try checkCredentials(p, key: cleanKey)
        var req: URLRequest
        switch p.kind {
        case .openai:
            req = URLRequest(url: try url(p.baseURL, "/models"))
            // 没有 Key 就别发认证头（局域网的自建服务不需要 Key，
            // 发一个空的头出去反而怪）
            if !cleanKey.isEmpty { req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            req = URLRequest(url: try url(p.baseURL, "/v1/models?limit=100"))
            if !cleanKey.isEmpty { req.setValue(cleanKey, forHTTPHeaderField: "x-api-key") }
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        req.timeoutInterval = 30
        let json = try await send(req)
        let list = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return list.sorted()
    }

    /// 发送一次对话，返回文字结果
    static func complete(_ p: LLMProvider, key: String, model: String,
                         system: String, user: String) async throws -> String {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try checkCredentials(p, key: cleanKey)
        var req: URLRequest
        let body: [String: Any]
        switch p.kind {
        case .openai:
            req = URLRequest(url: try url(p.baseURL, "/chat/completions"))
            if !cleanKey.isEmpty { req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization") }
            var payload: [String: Any] = [
                "model": model,
                "messages": [["role": "system", "content": system],
                             ["role": "user", "content": user]]
            ]
            if !isReasoningModel(model) {
                payload["temperature"] = 0.3
            }
            body = payload
        case .anthropic:
            req = URLRequest(url: try url(p.baseURL, "/v1/messages"))
            if !cleanKey.isEmpty { req.setValue(cleanKey, forHTTPHeaderField: "x-api-key") }
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let lowerModel = model.lowercased()
            let maxTokens = (lowerModel.contains("claude-3-opus")
                || lowerModel.contains("claude-3-sonnet")
                || lowerModel.contains("claude-3-haiku")) ? 4096 : 8192
            body = ["model": model,
                    "max_tokens": maxTokens,
                    "system": system,
                    "messages": [["role": "user", "content": user]]]
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(req)
        let text: String?
        switch p.kind {
        case .openai:
            let choice = (json["choices"] as? [[String: Any]])?.first
            let msg = choice?["message"] as? [String: Any]
            if let str = msg?["content"] as? String {
                text = str
            } else if let parts = msg?["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined()
            } else {
                text = nil
            }
        case .anthropic:
            text = (json["content"] as? [[String: Any]])?
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined()
        }
        guard let raw = text else { throw LLMError.empty }
        let t = stripThinking(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw LLMError.empty }
        return t
    }

    /// 流式发送一次对话（SSE），边生成边回调增量正文；若服务端不支持流式则自动回退到普通请求
    static func completeStream(_ p: LLMProvider, key: String, model: String,
                               system: String, user: String,
                               onPartial: @Sendable @MainActor (String) -> Void) async throws -> String {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try checkCredentials(p, key: cleanKey)
        var req: URLRequest
        let body: [String: Any]
        switch p.kind {
        case .openai:
            req = URLRequest(url: try url(p.baseURL, "/chat/completions"))
            if !cleanKey.isEmpty { req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization") }
            var payload: [String: Any] = [
                "model": model,
                "stream": true,
                "messages": [["role": "system", "content": system],
                             ["role": "user", "content": user]]
            ]
            if !isReasoningModel(model) {
                payload["temperature"] = 0.3
            }
            body = payload
        case .anthropic:
            req = URLRequest(url: try url(p.baseURL, "/v1/messages"))
            if !cleanKey.isEmpty { req.setValue(cleanKey, forHTTPHeaderField: "x-api-key") }
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let lowerModel = model.lowercased()
            let maxTokens = (lowerModel.contains("claude-3-opus")
                || lowerModel.contains("claude-3-sonnet")
                || lowerModel.contains("claude-3-haiku")) ? 4096 : 8192
            body = ["model": model,
                    "max_tokens": maxTokens,
                    "stream": true,
                    "system": system,
                    "messages": [["role": "user", "content": user]]]
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await session.bytes(for: req)
        let httpResp = resp as? HTTPURLResponse
        let code = httpResp?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            var errBytes = Data()
            for try await b in bytes {
                errBytes.append(b)
                if errBytes.count >= 1024 { break }
            }
            throw LLMError.http(code, String(decoding: errBytes, as: UTF8.self))
        }

        var accumulated = ""
        var lastEmit = Date.distantPast
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payloadStr = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payloadStr == "[DONE]" || payloadStr.isEmpty { continue }
            guard let data = payloadStr.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            var deltaText: String?
            switch p.kind {
            case .openai:
                let choice = (json["choices"] as? [[String: Any]])?.first
                let delta = choice?["delta"] as? [String: Any]
                deltaText = delta?["content"] as? String
            case .anthropic:
                if (json["type"] as? String) == "content_block_delta",
                   let delta = json["delta"] as? [String: Any] {
                    deltaText = delta["text"] as? String
                }
            }
            if let d = deltaText, !d.isEmpty {
                accumulated += d
                if Date().timeIntervalSince(lastEmit) >= 0.16 {
                    let cleaned = stripThinking(accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        lastEmit = Date()
                        await onPartial(cleaned)
                    }
                }
            }
        }

        let finalCleaned = stripThinking(accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalCleaned.isEmpty {
            return finalCleaned
        }
        // 若网关未按 SSE 返回（例如把 stream:true 当普通 JSON 返回），回退调用非流式接口
        return try await complete(p, key: key, model: model, system: system, user: user)
    }

    /// 推理模型可能把思考过程放在 <think>…</think> 里，总结里不需要
    static func stripThinking(_ s: String) -> String {
        var out = s
        while let a = out.range(of: "<think>") {
            if let b = out.range(of: "</think>", range: a.upperBound..<out.endIndex) {
                out.removeSubrange(a.lowerBound..<b.upperBound)
            } else {
                out.removeSubrange(a.lowerBound..<out.endIndex)
            }
        }
        return out
    }
}
