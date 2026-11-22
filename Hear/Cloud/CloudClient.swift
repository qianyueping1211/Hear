import Foundation
import Security
import UIKit

/// 云端模型服务客户端。
///
/// 服务端是自己电脑上跑的那个程序（仓库里的 server/ 目录有完整的说明和脚本），
/// 三个模型各自独立，一个地址三个接口：
///
/// - `POST /v1/asr`        识别：请求体是 16 kHz 单声道 wav，返回 {"lang":"en","text":"..."}
/// - `POST /v1/translate`  翻译：{"prompt":"...","src":"zh","dst":"en"}，返回 {"text":"..."}
/// - `POST /v1/clone`      声音克隆：{"text":"...","lang":"en","reference_wav":"<base64>","reference_text":"..."}
///                         返回 {"audio":"<base64 wav>","sample_rate":24000}
///                         （请求头带 X-Hear-Audio: wav 的话，服务直接回 wav 原始数据）
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

extension Notification.Name {
    /// 本地网络权限被系统拒了（或者压根没给）
    static let hearLocalNetworkDenied = Notification.Name("hear.localNetworkDenied")
}

/// 局域网服务用的是自签证书（电脑上自己生成的），系统默认不认。
///
/// 两种模式：
///   · **兼容模式**（默认）：只对"用户自己在设置里填的内网地址"放宽自签证书校验。
///     换了网络、开了 VPN 都能连上（证书会按新地址重签）。
///     公网地址一律走系统证书校验——就算用户填了公网地址也一样。
///   · **严格模式**（可选）：只认配对过的那台电脑的证书。
///     手机上确认一次它的"签发根"指纹，之后它重签证书（换网络、换 IP）也照样认，
///     但别的电脑拿别的证书来，一律拒绝。
final class LocalServerTrust: NSObject, URLSessionDelegate {
    static let shared = LocalServerTrust()

    /// 用户自己在设置里填的服务地址（他自己的电脑）。
    ///
    /// 这些地址上的自签证书也放行——不然换了网络、或者开了 VPN
    /// （Cloudflare WARP 那种 100.96.x.x 的地址），
    /// 手机就再也连不上自己的电脑了（系统不认自签证书，直接拒绝）。
    private static let hostLock = NSLock()
    private static var userHosts: Set<String> = []

    /// 把用户填的地址记下来（只留主机名，不带协议和端口）
    static func trustUserAddresses(_ addresses: [String]) {
        var hosts: Set<String> = []
        for a in addresses {
            let s = a.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            if let u = URL(string: CloudClient.cleanURL(s)), let h = u.host {
                hosts.insert(h.lowercased())
            }
        }
        hostLock.lock()
        userHosts = hosts
        hostLock.unlock()
    }

    /// 这个主机是不是用户自己填的地址
    static func isUserHost(_ host: String) -> Bool {
        hostLock.lock()
        defer { hostLock.unlock() }
        return userHosts.contains(host.lowercased())
    }

    /// 是不是"用户自己填的内网地址"：
    /// 只有这种地址才放宽自签证书的校验。
    /// 公网地址（用户填的也一样）走系统证书校验。
    static func isUserLocalHost(_ host: String) -> Bool {
        guard isUserHost(host) else { return false }
        return isLocalHost(host)
    }

    // MARK: - 严格模式（配对过的签发根）

    private static var strict = false
    private static var pinnedRoot: Data?

    /// 打开/关闭严格模式
    static func setStrictMode(_ on: Bool) {
        hostLock.lock()
        strict = on
        hostLock.unlock()
    }

    static var strictModeEnabled: Bool {
        hostLock.lock()
        defer { hostLock.unlock() }
        return strict
    }

    /// 正在"配对"：这一次连接允许自签证书。
    /// （配对的时候还没确认过指纹，根也就还没存下来，
    ///   要是还按严格模式来，就连不上了——配对也就无从谈起。
    ///   这一次只取一根证书，不发任何对话内容。）
    private let pairingHost: String?
    private let enteredHost: String?

