import Foundation

/// 云端模型服务客户端。
///
/// 服务端是自己电脑上跑的那个程序（仓库里的 server/ 目录有完整的说明和脚本），
/// 三个模型各自独立，一个地址三个接口：
///
/// - `POST /v1/asr`        识别：请求体是 16 kHz 单声道 wav，返回 {"lang":"en","text":"..."}
/// - `POST /v1/translate`  翻译：{"prompt":"...","src":"zh","dst":"en"}，返回 {"text":"..."}
/// - `POST /v1/clone`      声音克隆：{"text":"...","lang":"en","reference_wav":"<base64>","reference_text":"..."}
///                         返回 {"audio":"<base64 wav>","sample_rate":24000}
/// - `GET  /health`        看服务状态
///
/// 手机和电脑要在同一个局域网里，地址写成 http://192.168.x.x:8000 这种。
actor CloudClient {
    enum CloudError: LocalizedError {
        case notConfigured
        case badURL
        case http(Int, String)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "还没填云端模型地址"
            case .badURL: return "云端模型地址格式不对"
            case .http(let code, let msg): return "云端服务返回 \(code)：\(msg)"
            case .badResponse(let msg): return "云端服务返回的内容看不懂：\(msg)"
            }
        }
    }

    /// 服务地址（用户在设置里填的）
    private var address: String = ""

    func setAddress(_ s: String) {
        address = s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var currentAddress: String { address }

    // MARK: - 地址

    private func endpoint(_ path: String) throws -> URL {
        var s = address
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { throw CloudError.notConfigured }
        guard let u = URL(string: s + path) else { throw CloudError.badURL }
        return u
    }

    private func makeRequest(_ path: String, method: String = "GET",
                             body: Data? = nil, contentType: String = "application/json",
                             timeout: TimeInterval = 60) throws -> URLRequest {
        var req = URLRequest(url: try endpoint(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// 请求并解析 JSON
    private func json(_ path: String, method: String = "GET", body: Data? = nil,
                      contentType: String = "application/json",
                      timeout: TimeInterval = 60) async throws -> [String: Any] {
        let req = try makeRequest(path, method: method, body: body, contentType: contentType, timeout: timeout)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw CloudError.http(code, msg)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            throw CloudError.badResponse(String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return dict
    }

    // MARK: - 状态

    /// 连不上服务时返回 nil（不抛错，设置界面用来显示“连不上”）
    func health() async -> String? {
        guard let req = try? makeRequest("/health", timeout: 5) else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // 把各模型的状态拼成一行
        var parts: [String] = []
        for key in ["asr", "mt", "clone"] {
            if let v = obj[key] as? String { parts.append("\(key)：\(v)") }
        }
        return parts.isEmpty ? "已连接" : parts.joined(separator: "  ")
    }

    // MARK: - 语音识别

    /// 16 kHz 单声道声音 → 识别结果
    /// - Parameter candidates: 可能的语言（zh/en…），服务端会优先按这些判断
    func transcribe(samples: [Float], candidates: [String], fallback: String) async throws -> (lang: String, text: String) {
        let wav = Wav.encode(samples: samples, sampleRate: 16_000)
        var req = try makeRequest("/v1/asr", method: "POST", body: wav,
                                  contentType: "audio/wav", timeout: 120)
        req.setValue(candidates.joined(separator: ","), forHTTPHeaderField: "X-Languages")
        req.setValue(fallback, forHTTPHeaderField: "X-Fallback-Language")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw CloudError.http(code, String(data: data.prefix(400), encoding: .utf8) ?? "")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = obj["text"] as? String else {
            throw CloudError.badResponse(String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        let lang = (obj["lang"] as? String) ?? fallback
        return (lang, text)
    }

    // MARK: - 文本翻译

    /// prompt 是 App 拼好的提示词（和本地模型用的是同一套格式）
    func translate(prompt: String, src: String, dst: String) async throws -> String {
        let body: [String: Any] = ["prompt": prompt, "src": src, "dst": dst]
        let obj = try await json("/v1/translate", method: "POST",
                                 body: try JSONSerialization.data(withJSONObject: body), timeout: 120)
        guard let text = obj["text"] as? String else {
            throw CloudError.badResponse("没有 text 字段")
        }
        return text
    }

    // MARK: - 声音克隆

    /// 用参考音频里的声音念一句话
    func clone(text: String, lang: String, reference: [Float], referenceText: String) async throws -> CloneAudio {
        let refWav = Wav.encode(samples: reference, sampleRate: 16_000)
        let body: [String: Any] = [
            "text": text,
            "lang": lang,
            "reference_wav": refWav.base64EncodedString(),
            "reference_text": referenceText,
        ]
        let obj = try await json("/v1/clone", method: "POST",
                                 body: try JSONSerialization.data(withJSONObject: body), timeout: 300)
        guard let b64 = obj["audio"] as? String, let wavData = Data(base64Encoded: b64) else {
            throw CloudError.badResponse("没有 audio 字段")
        }
        guard let decoded = Wav.decode(wavData) else {
            throw CloudError.badResponse("返回的不是 wav 音频")
        }
        let rate = (obj["sample_rate"] as? Int) ?? decoded.sampleRate
        return CloneAudio(samples: decoded.samples, sampleRate: rate)
    }
}
