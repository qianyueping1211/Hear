import Foundation
import FluidAudio

/// 本地语音识别：SenseVoiceSmall（阿里 FunASR，FluidAudio 转成的 Core ML，跑在神经引擎上）。
/// 一次把整句文字算出来（不是一个字一个字往下生成），所以很快，也不会在噪声上“复读”卡住。
/// 擅长中文、英语、日语、韩语、粤语。
actor SenseVoiceRecognizer {
    private var models: SenseVoiceModels?
    /// 每种语言一个 manager（语言在创建时定好；创建很便宜，模型是共用的）
    private var managers: [Int32: SenseVoiceManager] = [:]

    /// SenseVoice 能识别的语言（Whisper 语言代码）
    static let languageIDs: Set<String> = ["zh", "en", "ja", "ko"]

    /// SenseVoice 的语言编号：0 = 自动判断
    private static let languageIndex: [String: Int32] = ["zh": 3, "en": 4, "yue": 7, "ja": 11, "ko": 12]
    /// 14 = 带标点和数字规整（withitn），15 = 不带
    private static let textNorm: Int32 = 14

    var isLoaded: Bool { models != nil }

    func unload() {
        models = nil
        managers.removeAll()
    }

    func load(folder: URL) throws {
        let t0 = Date()
        // 下载的是 int8（约 240 MB）；导入的文件夹里只有 fp16 时就用 fp16
        let precision: SenseVoiceEncoderPrecision =
            SenseVoiceModels.modelsExist(at: folder, precision: .int8) ? .int8 : .fp16
        hearLog("SenseVoice：开始加载（\(precision.rawValue)）")
        models = try SenseVoiceModels.load(from: folder, precision: precision)
        managers.removeAll()
        hearLog("SenseVoice：加载完成，用时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    }

    private func manager(for lang: String?) -> SenseVoiceManager? {
        guard let models else { return nil }
        let idx = lang.flatMap { Self.languageIndex[$0] } ?? 0
        if let m = managers[idx] { return m }
        let m = SenseVoiceManager(models: models, language: idx, textNorm: Self.textNorm)
        managers[idx] = m
        return m
    }

    /// 识别一句话。candidates 只有一种时（对话翻译模式）按这种语言识别，否则自动判断。
    /// 返回 (语言代码, 文字)；没听到人说话时文字为空
    func recognize(_ samples: [Float], candidates: [String], fallback: String) async throws -> (String, String) {
        let forced = candidates.count == 1 ? candidates.first : nil
        guard let m = manager(for: forced) else { return (fallback, "") }
        let r = try await m.transcribeDetailed(audio: samples)
        var lang = r.language ?? ""
        if lang == "yue" { lang = "zh" }                 // 粤语按中文处理
        if lang == "nospeech" { return (forced ?? fallback, "") }
        let detected = forced ?? (candidates.contains(lang) ? lang : fallback)
        var text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if detected == "zh" {
            text = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        }
        return (detected, Fillers.clean(text))
    }

    // MARK: - 模型文件（下载 / 导入 / 删除）

    /// FluidAudio 默认的模型目录：Application Support/FluidAudio/Models/sensevoice-small-coreml
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FluidAudio/Models/sensevoice-small-coreml", isDirectory: true)
    }

    /// 已下载（或已导入）就返回文件夹
    static func installedFolder() -> URL? {
        let f = folder
        let ok = SenseVoiceModels.modelsExist(at: f, precision: .int8)
            || SenseVoiceModels.modelsExist(at: f, precision: .fp16)
        return ok ? f : nil
    }

    static func download(host: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        ModelRegistry.baseURL = "https://\(host)"
        _ = try await SenseVoiceModels.download(precision: .int8, force: false) { p in
            progress(p.fractionCompleted)
        }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// 导入：选一个 SenseVoice 模型文件夹（里面有 SenseVoicePreprocessor.mlmodelc、
    /// SenseVoiceSmall_int8.mlmodelc 或 SenseVoiceSmall.mlmodelc、vocab.json）
    static func importFolder(from src: URL) throws {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        guard SenseVoiceModels.modelsExist(at: src, precision: .int8)
                || SenseVoiceModels.modelsExist(at: src, precision: .fp16) else {
            throw NSError(domain: "Hear", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "这个文件夹不是 SenseVoice 模型（需要 SenseVoicePreprocessor.mlmodelc、SenseVoiceSmall_int8.mlmodelc 和 vocab.json）"])
        }
        let fm = FileManager.default
        let dst = folder
        if src.standardizedFileURL.path == dst.standardizedFileURL.path { return }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
    }
}