    init(pairingHost: String? = nil, enteredHost: String? = nil) {
        self.pairingHost = pairingHost?.lowercased()
        self.enteredHost = enteredHost?.lowercased()
        super.init()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard pairingHost == nil, let original = task.originalRequest?.url, let next = request.url,
              original.scheme == next.scheme, original.host == next.host,
              (original.port ?? 443) == (next.port ?? 443) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    static func pinRoot(_ der: Data) {
        hostLock.lock()
        pinnedRoot = der
        hostLock.unlock()
    }

    static func pinnedRootData() -> Data? {
        hostLock.lock()
        defer { hostLock.unlock() }
        return pinnedRoot
    }

    /// 严格模式：用配对过的签发根验这张证书
    /// （根没配对、或者不是这个根签的，一律不认）
    private static func evaluateAgainstPinnedRoot(_ cert: SecCertificate, host: String) -> SecTrust? {
        hostLock.lock()
        let root = pinnedRoot
        hostLock.unlock()
        guard let root, let rootCert = SecCertificateCreateWithData(nil, root as CFData) else { return nil }
        var t: SecTrust?
        // 这次要检查主机名：地址填错了也得发现
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustCreateWithCertificates(cert, policy, &t) == errSecSuccess, let trust = t else { return nil }
        SecTrustSetAnchorCertificates(trust, [rootCert] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)   // 只认这个根，不要系统那些
        var err: CFError?
        guard SecTrustEvaluateWithError(trust, &err) else { return nil }
        return trust
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        let userLocal = Self.isUserLocalHost(host)
            || (host.lowercased() == enteredHost && Self.isLocalHost(host))
        let isPairingRequest = host.lowercased() == pairingHost
        if pairingHost != nil, !isPairingRequest {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // 严格模式只管"用户自己填的内网地址"：
        // 公网地址照常走系统证书校验（不能因为开了严格模式就把公网服务也毙了）。
        // 配对中的这一次是例外：还没确认指纹，先让它连上（只取证书，不发内容）。
        if Self.strictModeEnabled, !isPairingRequest, userLocal {
            if let cert = SecTrustGetCertificateAtIndex(trust, 0),
               let strictTrust = Self.evaluateAgainstPinnedRoot(cert, host: host) {
                // 严格模式：这台电脑的证书过了（根是配对过的那个）
                completionHandler(.useCredential, URLCredential(trust: strictTrust))
            } else {
                // 不是配对过的那台电脑：一律拒绝。
                // 不能退回系统信任——那等于把"严格"又变回"看系统脸色"。
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        if userLocal {
            // 内网自签证书：把证书本身当成自己的根，并且不校验主机名。
            // （证书里的 IP 是生成证书那一刻的，电脑换了网络、IP 变了，
            //   旧证书里就没有新 IP，手机会直接拒绝：
            //   "certificate unknown"——这里放开，省得每次换网络都要重装证书）
            var t = trust
            // 先按系统的判断来：证书本来就合格就用系统的
            var err: CFError?
            if !SecTrustEvaluateWithError(trust, &err),
               let cert = SecTrustGetCertificateAtIndex(trust, 0) {
                // 系统不认（自签证书、或者证书里的 IP 是旧的）：
                // 内网地址就放宽——把证书本身当成自己的根，并且不校验主机名
                var relaxed: SecTrust?
                let st = SecTrustCreateWithCertificates(cert, SecPolicyCreateSSL(true, nil), &relaxed)
                if st == errSecSuccess, let r = relaxed {
                    SecTrustSetAnchorCertificates(r, [cert] as CFArray)
                    var err2: CFError?
                    if SecTrustEvaluateWithError(r, &err2) {
                        t = r
                    }
                }
            }
            completionHandler(.useCredential, URLCredential(trust: t))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// 是不是内网地址（自己解析 IP，不依赖 IPv4Address 那套 API，省得两个 init 搞混）
    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".lan") { return true }
        let parts = h.split(separator: ".")
        guard parts.count == 4 else { return false }
        var n: [Int] = []
        for p in parts {
            guard let v = Int(p), v >= 0, v <= 255 else { return false }
            n.append(v)
        }
        if n[0] == 10 { return true }                       // 10.x
        if n[0] == 172 && n[1] >= 16 && n[1] <= 31 { return true }   // 172.16-31.x
        if n[0] == 192 && n[1] == 168 { return true }       // 192.168.x
        if n[0] == 169 && n[1] == 254 { return true }       // 169.254.x
        if n[0] == 127 { return true }                      // 127.x
        if n[0] == 100 && n[1] >= 64 && n[1] <= 127 { return true }  // 100.64-100.127（CGNAT）
        return false
    }
}

actor CloudClient {
    /// 访问口令（电脑上的服务要求时才填）。
    /// 填了以后，每个请求都带上它：局域网里别的设备就用不了你的电脑。
    private static let tokenLock = NSLock()
    private static var _accessToken = ""
    static var accessToken: String {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _accessToken }
        set { tokenLock.lock(); _accessToken = newValue; tokenLock.unlock() }
    }

    /// 自己的会话：带自签证书放行 + 超时放宽
    /// （不用系统那个共享会话：它没法加证书处理程序）
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: LocalServerTrust.shared, delegateQueue: nil)
    }()

    enum CloudError: LocalizedError {
        case notConfigured
        case badURL
        case http(Int, String)
        case badResponse(String)
        case net(String)          // 网络不通，说清楚为什么

        var shouldKeepConfiguredEngine: Bool {
            if case .http(let status, _) = self { return [401, 403, 429, 503].contains(status) }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "还没填云端模型地址"
            case .badURL: return "云端模型地址格式不对"
            case .http(let code, let msg): return "云端服务返回 \(code)：\(msg)"
            case .badResponse(let msg): return "云端服务返回的内容看不懂：\(msg)"
            case .net(let msg): return msg
            }
        }
    }

    /// 三个模型各自的接口地址
    private var asrAddress = ""
    private var mtAddress = ""
    private var cloneAddress = ""

    /// 通用服务地址（8000 那个总服务）。它会把请求转发给翻译/克隆后端，
    /// 所以某个模型自己的地址连不上时，可以退回用它。
    private var sharedAddress = ""

    /// 每个地址是哪种服务（改了地址就清掉缓存）
    private var kinds: [String: ServiceKind] = [:]

    // MARK: - 克隆请求排队（一次只发一个）

    /// 正在跑的克隆请求（true = 位置被占了）
    private var cloneBusy = false

