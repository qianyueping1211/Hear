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
            try fm.unzipItem(at: url, to: root)
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
                return url.pathExtension.lowercased() == "gguf"
            }
        }
    }
}
