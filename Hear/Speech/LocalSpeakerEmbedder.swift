import Foundation
import FluidAudio

/// 本机说话人声纹：CAM++ 把一句话编码成 192 维向量。
///
/// 模型文件放在 SenseVoice 文件夹里，与识别模型一起导入、一起备份。
actor LocalSpeakerEmbedder {
    private var loadedFolder: URL?
    private var embedder: CampPlusEmbedder?

    static let modelDirectories = [
        ModelNames.CampPlus.preprocessorFile,
        ModelNames.CampPlus.modelFile,
    ]

    static func isInstalled(in folder: URL) -> Bool {
        CampPlusModels.modelsExist(at: folder)
    }

    /// 把 FluidAudio 下载的 CAM++ 模型复制到 SenseVoice 文件夹。
    static func download(into folder: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        if isInstalled(in: folder) { return }
        let source = try await CampPlusModels.download { p in
            progress(p.fractionCompleted)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in modelDirectories {
            let src = source.appendingPathComponent(name, isDirectory: true)
            let dst = folder.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: src.path) else {
                throw NSError(domain: "Hear", code: 41, userInfo: [
                    NSLocalizedDescriptionKey: "说话人模型缺少 \(name)",
                ])
            }
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
        }
        guard isInstalled(in: folder) else {
            throw NSError(domain: "Hear", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "说话人模型复制不完整",
            ])
        }
    }

    func unload() {
        embedder = nil
        loadedFolder = nil
    }

    func embedding(samples: [Float], folder: URL) async throws -> [Float]? {
        let audio = Array(samples.prefix(160_000))       // 最多取 10 秒
        guard audio.count >= 22_400 else { return nil } // 至少约 1.4 秒
        if embedder == nil || loadedFolder?.standardizedFileURL != folder.standardizedFileURL {
            let models = try CampPlusModels.load(from: folder)
            embedder = CampPlusEmbedder(models: models)
            loadedFolder = folder
        }
        guard let embedder else { return nil }
        return try await embedder.embed(audio: audio)
    }
}
