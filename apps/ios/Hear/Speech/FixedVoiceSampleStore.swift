import Foundation
import Observation

/// 本地保存的用户「固定声纹样本」（16 kHz 单声道 16-bit PCM WAV + 对应朗读文本）。
/// 本地 ZipVoice 与云端 Qwen3-TTS 声音克隆均可直接复用，避免首句或短句出现「没有完整参考样本」。
@MainActor
@Observable
final class FixedVoiceSampleStore {
    static let shared = FixedVoiceSampleStore()

    private static let preferKey = "hear.fixedVoiceSample.preferOverLive"

    private(set) var hasSample: Bool = false
    private(set) var durationSeconds: Double = 0
    private(set) var referenceText: String = ""

    /// 为 true 时优先使用固定声纹；为 false 时仅在当前句样本不足时兜底复用
    var preferOverLive: Bool {
        didSet {
            UserDefaults.standard.set(preferOverLive, forKey: Self.preferKey)
        }
    }

    let directoryURL: URL
    let wavURL: URL
    let textURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("Hear/VoiceSample", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directoryURL = dir
        self.wavURL = dir.appendingPathComponent("my_voice_ref.wav")
        self.textURL = dir.appendingPathComponent("my_voice_ref.txt")
        if UserDefaults.standard.object(forKey: Self.preferKey) == nil {
            self.preferOverLive = true
        } else {
            self.preferOverLive = UserDefaults.standard.bool(forKey: Self.preferKey)
        }
        reloadMetadata()
    }

    func reloadMetadata() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: wavURL.path),
              let size = attrs[.size] as? Int,
              size > 44 + 16_000 * 2 * 2,
              let text = try? String(contentsOf: textURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            hasSample = false
            durationSeconds = 0
            referenceText = ""
            return
        }
        hasSample = true
        durationSeconds = Double(size - 44) / 32_000.0
        referenceText = text
    }

    func saveRecordedWav(from tempURL: URL, referenceText: String) throws {
        let cleanText = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            throw NSError(domain: "FixedVoiceSampleStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "参考朗读文本不能为空"])
        }
        let data = try Data(contentsOf: tempURL)
        let rawSamples = Self.decodePCM16Mono(from: data)
        // 自动裁掉按下录制到开口前、以及读完到停止之间的前后空白音，避免模型把开头静音/气口学进去导致朗读开头无声
        let samples = CloneAudio(samples: rawSamples, sampleRate: 16_000)
            .trimmingEdgeSilence()?.audio.samples ?? rawSamples
        let seconds = Double(samples.count) / 16_000.0
        guard seconds >= 2.2 else {
            throw NSError(domain: "FixedVoiceSampleStore", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "有效人声时长不足，请在安静环境下清晰朗读 3~10 秒"])
        }
        let clipped = seconds > 10.0 ? Array(samples.prefix(160_000)) : samples
        let canonicalWav = Self.encodeWav16kMono(samples: clipped)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try canonicalWav.write(to: wavURL, options: .atomic)
        try cleanText.write(to: textURL, atomically: true, encoding: .utf8)
        reloadMetadata()
    }

    func clear() {
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: textURL)
        reloadMetadata()
    }

    /// 读取 16 kHz Float 采样与参考文本，供本地 ZipVoice / 云端 Qwen3-TTS 直接使用
    func loadReference() -> (samples: [Float], text: String)? {
        guard hasSample,
              let data = try? Data(contentsOf: wavURL),
              !referenceText.isEmpty else {
            return nil
        }
        let rawSamples = Self.decodePCM16Mono(from: data)
        let samples = CloneAudio(samples: rawSamples, sampleRate: 16_000)
            .trimmingEdgeSilence()?.audio.samples ?? rawSamples
        guard samples.count >= 16_000 * 2 else { return nil }
        return (samples, referenceText)
    }

    static func decodePCM16Mono(from data: Data) -> [Float] {
        guard data.count > 44 else { return [] }
        // 查找 WAV 的 "data" chunk，兼容带额外元数据的 PCM WAV 头
        var offset = 12
        var dataStart = 44
        var dataSize = data.count - 44
        while offset + 8 <= data.count {
            let chunkID = String(bytes: data[offset..<(offset + 4)], encoding: .ascii)
            let size = data.withUnsafeBytes { raw -> Int in
                Int(raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self).littleEndian)
            }
            if chunkID == "data" {
                dataStart = offset + 8
                dataSize = min(size, max(0, data.count - dataStart))
                break
            }
            let step = 8 + size + (size % 2)
            if step <= 0 { break }
            offset += step
        }
        let sampleCount = dataSize / 2
        guard sampleCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { raw in
            for i in 0..<sampleCount {
                let s = raw.loadUnaligned(fromByteOffset: dataStart + i * 2, as: Int16.self).littleEndian
                out[i] = max(-1.0, min(1.0, Float(s) / 32768.0))
            }
        }
        return out
    }

    static func encodeWav16kMono(samples: [Float]) -> Data {
        let dataBytes = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + Int(dataBytes))
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36) + dataBytes)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1))       // PCM
        appendLE(UInt16(1))       // mono
        appendLE(UInt32(16_000))  // sample rate
        appendLE(UInt32(32_000))  // byte rate
        appendLE(UInt16(2))       // block align
        appendLE(UInt16(16))      // bits per sample
        data.append(contentsOf: "data".utf8)
        appendLE(dataBytes)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i16 = Int16(clamped < 0 ? clamped * 32768.0 : clamped * 32767.0)
            appendLE(i16)
        }
        return data
    }
}
