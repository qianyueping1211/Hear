import Foundation

/// 自动选模型下载源：在中国就用国内镜像 hf-mirror，在国外用 Hugging Face 官方。
/// 先查当前网络所在的国家；查不到就同时试两个源，哪个先连上用哪个。每次打开 App 只选一次。
enum HostPicker {
    static let official = "huggingface.co"
    static let mirror = "hf-mirror.com"

    private static let lock = NSLock()
    private static var cached: String?

    static func best() async -> String {
        lock.lock(); let c = cached; lock.unlock()
        if let c { return c }
        let pick: String
        if let cc = await countryCode() {
            pick = cc == "CN" ? mirror : official
            hearLog("下载源：当前网络在 \(cc)，使用\(pick == mirror ? "国内镜像 hf-mirror" : " Hugging Face 官方")")
        } else {
            pick = await fastest()
            hearLog("下载源：查不到所在国家，\(pick == mirror ? "国内镜像 hf-mirror" : "Hugging Face 官方")更快")
        }
        lock.lock(); cached = pick; lock.unlock()
        return pick
    }

    /// 下载失败时调用：下次重新选
    static func reset() {
        lock.lock(); cached = nil; lock.unlock()
    }

    /// 当前网络所在国家（两位代码，例如 CN）
    private static func countryCode() async -> String? {
        guard let url = URL(string: "https://www.cloudflare.com/cdn-cgi/trace") else { return nil }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("loc=") {
            let cc = line.dropFirst(4).trimmingCharacters(in: .whitespaces).uppercased()
            return cc.isEmpty ? nil : cc
        }
        return nil
    }

    /// 两个源同时试，先连上的用它；都连不上用官方
    private static func fastest() async -> String {
        await withTaskGroup(of: String?.self) { group in
            for host in [official, mirror] {
                group.addTask { await reachable(host) ? host : nil }
            }
            for await r in group {
                if let r { group.cancelAll(); return r }
            }
            return official
        }
    }

    private static func reachable(_ host: String) async -> Bool {
        guard let url = URL(string: "https://\(host)/") else { return false }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode < 500
    }
}
