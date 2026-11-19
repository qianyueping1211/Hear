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
/// 在线模型里的三个模型，各有各的接口
enum CloudModel: String, CaseIterable, Identifiable {
    case asr, mt, clone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asr: return "语音识别"
        case .mt: return "文本翻译"
        case .clone: return "声音克隆"
        }
    }

    var icon: String {
        switch self {
        case .asr: return "waveform"
        case .mt: return "character.book.closed"
        case .clone: return "person.wave.2"
        }
    }
}

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

    /// 三个模型各自的接口地址
    private var asrAddress = ""
    private var mtAddress = ""
    private var cloneAddress = ""

    /// 每个地址是哪种服务（改了地址就清掉缓存）
    private var kinds: [String: ServiceKind] = [:]

    /// 这个地址上跑的是哪种服务
    /// （探测失败时不缓存：可能只是暂时连不上，下次还要再问一次）
    func kind(of address: String) async -> ServiceKind {
        let a = Self.cleanURL(address)
        if let k = kinds[a] { return k }
        if let info = await Self.probe(address: a) {
            kinds[a] = info.kind
            return info.kind
        }
        return .aggregator
    }

    /// 三个模型用同一个地址时最省事，所以也可以一次性设置
    func setAddress(_ s: String) {
        let a = s.trimmingCharacters(in: .whitespacesAndNewlines)
        asrAddress = a; mtAddress = a; cloneAddress = a
        kinds.removeAll()
    }

    /// 分别设置三个模型的接口地址
    func setAddresses(asr: String, mt: String, clone: String) {
        asrAddress = asr.trimmingCharacters(in: .whitespacesAndNewlines)
        mtAddress = mt.trimmingCharacters(in: .whitespacesAndNewlines)
        cloneAddress = clone.trimmingCharacters(in: .whitespacesAndNewlines)
        kinds.removeAll()
    }

    var currentAddress: String { asrAddress }

    // MARK: - 地址

    static func cleanURL(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    private func endpoint(_ path: String, address: String) throws -> URL {
        let s = Self.cleanURL(address)
        guard !s.isEmpty else { throw CloudError.notConfigured }
        guard let u = URL(string: s + path) else { throw CloudError.badURL }
        return u
    }

    private func makeRequest(_ path: String, address: String, method: String = "GET",
                             body: Data? = nil, contentType: String = "application/json",
                             timeout: TimeInterval = 60) throws -> URLRequest {
        var req = URLRequest(url: try endpoint(path, address: address))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// 请求并解析 JSON
    private func json(_ path: String, address: String, method: String = "GET", body: Data? = nil,
                      contentType: String = "application/json",
                      timeout: TimeInterval = 60) async throws -> [String: Any] {
        let req = try makeRequest(path, address: address, method: method, body: body, contentType: contentType, timeout: timeout)
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

    /// 请求并返回原始数据（不是 JSON）
    private func rawData(_ path: String, address: String, method: String = "GET", body: Data? = nil,
                         contentType: String = "application/json",
                         timeout: TimeInterval = 60) async throws -> Data {
        let req = try makeRequest(path, address: address, method: method, body: body, contentType: contentType, timeout: timeout)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw CloudError.http(code, msg)
        }
        return data
    }

    // MARK: - 服务类型

    /// 地址上跑的是哪种服务
    enum ServiceKind: Sendable, Equatable {
        /// 8000 那个总服务（hear_cloud.py）：/v1/asr、/v1/translate、/v1/clone 都有
        case aggregator
        /// 8081 / 8082 那种单独的 llama-server：只有 OpenAI 那套接口（或 /tts）
        case llamaServer
    }

    /// 读某个地址上的 /health，拿到各模型的状态。连不上返回 nil
    static func healthInfo(address: String) async -> [String: String]? {
        await probe(address: address)?.health
    }

    /// 顺便看一下这个地址上跑的是哪种服务
    static func probe(address: String) async -> (kind: ServiceKind, health: [String: String])? {
        let s = cleanURL(address)
        guard !s.isEmpty, let url = URL(string: s + "/health") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return nil }
        var out: [String: String] = [:]
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (k, v) in obj { if let t = v as? String { out[k] = t } }
        }
        // 总服务回的是 asr / mt / clone；llama-server 回的是 status
        if out["asr"] != nil || out["mt"] != nil || out["clone"] != nil {
            return (.aggregator, out)
        }
        if out["status"] != nil {
            return (.llamaServer, out)
        }
        // 别的服务：能不能连上算连上了
        if (200..<300).contains(code) || code == 503 {
            return (.llamaServer, out)
        }
        return nil
    }

    /// 连一下某个地址，把失败的原因说清楚（设置界面"测试连接"用）
    /// 不只说"连不上"，要说清楚是被系统拦了、对方没开、还是被防火墙挡了
    static func diagnose(address: String) async -> String {
        let s = cleanURL(address)
        if s.isEmpty { return "还没填地址" }
        guard let url = URL(string: s + "/health") else { return "地址格式不对：\(s)" }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
                return "连上了，但服务返回 \(code)：\(body)"
            }
            return "连接正常，服务在运行"
        } catch let e as URLError {
            switch e.code {
            case .appTransportSecurityRequiresSecureConnection:
                return "被系统拦下了（不允许 http 明文），请用 0.4.19 以上的版本"
            case .cannotConnectToHost:
                let u = URL(string: s)
                let host = u?.host ?? "电脑的IP"
                let port = u?.port.map(String.init) ?? "这个端口"
                return "连不上（\(port) 没有在监听）：确认服务已经启动。三个模型都填同一个地址 http://192.168.x.x:8000，8081、8082 只在你电脑上监听，手机访问不了。也可以在手机浏览器打开 http://\(host):\(port)/ 看看"
            case .timedOut:
                let u = URL(string: s)
                let host = u?.host ?? "电脑的IP"
                let port = u?.port ?? 8000
                return "超时，手机没收到回应。先在手机浏览器打开 http://\(host):\(port)/ 试试：能打开说明是 App 的「本地网络」权限没给（设置 → 隐私与安全性 → 本地网络），打不开说明网络不通。"
            case .cannotFindHost:
                return "找不到这个地址：IP 写错了？"
            case .notConnectedToInternet:
                return "手机现在没有联网"
            case .networkConnectionLost:
                return "连接断开了：服务可能刚重启，或者 Wi-Fi 断了"
            default:
                return "连不上（\(e.code)）：\(e.localizedDescription)"
            }
        } catch {
            return "连不上：\(error.localizedDescription)"
        }
    }

    /// 连不上服务时返回 nil（不抛错，设置界面用来显示“连不上”）
    func health() async -> String? {
        guard let info = await Self.healthInfo(address: asrAddress) else { return nil }
        var parts: [String] = []
        for key in ["asr", "mt", "clone"] {
            if let v = info[key] { parts.append("\(key)：\(v)") }
        }
        return parts.isEmpty ? "已连接" : parts.joined(separator: "  ")
    }

    // MARK: - 语音识别

    /// 16 kHz 单声道声音 → 识别结果
    /// - Parameter candidates: 可能的语言（zh/en…），服务端会优先按这些判断
    /// 用哪个识别方案（服务端认这三个）
    private var asrScheme = "sensevoice+whisper"

    /// 设置识别方案：whisper / sensevoice / sensevoice+whisper
    func setASRScheme(_ s: String) {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { asrScheme = v }
    }

    func transcribe(samples: [Float], candidates: [String], fallback: String) async throws -> (lang: String, text: String) {
        // 单独的 llama-server 没有识别接口，识别只能用 8000 的总服务
        if await kind(of: asrAddress) == .llamaServer {
            throw CloudError.badResponse("这个地址是单独的模型服务，不提供语音识别；识别请用 8000 的总服务地址")
        }
        let wav = Wav.encode(samples: samples, sampleRate: 16_000)
        var req = try makeRequest("/v1/asr", address: asrAddress, method: "POST", body: wav,
                                  contentType: "audio/wav", timeout: 120)
        req.setValue(candidates.joined(separator: ","), forHTTPHeaderField: "X-Languages")
        req.setValue(fallback, forHTTPHeaderField: "X-Fallback-Language")
        // 告诉服务端用哪个识别方案
        req.setValue(asrScheme, forHTTPHeaderField: "X-ASR-Scheme")
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
        // 地址上跑的是单独的 llama-server（8081 那种）时，用 OpenAI 那套接口
        if await kind(of: mtAddress) == .llamaServer {
            let body: [String: Any] = [
                "messages": [["role": "user", "content": prompt]],
                "stream": false,
                "max_tokens": 512,
                "top_k": 20,
                "top_p": 0.6,
                "temperature": 0.7,
            ]
            let obj = try await json("/v1/chat/completions", address: mtAddress, method: "POST",
                                     body: try JSONSerialization.data(withJSONObject: body), timeout: 120)
            if let choices = obj["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let text = msg["content"] as? String, !text.isEmpty {
                return text
            }
            throw CloudError.badResponse("llama-server 没有返回翻译结果")
        }
        let body: [String: Any] = ["prompt": prompt, "src": src, "dst": dst]
        let obj = try await json("/v1/translate", address: mtAddress, method: "POST",
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
        // 地址上跑的是单独的 llama-server（8082 那种）时，用 /tts，返回的是 wav 原始数据
        if await kind(of: cloneAddress) == .llamaServer {
            let body: [String: Any] = [
                "input": text,
                "lang": lang,
                "speaker_ref_b64": refWav.base64EncodedString(),
                "speaker_ref_text": referenceText,
            ]
            let data = try await rawData("/tts", address: cloneAddress, method: "POST",
                                         body: try JSONSerialization.data(withJSONObject: body), timeout: 300)
            guard let decoded = Wav.decode(data) else {
                throw CloudError.badResponse("llama-server 返回的不是 wav 音频")
            }
            return CloneAudio(samples: decoded.samples, sampleRate: decoded.sampleRate)
        }
        let body: [String: Any] = [
            "text": text,
            "lang": lang,
            "reference_wav": refWav.base64EncodedString(),
            "reference_text": referenceText,
        ]
        let obj = try await json("/v1/clone", address: cloneAddress, method: "POST",
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
