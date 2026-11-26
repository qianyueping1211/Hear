import Foundation
import CryptoKit
import Darwin

enum ZipVoiceArchive {
    enum Failure: LocalizedError {
        case invalidChecksum, invalidArchive

        var errorDescription: String? {
            switch self {
            case .invalidChecksum: return "下载的 ZipVoice 文件校验失败"
            case .invalidArchive: return "无法解压 ZipVoice 模型文件"
            }
        }
    }

    static func verify(_ file: URL, sha256 expected: String) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256()
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw Failure.invalidChecksum }
    }

    /// Reads the verified upstream tar.bz2 on disk and copies only the model files.
    static func extract(_ archive: URL, into destination: URL, root: String,
                        modelFiles: Set<String>) throws {
        guard let input = fopen(archive.path, "rb") else { throw Failure.invalidArchive }
        defer { fclose(input) }
        var status: Int32 = BZ_OK
        guard let reader = BZ2_bzReadOpen(&status, input, 0, 0, nil, 0),
              status == BZ_OK else { throw Failure.invalidArchive }
        defer { BZ2_bzReadClose(&status, reader) }

        func read(_ size: Int) throws -> Data {
            try Task.checkCancellation()
            guard size > 0, status == BZ_OK else { throw Failure.invalidArchive }
            var chunk = Data(count: size)
            let count = chunk.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                BZ2_bzRead(&status, reader, buffer.baseAddress, Int32(size))
            }
            guard count == Int32(size), status == BZ_OK || status == BZ_STREAM_END else {
                throw Failure.invalidArchive
            }
            return chunk
        }

        let fm = FileManager.default
        var remainingBytes = 600 * 1024 * 1024
        for _ in 0..<4096 {
            let header = try read(512)
            if header.allSatisfy({ $0 == 0 }) { return }
            guard let name = String(data: Data(header.prefix(100).prefix { $0 != 0 }), encoding: .utf8),
                  let sizeText = String(data: Data(header[124..<136].prefix { $0 != 0 }), encoding: .ascii),
                  let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 8),
                  size >= 0, size <= remainingBytes else { throw Failure.invalidArchive }
            remainingBytes -= size

            let parts = name.split(separator: "/")
            guard parts.first == Substring(root), !name.hasPrefix("/"),
                  parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw Failure.invalidArchive }
            let relative = parts.dropFirst()
            let isFile = header[156] == 48 || header[156] == 0
            let isModel = relative.count == 1 && modelFiles.contains(relative.joined())
            let isVoiceData = relative.count > 1 && relative.first == "espeak-ng-data"
            let target = isFile && (isModel || isVoiceData)
                ? destination.appendingPathComponent(relative.joined(separator: "/")) : nil

            var output: FileHandle?
            if let target {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard !fm.fileExists(atPath: target.path), fm.createFile(atPath: target.path, contents: nil) else {
                    throw Failure.invalidArchive
                }
                output = try FileHandle(forWritingTo: target)
            }
            defer { try? output?.close() }

            var unread = size
            while unread > 0 {
                let chunk = try read(min(unread, 1 << 20))
                try output?.write(contentsOf: chunk)
                unread -= chunk.count
            }
            let padding = (512 - size % 512) % 512
            if padding > 0 { _ = try read(padding) }
        }
        throw Failure.invalidArchive
    }
}
