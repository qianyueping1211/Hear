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
            let v = samples[i].isFinite ? max(-1.0, min(1.0, samples[i])) : 0
            let x = (v * 32767.0).rounded()
            pcm[i] = Int16(max(-32767.0, min(32767.0, x)))
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// wav 数据解成 [Float]。只支持 16 bit PCM
    ///
    /// 注意：采样值是用 Int16(bitPattern:) 还原的。
    /// 之前写成 Int16(UInt16(...))，遇到负数（高位是 1）的采样会直接崩，
    /// 云端声音克隆收到 wav 之后就在这里退出了。
    static func decode(_ data: Data) -> (samples: [Float], sampleRate: Int)? {
        guard data.count > 44 else { return nil }
        // 直接在原始字节上解析，不再额外复制一份 [UInt8]（云端返回的音频有几百 KB）
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (samples: [Float], sampleRate: Int)? in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            func str(_ at: Int, _ len: Int) -> String {
                guard at >= 0, at + len <= n else { return "" }
                return String(decoding: b[at..<(at + len)], as: UTF8.self)
            }
            guard str(0, 4) == "RIFF", str(8, 4) == "WAVE" else { return nil }
            var sampleRate = 16_000
            var bits = 16
            var channels = 1
            var dataOffset = -1
            var dataLength = 0
            var pos = 12
            while pos + 8 <= n {
                let id = str(pos, 4)
                let size = Int(UInt32(b[pos + 4]) | (UInt32(b[pos + 5]) << 8)
                               | (UInt32(b[pos + 6]) << 16) | (UInt32(b[pos + 7]) << 24))
                let body = pos + 8
                if id == "fmt " && body + 16 <= n {
                    channels = Int(UInt16(b[body + 2]) | (UInt16(b[body + 3]) << 8))
                    sampleRate = Int(UInt32(b[body + 4]) | (UInt32(b[body + 5]) << 8)
                                     | (UInt32(b[body + 6]) << 16) | (UInt32(b[body + 7]) << 24))
                    bits = Int(UInt16(b[body + 14]) | (UInt16(b[body + 15]) << 8))
                } else if id == "data" {
                    dataOffset = body
                    dataLength = min(size, n - body)
                    break
                }
                pos = body + size + (size % 2)
            }
            guard dataOffset >= 0, dataLength > 0, bits == 16 else { return nil }
            let ch = max(channels, 1)
            let frames = dataLength / 2 / ch
            var out = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                let off = dataOffset + i * 2 * ch
                guard off + 1 < n else { break }
                let u = UInt16(b[off]) | (UInt16(b[off + 1]) << 8)
                out[i] = Float(Int16(bitPattern: u)) / 32767.0
            }
            return (out, sampleRate)
        }
    }
}
