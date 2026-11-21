import Foundation
import SherpaOnnx
import os

enum LocalVoiceCloneError: LocalizedError {
    case missingFile(String)
    case notLoaded
    case loadFailed
    case invalidReference
    case unsupportedLanguage
    case generationFailed
    case lowMemory

    var errorDescription: String? {
        switch self {
        case .missingFile(let name): return "ZipVoice 模型文件夹缺少或无法读取 \(name)"
        case .notLoaded: return "ZipVoice 模型尚未加载"
        case .loadFailed: return "ZipVoice 模型无法加载"
        case .invalidReference: return "需要匹配的参考音频和原文"
        case .unsupportedLanguage: return "本地 ZipVoice 仅支持中文和英文"
        case .generationFailed: return "ZipVoice 未生成有效音频"
        case .lowMemory: return "手机可用内存不足，已跳过本地声音克隆"
        }
    }
}

enum ZipVoiceModel {
    static let displayName = "ZipVoice"
    private static let files = ["encoder.int8.onnx", "decoder.int8.onnx", "vocos_24khz.onnx",
                        "tokens.txt", "lexicon.txt", "espeak-ng-data"]
    private static let archiveRoot = "sherpa-onnx-zipvoice-distill-int8-zh-en-emilia"
    private static let releaseAssets = "https://github.com/k2-fsa/sherpa-onnx/releases/download"

    static var directory: URL {
        ModelManager.documents.appendingPathComponent("ZipVoice", isDirectory: true)
    }

    static var installed: Bool { (try? validate(directory)) != nil }

    static func supports(_ language: String) -> Bool {
        language == "zh" || language == "en"
    }

    private static func validate(_ folder: URL) throws {
        let paths = files.filter { $0 != "espeak-ng-data" } +
            ["espeak-ng-data/phondata", "espeak-ng-data/phonindex", "espeak-ng-data/phontab",
             "espeak-ng-data/en_dict"]
        for name in paths {
            let url = folder.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else {
                throw LocalVoiceCloneError.missingFile(name)
            }
        }
    }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let staging = ModelManager.documents.appendingPathComponent(".zipvoice-\(UUID().uuidString)")
        let model = staging.appendingPathComponent("model")
        try fm.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let archive = staging.appendingPathComponent("model.tar.bz2")
        let archiveURL = URL(string: "\(releaseAssets)/tts-models/\(archiveRoot).tar.bz2")!
        try await FileDownloader().download(archiveURL, to: archive) { progress($0 * 0.65) }
        try ZipVoiceArchive.verify(archive, sha256: "77219c8b40f4ee8d73a7f902305ff6c1128ef9b54461c41b4ca6ed890b6c2803")
        try ZipVoiceArchive.extract(archive, into: model, root: archiveRoot,
                                    modelFiles: Set(files).subtracting(["vocos_24khz.onnx", "espeak-ng-data"]))
        try fm.removeItem(at: archive)

        let vocos = model.appendingPathComponent("vocos_24khz.onnx")
        let vocosURL = URL(string: "\(releaseAssets)/vocoder-models/vocos_24khz.onnx")!
        try await FileDownloader().download(vocosURL, to: vocos) { progress(0.65 + $0 * 0.34) }
        try ZipVoiceArchive.verify(vocos, sha256: "bcb3b970e384161c4d634f0bb9e999ff1c471b34c9bc0b1049a5014065ed3cc0")
        try validate(model)
        try Task.checkCancellation()
        try ModelManager.installModelFile(model, at: directory)
        progress(1)
    }

    static func importFolder(_ source: URL) throws {
        let authorized = source.startAccessingSecurityScopedResource()
        defer { if authorized { source.stopAccessingSecurityScopedResource() } }
        try validate(source)
        let fm = FileManager.default
        let staging = ModelManager.documents.appendingPathComponent(".zipvoice-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for name in files {
            let url = source.appendingPathComponent(name)
            try fm.copyItem(at: url, to: staging.appendingPathComponent(name))
        }
        try validate(staging)
        try ModelManager.installModelFile(staging, at: directory)
    }
}

/// Serializes model loading and synthesis off the main actor.
actor LocalVoiceCloner {
    private var engine: SherpaOnnxOfflineTtsWrapper?
    var isLoaded: Bool { engine != nil }

    func unload() { engine = nil }

    func load() throws {
        try Task.checkCancellation()
        guard engine == nil else { return }
        guard ZipVoiceModel.installed else { throw LocalVoiceCloneError.notLoaded }
        let base = ZipVoiceModel.directory
        func path(_ name: String) -> String { base.appendingPathComponent(name).path }
        let paths = sherpaOnnxOfflineTtsZipvoiceModelConfig(
            tokens: path("tokens.txt"), encoder: path("encoder.int8.onnx"),
            decoder: path("decoder.int8.onnx"), vocoder: path("vocos_24khz.onnx"),
            dataDir: path("espeak-ng-data"), lexicon: path("lexicon.txt"))
        let model = sherpaOnnxOfflineTtsModelConfig(numThreads: 2, provider: "cpu", zipvoice: paths)
        var config = sherpaOnnxOfflineTtsConfig(model: model)
        let loaded = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard loaded.tts != nil else { throw LocalVoiceCloneError.loadFailed }
        try Task.checkCancellation()
        engine = loaded
    }

    func synthesize(text: String, language: String, reference: [Float],
                    referenceText: String) throws -> CloneAudio {
        try Task.checkCancellation()
        guard let engine else { throw LocalVoiceCloneError.notLoaded }
        guard ZipVoiceModel.supports(language) else { throw LocalVoiceCloneError.unsupportedLanguage }
        guard !reference.isEmpty, !referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalVoiceCloneError.invalidReference
        }
        let free = os_proc_available_memory() / 1_048_576
        guard free >= 280 else { throw LocalVoiceCloneError.lowMemory }
        let start = ContinuousClock.now
        hearLog("ZipVoice：开始合成，可用内存 \(free) MB")
        defer {
            hearLog("ZipVoice：合成结束，可用内存 \(os_proc_available_memory() / 1_048_576) MB，耗时 \(start.duration(to: .now))")
        }
        let config = SherpaOnnxGenerationConfigSwift(referenceAudio: reference, referenceSampleRate: 16_000,
                                                     referenceText: referenceText, numSteps: 4)
        let audio = engine.generateWithConfig(text: text, config: config, callback: nil, arg: nil)
        try Task.checkCancellation()
        guard audio.audio != nil, audio.sampleRate > 0 else { throw LocalVoiceCloneError.generationFailed }
        let samples = audio.samples
        guard samples.contains(where: { abs($0) > 0.0005 }) else {
            throw LocalVoiceCloneError.generationFailed
        }
        return CloneAudio(samples: samples, sampleRate: Int(audio.sampleRate))
    }
}
