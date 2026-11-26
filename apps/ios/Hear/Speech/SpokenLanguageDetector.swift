import Foundation
import SherpaOnnx
import os

/// 独立的轻量语音语种识别（Spoken Language Identification, LID）：
/// 基于 sherpa-onnx 官方 Whisper-Tiny INT8（支持 99 种语言，含中/英/日/韩/阿/法/德/西/俄/葡/意/泰/越），
/// 专门作为「苹果自带双路听写」的 50~80ms 语种裁判，彻底解决双路听写互抢语种（如把中文判成英文乱码）的问题。
enum SpokenLanguageIDModel {
    static let displayName = "Whisper-Tiny 语种裁判"
    static let archiveRoot = "sherpa-onnx-whisper-tiny"
    static let encoderFile = "tiny-encoder.int8.onnx"
    static let decoderFile = "tiny-decoder.int8.onnx"
    static let requiredFiles: Set<String> = [encoderFile, decoderFile]
    private static let downloadURLs: [URL] = [
        URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.tar.bz2")!,
        URL(string: "https://gh-proxy.com/https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.tar.bz2")!,
    ]

    static var directory: URL {
        ModelManager.documents.appendingPathComponent("WhisperLID", isDirectory: true)
    }

    static var installed: Bool {
        for name in requiredFiles {
            let url = directory.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else {
                return false
            }
        }
        return true
    }

    static func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if installed {
            progress(1)
            return
        }
        let fm = FileManager.default
        let staging = ModelManager.documents.appendingPathComponent(".whisper-lid-\(UUID().uuidString)")
        let model = staging.appendingPathComponent("model")
        try fm.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearWhisperLID", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let archive = cache.appendingPathComponent(archiveRoot + ".tar.bz2")

        var lastError: Error?
        var downloaded = false
        for url in downloadURLs {
            do {
                hearLog("语种裁判：开始下载 Whisper-Tiny LID（约 98 MB）…")
                try await FileDownloader().download(url, to: archive) { progress($0 * 0.85) }
                downloaded = true
                break
            } catch {
                lastError = error
                hearLog("语种裁判下载尝试失败（\(url.host ?? "")）：\(error.localizedDescription)", .warning)
            }
        }
        guard downloaded else {
            throw lastError ?? NSError(domain: "Hear", code: 61, userInfo: [
                NSLocalizedDescriptionKey: "语种裁判模型下载失败",
            ])
        }
        try Task.checkCancellation()
        progress(0.88)
        try ZipVoiceArchive.extract(archive, into: model, root: archiveRoot, modelFiles: requiredFiles)
        for name in requiredFiles {
            let u = model.appendingPathComponent(name)
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v?.isRegularFile == true, (v?.fileSize ?? 0) > 0 else {
                throw NSError(domain: "Hear", code: 62, userInfo: [
                    NSLocalizedDescriptionKey: "语种裁判解压缺少文件：\(name)",
                ])
            }
        }
        try Task.checkCancellation()
        try ModelManager.installModelFile(model, at: directory)
        try? fm.removeItem(at: archive)
        progress(1)
        hearLog("语种裁判：Whisper-Tiny LID 模型安装完成")
    }
}

/// 串行管理 Whisper-Tiny Spoken LID 模型的按需下载、加载与推理（不阻塞主线程与苹果流式听写）。
actor SpokenLanguageDetector {
    private var wrapper: SherpaOnnxSpokenLanguageIdentificationWrapper?
    private var preparing = false
    private var lastFailureAt: Date?

    var isReady: Bool { wrapper != nil }

    func unload() {
        wrapper = nil
    }

    /// 后台静默准备：未安装时自动下载（约 98 MB），已安装时直接加载到内存。
    func ensureReady() async {
        if wrapper != nil || preparing { return }
        if let last = lastFailureAt, Date().timeIntervalSince(last) < 60 { return }
        preparing = true
        defer { preparing = false }
        do {
            if !SpokenLanguageIDModel.installed {
                try await SpokenLanguageIDModel.download()
            }
            try loadIfInstalled()
        } catch {
            lastFailureAt = Date()
            hearLog("语种裁判准备未完成（将自动使用置信度打分）：\(error.localizedDescription)", .warning)
        }
    }

    private func loadIfInstalled() throws {
        guard wrapper == nil, SpokenLanguageIDModel.installed else { return }
        let availMB = os_proc_available_memory() / 1_048_576
        guard availMB >= 220 else {
            hearLog("可用内存偏低（\(availMB) MB），暂不加载语种裁判", .warning)
            return
        }
        let enc = SpokenLanguageIDModel.directory.appendingPathComponent(SpokenLanguageIDModel.encoderFile).path
        let dec = SpokenLanguageIDModel.directory.appendingPathComponent(SpokenLanguageIDModel.decoderFile).path
        let t0 = Date()
        let whisperCfg = sherpaOnnxSpokenLanguageIdentificationWhisperConfig(
            encoder: enc,
            decoder: dec
        )
        var cfg = sherpaOnnxSpokenLanguageIdentificationConfig(
            whisper: whisperCfg,
            numThreads: 2,
            debug: 0,
            provider: "cpu"
        )
        let instance = SherpaOnnxSpokenLanguageIdentificationWrapper(config: &cfg)
        guard instance.slid != nil else {
            throw NSError(domain: "Hear", code: 63, userInfo: [
                NSLocalizedDescriptionKey: "SherpaOnnx 语种裁判初始化失败",
            ])
        }
        wrapper = instance
        hearLog("语种裁判：Whisper-Tiny LID 加载完成，用时 \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    }

    /// 识别一段 16kHz 单声道音频的语种代码：同时返回「命中 candidates 的语种」与「原始识别出的语种」。
    func detectLanguageResult(samples: [Float], candidates: [String]) -> (matched: String?, raw: String?) {
        guard let wrapper else { return (nil, nil) }
        guard samples.count >= 4_800 else { return (nil, nil) } // 至少 0.3 秒
        let audio = samples.count > 96_000 ? Array(samples.prefix(96_000)) : samples
        let result = wrapper.decode(samples: audio, sampleRate: 16_000)
        var code = result.lang.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if code == "yue" { code = "zh" }
        guard !code.isEmpty else { return (nil, nil) }
        return (candidates.contains(code) ? code : nil, code)
    }

    /// 识别一段 16kHz 单声道音频的语种代码（如 "zh"、"en"、"ar"）；仅返回命中 `candidates` 的语种。
    func detectLanguage(samples: [Float], candidates: [String]) -> String? {
        detectLanguageResult(samples: samples, candidates: candidates).matched
    }
}
