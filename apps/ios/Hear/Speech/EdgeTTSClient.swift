import Foundation
import AVFoundation

/// 客户端直连微软 Edge-TTS 神经语音（WebSocket + Sec-MS-GEC v2 + 原生 AVAudioFile MP3 解码）。
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
    private static let secMsGecVersion = "2-143.0.3650.75"
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
        let gec = generateSecMsGecV2()
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
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("muid=\(randomHex32().uppercased());", forHTTPHeaderField: "Cookie")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
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

    // MARK: - Sec-MS-GEC v2 (与 edge-tts 7.3.1 完全对齐)

    private static let sha256Initial: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]
    private static let sha256State: [UInt32] = [
        0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A,
        0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2,
    ]
    private static let sha256Schedule: [UInt32] = [
        0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA,
        0xA622EE8C, 0xD1DD9491, 0xC0DD25A0, 0xF9E70AB6,
        0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33,
        0xD258B060, 0x72766564,
    ]
    private static let sha256RoundConstants: [UInt32] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5,
        0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
        0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
        0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
        0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
        0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
        0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
        0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
        0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
        0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
        0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
        0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
        0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
        0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
    ]
    private static let sha256Adjustment: UInt32 = 0xC9DC06A7
    private static let sha256BlockConstants: [UInt32] = {
        var c = sha256RoundConstants
        c[14] = sha256Adjustment
        return c
    }()
    private static let sha256Sigma0Adjustment: UInt32 = 0x059C0B80
    private static let sha256Sigma1Adjustment: UInt32 = 0x000B92C0

    private static let cs64Coefficients: [(UInt32, UInt32)] = [
        (0xE82E91B1, 0xB32700D0), (0x44DE24C6, 0x88DFF51D),
        (0x3BEB65BC, 0x29514038), (0xC89C5933, 0xB328CBDF),
        (0x8D1EC211, 0xD405B4D5), (0x314EF5D5, 0x26E55F3C),
        (0xE92491B1, 0x607801C6), (0xF0A5B9D5, 0x82B2C1FB),
        (0x06064CF3, 0xFA51A3DA), (0xDA79FA60, 0x207CC464),
        (0xBED20560, 0x3C3C74F3), (0x89F9C9F8, 0xD2D14B61),
        (0x35FA38C6, 0xBB04A2C1), (0xCB49E3C6, 0xC5626167),
    ]
    private static let cs64Factor: UInt32 = 0x82893933
    private static let cs64Adjustment0: UInt32 = 0xF2F90B1A
    private static let cs64Adjustment1: UInt32 = 0x0B1A0000

    private static func rotr(_ v: UInt32, _ n: UInt32) -> UInt32 { (v >> n) | (v << (32 - n)) }
    private static func rol16(_ v: UInt32) -> UInt32 { (v << 16) | (v >> 16) }
    private static func sigma0(_ v: UInt32) -> UInt32 { rotr(v, 7) ^ rotr(v, 18) ^ (v >> 3) }
    private static func sigma1(_ v: UInt32) -> UInt32 { rotr(v, 17) ^ rotr(v, 19) ^ (v >> 10) }

    private static func expandSchedule(_ words: inout [UInt32], firstWord: Int = 16) {
        for i in firstWord..<64 {
            let w = sigma1(words[i - 2]) &+ words[i - 7] &+ sigma0(words[i - 15]) &+ words[i - 16]
            words.append(w)
        }
    }

    private static func sha256Rounds(_ state: [UInt32], _ words: [UInt32], firstRound: Int = 0) -> [UInt32] {
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        let constants = (firstRound == 14) ? sha256BlockConstants : sha256RoundConstants
        for i in firstRound..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = g ^ (e & (f ^ g))
            let t1 = h &+ s1 &+ ch &+ constants[i] &+ words[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) | (c & (a | b))
            let t2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        return [a, b, c, d, e, f, g, h]
    }

    private static func sha256Init(_ prefix7: [UInt8]) -> [UInt32] {
        var words = Array(repeating: UInt32(0), count: 14)
        words.append((UInt32(prefix7[0]) << 16) | (UInt32(prefix7[1]) << 8) | UInt32(prefix7[2]))
        words.append((UInt32(prefix7[3]) << 24) | (UInt32(prefix7[4]) << 16) | (UInt32(prefix7[5]) << 8) | UInt32(prefix7[6]))
        for i in 16..<30 {
            var v = sha256Schedule[i - 16]
            if i - 2 >= 14 {
                let s1 = sigma1(words[i - 2])
                v = v &+ (i == 16 ? (s1 ^ sha256Sigma1Adjustment) : s1)
            }
            if i - 7 >= 14 {
                v = v &+ words[i - 7]
            }
            if i - 15 >= 14 {
                let s0 = sigma0(words[i - 15])
                v = v &+ (i == 29 ? (s0 ^ sha256Sigma0Adjustment) : s0)
            }
            words.append(v)
        }
        let w30 = sigma1(words[28]) &+ words[23] &+ sigma0(words[15]) &+ words[14]
            &+ sha256Adjustment &- sha256RoundConstants[14]
        words.append(w30)
        expandSchedule(&words, firstWord: 31)
        let working = sha256Rounds(sha256State, words, firstRound: 14)
        return (0..<8).map { sha256Initial[$0] &+ working[$0] }
    }

    private static func sha256DigestV2(_ data: [UInt8]) -> [UInt8] {
        let totalLen = 57 + data.count
        var padded = Array(data[7...])
        padded.append(0x80)
        let zeroCount = ((55 - totalLen) % 64 + 64) % 64
        padded.append(contentsOf: repeatElement(UInt8(0), count: zeroCount))
        let bitLen = UInt64(totalLen) * 8
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLen >> shift) & 0xFF))
        }
        var state = sha256Init(Array(data[0..<7]))
        var offset = 0
        while offset < padded.count {
            var words: [UInt32] = []
            words.reserveCapacity(64)
            for i in 0..<16 {
                let b = offset + i * 4
                let w = (UInt32(padded[b]) << 24) | (UInt32(padded[b + 1]) << 16)
                    | (UInt32(padded[b + 2]) << 8) | UInt32(padded[b + 3])
                words.append(w)
            }
            expandSchedule(&words, firstWord: 16)
            let working = sha256Rounds(state, words, firstRound: 0)
            for i in 0..<8 { state[i] = state[i] &+ working[i] }
            offset += 64
        }
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for w in state {
            out.append(UInt8((w >> 24) & 0xFF))
            out.append(UInt8((w >> 16) & 0xFF))
            out.append(UInt8((w >> 8) & 0xFF))
            out.append(UInt8(w & 0xFF))
        }
        return out
    }

    private static func wordsLE4Even(_ bytes: [UInt8]) -> [UInt32] {
        var padded = bytes
        let rem = padded.count % 4
        if rem != 0 {
            padded.append(contentsOf: repeatElement(UInt8(0), count: 4 - rem))
        }
        var words: [UInt32] = []
        words.reserveCapacity(padded.count / 4 + 1)
        var i = 0
        while i < padded.count {
            let w = UInt32(padded[i])
                | (UInt32(padded[i + 1]) << 8)
                | (UInt32(padded[i + 2]) << 16)
                | (UInt32(padded[i + 3]) << 24)
            words.append(w)
            i += 4
        }
        if words.count % 2 != 0 { words.append(0) }
        return words
    }

    private static func cs64Digest(_ data: [UInt8], _ digest: [UInt8]) -> (UInt32, UInt32) {
        let keyA = (UInt32(digest[0]) | (UInt32(digest[1]) << 8) | (UInt32(digest[2]) << 16) | (UInt32(digest[3]) << 24)) | 1
        let keyB = (UInt32(digest[4]) | (UInt32(digest[5]) << 8) | (UInt32(digest[6]) << 16) | (UInt32(digest[7]) << 24)) | 1
        let factor0 = keyA &* cs64Factor
        let factor1 = keyB &* cs64Factor

        var terms: [UInt32] = []
        var offsets: [UInt32] = []
        for (idx, pair) in cs64Coefficients.enumerated() {
            terms.append(pair.0 &* (idx % 2 == 0 ? factor0 : factor1))
            offsets.append(pair.1)
        }
        let prefixed = [UInt8(0)] + data
        for (idx, word) in wordsLE4Even(prefixed).enumerated() {
            var term = word &* (idx % 2 == 0 ? keyA : keyB)
            var offset = rol16(word) &* (idx % 2 == 0 ? 0xEF0569FB : 0xC31713DB)
            if idx == 0 {
                term = term &+ (cs64Adjustment0 &* factor0)
                offset = offset &+ cs64Adjustment1
            }
            terms.append(term)
            offsets.append(offset)
        }

        var swapAcc: UInt32 = 0
        var swapLast: UInt32 = 0
        var state: UInt32 = 0
        var acc: UInt32 = 0
        var idx = 0
        while idx < terms.count {
            let x = terms[idx], y = terms[idx + 1]
            let t0 = rol16(offsets[idx] &+ x)
            let q0 = t0 &* 0x76F50F34
            swapAcc = swapAcc &+ (rol16(q0) &* 0xC3EFEA97 &+ q0)
            let t1 = rol16(offsets[idx + 1] &+ y)
            let q1 = t1 &* 0x1881CE3C
            swapLast = rol16(q1) &* 0x35BD1EC9 &+ q1
            swapAcc = swapAcc &+ swapLast

            state = state &* keyA &+ x
            state = rol16(state) &* 0xCF98B111
            state = rol16(state) &* 0x87085B9F
            state = rol16(state) &* 0x12CEB96D
            state = rol16(state) &* 0x257E1D83
            acc = acc &+ state
            var t = state &* keyB &+ y
            t = rol16(t) &* 0xA27416F5
            t = rol16(t) &* 0xD38396FF
            state = rol16(rol16(t) &* 0x7C932B89) &* 0xBFA49F69
            acc = acc &+ state
            idx += 2
        }
        return (swapLast ^ state, swapAcc ^ acc)
    }

    private static func generateSecMsGecV2() -> String {
        var ticks = Int64(Date().timeIntervalSince1970) + winEpoch
        ticks -= ticks % 300
        ticks *= 10_000_000
        let raw = Array("\(ticks)\(trustedToken)".utf8)
        let digest = sha256DigestV2(raw)
        let (w0, w1) = cs64Digest(raw, digest)
        let cs64Bytes: [UInt8] = [
            UInt8(w0 & 0xFF), UInt8((w0 >> 8) & 0xFF), UInt8((w0 >> 16) & 0xFF), UInt8((w0 >> 24) & 0xFF),
            UInt8(w1 & 0xFF), UInt8((w1 >> 8) & 0xFF), UInt8((w1 >> 16) & 0xFF), UInt8((w1 >> 24) & 0xFF),
        ]
        let cs64Hex = cs64Bytes.map { String(format: "%02X", $0) }.joined()
        let shaHex = digest.map { String(format: "%02X", $0) }.joined()
        return "\(cs64Hex)-\(shaHex)"
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
