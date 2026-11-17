import SwiftUI
import UIKit
import AVFoundation

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
    @Published var partial = ""                 // 说话中的实时识别文字
    @Published var partialTranslation = ""      // 说话中的实时译文（会不断更正）
    @Published var partialSource: Language?     // 实时识别判断出的语言
    @Published var level: Float = 0
    @Published var activity = ""

    // 设置
    @Published var speakOutput: Bool {
        didSet {
            save("speakOutput", speakOutput)
            if speakOutput { readIndex = items.count }   // 重新打开时不补读之前的
            else { stopReading() }
        }
    }
    @Published var useContext: Bool { didSet { save("useContext", useContext) } }
    @Published var sensitivity: Double { didSet { save("sensitivity", sensitivity); pushConfig() } }
    @Published var silenceMs: Double { didSet { save("silenceMs", silenceMs); pushConfig() } }
    @Published var glossary: String { didSet { save("glossary", glossary) } }
    @Published var hfHost: String { didSet { save("hfHost", hfHost) } }

    // 朗读输出：扬声器 / 耳机；耳机时左右耳各播哪种语言（"A" / "B" / "off"）
    @Published var outputMode: AudioOutput { didSet { save("outputMode", outputMode.rawValue) } }
    @Published var leftEar: String { didSet { save("leftEar", leftEar) } }
    @Published var rightEar: String { didSet { save("rightEar", rightEar) } }
    // 音色："system" 系统默认 / "match" 接近说话人（性别 + 音高）
    @Published var voiceStyle: String { didSet { save("voiceStyle", voiceStyle) } }
    // 用我的“个人声音”朗读我说的话；mySide 表示我说的是语言 A 还是 B
    @Published var usePersonalVoice: Bool { didSet { save("usePersonalVoice", usePersonalVoice) } }
    @Published var mySide: String { didSet { save("mySide", mySide) } }
    // 语音识别用 GPU（加载快）还是神经引擎（省电，首次编译慢）
    @Published var asrUseGPU: Bool { didSet { save("asrUseGPU", asrUseGPU) } }
    // 语音增强：系统的降噪 + 回声消除 + 自动增益
    @Published var voiceProcessing: Bool {
        didSet { save("voiceProcessing", voiceProcessing); capture.voiceProcessing = voiceProcessing }
    }

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

    // 朗读队列：readIndex 指向下一句要读的译文
    @Published private(set) var readingID: UUID?
    private var readIndex = 0
    private var readerTask: Task<Void, Never>?
    private var readerGen = 0
    private var oneShot = false
    private var manualSpeaker = false     // 戴着耳机时用户手动切到了扬声器

    // 当前这一页对话（自动保存到历史）
    private(set) var conversationID = UUID()
    private var conversationCreated = Date()

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
        outputMode = AudioOutput(rawValue: d.string(forKey: "outputMode") ?? "") ?? .speaker
        leftEar = d.string(forKey: "leftEar") ?? "A"
        rightEar = d.string(forKey: "rightEar") ?? "B"
        voiceStyle = d.string(forKey: "voiceStyle") ?? "system"
        usePersonalVoice = d.object(forKey: "usePersonalVoice") as? Bool ?? false
        mySide = d.string(forKey: "mySide") ?? "A"
        asrUseGPU = d.object(forKey: "asrUseGPU") as? Bool ?? true
        voiceProcessing = d.object(forKey: "voiceProcessing") as? Bool ?? true
        capture.voiceProcessing = voiceProcessing

        capture.segmenter.onEvent = { [weak self] e in
            Task { @MainActor in self?.handle(e) }
        }
        pushConfig()

        // 插上耳机：自动改为耳机朗读；拔掉：改回扬声器（正在聆听时先暂停朗读）
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            Task { @MainActor in self?.routeChanged(reason) }
        }

        // 来电、Siri 等打断音频时停止
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in
                guard let self else { return }
                hearLog("音频被系统打断（来电等）", .warning)
                self.stopReading()
                if self.isRunning { self.stop() }
            }
        }
    }

    // MARK: - 朗读输出（扬声器 / 耳机）

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .newDeviceAvailable:
            guard outputMode == .speaker else { return }
            // 蓝牙耳机在扬声器模式下不一定看得到，所以再临时取消强制扬声器检查一次
            guard AudioRoute.headphonesLikelyConnected() || AudioRoute.detectHeadphones() else {
                AudioRoute.apply(.speaker); return
            }
            outputMode = .headphones
            manualSpeaker = false
            AudioRoute.apply(.headphones)
            activity = "已连接耳机，改为耳机朗读"
            hearLog("检测到耳机，朗读改为耳机")
            kickReader()
        case .oldDeviceUnavailable:
            manualSpeaker = false
            guard outputMode == .headphones, !AudioRoute.headphonesLikelyConnected() else { return }
            outputMode = .speaker
            AudioRoute.apply(.speaker)
            if isRunning { stopReading() }      // 扬声器 + 聆听中：先不读，停止后从这句接着读
            activity = "耳机已断开，改为扬声器朗读"
            hearLog("耳机已断开，朗读改为扬声器", .warning)
        default:
            break
        }
    }

    /// 长按“朗读”按钮 2 秒：在扬声器和耳机之间切换。没连耳机时不切换。
    func cycleOutput() {
        let haptic = UINotificationFeedbackGenerator()
        if outputMode == .speaker {
            try? AudioRoute.activate()
            guard AudioRoute.detectHeadphones() else {
                AudioRoute.apply(.speaker)
                haptic.notificationOccurred(.warning)
                activity = "未连接耳机"
                hearLog("切换耳机朗读：未检测到耳机", .warning)
                return
            }
            outputMode = .headphones
            manualSpeaker = false
            activity = "改为耳机朗读"
        } else {
            outputMode = .speaker
            manualSpeaker = true
            if isRunning { stopReading() }
            activity = "改为扬声器朗读"
        }
        AudioRoute.apply(outputMode)
        kickReader()
        hearLog("朗读输出切换为\(outputMode == .speaker ? "扬声器" : "耳机")")
        haptic.notificationOccurred(.success)
    }

    func earLabel(_ slot: String) -> String {
        switch slot {
        case "A": return langA.name
        case "B": return langB.name
        default: return "不播放"
        }
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
            hearLog("下载失败：\(error)", .error)
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
                let start = Date()
                let gpu = asrUseGPU
                // 每秒刷新一次：已用时间 + 当前阶段，让用户知道没有卡死
                let ticker = Task { @MainActor in
                    var warned = false
                    while !Task.isCancelled {
                        let secs = Int(Date().timeIntervalSince(start))
                        if secs > 120 && !warned {
                            warned = true
                            hearLog("语音识别模型加载已超过 2 分钟（\(ASRProgress.shared.description)）", .warning)
                        }
                        var msg = "正在加载语音识别模型（\(gpu ? "GPU" : "神经引擎")）\n\(ASRProgress.shared.description) · 已用 \(secs) 秒"
                        if !gpu { msg += "\n神经引擎第一次需要编译，可能要 3–10 分钟" }
                        if secs > 120 { msg += "\n等太久？可以在 设置 → 语音识别 改为 GPU" }
                        if case .loading = phase { phase = .loading(msg) }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
                phase = .loading("正在加载语音识别模型…")
                defer { ticker.cancel() }
                try await asr.load(folder: wf, useGPU: gpu)
            }
            phase = .loading("正在加载翻译模型…")
            let t0 = Date()
            hearLog("翻译模型：开始加载 \(gguf.lastPathComponent)")
            try await translator.load(path: gguf.path)
            hearLog("翻译模型：加载完成，用时 \(Int(Date().timeIntervalSince(t0)))s")
            phase = .ready
            hearLog("全部就绪")
        } catch {
            hearLog("模型加载失败：\(error)", .error)
            phase = .failed("模型加载失败：\(error.localizedDescription)\n可以在 设置 → 运行日志 查看详情。")
        }
    }

    /// 切换语音识别的运行方式后重新加载
    func reloadASR() async {
        if isRunning { stop() }
        await asr.unload()
        await loadModels()
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
        // 已经插着耳机就用耳机朗读（除非用户手动选了扬声器）；耳机已拔掉就改回扬声器
        try? AudioRoute.activate()
        let hasHeadphones = AudioRoute.headphonesLikelyConnected() || AudioRoute.detectHeadphones()
        if outputMode == .speaker, hasHeadphones, !manualSpeaker {
            outputMode = .headphones
            hearLog("检测到耳机，朗读改为耳机")
        }
        if outputMode == .headphones, !hasHeadphones { outputMode = .speaker }
        // 用扬声器时实时翻译优先：立即暂停朗读，停止聆听后从这句接着读
        if outputMode == .speaker { stopReading() }
        do {
            try capture.start()
            AudioRoute.apply(outputMode)
            isRunning = true
            hearLog("开始实时翻译：\(langA.displayName) ⇄ \(langB.displayName)，朗读\(outputMode == .speaker ? "扬声器" : "耳机")")
            activity = "正在聆听"
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            hearLog("麦克风启动失败：\(error)", .error)
            activity = "麦克风启动失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        let wasRunning = isRunning
        if wasRunning { hearLog("停止实时翻译") }
        capture.stop()
        capture.muted = false
        isRunning = false
        level = 0
        activity = ""
        UIApplication.shared.isIdleTimerDisabled = false
        if wasRunning { kickReader() }        // 停止聆听后，从上次没读完的地方接着读
    }

    func swapLanguages() {
        swapping = true
        let a = langA
        langA = langB
        langB = a
        swapping = false
        save("langA", langA.id); save("langB", langB.id)
    }

    func clear() {
        stopReading()
        items.removeAll(); partial = ""; partialTranslation = ""; partialSource = nil
        readIndex = 0
    }

    /// 左上角“清空”：清掉当前屏幕（内容已自动保存在历史里），正在聆听时继续聆听，记到新的一页
    func clearPage() {
        persist()
        clear()
        conversationID = UUID()
        conversationCreated = Date()
        lastLangID = nil
        hearLog("清空当前页")
    }

    // MARK: - 对话保存 / 新建

    /// 把当前页保存到历史（保留已有的总结）
    func persist() {
        let done = items.filter { $0.done }
        guard !done.isEmpty else { return }
        let store = ConversationStore.shared
        var c = store.load(conversationID)
            ?? Conversation(id: conversationID, title: Conversation.defaultTitle(conversationCreated),
                            createdAt: conversationCreated, langA: langA, langB: langB)
        c.items = done
        c.langA = langA
        c.langB = langB
        store.save(c)
    }

    /// 新建一页。summarize = true 时在后台用默认模板总结刚才那一页
    func newConversation(summarize: Bool) {
        if isRunning { stop() }
        persist()
        let oldID = conversationID
        let hadContent = items.contains { $0.done }
        clear()
        conversationID = UUID()
        conversationCreated = Date()
        lastLangID = nil
        hearLog("新建对话\(summarize && hadContent ? "，后台总结上一页" : "")")
        if summarize && hadContent {
            SummaryService.shared.generate(conversationID: oldID, templateID: SummaryTemplate.defaultID)
        }
    }

    // MARK: - 朗读队列
    //
    // 戴耳机：译文出来就从耳机读，边听边读，麦克风不暂停（耳机声音不会被录进去）。
    // 扬声器：聆听中不读；停止实时翻译后，从上次没读完的那句开始往后读；
    //        再点开始实时翻译，立刻停止朗读（实时翻译优先），下次从被打断的那句重新读。
    // 点某一句：从这句开始往后读；之后的自动朗读也从这句往后接着读。

    /// 现在能不能自动朗读
    private var autoReadAllowed: Bool {
        speakOutput && (outputMode == .headphones || !isRunning)
    }

    /// 有新译文或状态变化时调用：能读就从 readIndex 开始往后读
    private func kickReader() {
        guard readerTask == nil, autoReadAllowed, readIndex < items.count else { return }
        startReader(oneShot: false)
    }

    private func startReader(oneShot single: Bool) {
        readerTask?.cancel()
        readerGen += 1
        let g = readerGen
        oneShot = single
        readerTask = Task { [weak self] in await self?.readLoop(g) }
    }

    private func readLoop(_ g: Int) async {
        defer {
            if g == readerGen { readerTask = nil; readingID = nil }
        }
        while !Task.isCancelled, g == readerGen, readIndex < items.count {
            let item = items[readIndex]
            guard item.done else { break }                  // 还在翻译，翻译完会再叫醒
            if !oneShot && !autoReadAllowed { break }
            let usable = !item.translated.isEmpty && !item.translated.hasPrefix("（翻译失败")
            if usable {
                readingID = item.id
                await speak(item)
                if Task.isCancelled || g != readerGen { return }   // 被打断：这句下次从头读
            }
            readIndex += 1
            if oneShot { break }
        }
    }

    /// 停止朗读。readIndex 不动，下次从被打断的这句开始读
    func stopReading() {
        readerGen += 1
        readerTask?.cancel()
        readerTask = nil
        readingID = nil
        speaker.stop()
        capture.muted = false
    }

    /// 点某一句：从这句开始往后读；正在读这句时再点一下就停止
    func tapRead(_ item: TranslationItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { replay(item); return }
        if readingID == item.id { stopReading(); return }
        stopReading()
        readIndex = i
        // 能连续读（戴耳机，或已停止聆听）就一直往后读；否则只读这一句
        startReader(oneShot: !autoReadAllowed)
    }

    /// 只读一句，不影响朗读进度（历史记录里用）
    func replay(_ item: TranslationItem) {
        stopReading()
        readerGen += 1
        let g = readerGen
        readerTask = Task { [weak self] in
            guard let self else { return }
            self.readingID = item.id
            await self.speak(item)
            if g == self.readerGen { self.readerTask = nil; self.readingID = nil }
        }
    }

    // MARK: - 流水线

    private func handle(_ e: Segmenter.Event) {
        switch e {
        case .level(let l):
            level = l
        case .started(let id):
            currentSeg = id
            if partial.isEmpty { partial = "…" }
            hearLog("断句：检测到说话（第 \(id) 句）")
        case .partial(let id, let samples):
            // 说话过程中：识别到目前为止的内容并马上翻译，后面的内容会更正前面的
            guard !working, !partialBusy else { return }
            partialBusy = true
            Task { await livePreview(id: id, samples: samples) }
        case .ended(let id, let samples):
            finishedSeg = id
            hearLog("断句：一句话结束，时长 \(String(format: "%.1f", Double(samples.count) / 16000)) 秒")
            queue.append(samples)
            if !working { Task { await drain() } }
        case .discarded(let id):
            finishedSeg = max(finishedSeg, id)
            if !working && queue.isEmpty { partial = ""; partialTranslation = ""; partialSource = nil }
        case .noise(let n, let t):
            if isRunning { hearLog(String(format: "环境噪声 %.0f dB，说话触发阈值 %.0f dB", n, t)) }
        }
    }

    /// 实时预览：识别 + 翻译当前这句话说到目前为止的内容
    private func livePreview(id: Int, samples: [Float]) async {
        defer { partialBusy = false }
        let a = langA, b = langB
        let fallback = (lastLangID == b.id) ? b.id : a.id
        let t0 = Date()
        let r: (String, String)
        do {
            r = try await asr.recognize(samples, candidates: [a.id, b.id], fallback: fallback, preview: true)
        } catch {
            hearLog("实时识别失败：\(error)", .error)
            return
        }
        hearLog("实时识别 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s：\(r.1.prefix(30))")
        guard id == currentSeg, id > finishedSeg, SpeechRecognizer.isMeaningful(r.1) else { return }
        let src = (r.0 == b.id) ? b : a
        let tgt = (src == a) ? b : a
        partialSource = src
        partial = r.1

        let prompt = PromptBuilder.build(text: r.1, from: src, to: tgt, context: [],
                                         glossary: PromptBuilder.parseGlossary(glossary))
        let out = try? await translator.translate(prompt: prompt, maxNewTokens: 256) { p in
            Task { @MainActor in
                if id == self.currentSeg, id > self.finishedSeg { self.partialTranslation = p }
            }
        }
        if let out, !out.isEmpty, id == currentSeg, id > finishedSeg { partialTranslation = out }
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
        let t0 = Date()
        do {
            let r = try await asr.recognize(samples, candidates: [a.id, b.id], fallback: fallback)
            detected = r.0
            text = r.1
            hearLog("整句识别 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s：\(text.prefix(40))")
        } catch {
            hearLog("识别失败：\(error)", .error)
            activity = "识别失败"; partial = ""; return
        }
        let src = (detected == b.id) ? b : a
        let tgt = (src == a) ? b : a
        lastLangID = src.id

        guard SpeechRecognizer.isMeaningful(text) else {
            partial = ""; partialTranslation = ""; partialSource = nil
            activity = isRunning ? "正在聆听" : ""
            return
        }

        var item = TranslationItem(source: src, target: tgt, sourceText: text)
        if voiceStyle == "match" {
            item.speakerF0 = await Task.detached(priority: .utility) {
                VoiceAnalyzer.estimateF0(samples)
            }.value
        }
        // 先把实时预览的译文放进去，最终译文出来后再替换，避免闪烁
        let preview = partialTranslation
        item.translated = preview
        partial = ""; partialTranslation = ""; partialSource = nil
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
                // 有预览译文时，等最终结果完整再替换；没有预览时边生成边显示
                guard preview.isEmpty else { return }
                Task { @MainActor in self.update(id, partialText, done: false) }
            }
        } catch {
            hearLog("翻译失败：\(error)", .error)
            update(id, "（翻译失败：\(error.localizedDescription)）", done: true)
            kickReader()
            return
        }
        update(id, result, done: true)
        persist()
        activity = isRunning ? "正在聆听" : ""
        // 朗读在单独的队列里进行，不会挡住后面的识别和翻译
        kickReader()
    }

    /// 朗读一条译文：决定左右耳、声音和音高
    private func speak(_ item: TranslationItem) async {
        let text = item.translated
        guard !text.isEmpty, !text.hasPrefix("（翻译失败") else { return }

        // 译文是 A 语言还是 B 语言
        let slot = item.target == langA ? "A" : (item.target == langB ? "B" : "?")
        var pan: Float = 0
        if outputMode == .headphones, slot != "?" {
            let l = leftEar == slot, r = rightEar == slot
            if !l && !r { return }                       // 两耳都不播这种语言
            pan = (l && r) ? 0 : (l ? -1 : 1)
        }

        // 音色
        var voice: AVSpeechSynthesisVoice?
        var pitch: Float = 1
        let fromSlot = item.source == langA ? "A" : "B"
        if usePersonalVoice, fromSlot == mySide, let pv = Speaker.personalVoice(for: item.target.tts) {
            voice = pv
        } else if voiceStyle == "match", let f0 = item.speakerF0 {
            let male = f0 < 165
            voice = Speaker.bestVoice(for: item.target.tts, gender: male ? .male : .female)
            let base: Float = male ? 120 : 210
            pitch = min(1.4, max(0.75, f0 / base))
        }

        AudioRoute.apply(outputMode)
        // 聆听中用扬声器读（只有点句子时才会）：暂停麦克风，避免把喇叭声音再识别一遍
        let mute = outputMode == .speaker && isRunning
        hearLog("朗读：\(item.target.displayName)，\(outputMode == .speaker ? "扬声器" : (pan < 0 ? "左耳" : (pan > 0 ? "右耳" : "双耳")))，声音 \(voice?.name ?? "默认")")
        activity = "朗读中…"
        if mute { capture.muted = true }
        await speaker.speak(SpeakRequest(text: text, locale: item.target.tts,
                                         voice: voice, pitch: pitch, pan: pan))
        if mute {
            try? await Task.sleep(nanoseconds: 300_000_000)
            capture.muted = false
        }
        if activity == "朗读中…" { activity = isRunning ? "正在聆听" : "" }
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
