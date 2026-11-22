import Foundation
import FluidAudio
import CoreML
import os

/// 本地语音识别：SenseVoiceSmall（阿里 FunASR，FluidAudio 转成的 Core ML，跑在神经引擎上）。
/// 一次把整句文字算出来（不是一个字一个字往下生成），所以很快，也不会在噪声上“复读”卡住。
/// 擅长中文、英语、日语、韩语、粤语。
actor SenseVoiceRecognizer {
    struct LoadFailure: LocalizedError {
        var errorDescription: String? {
            "SenseVoice 无法加载。可以重试，或在「模型管理」中重新下载 SenseVoice。"
        }
    }
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
        hearLog("SenseVoice：开始加载（\(precision.rawValue)），可用内存 \(os_proc_available_memory() / 1_048_576) MB")
        do {
            models = try SenseVoiceModels.load(from: folder, precision: precision)
        } catch {
            try Task.checkCancellation()
            hearLog("SenseVoice 首次加载失败：\(error)", .warning)
            guard (error as NSError).domain == "com.apple.CoreML" else { throw LoadFailure() }
            hearLog("SenseVoice：尝试 CPU 兼容加载，可用内存 \(os_proc_available_memory() / 1_048_576) MB")
            do {
                models = try Self.loadOnCPU(folder, precision: precision)
            } catch {
                hearLog("SenseVoice CPU 加载失败：\(error)", .error)
                throw LoadFailure()
            }
        }
        managers.removeAll()
        hearLog("SenseVoice：加载完成，用时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s，可用内存 \(os_proc_available_memory() / 1_048_576) MB")
    }

    private static func loadOnCPU(_ folder: URL, precision: SenseVoiceEncoderPrecision) throws -> SenseVoiceModels {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let encoderFile: String
        if SenseVoiceModels.modelsExist(at: folder, precision: .fp32) {
            encoderFile = ModelNames.SenseVoice.encoderFp32File
        } else {
            encoderFile = precision == .int8 ? ModelNames.SenseVoice.encoderInt8File : ModelNames.SenseVoice.encoderFile
        }
        let data = try Data(contentsOf: folder.appendingPathComponent(ModelNames.SenseVoice.vocabularyFile))
        let decoder = JSONDecoder()
        let vocabulary: [Int: String]
        if let tokens = try? decoder.decode([String].self, from: data) {
            vocabulary = Dictionary(uniqueKeysWithValues: tokens.enumerated().map { ($0.offset, $0.element) })
        } else {
            let tokens = try decoder.decode([String: String].self, from: data)
            vocabulary = tokens.reduce(into: [:]) { result, token in
                if let id = Int(token.key) { result[id] = token.value }
            }
        }
        guard !vocabulary.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let preprocessor = try MLModel(contentsOf: folder.appendingPathComponent(ModelNames.SenseVoice.preprocessorFile),
                                      configuration: config)
        let encoder = try MLModel(contentsOf: folder.appendingPathComponent(encoderFile), configuration: config)
        return SenseVoiceModels(preprocessor: preprocessor, encoder: encoder, vocabulary: vocabulary)
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
    /// 返回选定语言、文字和模型原始语言；没听到人说话时文字为空。
    func recognize(_ samples: [Float], candidates: [String], fallback: String, preview: Bool)
        async throws -> (language: String, text: String, observed: String?) {
        let forced = candidates.count == 1 ? candidates.first : nil
        guard let m = manager(for: forced) else {
            // 模型不在了：报错，别静悄悄返回空字符串（会被当成"没说话"丢掉）
            throw NSError(domain: "Hear", code: 21, userInfo: [NSLocalizedDescriptionKey:
                "SenseVoice 模型不在了（可能被内存不足卸载了），请重新开始一次"])
        }
        let r = try await m.transcribeDetailed(audio: samples)
        try Task.checkCancellation()
        let observed = r.language == "yue" ? "zh" : r.language
        if observed == "nospeech" { return (forced ?? fallback, "", nil) }
        var text = Fillers.clean(r.text.trimmingCharacters(in: .whitespacesAndNewlines))
        var language = forced ?? SpeechTextFilter.resolveLanguage(text, detected: observed,
                                                                   candidates: candidates, fallback: fallback)
        if language == nil, !preview, SpeechTextFilter.isMeaningful(text),
           let retry = SpeechTextFilter.retryLanguage(text, detected: observed, candidates: candidates),
           let retryManager = manager(for: retry) {
            do {
                let retryResult = try await retryManager.transcribeDetailed(audio: samples)
                try Task.checkCancellation()
                let retryText = Fillers.clean(retryResult.text.trimmingCharacters(in: .whitespacesAndNewlines))
                if retryResult.language != "nospeech", SpeechTextFilter.isMeaningful(retryText),
                   SpeechTextFilter.resolveLanguage(retryText, detected: retry,
                                                     candidates: candidates, fallback: fallback) == retry {
                    language = retry
                    text = retryText
                }
            } catch {
                try Task.checkCancellation()
                hearLog("SenseVoice：语种复核失败，保留原识别结果。", .info)
            }
        }
        if language == "zh" {
            text = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        }
        return (language ?? observed ?? fallback, text, observed)
    }

    // MARK: - 模型文件（下载 / 导入 / 删除）

    /// FluidAudio 默认的模型目录：Application Support/FluidAudio/Models/sensevoice-small-coreml
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FluidAudio/Models/sensevoice-small-coreml", isDirectory: true)
    }

    /// 已下载（或已导入）就返回文件夹。
    /// FluidAudio 下载的位置可能和默认目录不完全一样，所以找不到时在它的模型目录里找一遍，找到就记住
    static func installedFolder() -> URL? {
        var candidates: [URL] = []
        if let p = UserDefaults.standard.string(forKey: "senseVoiceFolder") {
            candidates.append(URL(fileURLWithPath: p, isDirectory: true))
        }
        candidates.append(folder)
        for f in candidates where hasModels(f) { return f }
        guard let found = scan() else { return nil }
        UserDefaults.standard.set(found.path, forKey: "senseVoiceFolder")
        // 打印实际位置（找到一次后就记住，不会重复打印）
        hearLog("SenseVoice 模型实际位置：\(found.path)")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: found.path)) ?? []
        hearLog("SenseVoice 模型文件：\(files.sorted().joined(separator: ", "))")
        return found
    }

    private static func hasModels(_ f: URL) -> Bool {
        SenseVoiceModels.modelsExist(at: f, precision: .int8)
            || SenseVoiceModels.modelsExist(at: f, precision: .fp16)
    }

    static func isImportableFolder(_ folder: URL) -> Bool {
        hasModels(folder)
    }

    /// 在 Application Support 和 Caches 里找含有 SenseVoice 模型的文件夹（最多往下 5 层）
    private static func scan() -> URL? {
        let fm = FileManager.default
        let roots = [fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                     fm.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                     fm.urls(for: .documentDirectory, in: .userDomainMask)[0]]
        for root in roots {
            var level = [root]
            for _ in 0..<5 {
                var next: [URL] = []
                for dir in level {
                    guard let subs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
                    for u in subs {
                        guard (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                        let name = u.lastPathComponent.lowercased()
                        if name.hasSuffix(".mlmodelc") || name.hasSuffix(".mlpackage") { continue }
                        if name.contains("sensevoice"), hasModels(u) { return u }
                        next.append(u)
                    }
                }
                level = next
                if level.isEmpty { break }
            }
        }
        return nil
    }

    static func download(host: String, force: Bool = false, progress: @escaping @Sendable (Double) -> Void) async throws {
        ModelRegistry.baseURL = "https://\(host)"
        let files = FileManager.default
        let previous = folder.deletingLastPathComponent()
            .appendingPathComponent(".sensevoice-backup-\(UUID().uuidString)")
        let existing = force && files.fileExists(atPath: folder.path)
        if existing { try files.copyItem(at: folder, to: previous) }
        do {
            _ = try await SenseVoiceModels.download(precision: .int8, force: force) { p in
                progress(p.fractionCompleted * 0.9)
            }
            try Task.checkCancellation()
            guard hasModels(folder) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            progress(0.92)
            do {
                try await LocalSpeakerEmbedder.download(into: folder) { p in
                    progress(0.92 + p * 0.07)
                }
                hearLog("SenseVoice：本机说话人模型已安装")
            } catch {
                // 老版本也可以先只用识别；下次重新下载模型时会再补齐。
                hearLog("SenseVoice：本机说话人模型安装失败：\(error)", .warning)
            }
            UserDefaults.standard.removeObject(forKey: "senseVoiceFolder")
            if existing { try? files.removeItem(at: previous) }
            progress(1)
        } catch {
            if existing { try ModelManager.installModelFile(previous, at: folder) }
            throw error
        }
    }

    static func delete() {
        if let f = installedFolder(), f != folder { try? FileManager.default.removeItem(at: f) }
        UserDefaults.standard.removeObject(forKey: "senseVoiceFolder")
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
