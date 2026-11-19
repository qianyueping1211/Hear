import Foundation
import Security

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
        return !p.selectedModel.isEmpty && !(key(for: p) ?? "").isEmpty
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
    var errorDescription: String? {
        switch self {
        case .badURL: return "接口地址不正确"
        case .http(let code, let body): return "接口返回错误 \(code)：\(body.prefix(300))"
        case .empty: return "模型没有返回内容"
        }
    }
}

/// 调用大模型
enum LLMClient {
    private static func url(_ base: String, _ path: String) throws -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard let u = URL(string: b + path) else { throw LLMError.badURL }
        return u
    }

    private static func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, String(decoding: data, as: UTF8.self))
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// 获取模型列表
    static func listModels(_ p: LLMProvider, key: String) async throws -> [String] {
        var req: URLRequest
        switch p.kind {
        case .openai:
            req = URLRequest(url: try url(p.baseURL, "/models"))
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            req = URLRequest(url: try url(p.baseURL, "/v1/models?limit=100"))
            req.setValue(key, forHTTPHeaderField: "x-api-key")
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
        var req: URLRequest
        let body: [String: Any]
        switch p.kind {
        case .openai:
            req = URLRequest(url: try url(p.baseURL, "/chat/completions"))
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": model,
                    "temperature": 0.3,
                    "messages": [["role": "system", "content": system],
                                 ["role": "user", "content": user]]]
        case .anthropic:
            req = URLRequest(url: try url(p.baseURL, "/v1/messages"))
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model,
                    "max_tokens": 8000,
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
            text = (choice?["message"] as? [String: Any])?["content"] as? String
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
