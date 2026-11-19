import Foundation

/// 最简单的 wav 编解码：16 bit PCM、单声道。
/// 云端模型接口要把声音传过去，参考音频也要传，所以两边都得用到。
enum Wav {
    /// [Float]（-1 ~ 1）编成 wav 数据
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let n = UInt32(samples.count)
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign = UInt16(2)
        let bits = UInt16(16)
        func u32(_ v: UInt32) -> Data { var x = v.littleEndian; return withUnsafeBytes(of: &x) { Data($0) } }
        func u16(_ v: UInt16) -> Data { var x = v.littleEndian; return withUnsafeBytes(of: &x) { Data($0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(u32(UInt32(36 + samples.count * 2)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(u32(16))
        data.append(u16(1))                       // PCM
        data.append(u16(1))                       // 单声道
        data.append(u32(UInt32(sampleRate)))
        data.append(u32(byteRate))
        data.append(u16(blockAlign))
        data.append(u16(bits))
        data.append(contentsOf: Array("data".utf8))
        data.append(u32(n &* 2))
        // 采样数据
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices {
            let v = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(v * 32767.0)
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// wav 数据解成 [Float]。只支持 16 bit PCM
    static func decode(_ data: Data) -> (samples: [Float], sampleRate: Int)? {
        guard data.count > 44 else { return nil }
        let bytes = [UInt8](data)
        func str(_ at: Int, _ n: Int) -> String {
            String(bytes: bytes[at..<(at + n)], encoding: .ascii) ?? ""
        }
        guard str(0, 4) == "RIFF", str(8, 4) == "WAVE" else { return nil }
        var pos = 12
        var sampleRate = 16_000
        var bits = 16
        var channels = 1
        var dataOffset = -1
        var dataLength = 0
        while pos + 8 <= bytes.count {
            let id = str(pos, 4)
            let size = Int(UInt32(bytes[pos + 4]) | (UInt32(bytes[pos + 5]) << 8)
                           | (UInt32(bytes[pos + 6]) << 16) | (UInt32(bytes[pos + 7]) << 24))
            let body = pos + 8
            if id == "fmt " && body + 16 <= bytes.count {
                channels = Int(UInt16(bytes[body + 2]) | (UInt16(bytes[body + 3]) << 8))
                sampleRate = Int(UInt32(bytes[body + 4]) | (UInt32(bytes[body + 5]) << 8)
                                 | (UInt32(bytes[body + 6]) << 16) | (UInt32(bytes[body + 7]) << 24))
                bits = Int(UInt16(bytes[body + 14]) | (UInt16(bytes[body + 15]) << 8))
            } else if id == "data" {
                dataOffset = body
                dataLength = min(size, bytes.count - body)
                break
            }
            pos = body + size + (size % 2)
        }
        guard dataOffset >= 0, dataLength > 0, bits == 16 else { return nil }
        let frames = dataLength / 2 / max(channels, 1)
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let b = dataOffset + i * 2 * max(channels, 1)
            guard b + 1 < bytes.count else { break }
            let raw = Int16(UInt16(bytes[b]) | (UInt16(bytes[b + 1]) << 8))
            out[i] = Float(raw) / 32767.0
        }
        return (out, sampleRate)
    }
}
