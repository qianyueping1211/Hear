import SwiftUI
import UIKit

/// 整个实时翻译流程的调度中心：
/// 麦克风 → 断句 → 判断语种 → 识别 → 翻译（流式显示）→ 朗读
@MainActor
final class LiveSession: ObservableObject {
    enum Phase: Equatable {
        case checking
        case needsModels
        case downloading(String, Double)
        case loading(String)
        case ready
        case failed(String)
    }

    // 语言
    @Published var langA: Language { didSet { languageChanged(old: oldValue, isA: true) } }
    @Published var langB: Language { didSet { languageChanged(old: oldValue, isA: false) } }

    // 状态
    @Published var phase: Phase = .checking
    @Published var isRunning = false
    @Published var items: [TranslationItem] = []
    @Published var partial = ""
    @Published var level: Float = 0
    @Published var activity = ""

    // 设置
    @Published var speakOutput: Bool { didSet { save("speakOutput", speakOutput) } }
    @Published var useContext: Bool { didSet { save("useContext", useContext) } }
    @Published var sensitivity: Double { didSet { save("sensitivity", sensitivity); pushConfig() } }
    @Published var silenceMs: Double { didSet { save("silenceMs", silenceMs); pushConfig() } }
    @Published var glossary: String { didSet { save("glossary", glossary) } }
    @Published var hfHost: String { didSet { save("hfHost", hfHost) } }

    private let capture = AudioCapture()
    private let asr = SpeechRecognizer()
    private let translator = LlamaTranslator()
    private let speaker = Speaker()

    private var queue: [[Float]] = []
    private var working = false
    private var partialBusy = false
    private var currentSeg = 0
    private var finishedSeg = 0
    private var lastLangID: String?
    private var swapping = false

    init() {
        let d = UserDefaults.standard
        langA = Language.find(d.string(forKey: "langA") ?? "zh")
        langB = Language.find(d.string(forKey: "langB") ?? "en")
        speakOutput = d.object(forKey: "speakOutput") as? Bool ?? true
        useContext = d.object(forKey: "useContext") as? Bool ?? true
        sensitivity = d.object(forKey: "sensitivity") as? Double ?? 12
        silenceMs = d.object(forKey: "silenceMs") as? Double ?? 700
        glossary = d.string(forKey: "glossary") ?? ""
        hfHost = d.string(forKey: "hfHost") ?? "huggingface.co"

        capture.segmenter.onEvent = { [weak self] e in
            Task { @MainActor in self?.handle(e) }
        }
        pushConfig()
    }

    // MARK: - 模型状态（设置页显示）

    enum ModelKind { case translation, speech }

    struct ModelStatus {
        let name: String
        let detail: String
        let installed: Bool
    }

    /// 模型文件变动后加一，让设置页刷新
    @Published private(set) var modelsRevision = 0

    var translationStatus: ModelStatus {
        _ = modelsRevision
        if let u = ModelManager.currentGGUF() {
            return .init(name: u.lastPathComponent,
                         detail: ModelManager.format(ModelManager.fileSize(u)), installed: true)
        }
        return .init(name: "Hy-MT2-1.8B", detail: "未下载", installed: false)
    }

    var speechStatus: ModelStatus {
        _ = modelsRevision
        if let f = ModelManager.whisperFolder() {
            return .init(name: "Whisper large-v3 turbo",
                         detail: ModelManager.format(ModelManager.folderSize(f)), installed: true)
        }
        return .init(name: "Whisper large-v3 turbo", detail: "未下载", installed: false)
    }

    var installedGGUFs: [URL] {
        _ = modelsRevision
        return ModelManager.installedGGUFs()
    }

    var isBusyWithModels: Bool {
        switch phase {
        case .downloading, .loading, .checking: return true
        default: return false
        }
    }

    func selectGGUF(_ url: URL) async {
        if isRunning { stop() }
        ModelManager.select(url)
        await translator.unload()
        modelsRevision += 1
        await loadModels()
    }

    /// 删除某个模型并重新下载
    func redownload(_ kind: ModelKind) async {
        if isRunning { stop() }
        switch kind {
        case .translation:
            await translator.unload()
            ModelManager.deleteCurrentGGUF()
        case .speech:
            await asr.unload()
            ModelManager.deleteWhisper()
        }
        modelsRevision += 1
        await downloadModels(forceTranslation: kind == .translation)
        modelsRevision += 1
    }

    // MARK: - 模型

    func bootstrap() async {
        guard phase == .checking || phase == .needsModels || phaseIsFailed else { return }
        if ModelManager.currentGGUF() != nil, ModelManager.whisperFolder() != nil {
            await loadModels()
        } else {
            phase = .needsModels
        }
    }

    private var phaseIsFailed: Bool { if case .failed = phase { return true }; return false }

