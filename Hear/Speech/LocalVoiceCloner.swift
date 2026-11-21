import Foundation
import SherpaOnnx

enum ZipVoiceModel {
    static let files = ["encoder.int8.onnx", "decoder.int8.onnx", "vocos_24khz.onnx",
                        "tokens.txt", "lexicon.txt", "espeak-ng-data"]

    static var directory: URL {
        ModelManager.documents.appendingPathComponent("ZipVoice", isDirectory: true)
    }

    static var installed: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    static func importFolder(_ source: URL) throws {
        let authorized = source.startAccessingSecurityScopedResource()
        defer { if authorized { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let staging = ModelManager.documents.appendingPathComponent(".zipvoice-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for name in files {
            let url = source.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else {
                throw VoiceCloneGGUFError.modelMissing("ZipVoice 模型文件夹缺少 \(name)")
            }
            try fm.copyItem(at: url, to: staging.appendingPathComponent(name))
        }
        try ModelManager.installModelFile(staging, at: directory)
    }
}

/// Serializes native synthesis and model switching. Audio playback only consumes CloneAudio.
actor LocalVoiceCloner {
    private let qwen = GGUFVoiceCloner()
    private var zipVoice: SherpaOnnxOfflineTtsWrapper?
    private var usingZipVoice = false
    private(set) var isLoading = false

    var isLoaded: Bool {
        get async {
            if usingZipVoice { return zipVoice != nil }
            return await qwen.isLoaded
        }
    }

    func unload() async {
        zipVoice = nil
        await qwen.unload()
    }

    func load(zipVoice useZip: Bool, useGPU: Bool, lowMemory: Bool) async throws {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if useZip != usingZipVoice { await unload() }
        usingZipVoice = useZip
        if useZip {
            guard zipVoice == nil else { return }
            guard ZipVoiceModel.installed else { throw VoiceCloneGGUFError.notLoaded }
            let base = ZipVoiceModel.directory
            func path(_ name: String) -> String { base.appendingPathComponent(name).path }
            let paths = sherpaOnnxOfflineTtsZipvoiceModelConfig(
                tokens: path("tokens.txt"), encoder: path("encoder.int8.onnx"),
                decoder: path("decoder.int8.onnx"), vocoder: path("vocos_24khz.onnx"),
                dataDir: path("espeak-ng-data"), lexicon: path("lexicon.txt"))
            let model = sherpaOnnxOfflineTtsModelConfig(numThreads: 2, provider: "cpu", zipvoice: paths)
            var config = sherpaOnnxOfflineTtsConfig(model: model)
            let engine = SherpaOnnxOfflineTtsWrapper(config: &config)
            guard engine.tts != nil else { throw VoiceCloneGGUFError.loadFailed("ZipVoice") }
            zipVoice = engine
        } else {
            try await qwen.load(useGPU: useGPU, lowMemory: lowMemory)
        }
    }

    func synthesize(text: String, language: String, reference: [Float],
                    referenceText: String) async throws -> CloneAudio {
        try Task.checkCancellation()
        if usingZipVoice {
            guard let zipVoice else { throw VoiceCloneGGUFError.notLoaded }
            guard language == "zh" || language == "en" else { throw VoiceCloneGGUFError.unsupportedLanguage }
            guard !reference.isEmpty, !referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceCloneGGUFError.encodeFailed
            }
            let config = SherpaOnnxGenerationConfigSwift(referenceAudio: reference, referenceSampleRate: 16_000,
                                                         referenceText: referenceText, numSteps: 4)
            let audio = zipVoice.generateWithConfig(text: text, config: config, callback: nil, arg: nil)
            guard audio.audio != nil, audio.sampleRate > 0 else {
                throw VoiceCloneGGUFError.generateFailed("ZipVoice")
            }
            return CloneAudio(samples: audio.samples, sampleRate: Int(audio.sampleRate))
        }
        return try await qwen.synthesize(text: text, language: language, reference: reference, referenceText: referenceText)
    }
}
