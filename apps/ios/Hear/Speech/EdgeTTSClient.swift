import Foundation
import AVFoundation
import CryptoKit

/// 客户端直连微软 Edge-TTS 神经语音（WebSocket + Sec-MS-GEC + 原生 AVAudioFile MP3 解码）。
/// 不经电脑端云服务中转，降低一次网络跳数并支持完全脱离电脑端独立使用。
enum EdgeTTSClient {
    enum ClientError: LocalizedError {
        case invalidURL
        case emptyAudio
        case decodeFailed
        case timeout

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Edge-TTS 连接地址无效"
            case .emptyAudio: return "Edge-TTS 未返回音频数据"
            case .decodeFailed: return "Edge-TTS 音频解码失败"
            case .timeout: return "Edge-TTS 请求超时"
            }
        }
    }

    private static let trustedToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let chromiumMajor = "143"
    private static let chromiumFull = "143.0.3650.75"
    private static let secMsGecVersion = "1-143.0.3650.75"
    private static let winEpoch: Int64 = 11_644_473_600

    /// 13 种语言的微软 Neural 音色映射（女声, 男声），与服务端完全对齐
    private static let voices: [String: (female: String, male: String)] = [
        "zh": ("zh-CN-XiaoxiaoNeural", "zh-CN-YunxiNeural"),
        "en": ("en-US-JennyNeural", "en-US-GuyNeural"),
        "ja": ("ja-JP-NanamiNeural", "ja-JP-KeitaNeural"),
        "ko": ("ko-KR-SunHiNeural", "ko-KR-InJoonNeural"),
        "ar": ("ar-AE-FatimaNeural", "ar-AE-HamdanNeural"),
        "fr": ("fr-FR-DeniseNeural", "fr-FR-HenriNeural"),
        "de": ("de-DE-KatjaNeural", "de-DE-ConradNeural"),
        "es": ("es-ES-ElviraNeural", "es-ES-AlvaroNeural"),
        "ru": ("ru-RU-SvetlanaNeural", "ru-RU-DmitryNeural"),
        "pt": ("pt-BR-FranciscaNeural", "pt-BR-AntonioNeural"),
        "it": ("it-IT-ElsaNeural", "it-IT-DiegoNeural"),
        "th": ("th-TH-PremwadeeNeural", "th-TH-NiwatNeural"),
        "vi": ("vi-VN-HoaiMyNeural", "vi-VN-NamMinhNeural"),
    ]

    static func voiceName(for langID: String, gender: String) -> String {
        let pair = voices[langID] ?? ("en-US-JennyNeural", "en-US-GuyNeural")
        return gender == "male" ? pair.male : pair.female
    }

    /// 合成译文为 24kHz 单声道 Float32 音频（客户端直连微软）
    static func synthesize(text: String, langID: String, gender: String,
                           timeoutSeconds: Double = 10) async throws -> CloneAudio {
        let cleaned = sanitizeForSSML(text)
        guard !cleaned.isEmpty else { throw ClientError.emptyAudio }

        let connID = randomHex32()
        let gec = generateSecMsGec()
        let urlStr = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
            + "?TrustedClientToken=\(trustedToken)"
            + "&ConnectionId=\(connID)"
            + "&Sec-MS-GEC=\(gec)"
            + "&Sec-MS-GEC-Version=\(secMsGecVersion)"
        guard let url = URL(string: urlStr) else { throw ClientError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chromiumMajor).0.0.0 Safari/537.36 Edg/\(chromiumMajor).0.0.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("muid=\(randomHex32().uppercased());", forHTTPHeaderField: "Cookie")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeoutSeconds
        cfg.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: cfg)
        let ws = session.webSocketTask(with: request)
        ws.resume()
        defer {
            ws.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        let ts = jsDateString()
        let configPayload =
            "X-Timestamp:\(ts)\r\n"
            + "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n\r\n"
            + "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{"
            + "\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},"
            + "\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"

        let voice = voiceName(for: langID, gender: gender)
        let reqID = randomHex32()
        let ssml =
            "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
            + "<voice name='\(voice)'>"
            + "<prosody pitch='+0Hz' rate='+0%' volume='+0%'>\(xmlEscape(cleaned))</prosody>"
            + "</voice></speak>"
        let ssmlPayload =
            "X-RequestId:\(reqID)\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            + "X-Timestamp:\(ts)Z\r\n"
            + "Path:ssml\r\n\r\n"
            + ssml

        try await ws.send(.string(configPayload))
        try await ws.send(.string(ssmlPayload))

        var mp3Data = Data()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            try Task.checkCancellation()
            if Date() > deadline { throw ClientError.timeout }
            let message = try await ws.receive()
            switch message {
            case .string(let s):
                if s.contains("Path:turn.end") {
                    guard !mp3Data.isEmpty else { throw ClientError.emptyAudio }
                    return try decodeMP3ToPCM24k(mp3Data)
                }
            case .data(let d):
                guard d.count >= 2 else { continue }
                let headerLen = Int(d[d.startIndex]) << 8 | Int(d[d.startIndex + 1])
                let audioStart = 2 + headerLen
                guard audioStart <= d.count else { continue }
                let headerData = d.subdata(in: 2..<audioStart)
                if let headerStr = String(data: headerData, encoding: .utf8),
                   headerStr.contains("Path:audio") {
                    mp3Data.append(d.subdata(in: audioStart..<d.count))
                }
            @unknown default:
                break
            }
        }
    }

    private static func generateSecMsGec() -> String {
        var ticks = Int64(Date().timeIntervalSince1970) + winEpoch
        ticks -= ticks % 300
        ticks *= 10_000_000
        let raw = "\(ticks)\(trustedToken)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    private static func randomHex32() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func jsDateString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return f.string(from: Date())
    }

    private static func sanitizeForSSML(_ s: String) -> String {
        let filtered = s.unicodeScalars.filter { u in
            let v = u.value
            return v >= 0x20 || v == 0x09 || v == 0x0A || v == 0x0D
        }
        return String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func decodeMP3ToPCM24k(_ data: Data) throws -> CloneAudio {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-tts-\(UUID().uuidString).mp3")
        try data.write(to: tmp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = try AVAudioFile(forReading: tmp)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 24_000, channels: 1, interleaved: false) else {
            throw ClientError.decodeFailed
        }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else {
            throw ClientError.emptyAudio
        }
        try file.read(into: inBuf)

        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else {
            throw ClientError.decodeFailed
        }
        var consumed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inBuf
        }
        if err != nil || outBuf.frameLength == 0 {
            throw ClientError.decodeFailed
        }
        guard let ch = outBuf.floatChannelData else { throw ClientError.decodeFailed }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
        return CloneAudio(samples: samples, sampleRate: 24_000)
    }
}