    /// 拿一个位置来跑克隆请求。
    /// 拿不到就等（前面的做完了会放出来）。
    /// 返回 false 表示任务被取消了，别发请求。
    private func acquireCloneSlot() async -> Bool {
        // 轮询等位置（50 毫秒一次）：
        // 简单、不会漏掉、也不会把位置给错人
        while cloneBusy {
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        cloneBusy = true
        return true
    }

    /// 用完了把位置放出来
    private func releaseCloneSlot() {
        cloneBusy = false
    }

    /// 参考音频在服务器上缓存着：同一段参考只从手机传一次，
    /// 后面每句话只带一个 id。
    ///
    /// 每句话都重传一遍参考音频的话，一段 10 秒的参考就是几百 KB，
    /// 一场对话下来白白占掉手机的流量，电脑那边的带宽也被占着——
    /// 手机自己的网络都可能被拖累（用户抱怨过切到别的软件手机提示断网）。
    private var cloneRefID: String = ""
    private var cloneRefKey: String = ""        // 参考音频的指纹（换参考了要重新传）
    private var cloneRefUnsupported = false    // 老服务没有这个接口，别再试了

    /// 参考音频的指纹（换了参考音频就得重新传）
    private func refFingerprint(_ samples: [Float]) -> String {
        var acc: Double = 0
        var i = 0
        while i < samples.count {
            acc += Double(samples[i])
            i += 331
        }
        return "\(samples.count)-\(Int(acc * 1000))"
    }

    /// 把参考音频传到服务器上，换一个 id 回来（后面每句话只带 id）
    private func uploadCloneReference(_ refWav: Data, address: String) async throws -> String {
        let req = try makeRequest("/v1/clone/reference", address: address, method: "POST",
                                  body: refWav, contentType: "audio/wav", timeout: 60)
        let (data, resp) = try await sendWithRetry(req, path: "/v1/clone/reference")
        let code = resp?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw CloudError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rid = obj["id"] as? String, !rid.isEmpty else {
            throw CloudError.badResponse("没有 reference id")
        }
        return rid
    }

    /// 这个地址上跑的是哪种服务
    /// （探测失败时不缓存：可能只是暂时连不上，下次还要再问一次）
    func kind(of address: String, timeout: TimeInterval = 5) async -> ServiceKind {
        let a = Self.cleanURL(address)
        if let k = kinds[a] { return k }
        if let info = await Self.probe(address: a, timeout: timeout) {
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
        cloneRefID = ""; cloneRefKey = ""; cloneRefUnsupported = false
        noteUserAddresses()
    }

    /// 分别设置三个模型的接口地址
    func setAddresses(asr: String, mt: String, clone: String) {
        asrAddress = asr.trimmingCharacters(in: .whitespacesAndNewlines)
        mtAddress = mt.trimmingCharacters(in: .whitespacesAndNewlines)
        cloneAddress = clone.trimmingCharacters(in: .whitespacesAndNewlines)
        kinds.removeAll()
        cloneRefID = ""; cloneRefKey = ""; cloneRefUnsupported = false
        noteUserAddresses()
    }

    /// 把用户填的地址告诉证书放行的那个类：
    /// 用户自己填的地址（自己的电脑，可能开着 VPN）上的自签证书要认。
    private func noteUserAddresses() {
        var all = [asrAddress, mtAddress, cloneAddress, sharedAddress]
        all += candidateAddresses(cloneAddress)
        LocalServerTrust.trustUserAddresses(all)
    }

    var currentAddress: String { asrAddress }

    /// 设置通用服务地址（三个模型共用的那个）
    func setSharedAddress(_ s: String) {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if sharedAddress != v {
            sharedAddress = v
            kinds.removeAll()
        }
        noteUserAddresses()
    }

    /// 这个模型要依次试的地址：先它自己的，再通用服务地址。
    /// 通用服务地址（8000）会把请求转发给真正干活的模型服务，
    /// 所以就算某个模型单独配的地址不通，也能通过它正常工作。
    private func candidateAddresses(_ primary: String) -> [String] {
        var out: [String] = []
        let p = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { out.append(p) }
        let s = sharedAddress
        if !s.isEmpty && !out.contains(s) { out.append(s) }
        return out
    }

    // MARK: - 地址

    /// 把用户填的地址整理成能用的样子：
    ///  - 去掉前后空格和结尾的 "/"
    ///  - **只用 https**：没写协议就补 https://，写了 http:// 的也换成 https://
    ///    （不补的话 "192.168.1.10:8000" 会被当成别的协议，URL 直接建不出来）
    static func cleanURL(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        if t.isEmpty { return t }
        let lower = t.lowercased()
        if lower.hasPrefix("https://") { return t }
        if lower.hasPrefix("http://") { return "https://" + String(t.dropFirst(7)) }
        return "https://" + t
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
        // 访问口令（服务要求时才发）
        let token = CloudClient.accessToken
        // The configured gateway owns the token. Direct or fallback servers have their own identity.
        if !token.isEmpty, !sharedAddress.isEmpty,
           Self.cleanURL(address) == Self.cleanURL(sharedAddress) {
            req.setValue(token, forHTTPHeaderField: "X-Hear-Token")
        }
        // 用户在 App 设置里明确开启“记录对话内容”时，允许当前云端服务
        // 也记录这次请求的原文 / 译文。关闭时服务端继续保持内容隐藏。
        if UserDefaults.standard.bool(forKey: "logContentEnabled") {
            req.setValue("1", forHTTPHeaderField: "X-Hear-Log-Content")
        }
        return req
    }

    /// 发一个请求：连接被服务端断开之类的临时错误，重试一次。
    ///
    /// 服务现在用 HTTP/1.1 长连接，手机会复用同一个连接；
    /// 连接空闲太久被服务端收掉的时候，正好赶上发请求就会断一下——
    /// 重试一次就好，别让用户这一句白说。
    /// （超时不重试：那是服务真的慢，重试只会让等待翻倍。）
    /// retries = 1 表示不重试（实时预览用：要快，宁可这次失败也不要一直等着）
    private func sendWithRetry(_ req: URLRequest, path: String, retries: Int = 3) async throws -> (Data, HTTPURLResponse?) {
        // 切到别的 App 以后，系统只给很短的时间跑代码，请求会被掐断。
        // 用后台任务多要一点时间：翻译和声音克隆的请求能跑完。
        try await withBackgroundTime {
        // 网络断了（Wi-Fi 抖一下、刚切过网络、电脑上的服务重启），
        // 等一下再试往往就好了——不用让用户把刚才那句话重新说一遍。
        var lastError: Error = CloudError.notConfigured
        let tries = max(1, retries)
        for attempt in 0..<tries {
            do {
                let (data, resp) = try await CloudClient.session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                // 服务端说"现在太忙"（并发上限挡住了）：等一下再试。
                // 不重试的话，这一句就白白丢了。
                if (code == 503 || code == 429), attempt < tries - 1 {
                    let wait = attempt == 0 ? 1.0 : 2.5
                    hearLog("云端忙（HTTP \(code)），等 \(wait) 秒重试：\(path)", .warning)
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                return (data, resp as? HTTPURLResponse)
            } catch let e as URLError {
                lastError = e
                // 本地网络权限被系统拒了：告诉界面弹提示。
                // 系统的授权框只问一次，拒绝了就得用户自己去设置里开，
                // 不提示的话用户只会看到"连不上"，根本不知道要去哪儿开。
                if Self.isLocalNetworkDenied(e) {
                    hearLog("本地网络权限被拒绝：\(path)", .warning)
                    NotificationCenter.default.post(name: .hearLocalNetworkDenied, object: nil)
                    throw CloudError.net(Self.friendlyError(e))
                }
                if Self.isTransientNetworkError(e), attempt < tries - 1 {
                    let wait = attempt == 0 ? 1.5 : 4.0
                    hearLog("云端连不上，等 \(wait) 秒重试：\(path)（\(e.code.rawValue)）", .warning)
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                throw CloudError.net(Self.friendlyError(e))
            }
        }
            throw CloudError.net(Self.friendlyError(lastError))
        }
    }

    /// 在后台（切到别的 App）跑一个请求：向系统多要一点执行时间。
    ///
    /// 实时翻译时麦克风一直开着，App 本来就不会被挂起；
    /// 但没在收音的时候（比如只是在等电脑算克隆声音），
    /// 没有这个，任务可能刚发出去就被系统掐断了。
    private func withBackgroundTime<T>(_ body: () async throws -> T) async throws -> T {
        let token = await BackgroundTaskToken()
        await token.begin("听见·云端请求")
        defer { Task { @MainActor in token.finish() } }
        return try await body()
    }

    /// 请求并解析 JSON
    private func json(_ path: String, address: String, method: String = "GET", body: Data? = nil,
                      contentType: String = "application/json",
                      timeout: TimeInterval = 60, retries: Int = 3) async throws -> [String: Any] {
        let req = try makeRequest(path, address: address, method: method, body: body, contentType: contentType, timeout: timeout)
        let (data, resp) = try await sendWithRetry(req, path: path, retries: retries)
        let code = resp?.statusCode ?? 0
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
                         headers: [String: String] = [:],
                         timeout: TimeInterval = 60) async throws -> Data {
        var req = try makeRequest(path, address: address, method: method, body: body, contentType: contentType, timeout: timeout)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await sendWithRetry(req, path: path)
        let code = resp?.statusCode ?? 0
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

    /// 取这台电脑的"签发根"信息（配对用）：
    /// 手机第一次配对的时候确认一下指纹，以后它换网络重签证书都不用再配对。
    static func pairInfo(address: String) async throws -> (fingerprint: String, rootDer: Data) {
        let s = cleanURL(address)
        guard !s.isEmpty, let url = URL(string: s + "/v1/pair") else { throw CloudError.notConfigured }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        // 配对这一次临时按兼容模式放行自签证书：
        // 还没配过的电脑，在严格模式下是连不上的（那就没法配对了）。
        // 这一次只取一根证书，不发任何对话内容。
        guard let host = url.host, LocalServerTrust.isUserLocalHost(host) else {
            throw CloudError.badResponse("严格模式配对需要已配置的局域网地址")
        }
        let pairing = URLSession(configuration: .ephemeral,
                                 delegate: LocalServerTrust(pairingHost: host), delegateQueue: nil)
        defer { pairing.invalidateAndCancel() }
        let (data, resp) = try await pairing.data(for: req)
        guard (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else {
            throw CloudError.badResponse("服务没有回应（是不是地址填错了？）")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let fp = obj["root_fingerprint"] as? String,
              let b64 = obj["root_der"] as? String,
              let der = Data(base64Encoded: b64), !der.isEmpty else {
            throw CloudError.badResponse("服务返回的内容看不懂（可能是老版本的服务）")
        }
        return (fp, der)
    }

    struct ProbeResult: Equatable, Sendable {
        let kind: ServiceKind
        let health: [String: String]
    }

    /// 顺便看一下这个地址上跑的是哪种服务
    static func probe(address: String, timeout: TimeInterval = 5) async -> ProbeResult? {
        let s = cleanURL(address)
        guard !s.isEmpty, let url = URL(string: s + "/health") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        guard let (data, resp) = try? await CloudClient.session.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return nil }
        return probeResult(data: data, code: code)
    }

    private static func probeResult(data: Data, code: Int) -> ProbeResult? {
        let out = CloudModelReadiness.fields(from: data)
        // 总服务回的是 asr / mt / clone；llama-server 回的是 status
        if out["asr"] != nil || out["mt"] != nil || out["clone"] != nil ||
            out["asr_ready"] != nil || out["mt_ready"] != nil || out["clone_ready"] != nil {
            return ProbeResult(kind: .aggregator, health: out)
        }
        if out["status"] != nil {
            return ProbeResult(kind: .llamaServer, health: out)
        }
        // 别的服务：能不能连上算连上了
        if (200..<300).contains(code) || code == 503 {
            return ProbeResult(kind: .llamaServer, health: out)
        }
        return nil
    }

    /// 把网络错误说成人话
    ///
    /// 手机上最常见的是这两种：
    ///  - 连不上电脑（没有网络路径）：手机没连同一个 Wi-Fi、
    ///    或者「本地网络」权限没开（系统会直接拦掉局域网访问）；
    ///  - 连接断了：Wi-Fi 抖了一下，或者电脑上的服务刚重启。
    static func friendlyError(_ error: Error) -> String {
        if let ce = error as? CloudError { return ce.localizedDescription }
        guard let e = error as? URLError else { return error.localizedDescription }
        switch e.code {
        case .notConnectedToInternet:
            return "连不上电脑：手机到电脑这条路断了。可能是手机没连同一个 Wi-Fi、" +
                   "「本地网络」权限没开（设置 → 隐私与安全性 → 本地网络 → 听见），" +
                   "或者电脑上的服务没开、IP 换了"
        case .cannotConnectToHost:
            return "连不上电脑上的服务（那个端口没在监听）：确认服务开着、IP 没换"
        case .timedOut:
            return "等电脑上的服务回应超时"
        case .networkConnectionLost:
            return "连接断开了：Wi-Fi 断了，或者服务刚重启"
        case .cannotFindHost:
            return "找不到这个地址：IP 写错了？"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
            return "证书握手不上：电脑上没生成证书，或者电脑的地址变了（换了网络、开了 VPN）" +
                   "——在电脑上重跑一次 start-windows.ps1，证书会按现在的地址重新生成"
        case .appTransportSecurityRequiresSecureConnection:
            return "服务地址不可用，请确认"
        default:
            return error.localizedDescription
        }
    }

    /// 这些错误是"网络一时不通"，等一下再来往往就好了
    static func isTransientNetworkError(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .timedOut, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// 连接诊断的结果
    struct Diagnosis: Equatable {
        /// 给用户看的话
        var text: String
        /// 是不是「本地网络」权限没开（系统直接拦下来了）
        var localNetworkDenied: Bool = false
        var service: ProbeResult? = nil
    }

    /// 连一下某个地址，把失败的原因说清楚（设置界面"测试连接"用）
    /// 不只说"连不上"，要说清楚是被系统拦了、对方没开、还是被防火墙挡了
    static func diagnose(address: String, testingEnteredAddress: Bool = false) async -> Diagnosis {
        let s = cleanURL(address)
        if s.isEmpty { return Diagnosis(text: "还没填地址") }
        let testSession: URLSession?
        if testingEnteredAddress, let host = URL(string: s)?.host, LocalServerTrust.isLocalHost(host) {
            // 保存前也能测试。地址仅对这次测试有效，不写入全局配置。
            testSession = URLSession(configuration: .ephemeral,
                                     delegate: LocalServerTrust(enteredHost: host), delegateQueue: nil)
        } else {
            testSession = nil
        }
        defer { testSession?.finishTasksAndInvalidate() }
        let connection = testSession ?? session
        var r = await diagnoseOne(s, session: connection)
        if !Self.looksConnected(r.text) {
            // 第一次访问局域网会弹系统的「本地网络」授权框。
            // 用户点「允许」之前请求是不通的，等一下再试一次就能通。
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            r = await diagnoseOne(s, session: connection)
        }
        return r
    }

    /// 这段话是不是表示连上了
    static func looksConnected(_ text: String) -> Bool {
        text.hasPrefix("连接正常") || text.hasPrefix("服务在加载")
    }

    /// 错误链里有没有"操作不被允许"。
    ///
    /// 本地网络权限被拒时，系统就是这么报的：
    /// NSURLErrorCannotConnectToHost + 底下的 POSIX EPERM（errno 1）。
    /// 这和"电脑没开机"（连接被拒 / 超时）不是一回事，要分开说。
    static func isLocalNetworkDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == 1 { return true }   // EPERM
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isLocalNetworkDenied(u)
        }
        return false
    }

    /// 给用户看的那句"本地网络权限没开"
    static let localNetworkDeniedText =
        "本地网络权限没开：设置 → 隐私与安全性 → 本地网络 → 听见 → 打开"

    /// 真的连一次，把失败的原因说清楚
    private static func diagnoseOne(_ s: String, session: URLSession) async -> Diagnosis {
        guard let url = URL(string: s + "/health") else { return Diagnosis(text: "地址格式不对：\(s)") }
        var req = URLRequest(url: url)
        // 放长一点：第一次访问局域网会弹系统的「本地网络」授权框，
        // 用户点「允许」之前请求是等着的，6 秒太短会先超时
        req.timeoutInterval = 25
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
                // llama-server 加载模型时回 503 {"status":"loading model"}，
                // 这是"连上了、正在准备"，不是连不上
                if code == 503, body.contains("loading") {
                    return Diagnosis(text: "服务在加载模型（稍等几秒再试一次）",
                                     service: probeResult(data: data, code: code))
                }
                return Diagnosis(text: "连上了，但服务返回 \(code)：\(body)")
            }
            return Diagnosis(text: "连接正常，服务在运行", service: probeResult(data: data, code: code))
        } catch let e as URLError {
            // 系统把本地网络访问拦下来了：这是最常见的原因，
            // 而且系统只问一次，拒绝了就得自己去设置里开——要单独说清楚
            if Self.isLocalNetworkDenied(e) {
                hearLog("本地网络权限被拒绝：\(s)", .warning)
                return Diagnosis(text: localNetworkDeniedText, localNetworkDenied: true)
            }
            switch e.code {
            case .appTransportSecurityRequiresSecureConnection:
                // 地址写错（比如没写 http://、IP 打错）时系统也会报这个，
                // 界面上别提版本号，就说地址不可用让人去确认，细节写日志里
                hearLog("云端连接被系统拦下：\(s)（\(e.code.rawValue)）", .warning)
                return Diagnosis(text: "服务地址不可用，请确认")
            case .cannotConnectToHost:
                let u = URL(string: s)
                let host = u?.host ?? "电脑的IP"
                let port = u?.port.map(String.init) ?? "这个端口"
                return Diagnosis(text: "连不上（\(port) 没有在监听）：确认服务已经启动，而且已经生成了证书（server/certs/cert.pem，没有的话只有 http 能用，App 只走 https）。三个模型都填同一个地址 https://192.168.x.x:8000，8081、8082 只在你电脑上监听，手机访问不了。还有一种可能：手机的「本地网络」权限没开——设置 → 隐私与安全性 → 本地网络 → 听见 → 打开（系统的授权框只问一次，选了不允许就只能自己去设置里开）。")
            case .timedOut:
                let u = URL(string: s)
                let host = u?.host ?? "电脑的IP"
                let port = u?.port ?? 8000
                return Diagnosis(text: "连接超时。请确认电脑上的服务仍在响应，并检查手机和电脑的网络连接。也可以在手机浏览器打开 https://\(host):\(port)/，确认能否访问服务。")
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .clientCertificateRejected:
                hearLog("云端连接证书握手失败：\(s)（\(e.code.rawValue)）", .warning)
                return Diagnosis(text: "无法建立 HTTPS 连接。请确认服务地址与电脑启动窗口显示的地址一致。")
            case .cannotFindHost:
                return Diagnosis(text: "找不到这个地址：IP 写错了？")
            case .notConnectedToInternet:
                return Diagnosis(text: "手机现在没有联网")
            case .networkConnectionLost:
                return Diagnosis(text: "连接断开了：服务可能刚重启，或者 Wi-Fi 断了")
            default:
                hearLog("云端连接失败：\(s) 错误码 \(e.code.rawValue) \(e.localizedDescription)", .warning)
                return Diagnosis(text: "连不上（\(e.code.rawValue)）：\(e.localizedDescription)")
            }
        } catch {
            hearLog("云端连接失败：\(s) \(error.localizedDescription)", .warning)
            return Diagnosis(text: "连不上：\(error.localizedDescription)")
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

    /// 实时预览用的识别（要快，后端在组合方案下只用 SenseVoice）
    func transcribePreview(samples: [Float], candidates: [String], fallback: String) async throws -> (lang: String, text: String) {
        let result = try await transcribe(samples: samples, candidates: candidates, fallback: fallback, preview: true)
        return (result.lang, result.text)
    }

    func transcribe(samples: [Float], candidates: [String], fallback: String)
        async throws -> (lang: String, text: String, correctionAddress: String?, speakerAddress: String?) {
        try await transcribe(samples: samples, candidates: candidates, fallback: fallback, preview: false)
    }

    func correctTranscription(samples: [Float], language: String, address: String) async throws -> String {
        try Task.checkCancellation()
        guard candidateAddresses(asrAddress).contains(address) else { throw CloudError.notConfigured }
        let wav = Wav.encode(samples: samples, sampleRate: 16_000)
        var request = try makeRequest("/v1/asr", address: address, method: "POST", body: wav,
                                      contentType: "audio/wav", timeout: 12)
        request.setValue(language, forHTTPHeaderField: "X-Languages")
        request.setValue(language, forHTTPHeaderField: "X-Fallback-Language")
        request.setValue("sensevoice+whisper", forHTTPHeaderField: "X-ASR-Scheme")
        request.setValue("correct", forHTTPHeaderField: "X-ASR-Stage")
        let (data, response) = try await sendWithRetry(request, path: "/v1/asr", retries: 1)
        try Task.checkCancellation()
        let code = response?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw CloudError.http(code, "") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String ?? ""
    }

    private func transcribe(samples: [Float], candidates: [String], fallback: String,
                            preview: Bool) async throws -> (lang: String, text: String, correctionAddress: String?, speakerAddress: String?) {
        // 先试这个模型自己的地址，不行就退回通用服务地址（8000 会转发给识别后端）
        var lastError: Error = CloudError.notConfigured
        var sawOnlyModelService = false
        var attempted = false
        // 预览只有一个总时限：探测、回退、加起来都不能超过它。
        // （以前每个地址各等 12 秒，两个地址就是 24 秒——
        //   屏幕上还是省略号，用户早就等不下去了。）
        let deadline = preview ? Date().addingTimeInterval(12) : nil
        for addr in candidateAddresses(asrAddress) {
            // 总时限到了就别再试下一个地址了
            if let d = deadline, Date() >= d { break }
            // 单独的 llama-server 没有识别接口，识别只能用 8000 的总服务
            let probeBudget = deadline.map { min(5, max(0.05, $0.timeIntervalSinceNow)) } ?? 5
            if await kind(of: addr, timeout: probeBudget) == .llamaServer {
                sawOnlyModelService = true
                continue
            }
            if let deadline, Date() >= deadline { break }
            try Task.checkCancellation()
            attempted = true
            do {
                let wav = Wav.encode(samples: samples, sampleRate: 16_000)
                // 预览要快：给个短超时，而且不重试
                // （整句那种慢请求要是排在这里，后面的原文预览就都被它堵住了）
                // 这一次请求最多只能用"总时限里还剩下的时间"
                let budget: TimeInterval = deadline.map { max(0.05, $0.timeIntervalSinceNow) } ?? 120
                var req = try makeRequest("/v1/asr", address: addr, method: "POST", body: wav,
                                          contentType: "audio/wav", timeout: preview ? budget : 120)
                req.setValue(candidates.joined(separator: ","), forHTTPHeaderField: "X-Languages")
                req.setValue(fallback, forHTTPHeaderField: "X-Fallback-Language")
                // 告诉服务端用哪个识别方案
                req.setValue(asrScheme, forHTTPHeaderField: "X-ASR-Scheme")
                // 预览只要快，不要修正
                if preview { req.setValue("1", forHTTPHeaderField: "X-ASR-Preview") }
                else { req.setValue("first", forHTTPHeaderField: "X-ASR-Stage") }
                let (data, resp) = try await sendWithRetry(req, path: "/v1/asr", retries: preview ? 1 : 3)
                let code = resp?.statusCode ?? 0
                guard (200..<300).contains(code) else {
                    throw CloudError.http(code, String(data: data.prefix(400), encoding: .utf8) ?? "")
                }
                guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let text = obj["text"] as? String else {
                    throw CloudError.badResponse(String(data: data.prefix(200), encoding: .utf8) ?? "")
                }
                let lang = (obj["lang"] as? String) ?? fallback
                let correctionAddress = !preview && (obj["can_correct"] as? Bool == true) ? addr : nil
                let speakerAddress = !preview && (obj["speaker_available"] as? Bool == true) ? addr : nil
                return (lang, text, correctionAddress, speakerAddress)
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        if !attempted && sawOnlyModelService {
            throw CloudError.badResponse("这个地址是单独的模型服务，不提供语音识别；识别请用 8000 的总服务地址")
        }
        throw lastError
    }

    func speakerEmbedding(samples: [Float], address: String) async throws -> [Float]? {
        try Task.checkCancellation()
        guard candidateAddresses(asrAddress).contains(address) else { return nil }
        let wav = Wav.encode(samples: Array(samples.prefix(160_000)), sampleRate: 16_000)
        let request = try makeRequest("/v1/speaker", address: address, method: "POST", body: wav,
                                      contentType: "audio/wav", timeout: 8)
        let (data, response) = try await sendWithRetry(request, path: "/v1/speaker", retries: 1)
        guard response?.statusCode == 200, data.count < 32_768 else { return nil }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["embedding"] as? [NSNumber])?.map(\.floatValue)
    }

    // MARK: - 文本翻译

    /// prompt 是 App 拼好的提示词（和本地模型用的是同一套格式）
    func translate(prompt: String, src: String, dst: String, preview: Bool = false) async throws -> String {
        // 先试这个模型自己的地址，不行就退回通用服务地址（8000 会转发给翻译后端）
        var lastError: Error = CloudError.notConfigured
        let deadline = preview ? Date().addingTimeInterval(5) : nil
        let retries = preview ? 1 : 3
        for addr in candidateAddresses(mtAddress) {
            try Task.checkCancellation()
            if let deadline, deadline.timeIntervalSinceNow <= 0 { break }
            do {
                // 地址上跑的是单独的 llama-server（8081 那种）时，用 OpenAI 那套接口
                let service = await kind(of: addr, timeout: preview ? 1.0 : 5.0)
                try Task.checkCancellation()
                let budget = deadline?.timeIntervalSinceNow ?? 120
                if budget <= 0 { break }
                if service == .llamaServer {
                    let body: [String: Any] = [
                        "messages": [["role": "user", "content": prompt]],
                        "stream": false,
                        "max_tokens": 512,
                        "top_k": 20,
                        "top_p": 0.6,
                        "temperature": 0.7,
                    ]
                    let obj = try await json("/v1/chat/completions", address: addr, method: "POST",
                                             body: try JSONSerialization.data(withJSONObject: body), timeout: budget, retries: retries)
                    if let choices = obj["choices"] as? [[String: Any]],
                       let msg = choices.first?["message"] as? [String: Any],
                       let text = msg["content"] as? String, !text.isEmpty {
                        return text
                    }
                    throw CloudError.badResponse("llama-server 没有返回翻译结果")
                }
                let body: [String: Any] = ["prompt": prompt, "src": src, "dst": dst]
                let obj = try await json("/v1/translate", address: addr, method: "POST",
                                         body: try JSONSerialization.data(withJSONObject: body), timeout: budget, retries: retries)
                guard let text = obj["text"] as? String else {
                    throw CloudError.badResponse("没有 text 字段")
                }
                return text
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - 声音克隆

    /// 用参考音频里的声音念一句话
    ///
    /// 一次只发一个克隆请求：
    /// 每句话都会在后台预生成声音，同时来好几句的话，
    /// 好几个大响应一起在内存里，内存紧张时 App 会被系统直接杀掉。
    func clone(text: String, lang: String, reference: [Float], referenceText: String) async throws -> CloneAudio {
        // 排队：一次只发一个克隆请求
        guard await acquireCloneSlot() else {
            throw CloudError.badResponse("任务已取消")
        }
        defer { releaseCloneSlot() }
        guard !reference.isEmpty else {
            throw CloudError.badResponse("没有参考音频")
        }
        // 换参考音频了：服务器上存的那份就作废了
        let fp = refFingerprint(reference)
        if cloneRefKey != fp {
            cloneRefKey = fp
            cloneRefID = ""
        }
        let refWav = Wav.encode(samples: reference, sampleRate: 16_000)
        hearLogNow("云端克隆：开始（参考音频 \(refWav.count) 字节）")
        // 先试这个模型自己的地址，不行就退回通用服务地址（8000 会转发给克隆后端）
        var lastError: Error = CloudError.notConfigured
        for addr in candidateAddresses(cloneAddress) {
            let isLlama = await kind(of: addr) == .llamaServer
            // 最多试两次：服务器上存的参考音频可能没了（服务重启过）
            for _ in 0..<2 {
                do {
                    let t0 = Date()
                    var body: [String: Any] = ["text": text, "lang": lang]
                    if isLlama {
                        // 地址上跑的是单独的 llama-server（8082 那种）时，用 /tts，
                        // 返回的是 wav 原始数据。它只认 base64 的参考音频，用不了 id。
                        body["speaker_ref_b64"] = refWav.base64EncodedString()
                        body["speaker_ref_text"] = referenceText
                        hearLogNow("云端克隆：请求已发出（\(addr)）")
                        let data = try await rawData("/tts", address: addr, method: "POST",
                                                     body: try JSONSerialization.data(withJSONObject: body), timeout: 300)
                        hearLogNow("云端克隆：收到回复（\(data.count) 字节）")
                        guard let decoded = Wav.decode(data) else {
                            throw CloudError.badResponse("llama-server 返回的不是 wav 音频")
                        }
                        hearLogNow("云端克隆：结束（\(decoded.samples.count) 个采样，\(decoded.sampleRate) Hz，用时 \(Self.secs(t0))s）")
                        return CloneAudio(samples: decoded.samples, sampleRate: decoded.sampleRate)
                    }
                    // 总服务：参考音频只传一次，后面每句话只带 id
                    var refID = cloneRefID
                    if refID.isEmpty && !cloneRefUnsupported {
                        do {
                            let rid = try await uploadCloneReference(refWav, address: addr)
                            if !rid.isEmpty {
                                refID = rid
                                cloneRefID = rid
                                hearLogNow("云端克隆：参考音频已上传（\(refWav.count) 字节），后面几遍只传 id")
                            }
                        } catch let e as CloudError {
                            if case .http = e {
                                // 服务器不认识这个接口（老服务）：以后照旧整段发过去
                                cloneRefUnsupported = true
                                hearLog("云端克隆：服务器不支持参考音频 id，整段上传", .info)
                            } else {
                                hearLog("云端克隆：参考音频上传失败，整段上传（\(Self.friendlyError(e))）", .warning)
                            }
                        } catch {
                            hearLog("云端克隆：参考音频上传失败，整段上传", .warning)
                        }
                    }
                    if refID.isEmpty {
                        body["reference_wav"] = refWav.base64EncodedString()
                    } else {
                        body["reference_id"] = refID
                    }
                    body["reference_text"] = referenceText
                    hearLogNow("云端克隆：请求已发出（\(addr)）")
                    // 请求头里说明要原始 wav：新服务直接回 wav 原始数据（省掉 base64，
                    // 内存占用小很多）；老服务不认这个头，还是回 JSON，这里也照样能解。
                    let data = try await rawData("/v1/clone", address: addr, method: "POST",
                                                 body: try JSONSerialization.data(withJSONObject: body),
                                                 headers: ["X-Hear-Audio": "wav"], timeout: 300)
                    hearLogNow("云端克隆：收到回复（\(data.count) 字节）")
                    var wavData = data
                    var rate = 0
                    if !(data.count > 4 && data.prefix(4) == Data([0x52, 0x49, 0x46, 0x46])) {
                        // 老服务：回的是 JSON（audio 是 base64）
                        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let b64 = obj["audio"] as? String,
                              let d = Data(base64Encoded: b64) else {
                            throw CloudError.badResponse("没有 audio 字段")
                        }
                        wavData = d
                        rate = (obj["sample_rate"] as? Int) ?? 0
                    }
                    guard let decoded = Wav.decode(wavData) else {
                        throw CloudError.badResponse("返回的不是 wav 音频")
                    }
                    if rate <= 0 { rate = decoded.sampleRate }
                    if rate <= 0 { rate = 24_000 }
                    hearLogNow("云端克隆：结束（\(decoded.samples.count) 个采样，\(rate) Hz，用时 \(Self.secs(t0))s）")
                    return CloneAudio(samples: decoded.samples, sampleRate: rate)
                } catch {
                    // 服务器上存的参考音频没了（服务重启过）：清掉，重新传一次再来
                    if let ce = error as? CloudError, case .http(let code, _) = ce,
                       code == 404, !cloneRefID.isEmpty {
                        hearLog("云端克隆：服务器上的参考音频没了，重新上传", .warning)
                        cloneRefID = ""
                        continue
                    }
                    lastError = error
                    hearLog("云端克隆失败：\(Self.friendlyError(error))", .error)
                    break          // 这个地址不行，换下一个
                }
            }
        }
        throw lastError
    }

    /// 从开始到现在的秒数（一位小数）
    static func secs(_ t0: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(t0))
    }
}

/// 一个后台任务（切到别的 App 以后，系统只给很短的时间跑代码）。
///
/// 用来把云端请求包起来：用户切到别的软件以后，
/// 翻译和声音克隆的请求还能跑完，不会被系统半路掐断。
@MainActor
final class BackgroundTaskToken: @unchecked Sendable {
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // 时间到了：先把后台任务收掉（不收的话系统会杀掉 App）
            Task { @MainActor in self?.finish() }
        }
    }

    func finish() {
        guard id != .invalid else { return }
        let v = id
        id = .invalid
        UIApplication.shared.endBackgroundTask(v)
    }
}
