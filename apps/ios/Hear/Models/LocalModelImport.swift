import Foundation
import ZIPFoundation

enum LocalModelImport {
    struct Prepared: Sendable {
        let source: URL
        let cleanupRoot: URL?
    }

    enum Failure: LocalizedError {
        case noMatchingFolder(LiveSession.ModelKind)
        case invalidArchive
        case archiveTooLarge

        var errorDescription: String? {
            switch self {
            case .noMatchingFolder(.senseVoice):
                return "压缩包里没有找到完整的 SenseVoice 模型"
            case .noMatchingFolder(.translation):
                return "压缩包里没有找到 GGUF 翻译模型"
            case .noMatchingFolder(.voiceClone):
                return "压缩包里没有找到完整的 ZipVoice 模型"
            case .invalidArchive:
                return "无法解压这个模型压缩包"
            case .archiveTooLarge:
                return "压缩包内容过大或文件过多，请检查模型压缩包"
            }
        }
    }

    static func prepare(_ url: URL, for kind: LiveSession.ModelKind) throws -> Prepared {
        guard url.pathExtension.lowercased() == "zip" else {
            return Prepared(source: url, cleanupRoot: nil)
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("hear-model-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try extractCheckedArchive(url, into: root, kind: kind)
            guard let folder = findModelFolder(in: root, kind: kind) else {
                throw Failure.noMatchingFolder(kind)
            }
            return Prepared(source: folder, cleanupRoot: root)
        } catch {
            try? fm.removeItem(at: root)
            if error is Failure { throw error }
            throw Failure.invalidArchive
        }
    }

    private static func extractCheckedArchive(_ url: URL, into root: URL,
                                              kind: LiveSession.ModelKind) throws {
        let fm = FileManager.default
        let archive = try Archive(url: url, accessMode: .read)
        let maxBytes: UInt64
        switch kind {
        case .translation: maxBytes = 5 * 1024 * 1024 * 1024
        case .senseVoice, .voiceClone: maxBytes = 2 * 1024 * 1024 * 1024
        }
        var remaining = maxBytes
        var count = 0
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            guard count <= 8_192 else { throw Failure.archiveTooLarge }
            let path = entry.path
            let parts = path.split(separator: "/")
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
                  !path.contains("\0"),
                  parts.allSatisfy({ $0 != "." && $0 != ".." }),
                  entry.type != .symlink else { throw Failure.invalidArchive }
            let target = root.appendingPathComponent(path).standardizedFileURL
            guard target.path.hasPrefix(root.path + "/") else { throw Failure.invalidArchive }
            switch entry.type {
            case .directory:
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case .file:
                guard entry.uncompressedSize <= remaining else { throw Failure.archiveTooLarge }
                remaining -= entry.uncompressedSize
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard !fm.fileExists(atPath: target.path), fm.createFile(atPath: target.path, contents: nil) else {
                    throw Failure.invalidArchive
                }
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                var written: UInt64 = 0
                let checksum = try archive.extract(entry, bufferSize: 64 * 1024) { data in
                    try Task.checkCancellation()
                    guard UInt64(data.count) <= entry.uncompressedSize - written else {
                        throw Failure.archiveTooLarge
                    }
                    written += UInt64(data.count)
                    try output.write(contentsOf: data)
                }
                guard written == entry.uncompressedSize, checksum == entry.checksum else {
                    throw Failure.invalidArchive
                }
            case .symlink:
                throw Failure.invalidArchive
            }
        }
    }

    static func cleanup(_ prepared: Prepared) {
        guard let root = prepared.cleanupRoot else { return }
        try? FileManager.default.removeItem(at: root)
    }

    private static func findModelFolder(in root: URL, kind: LiveSession.ModelKind) -> URL? {
        let fm = FileManager.default
        var folders = [root]
        if let e = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in e {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    folders.append(url)
                }
            }
        }
        folders.sort { $0.pathComponents.count < $1.pathComponents.count }
        return folders.first { isValidModelFolder($0, kind: kind) }
    }

    private static func isValidModelFolder(_ folder: URL,
                                           kind: LiveSession.ModelKind) -> Bool {
        switch kind {
        case .senseVoice:
            return SenseVoiceRecognizer.isImportableFolder(folder)
        case .voiceClone:
            return ZipVoiceModel.isImportableFolder(folder)
        case .translation:
            guard let e = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return false }
            return e.contains { item in
                guard let url = item as? URL else { return false }
                return url.pathExtension.lowercased() == "gguf" &&
                    (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
        }
    }
}
