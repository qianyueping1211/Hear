import SwiftUI
import UIKit
import AVFoundation
import Translation

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
    /// 音量（每秒变化很多次）单独放一个对象，只有麦克风按钮跟着刷新，整页和弹出的页面不会跟着闪
    let meter = LevelMeter()
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
    // 识别引擎："whisper"（默认）/ "apple"（iOS 系统听写：说话时逐字显示，说完再由 Whisper 校正）
    @Published var asrEngine: String {
        didSet {
            save("asrEngine", asrEngine)
            guard asrEngine != oldValue, isRunning else { return }
            if asrEngine == "apple" { startLiveEngine() } else { stopLiveEngine() }
        }
    }
    // 引擎："local" 听见本地模型（Whisper + Hy-MT2）/ "apple" 苹果自带（系统听写 + 系统翻译）/ "" 还没选
    @Published private(set) var engineMode: String { didSet { save("engineMode", engineMode) } }
    // 后台下载本地模型（苹果自带模式下进行，设置里显示进度）
    @Published private(set) var bgDownloading = false
    @Published private(set) var bgDownloadName = ""
    @Published private(set) var bgDownloadProgress: Double = 0
    @Published private(set) var bgDownloadError: String?
    @Published private(set) var bgDownloadKind: ModelKind?
    @Published private(set) var bgDownloadAll = false       // true：这次下载所有缺少的模型（另一个会排队）
    private var bgSwitchWhenDone = true
    // 让系统弹出苹果翻译语言包下载（ContentView 的 translationTask 使用）
    @Published var translationPrepConfig: TranslationSession.Configuration?
    @Published private(set) var appleNote: String?
    private var pendingLocalSwitch = false

    var appleAvailable: Bool { LiveTextEngineFactory.isSupported }
    var usingApple: Bool { engineMode == "apple" && appleAvailable }
    var modelsInstalled: Bool {
        _ = modelsRevision
        return ModelManager.currentGGUF() != nil && ModelManager.whisperFolder() != nil
    }

    // 声音来源："phone" 手机麦克风（默认）/ "headset" 耳机麦克风（只在连着耳机时可选）
    @Published var inputSource: String {
        didSet {
            save("inputSource", inputSource)
            guard inputSource != oldValue else { return }
            applyInputSource()
        }
    }
    @Published private(set) var headsetConnected = false
    // 语音增强：系统的降噪 + 回声消除 + 自动增益
    @Published var voiceProcessing: Bool {
        didSet { save("voiceProcessing", voiceProcessing); capture.voiceProcessing = voiceProcessing }
    }

    private let capture = AudioCapture()
    private let asr = SpeechRecognizer()
    private let translator = LlamaTranslator()
    private let speaker = Speaker()
    private let systemTranslator = SystemTranslator()
    private var appleEngines: [LiveTextEngine] = []   // 苹果自带模式：每种语言一个系统听写

    private var queue: [(itemID: UUID, segID: Int, samples: [Float])] = []
    private var runGen = 0                // 每次停止 +1：停止前排队/进行中的识别和翻译全部作废
    private var working = false
    private var currentSeg = 0
    private var partialSeg = 0            // 实时气泡（partial）属于第几句
    // 实时预览分两条线：识别只管出原文，翻译只拿最新的原文去翻，互不等待
    private var previewSamples: (id: Int, samples: [Float])?
    private var asrPreviewBusy = false
    private var mtPending: (id: Int, text: String, src: Language, tgt: Language)?
    private var mtPreviewBusy = false
    // iOS 系统听写（逐字显示原文）
    private var live: LiveTextEngine?
    private var liveActive = false
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
        asrEngine = d.string(forKey: "asrEngine") ?? "whisper"
        engineMode = d.string(forKey: "engineMode") ?? ""
        voiceProcessing = d.object(forKey: "voiceProcessing") as? Bool ?? true
        inputSource = d.string(forKey: "inputSource") ?? "phone"
        capture.voiceProcessing = voiceProcessing
        AudioRoute.useHeadsetMic = inputSource == "headset"

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
                if self.isRunning { self.stop(readAfter: false) }
            }
        }
    }

    // MARK: - 朗读输出（扬声器 / 耳机）

    /// 刷新“是否连着耳机”（设置页用来决定能不能选耳机麦克风）
    func refreshHeadset() {
        headsetConnected = outputMode == .headphones || AudioRoute.headphonesLikelyConnected()
    }

    /// 切换声音来源；正在聆听时马上重新接麦克风
    private func applyInputSource() {
        AudioRoute.useHeadsetMic = inputSource == "headset"
        hearLog("声音来源切换为\(inputSource == "headset" ? "耳机麦克风" : "手机麦克风")")
        guard isRunning else { return }
        capture.stop()
        do {
            try capture.start()
            AudioRoute.apply(outputMode)
        } catch {
            hearLog("切换声音来源后麦克风启动失败：\(error)", .error)
        }
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason) {
        if reason == .newDeviceAvailable { headsetConnected = true }
        if reason == .oldDeviceUnavailable {
            refreshHeadset()
            // 耳机断开（关蓝牙、拿下耳机）：声音来源自动改回手机
            if inputSource == "headset", !AudioRoute.headphonesLikelyConnected() {
                headsetConnected = false
                inputSource = "phone"
                activity = "耳机已断开，改用手机麦克风"
                hearLog("耳机已断开，声音来源改回手机麦克风", .warning)
            }
        }
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
            return .init(name: f.lastPathComponent,
                         detail: ModelManager.format(ModelManager.folderSize(f)), installed: true)
        }
        return .init(name: "Whisper large-v3 turbo", detail: "未下载", installed: false)
    }

    var installedGGUFs: [URL] {
        _ = modelsRevision
        return ModelManager.installedGGUFs()
    }

    var isBusyWithModels: Bool {
        if bgDownloading { return true }
        switch phase {
        case .downloading, .loading, .checking: return true
        default: return false
        }
    }

    func selectGGUF(_ url: URL) async {
        if isRunning && !usingApple { stop(readAfter: false) }
        ModelManager.select(url)
        await translator.unload()
        modelsRevision += 1
        await reloadIfLocal()
    }

    /// 设置 → 下载与导入：下载（或删除后重新下载）某个模型，进度显示在设置里
    func redownload(_ kind: ModelKind) async {
        guard !bgDownloading else { return }
        let installed = kind == .translation ? ModelManager.currentGGUF() != nil : ModelManager.whisperFolder() != nil
        if installed {
            if isRunning && !usingApple { stop(readAfter: false) }
            switch kind {
            case .translation:
                await translator.unload()
                ModelManager.deleteCurrentGGUF()
            case .speech:
                await asr.unload()
                ModelManager.deleteWhisper()
            }
            modelsRevision += 1
            if !usingApple { phase = .loading("正在重新下载模型，完成后自动加载") }
        }
        startBackgroundDownload(only: kind, switchWhenDone: false)
    }

    // MARK: - 模型

    func bootstrap() async {
        guard phase == .checking || phase == .needsModels || phaseIsFailed else { return }
        let installed = modelsInstalled
        if engineMode.isEmpty && installed { engineMode = "local" }   // 已经下载过模型的老用户
        if usingApple {
            phase = .ready
            prepareAppleTranslation()
            return
        }
        if installed {
            engineMode = "local"
            await loadModels()
        } else {
            phase = .needsModels                  // 首次使用：让用户选择下载还是先用苹果自带
        }
    }

    // MARK: - 引擎选择

    /// 用苹果自带的系统听写 + 系统翻译（不用下载模型）
    func chooseApple() {
        guard appleAvailable else { return }
        if isRunning { stop(readAfter: false) }
        stopLiveEngine()
        engineMode = "apple"
        phase = .ready
        hearLog("引擎：苹果自带")
        prepareAppleTranslation()
    }

    /// 首次使用选择“下载”：能用苹果自带时先用它，后台下载完再自动切换
    func chooseLocalAndDownload() async {
        if appleAvailable {
            chooseApple()
            startBackgroundDownload()
        } else {
            engineMode = "local"
            await downloadModels()
        }
    }

    /// 切换到听见本地模型（模型已下载）
    func switchToLocal() async {
        if isRunning { stop(readAfter: false) }
        stopAppleASR()
        engineMode = "local"
        hearLog("引擎：听见本地模型")
        if modelsInstalled { await loadModels() } else { phase = .needsModels }
    }

    /// 后台下载本地模型：期间继续用苹果自带，设置里显示进度，下载完自动切换
    func startBackgroundDownload(only: ModelKind? = nil, switchWhenDone: Bool = true) {
        guard !bgDownloading else { return }
        bgDownloading = true
        bgDownloadError = nil
        bgDownloadProgress = 0
        bgSwitchWhenDone = switchWhenDone
        bgDownloadAll = only == nil
        let host = hfHost
        hearLog("后台下载本地模型")
        Task {
            UIApplication.shared.isIdleTimerDisabled = true
            var ok = false
            do {
                if only != .speech, ModelManager.currentGGUF() == nil {
                    bgDownloadKind = .translation
                    bgDownloadName = "翻译模型 Hy-MT2"
                    bgDownloadProgress = 0
                    _ = try await ModelManager.downloadGGUF(host: host) { p in
                        Task { @MainActor in self.bgDownloadProgress = p }
                    }
                    bgDownloadKind = nil              // 下载完立刻收起进度条
                    modelsRevision += 1
                }
                if only != .translation, ModelManager.whisperFolder() == nil {
                    bgDownloadKind = .speech
                    bgDownloadName = "语音识别模型 Whisper"
                    bgDownloadProgress = 0
                    _ = try await ModelManager.downloadWhisper(host: host) { p in
                        Task { @MainActor in self.bgDownloadProgress = p }
                    }
                    bgDownloadKind = nil
                    modelsRevision += 1
                }
                ok = true
            } catch {
                hearLog("后台下载失败：\(error)", .error)
                bgDownloadError = "下载失败：\(error.localizedDescription)"
            }
            // 先结束“下载中”的显示，再去切换或加载模型（加载要好几秒，不用一直挂着 100%）
            bgDownloading = false
            bgDownloadKind = nil
            UIApplication.shared.isIdleTimerDisabled = isRunning
            guard ok, modelsInstalled else {
                if !usingApple, case .loading = phase { phase = .needsModels }
                return
            }
            hearLog("模型下载完成")
            // 正在用本地模型（或刚重新下载）：直接加载；苹果自带：只有选择了切换才切过去
            guard !usingApple || bgSwitchWhenDone else { return }
            if isRunning {
                pendingLocalSwitch = true     // 正在对话：停止实时翻译后再切换
                activity = "本地模型已下载，停止实时翻译后切换"
            } else {
                await switchToLocal()
            }
        }
    }

    /// 检查苹果翻译的语言包；没下载就让系统弹出下载
    func prepareAppleTranslation() {
        guard usingApple else { return }
        let a = langA, b = langB
        systemTranslator.reset()
        Task {
            switch await SystemTranslator.availability(a, b) {
            case .installed:
                appleNote = nil
            case .needsDownload:
                appleNote = "需要下载苹果翻译的 \(a.name)、\(b.name) 语言包"
                translationPrepConfig = TranslationSession.Configuration(source: a.appleLanguage,
                                                                         target: b.appleLanguage)
            case .unsupported:
                appleNote = "苹果翻译暂不支持 \(a.name) ⇄ \(b.name)，可以在设置里改用听见本地模型"
                hearLog(appleNote ?? "", .warning)
            }
        }
    }

    /// 系统语言包下载完成（或用户关掉了下载窗口）
    func appleTranslationPrepared(_ ok: Bool) {
        if ok { appleNote = nil }
        systemTranslator.reset()
        hearLog(ok ? "苹果翻译语言包已就绪" : "苹果翻译语言包没有下载", ok ? .info : .warning)
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
        let start = Date()
        let gpu = asrUseGPU
        let needASR = !(await asr.isLoaded)
        let needMT = !(await translator.isLoaded)
        if !needASR && !needMT { phase = .ready; return }
        // 每秒刷新一次已用时间，让用户知道没有卡死
        let ticker = Task { @MainActor in
            var warned = false
            while !Task.isCancelled {
                let secs = Int(Date().timeIntervalSince(start))
                if secs > 120 && !warned {
                    warned = true
                    hearLog("模型加载已超过 2 分钟（\(ASRProgress.shared.description)）", .warning)
                }
                var msg = "正在准备模型 · \(secs) 秒"
                if needASR && !gpu && secs > 20 { msg += " · 神经引擎第一次要编译，可能要几分钟" }
                if case .loading = phase { phase = .loading(msg) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { ticker.cancel() }
        phase = .loading("正在准备模型…")
        do {
            // 语音识别和翻译模型同时加载，缩短等待
            async let asrDone: Void = loadASRIfNeeded(needASR, folder: wf, gpu: gpu)
            async let mtDone: Void = loadMTIfNeeded(needMT, path: gguf.path)
            try await asrDone
            try await mtDone
            phase = .ready
            hearLog("全部就绪，用时 \(Int(Date().timeIntervalSince(start)))s")
        } catch {
            hearLog("模型加载失败：\(error)", .error)
            if isRunning { stop(readAfter: false) }
            phase = .failed("模型加载失败：\(error.localizedDescription)\n可以在 设置 → 运行日志 查看详情。")
        }
    }

    private nonisolated func loadASRIfNeeded(_ need: Bool, folder: URL, gpu: Bool) async throws {
        guard need else { return }
        try await asr.load(folder: folder, useGPU: gpu)
    }

    private nonisolated func loadMTIfNeeded(_ need: Bool, path: String) async throws {
        guard need else { return }
        let t0 = Date()
        hearLog("翻译模型：开始加载 \((path as NSString).lastPathComponent)")
        try await translator.load(path: path)
        hearLog("翻译模型：加载完成，用时 \(Int(Date().timeIntervalSince(t0)))s")
    }

    /// 切换语音识别的运行方式后重新加载
    func reloadASR() async {
        if isRunning && !usingApple { stop(readAfter: false) }
        await asr.unload()
        await reloadIfLocal()
    }

    /// 设置 → 导入翻译模型（.gguf 文件）。苹果自带模式下只放进“已下载的模型”，不切换、不加载
    func importModel(_ url: URL) async {
        do {
            if isRunning && !usingApple { stop(readAfter: false) }
            await translator.unload()
            _ = try ModelManager.importGGUF(from: url)
            modelsRevision += 1
            bgDownloadError = nil
            hearLog("已导入翻译模型：\(url.lastPathComponent)")
            await reloadIfLocal()
        } catch {
            hearLog("导入翻译模型失败：\(error)", .error)
            bgDownloadError = "导入失败：\(error.localizedDescription)"
        }
    }

    /// 设置 → 导入语音识别模型（WhisperKit 模型文件夹）
    func importWhisper(_ url: URL) async {
        do {
            if isRunning && !usingApple { stop(readAfter: false) }
            await asr.unload()
            try ModelManager.importWhisper(from: url)
            modelsRevision += 1
            bgDownloadError = nil
            hearLog("已导入语音识别模型：\(url.lastPathComponent)")
            await reloadIfLocal()
        } catch {
            hearLog("导入语音识别模型失败：\(error)", .error)
            bgDownloadError = "导入失败：\(error.localizedDescription)"
        }
    }

    /// 正在用本地模型时，模型变了就重新加载；苹果自带模式下什么都不做
    private func reloadIfLocal() async {
        guard !usingApple, engineMode == "local", modelsInstalled else { return }
        await loadModels()
    }

    // MARK: - 开始 / 停止

    func toggle() async {
        if isRunning { stop(); return }
        // 模型还在加载时也可以先开始收音：说的话先排队，加载好马上识别
        guard phase == .ready || isLoadingPhase else { return }
        guard await AudioCapture.requestPermission() else {
            activity = "请在 设置 → 听见 里允许使用麦克风"
            return
        }
        // 已经插着耳机就用耳机朗读（除非用户手动选了扬声器）；耳机已拔掉就改回扬声器
        // 注意：这里不强制改输出路由，避免开始聆听时麦克风被重新配置
        try? AudioRoute.activate()
        let hasHeadphones = AudioRoute.headphonesLikelyConnected()
        if outputMode == .speaker, hasHeadphones, !manualSpeaker {
            outputMode = .headphones
            hearLog("检测到耳机，朗读改为耳机")
        }
        if outputMode == .headphones, !hasHeadphones { outputMode = .speaker }
        headsetConnected = hasHeadphones
        if inputSource == "headset", !hasHeadphones { inputSource = "phone" }   // 没耳机就用手机麦克风
        // 扬声器模式：聆听期间完全不播放、不改输出路由，停止后再从没读的那句开始读
        if outputMode == .speaker { stopReading() }
        do {
            try capture.start()
            if outputMode == .headphones { AudioRoute.apply(.headphones) }
            isRunning = true
            if usingApple {
                startAppleASR()
            } else if asrEngine == "apple" {
                startLiveEngine()
            }
            hearLog("开始实时翻译：\(langA.displayName) ⇄ \(langB.displayName)，朗读\(outputMode == .speaker ? "扬声器" : "耳机")")
            activity = "正在聆听"
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            hearLog("麦克风启动失败：\(error)", .error)
            activity = "麦克风启动失败：\(error.localizedDescription)"
        }
    }

    /// readAfter：停止后是否接着朗读没读的句子（只有用户自己点停止时才读）
    func stop(readAfter: Bool = true) {
        let wasRunning = isRunning
        if wasRunning { hearLog("停止实时翻译") }
        capture.stop()
        capture.muted = false
        isRunning = false
        meter.level = 0
        activity = ""
        UIApplication.shared.isIdleTimerDisabled = false
        // 停止收音 = 立刻停止所有识别和翻译：清空排队的句子，打断正在生成的译文
        runGen += 1
        queue.removeAll()
        translator.cancelCurrent()
        translator.cancelPreview()
        previewSamples = nil
        mtPending = nil
        stopLiveEngine()
        stopAppleASR()
        finishedSeg = max(finishedSeg, currentSeg)
        partial = ""; partialTranslation = ""; partialSource = nil
        dropUnfinished()
        if wasRunning && readAfter { kickReader() }   // 停止聆听后，从上次没读完的地方接着读
        if pendingLocalSwitch {
            pendingLocalSwitch = false
            Task { await switchToLocal() }
        }
    }

    /// 停止时还没翻译完的句子：有部分译文就保留，没有就删掉
    private func dropUnfinished() {
        var changed = false
        for i in items.indices.reversed() where !items[i].done {
            if items[i].translated.isEmpty || items[i].sourceText == "…" {
                items.remove(at: i)
                if i < readIndex { readIndex -= 1 }
            } else {
                items[i].done = true
            }
            changed = true
        }
        if readIndex > items.count { readIndex = items.count }
        if changed { persist() }
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
        if isRunning { stop(readAfter: false) }
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
        let wasReading = readerTask != nil || readingID != nil
        readerGen += 1
        readerTask?.cancel()
        readerTask = nil
        readingID = nil
        if wasReading { speaker.stop() }
        capture.muted = false
    }

    /// 点某一句：从这句开始往后读；正在读这句时再点一下就停止
    func tapRead(_ item: TranslationItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { replay(item); return }
        if readingID == item.id { stopReading(); return }
        stopReading()
        readIndex = i
        // 扬声器模式 + 正在聆听：不出声，只记住从这句开始，停止实时翻译后再读
        if outputMode == .speaker && isRunning {
            activity = "停止实时翻译后从这句开始朗读"
            return
        }
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
        // 已经停止：停止前还没送到的断句事件一律丢弃
        if !isRunning {
            switch e {
            case .started, .partial, .ended: return
            default: break
            }
        }
        switch e {
        case .level(let l):
            meter.level = isRunning ? l : 0
        case .started(let id):
            currentSeg = id
            partialSeg = id
            partial = "…"; partialTranslation = ""; partialSource = nil
            live?.markSegmentStart(id)
            for eng in appleEngines { eng.markSegmentStart(id) }
            hearLog("断句：检测到说话（第 \(id) 句）")
        case .partial(let id, let samples):
            // 系统听写在工作时由它出原文；否则用 Whisper 不停地识别最新的声音
            guard !liveActive, !usingApple else { return }
            previewSamples = (id, samples)
            if !asrPreviewBusy {
                asrPreviewBusy = true
                Task { await previewLoop() }
            }
        case .ended(let id, let samples):
            finishedSeg = id
            live?.markSegmentEnd(id)
            for eng in appleEngines { eng.markSegmentEnd(id) }
            hearLog("断句：一句话结束，时长 \(String(format: "%.1f", Double(samples.count) / 16000)) 秒")
            // 立刻打断这句的实时预览，让整句识别和翻译马上开始
            translator.cancelPreview()
            previewSamples = nil
            mtPending = nil
            // 先把这句（实时预览的文字）放进对话，整句识别完再替换，屏幕上不会空一下
            let mine = partialSeg == id
            let src = (mine ? partialSource : nil) ?? ((lastLangID == langB.id) ? langB : langA)
            let tgt = src == langA ? langB : langA
            var item = TranslationItem(source: src, target: tgt,
                                       sourceText: mine && !partial.isEmpty ? partial : "…")
            item.translated = mine ? partialTranslation : ""
            items.append(item)
            if mine { partial = ""; partialTranslation = ""; partialSource = nil }
            queue.append((item.id, id, samples))
            if !working { Task { await drain() } }
        case .discarded(let id):
            finishedSeg = max(finishedSeg, id)
            if partialSeg == id { partial = ""; partialTranslation = ""; partialSource = nil }
        case .noise(let n, let t):
            if isRunning { hearLog(String(format: "环境噪声 %.0f dB，说话触发阈值 %.0f dB", n, t)) }
        }
    }

    // MARK: - 实时预览（说话过程中）

    /// 识别线：上一次识别一结束就拿最新的声音再识别，不等翻译
    private func previewLoop() async {
        defer { asrPreviewBusy = false }
        while let job = previewSamples {
            previewSamples = nil
            let id = job.id
            guard phase == .ready, isRunning, !liveActive, id == currentSeg, id > finishedSeg else { continue }
            let gen = runGen
            let a = langA, b = langB
            let fallback = (lastLangID == b.id) ? b.id : a.id
            // 只识别最近 10 秒，长句也跟得上
            let maxN = 16_000 * 10
            let clipped = job.samples.count > maxN
            let clip = clipped ? Array(job.samples.suffix(maxN)) : job.samples
            let t0 = Date()
            let r: (String, String)
            do {
                r = try await asr.recognize(clip, candidates: [a.id, b.id], fallback: fallback, preview: true)
            } catch {
                hearLog("实时识别失败：\(error)", .error)
                continue
            }
            hearLog("实时识别 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s：\(r.1.prefix(30))")
            guard gen == runGen, isRunning, id == currentSeg, id > finishedSeg, partialSeg == id,
                  SpeechRecognizer.isMeaningful(r.1) else { continue }
            let src = (r.0 == b.id) ? b : a
            partialSource = src
            partial = (clipped ? "…" : "") + r.1
            requestPreviewTranslation(id: id, text: r.1, src: src, tgt: src == a ? b : a)
        }
    }

    /// 系统听写给出的最新文字
    private func liveText() {
        guard liveActive, isRunning, currentSeg > finishedSeg, partialSeg == currentSeg,
              let live else { return }
        let text = live.segmentText(currentSeg).text
        guard SpeechRecognizer.isMeaningful(text) else { return }
        let src = (live.languageID == langB.id) ? langB : langA
        partialSource = src
        partial = text
        requestPreviewTranslation(id: currentSeg, text: text, src: src, tgt: src == langA ? langB : langA)
    }

    /// 翻译线：只翻最新的原文，翻完一次再拿最新的，不断修正译文
    private func requestPreviewTranslation(id: Int, text: String, src: Language, tgt: Language) {
        mtPending = (id, text, src, tgt)
        guard !mtPreviewBusy else { return }
        mtPreviewBusy = true
        Task { await previewTranslateLoop() }
    }

    private func previewTranslateLoop() async {
        defer { mtPreviewBusy = false }
        while let p = mtPending {
            mtPending = nil
            let id = p.id
            guard isRunning, id == currentSeg, id > finishedSeg else { continue }
            let gen = runGen
            if usingApple {
                let out = try? await systemTranslator.translate(p.text, from: p.src, to: p.tgt)
                if let out, !out.isEmpty, gen == runGen, id == partialSeg, id > finishedSeg { partialTranslation = out }
                continue
            }
            let epoch = translator.currentPreviewEpoch
            let prompt = PromptBuilder.build(text: p.text, from: p.src, to: p.tgt, context: [],
                                             glossary: PromptBuilder.parseGlossary(glossary))
            let out = try? await translator.translate(prompt: prompt, maxNewTokens: 256, previewEpoch: epoch) { t in
                Task { @MainActor in
                    if gen == self.runGen, id == self.partialSeg, id > self.finishedSeg { self.partialTranslation = t }
                }
            }
            if let out, !out.isEmpty, gen == runGen, id == partialSeg, id > finishedSeg { partialTranslation = out }
        }
    }

    // MARK: - iOS 系统听写

    private func startLiveEngine() {
        liveActive = false
        guard LiveTextEngineFactory.isSupported else {
            activity = "系统听写需要 iOS 26，已改用 Whisper"
            return
        }
        if live == nil {
            live = LiveTextEngineFactory.make()
            live?.onUpdate = { [weak self] in
                Task { @MainActor in self?.liveText() }
            }
        }
        guard let live else { return }
        capture.onSamples = { [weak live] s in live?.feed(s) }
        let lang = (lastLangID == langB.id) ? langB : langA
        runLiveEngine(live, lang)
    }

    private func stopLiveEngine() {
        liveActive = false
        capture.onSamples = nil
        if let live { Task { await live.stop() } }
    }

    /// 系统听写一次只能听一种语言：整句识别发现换了语言，就改听这种语言
    private func switchLiveLanguage(to lang: Language) {
        guard asrEngine == "apple", isRunning, let live, live.languageID != lang.id else { return }
        hearLog("系统听写改听 \(lang.name)")
        liveActive = false
        runLiveEngine(live, lang)
    }

    private func runLiveEngine(_ live: LiveTextEngine, _ lang: Language) {
        let gen = runGen
        Task {
            do {
                try await live.start(languageID: lang.id, locale: lang.tts)
                guard isRunning, gen == runGen, asrEngine == "apple" else { await live.stop(); return }
                liveActive = true
                if currentSeg > finishedSeg { live.markSegmentStart(currentSeg) }
            } catch {
                hearLog("系统听写不可用（\(lang.name)）：\(error.localizedDescription)，改用 Whisper 实时预览", .warning)
                if gen == runGen { liveActive = false }
            }
        }
    }

    // MARK: - 苹果自带模式（系统听写 + 系统翻译）

    /// 两种语言各开一个系统听写，同时听；每句话取更有把握的那个
    private func startAppleASR() {
        stopAppleASR()
        guard appleAvailable else { return }
        var engines: [LiveTextEngine] = []
        let gen = runGen
        for lang in [langA, langB] {
            guard let e = LiveTextEngineFactory.make() else { continue }
            e.onUpdate = { [weak self] in
                Task { @MainActor in self?.appleUpdated() }
            }
            engines.append(e)
            Task {
                do {
                    try await e.start(languageID: lang.id, locale: lang.tts)
                    guard isRunning, gen == runGen, usingApple else { await e.stop(); return }
                    if currentSeg > finishedSeg { e.markSegmentStart(currentSeg) }
                } catch {
                    hearLog("系统听写不支持 \(lang.name)：\(error.localizedDescription)", .warning)
                    activity = "系统听写暂不支持 \(lang.name)"
                }
            }
        }
        appleEngines = engines
        let list = engines
        capture.onSamples = { s in for e in list { e.feed(s) } }
    }

    private func stopAppleASR() {
        guard !appleEngines.isEmpty else { return }
        capture.onSamples = nil
        let list = appleEngines
        appleEngines = []
        Task { for e in list { await e.stop() } }
    }

    /// 第 id 句：两个听写里置信度更高的结果
    private func bestApple(_ id: Int) -> (text: String, lang: Language)? {
        var best: (text: String, lang: Language, conf: Double)?
        for e in appleEngines {
            let r = e.segmentText(id)
            guard !r.text.isEmpty, let lid = e.languageID else { continue }
            let lang = lid == langB.id ? langB : langA
            if best == nil || r.confidence > best!.conf { best = (r.text, lang, r.confidence) }
        }
        guard let best else { return nil }
        return (best.text, best.lang)
    }

    private func appleUpdated() {
        guard usingApple, isRunning, currentSeg > finishedSeg, partialSeg == currentSeg,
              let b = bestApple(currentSeg), SpeechRecognizer.isMeaningful(b.text) else { return }
        partialSource = b.lang
        // 中间停顿过的一句话：系统听写会把上一句的内容再带一遍，这里只显示新说的部分
        var text = b.text
        if let c = continuation(of: b.text, lang: b.lang) {
            guard SpeechRecognizer.isMeaningful(c.rest) else { partial = "…"; return }
            text = c.rest
        }
        partial = text
        requestPreviewTranslation(id: currentSeg, text: text, src: b.lang, tgt: b.lang == langA ? langB : langA)
    }

    /// 上一条苹果听写定稿的句子（用来识别“同一句话被拆成两段”）
    private var lastCommit: (id: UUID, text: String, lang: Language, at: Date)?

    /// text 是不是上一句的延续（开头和上一句基本一样）。是的话返回上一句的 id 和新多出来的部分
    private func continuation(of text: String, lang: Language) -> (prevID: UUID, rest: String)? {
        guard let c = lastCommit, c.lang == lang, Date().timeIntervalSince(c.at) < 12,
              items.contains(where: { $0.id == c.id }) else { return nil }
        func norm(_ s: String) -> [Character] {
            Array(s.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let a = norm(c.text), b = norm(text)
        guard a.count >= 2 else { return nil }
        var same = 0
        while same < a.count, same < b.count, a[same] == b[same] { same += 1 }
        // 系统听写后面会更正前面的字，所以不要求完全一样：前 80% 对得上就算同一句
        guard same >= max(2, Int((Double(a.count) * 0.8).rounded(.up))) else { return nil }
        // 跳过已经对上的字，剩下的就是新说的
        var skipped = 0
        var idx = text.startIndex
        while idx < text.endIndex, skipped < same {
            let ch = text[idx]
            if ch.isLetter || ch.isNumber { skipped += 1 }
            idx = text.index(after: idx)
        }
        let rest = String(text[idx...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return (c.id, rest)
    }

    /// 把这句并进上一句：上一条换成完整的原文并重新翻译，这条占位删掉
    private func mergeIntoPrevious(_ prevID: UUID, fullText: String, src: Language,
                                   placeholder: UUID, gen: Int) async {
        guard let i = items.firstIndex(where: { $0.id == prevID }) else { removeItem(placeholder); return }
        let tgt = items[i].target
        hearLog("系统听写：和上一句是同一句话，合并为「\(fullText.prefix(40))」")
        // 正在读或已经读过：译文变了，换成新译文从这句重新读
        if readingID == prevID { stopReading() }
        if readIndex > i { readIndex = i }
        items[i].sourceText = fullText
        items[i].done = false          // 译文先保留旧的；停止时不会被删掉
        removeItem(placeholder)
        lastCommit = (prevID, fullText, src, Date())
        activity = "翻译中…"
        do {
            let out = try await systemTranslator.translate(fullText, from: src, to: tgt)
            guard gen == runGen else { return }
            update(prevID, out, done: true)
        } catch {
            hearLog("苹果翻译失败：\(error)", .error)
            if let j = items.firstIndex(where: { $0.id == prevID }) { items[j].done = true }
            prepareAppleTranslation()
        }
        persist()
        activity = isRunning ? "正在聆听" : ""
        kickReader()
    }

    private func processApple(_ samples: [Float], itemID: UUID, segID: Int, gen: Int) async {
        activity = "识别中…"
        // 稍等一下，让系统听写把这句话定稿
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard gen == runGen else { return }
        guard let b = bestApple(segID), SpeechRecognizer.isMeaningful(b.text) else {
            removeItem(itemID)
            activity = isRunning ? "正在聆听" : ""
            return
        }
        let src = b.lang
        let tgt = src == langA ? langB : langA
        lastLangID = src.id
        hearLog("系统听写（\(src.name)）：\(b.text.prefix(40))")
        if let c = continuation(of: b.text, lang: src) {
            await mergeIntoPrevious(c.prevID, fullText: b.text, src: src, placeholder: itemID, gen: gen)
            return
        }
        lastCommit = (itemID, b.text, src, Date())
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        let old = items[idx]
        let preview = old.source == src ? old.translated : ""
        var item = TranslationItem(id: itemID, source: src, target: tgt, sourceText: b.text, translated: preview)
        if voiceStyle == "match" {
            item.speakerF0 = await Task.detached(priority: .utility) {
                VoiceAnalyzer.estimateF0(samples)
            }.value
            guard gen == runGen else { return }
        }
        guard let idx2 = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx2] = item
        activity = "翻译中…"
        do {
            let out = try await systemTranslator.translate(b.text, from: src, to: tgt)
            guard gen == runGen else { return }
            update(itemID, out, done: true)
        } catch {
            hearLog("苹果翻译失败：\(error)", .error)
            update(itemID, "（翻译失败：\(error.localizedDescription)）", done: true)
            prepareAppleTranslation()
        }
        persist()
        activity = isRunning ? "正在聆听" : ""
        kickReader()
    }

    // MARK: - 整句识别和翻译

    private func drain() async {
        working = true
        while !queue.isEmpty {
            let job = queue.removeFirst()
            if usingApple {
                await processApple(job.samples, itemID: job.itemID, segID: job.segID, gen: runGen)
            } else {
                await process(job.samples, itemID: job.itemID, gen: runGen)
            }
        }
        working = false
    }

    var isLoadingPhase: Bool { if case .loading = phase { return true }; return false }
    var loadingText: String? { if case .loading(let m) = phase { return m }; return nil }

    /// 删掉一条（识别结果没有意义时）
    private func removeItem(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: i)
        if i < readIndex { readIndex -= 1 }
        kickReader()
    }

    private func process(_ samples: [Float], itemID: UUID, gen: Int) async {
        // 模型还在加载：先把这句话留着，加载好马上识别
        if phase != .ready {
            activity = "模型准备好后马上识别"
            while isLoadingPhase, gen == runGen {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        guard gen == runGen, phase == .ready else { return }
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
            if gen == runGen { activity = "识别失败"; removeItem(itemID) }
            return
        }
        guard gen == runGen else { return }              // 已经停止：结果丢弃
        let src = (detected == b.id) ? b : a
        let tgt = (src == a) ? b : a
        lastLangID = src.id
        switchLiveLanguage(to: src)

        guard SpeechRecognizer.isMeaningful(text) else {
            removeItem(itemID)
            activity = isRunning ? "正在聆听" : ""
            return
        }
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        // 语言和预览一致时先保留预览译文，最终译文出来后再替换，避免闪烁
        let old = items[idx]
        let preview = old.source == src ? old.translated : ""
        var item = TranslationItem(id: itemID, source: src, target: tgt, sourceText: text, translated: preview)
        if voiceStyle == "match" {
            item.speakerF0 = await Task.detached(priority: .utility) {
                VoiceAnalyzer.estimateF0(samples)
            }.value
            guard gen == runGen else { return }
        }
        guard let idx2 = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx2] = item
        let id = itemID

        let context: [String] = useContext
            ? Array(items[..<idx2].filter { $0.done }.suffix(2).map(\.sourceText))
            : []
        let prompt = PromptBuilder.build(text: text, from: src, to: tgt,
                                         context: context,
                                         glossary: PromptBuilder.parseGlossary(glossary))
        activity = "翻译中…"
        translator.cancelPreview()        // 正在跑的实时预览翻译先让路
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
        guard gen == runGen else { return }              // 翻译中途被停止：stop() 已经收尾
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

    // MARK: - 修改原文后重新翻译

    /// 长按气泡改了原文：保存新原文，重新翻译并替换译文
    func editSource(_ id: UUID, to newText: String) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = items.firstIndex(where: { $0.id == id }), !text.isEmpty,
              text != items[i].sourceText else { return }
        if readingID == id { stopReading() }
        let src = items[i].source, tgt = items[i].target
        items[i].sourceText = text
        items[i].translated = ""          // 译文清空，界面显示转圈；保持 done，停止实时翻译时不会被当成未完成删掉
        hearLog("修改原文并重新翻译：\(text.prefix(40))")
        let context: [String] = useContext
            ? Array(items[..<i].filter { $0.done }.suffix(2).map(\.sourceText))
            : []
        Task {
            do {
                let result: String
                if usingApple {
                    result = try await systemTranslator.translate(text, from: src, to: tgt)
                } else {
                    // 本地模型还在加载时先等它就绪
                    while isLoadingPhase { try? await Task.sleep(nanoseconds: 200_000_000) }
                    guard phase == .ready else { throw TranslatorError.notLoaded }
                    let prompt = PromptBuilder.build(text: text, from: src, to: tgt, context: context,
                                                     glossary: PromptBuilder.parseGlossary(glossary))
                    result = try await translator.translate(prompt: prompt) { _ in }
                }
                update(id, result, done: true)
            } catch {
                hearLog("重新翻译失败：\(error)", .error)
                update(id, "（翻译失败：\(error.localizedDescription)）", done: true)
            }
            persist()
            kickReader()
        }
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
        if usingApple {
            prepareAppleTranslation()
            if isRunning { startAppleASR() }
        }
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

/// 麦克风音量（0~1），只给麦克风按钮的动画用
@MainActor
final class LevelMeter: ObservableObject {
    @Published var level: Float = 0
}