    func downloadModels(forceTranslation: Bool = false) async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = isRunning }
        let host = hfHost
        do {
            if forceTranslation || ModelManager.currentGGUF() == nil {
                phase = .downloading("翻译模型 Hy-MT2", 0)
                _ = try await ModelManager.downloadGGUF(host: host) { p in
                    Task { @MainActor in self.setProgress("翻译模型 Hy-MT2", p) }
                }
            }
            if ModelManager.whisperFolder() == nil {
                phase = .downloading("语音识别模型 Whisper", 0)
                _ = try await ModelManager.downloadWhisper(host: host) { p in
                    Task { @MainActor in self.setProgress("语音识别模型 Whisper", p) }
                }
            }
            await loadModels()
        } catch {
            phase = .failed("下载失败：\(error.localizedDescription)\n可以在设置里换下载源后重试。")
        }
    }

    /// 只在仍处于同一个下载阶段时更新进度，避免迟到的回调覆盖后续状态
    private func setProgress(_ name: String, _ p: Double) {
        if case .downloading(let n, _) = phase, n == name { phase = .downloading(name, p) }
    }

    func loadModels() async {
        guard let gguf = ModelManager.currentGGUF(), let wf = ModelManager.whisperFolder() else {
            phase = .needsModels; return
        }
        do {
            if !(await asr.isLoaded) {
                phase = .loading("正在加载语音识别模型…\n第一次需要编译，约 1–3 分钟，请保持在前台")
                try await asr.load(folder: wf)
            }
            phase = .loading("正在加载翻译模型…")
            try await translator.load(path: gguf.path)
            phase = .ready
        } catch {
            phase = .failed("模型加载失败：\(error.localizedDescription)")
        }
    }

    func importModel(_ url: URL) async {
        do {
            if isRunning { stop() }
            _ = try ModelManager.importGGUF(from: url)
            await translator.unload()
            modelsRevision += 1
            await loadModels()
        } catch {
            phase = .failed("导入失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 开始 / 停止

    func toggle() async {
        if isRunning { stop(); return }
        guard phase == .ready else { return }
        guard await AudioCapture.requestPermission() else {
            activity = "请在 设置 → 听见 里允许使用麦克风"
            return
        }
        do {
            try capture.start()
            isRunning = true
            activity = "正在聆听"
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            activity = "麦克风启动失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        capture.stop()
        speaker.stop()
        capture.muted = false
        isRunning = false
        level = 0
        activity = ""
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func swapLanguages() {
        swapping = true
        let a = langA
        langA = langB
        langB = a
        swapping = false
        save("langA", langA.id); save("langB", langB.id)
    }

    func clear() { items.removeAll(); partial = "" }

    func replay(_ item: TranslationItem) {
        Task { await speakTranslation(item.translated, locale: item.target.tts) }
    }

    // MARK: - 流水线

    private func handle(_ e: Segmenter.Event) {
        switch e {
        case .level(let l):
            level = l
        case .started(let id):
            currentSeg = id
            if partial.isEmpty { partial = "…" }
        case .partial(let id, let samples):
            guard !working, !partialBusy else { return }
            partialBusy = true
            let lang = lastLangID
            Task {
                let t = (try? await asr.transcribe(samples, language: lang)) ?? ""
                if id == currentSeg, id > finishedSeg, SpeechRecognizer.isMeaningful(t) { partial = t }
                partialBusy = false
            }
        case .ended(let id, let samples):
            finishedSeg = id
            queue.append(samples)
            if !working { Task { await drain() } }
        }
    }

    private func drain() async {
        working = true
        while !queue.isEmpty {
            let s = queue.removeFirst()
            await process(s)
        }
        working = false
    }

    private func process(_ samples: [Float]) async {
        let a = langA, b = langB
        activity = "识别中…"
        let fallback = (lastLangID == b.id) ? b.id : a.id
        let detected: String
        let text: String
        do {
            let r = try await asr.recognize(samples, candidates: [a.id, b.id], fallback: fallback)
            detected = r.0
            text = r.1
        } catch {
            activity = "识别失败"; partial = ""; return
        }
        let src = (detected == b.id) ? b : a
        let tgt = (src == a) ? b : a
        lastLangID = src.id

        guard SpeechRecognizer.isMeaningful(text) else {
            partial = ""
            activity = isRunning ? "正在聆听" : ""
            return
        }

        let item = TranslationItem(source: src, target: tgt, sourceText: text)
        partial = ""
        items.append(item)
        let id = item.id

        let context = useContext
            ? items.dropLast().suffix(2).map(\.sourceText)
            : []
        let prompt = PromptBuilder.build(text: text, from: src, to: tgt,
                                         context: Array(context),
                                         glossary: PromptBuilder.parseGlossary(glossary))
        activity = "翻译中…"
        let result: String
        do {
            result = try await translator.translate(prompt: prompt) { partialText in
                Task { @MainActor in self.update(id, partialText, done: false) }
            }
        } catch {
            update(id, "（翻译失败：\(error.localizedDescription)）", done: true)
            return
        }
        update(id, result, done: true)

        if speakOutput, !result.isEmpty, isRunning {
            await speakTranslation(result, locale: tgt.tts)
        }
        activity = isRunning ? "正在聆听" : ""
    }

    private func speakTranslation(_ text: String, locale: String) async {
        activity = "朗读中…"
        capture.muted = true
        await speaker.speak(text, locale: locale)
        try? await Task.sleep(nanoseconds: 300_000_000)
        capture.muted = false
    }

    private func update(_ id: UUID, _ text: String, done: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].done && !done { return }
        items[i].translated = text
        items[i].done = done
    }

    // MARK: - 设置

    private func languageChanged(old: Language, isA: Bool) {
        guard !swapping else { return }
        if langA == langB {               // 两边选成一样时自动对调
            swapping = true
            if isA { langB = old } else { langA = old }
            swapping = false
        }
        save("langA", langA.id); save("langB", langB.id)
        lastLangID = nil
    }

    private func pushConfig() {
        var c = Segmenter.Config()
        c.sensitivityDB = Float(sensitivity)
        c.silenceMs = Int(silenceMs)
        capture.updateConfig(c)
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
