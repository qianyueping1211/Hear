import SwiftUI
import UIKit
import AVFoundation
import Translation
import Security
import CryptoKit
import os

/// 顶层 4 种翻译模式（仅「并排双键」与「面对面」之间切换时保留当前屏幕内容，其余切换均归档并开启新对话）
enum AppTranslationMode: String, CaseIterable, Identifiable, Hashable {
    case listening
    case singleAuto
    case sideBySide
    case faceToFace

    var id: String { rawValue }
}

/// 对话翻译模式的三种展示方式（在对话模式右上角 ⋯ 菜单内切换）
enum ConversationDisplayStyle: String, CaseIterable, Identifiable {
    case single      // 自由对话（单按钮 · 自动双向识别）
    case sideBySide  // 并排对话（左右双按钮 · 同向看屏）
    case faceToFace  // 面对面（上下分屏 · 各有按钮）

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: return "自由对话"
        case .sideBySide: return "并排对话"
        case .faceToFace: return "面对面"
        }
    }

    var subtitle: String {
        switch self {
        case .single: return "单按钮 · 自动双向识别"
        case .sideBySide: return "左右双按钮 · 同向看屏"
        case .faceToFace: return "上下分屏 · 各有按钮"
        }
    }

    var icon: String {
        switch self {
        case .single: return "mic.circle"
        case .sideBySide: return "rectangle.split.2x1"
        case .faceToFace: return "rectangle.split.1x2"
        }
    }
}

/// 等克隆任务出结果用的盒子（后台任务写，主线程读）
final class CloneOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CloneAudio?
    private var finished = false

    func set(_ v: CloneAudio?) {
        lock.lock(); value = v; finished = true; lock.unlock()
    }
    var result: CloneAudio? {
        lock.lock(); defer { lock.unlock() }; return value
    }
    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }; return finished
    }
}

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
    @Published private var captureHealth: AudioCapture.Health = .normal
    var recordingStatus: String {
        guard isRunning else { return activity }
        if captureHealth == .reconnecting { return "正在恢复麦克风连接…" }
        if captureHealth == .backlogged { return "音频积压，部分录音可能未识别…" }
        let count = recognition.queue.pendingCount
        return count > 1 ? "收音正常，\(count) 句等待识别…" : activity
    }
    enum ToastPlacement { case controls, modelStatus }
    private struct Toast {
        let text: String
        let placement: ToastPlacement
    }
    @Published private var activeToast: Toast?
    var toast: String? { activeToast?.placement == .controls ? activeToast?.text : nil }
    var modelReadyHint: String? {
        guard !isAnyModelLoading, activeToast?.placement == .modelStatus else { return nil }
        return activeToast?.text
    }
    private var toastTask: Task<Void, Never>?

    // 设置
    @Published var speakOutput: Bool {
        didSet {
            save("speakOutput", speakOutput)
            if speakOutput { readIndex = items.count }   // 重新打开时不补读之前的
            else { stopReading() }
        }
    }
    @Published var showReadingIcon: Bool { didSet { save("showReadingIcon", showReadingIcon) } }
    @Published var chineseDisplayLanguage = ChineseDisplayLanguage(
        rawValue: UserDefaults.standard.string(forKey: ChineseDisplayLanguage.preferenceKey) ?? ""
    ) ?? .simplified {
        didSet {
            guard chineseDisplayLanguage != oldValue else { return }
            save(ChineseDisplayLanguage.preferenceKey, chineseDisplayLanguage.rawValue)
            publishLiveActivity()
        }
    }

    var displayedPartial: String {
        chineseDisplayLanguage.display(partial, languageID: partialSource?.id)
    }

    var displayedPartialTranslation: String {
        chineseDisplayLanguage.display(partialTranslation, languageID: partialTranslationTarget?.id)
    }

    @Published var liveActivityOnlyTranslation: Bool {
        didSet {
            save("liveActivityOnlyTranslation", liveActivityOnlyTranslation)
            if isRunning { publishLiveActivity() }
        }
    }
    @Published var useContext: Bool { didSet { save("useContext", useContext) } }
    @Published var sensitivity: Double { didSet { save("sensitivity", sensitivity); pushConfig() } }
    @Published var silenceMs: Double { didSet { save("silenceMs", silenceMs); pushConfig() } }
    @Published var glossary: String { didSet { save("glossary", glossary) } }
    @Published var hfHost: String { didSet { save("hfHost", hfHost) } }
    /// 云端模型服务地址（自己电脑上跑的服务），例如 http://192.168.1.10:8000
    @Published var cloudAddress: String {
        didSet {
            save("cloudAddress", cloudAddress)
            updateCloudAddresses()
        }
    }
    /// 每个云端模型自己的接口地址（留空就用上面的默认地址）
    @Published var cloudModelAddress: [String: String] = [:] {
        didSet {
            save("cloudModelAddress", cloudModelAddress)
            updateCloudAddresses()
        }
    }
    /// 云端语音识别用哪个方案：
    ///   whisper              只用 Whisper（准，慢）
    ///   sensevoice           只用 SenseVoice（快）
    ///   sensevoice+whisper   SenseVoice 先出，Whisper 再修正（推荐）
    @Published var cloudASRScheme: String {
        didSet {
            save("cloudASRScheme", cloudASRScheme)
            updateCloudAddresses()
        }
    }
    /// 云端识别方案的中文名（日志里用）
    static func cloudSchemeName(_ scheme: String) -> String {
        switch scheme {
        case "whisper": return "Whisper"
        case "sensevoice": return "SenseVoice"
        case "sensevoice+whisper": return "SenseVoice+Whisper"
        default: return scheme
        }
    }
    /// 云端服务返回的各模型状态（asr / mt / clone）
    @Published private(set) var cloudStatus: [String: String] = [:]
    /// 电脑上跑的识别模型（Whisper 的型号，比如 large-v3）
    @Published private(set) var cloudASRModelName: String = ""
    // MARK: - 云端证书（严格模式 / 配对）

    /// 严格模式：只认配对过的那台电脑的证书。
    /// 关着的时候是兼容模式：只对"用户自己填的内网地址"放宽自签证书校验。
    @Published var cloudStrictMode: Bool = false {
        didSet {
            save("cloudStrictMode", cloudStrictMode)
            LocalServerTrust.setStrictMode(cloudStrictMode)
            if !cloudStrictMode {
                // 关掉严格模式：配对信息就没用了
                UserDefaults.standard.removeObject(forKey: "cloudPinnedRoot")
                LocalServerTrust.pinRoot(Data())
                cloudRootFingerprint = ""
            }
        }
    }
    /// 访问口令：电脑上的服务要求时才填。
    /// 填了以后，同一个局域网里的别的设备就不能用你的电脑跑模型了。
    @Published var cloudAccessToken: String = "" {
        didSet { save("cloudAccessToken", cloudAccessToken) }
    }
    /// 已经配对过的签发根指纹（给用户核对用）
    @Published private(set) var cloudRootFingerprint: String = ""
    /// 电脑上没有 SenseVoice 的状态："" = 还不知道（还没问过服务），
    /// "就绪" / "没装"。老版本的服务没这个字段，就当作不知道（照旧给用户选）。
    @Published private(set) var cloudSenseVoiceState: String = ""
    /// 电脑上实际能用的识别方案（服务报上来的清单）。
    /// App 的识别方案列表就是照着它来的：电脑上没装的就一个都不给。
    @Published private(set) var cloudASRSchemes: [String] = []
    /// 每个模型实际连上的地址（模型自己的地址不通、用通用服务地址顶上的，记通用那个）
    @Published private(set) var cloudStatusAddress: [String: String] = [:]
    /// 系统朗读声音偏好："auto" 跟随说话人性别 / "default" 系统默认 / "female" 女声 / "male" 男声
    @Published var systemVoicePreference: String {
        didSet { save("systemVoicePreference", systemVoicePreference) }
    }
    /// 根据原声基频估算的每句说话人性别（用于未手动设置性别时的系统朗读男女声自动切换）
    private var detectedGenders: [UUID: AVSpeechSynthesisVoiceGender] = [:]
    private var detectedGenderOrder: [UUID] = []

    /// 声音克隆用云端模型（false = 用 iPhone 本机的 ZipVoice）
    @Published var voiceCloneCloud: Bool {
        didSet {
            save("voiceCloneCloud", voiceCloneCloud)
            guard voiceCloneCloud != oldValue else { return }
            hearLog("声音克隆引擎改为\(voiceCloneCloud ? "云端" : "本地")")
            clearCloneTasks()
            if voiceCloneCloud {
                // 不用本地模型了，卸掉省内存
                Task { await cloner.unload() }
            } else if voiceClone {
                scheduleCloneLoad(delay: 0.5)
            }
        }
    }
    /// 云端声音合成模型："qwen3"（Qwen3-TTS 原声克隆）| "edge_tts"（微软 Edge-TTS 神经语音）
    @Published var cloudCloneModel: String {
        didSet {
            save("cloudCloneModel", cloudCloneModel)
            guard cloudCloneModel != oldValue else { return }
            hearLog("云端声音模型改为：\(cloudCloneModel == "edge_tts" ? "Edge-TTS" : "Qwen3-TTS")")
            clearCloneTasks()
        }
    }
    /// 语音识别走云端
    var usingCloudASR: Bool { asrEngine == "cloud" }
    /// 文本翻译走云端
    var usingCloudMT: Bool { translationEngine == "cloud" }
    /// 声音克隆走云端
    var usingCloudClone: Bool { voiceClone && voiceCloneCloud }
    /// 当前识别引擎能不能做说话人区分。
    /// 云端始终可以；本地需要 SenseVoice 文件夹里带 CAM++ 声纹模型。
    var speakerTrackingAvailable: Bool {
        if usingCloudASR { return true }
        guard asrEngine == "sensevoice", let folder = SenseVoiceRecognizer.installedFolder() else {
            return false
        }
        return LocalSpeakerEmbedder.isInstalled(in: folder)
    }

    /// 模型管理默认显示哪一边：0 = 本地模型，1 = 在线模型
    ///
    /// 每次打开设置都按现在的实际情况重新判断一次，省得用户自己再点一下：
    ///   · 引擎里有本地引擎（Whisper / SenseVoice / 本地 MT / 本地克隆）→ 本地模型
    ///   · 没有本地引擎，但有在线引擎 → 在线模型
    ///   · 没有本地引擎，在线模型那边也已经填好地址了 → 在线模型
    ///   · 都没有（全是苹果自带、在线那边也是空的）→ 本地模型
    ///     （得让用户看到下载入口，不然模型没法下）
    var preferredModelTab: Int {
        // 声音克隆的开关关着的时候不算一个引擎
        var engines = [asrEngine, translationEngine]
        if voiceClone { engines.append(voiceCloneCloud ? "cloud" : "local") }
        if engines.contains(where: { Self.isLocalEngine($0) }) { return 0 }
        if engines.contains("cloud") { return 1 }
        // 没有本地引擎，但在线模型已经配好了（填过地址）→ 直接进在线模型
        if hasOnlineModel { return 1 }
        return 0
    }

    /// 在线模型那边是不是已经有东西了（填过服务地址）
    var hasOnlineModel: Bool {
        if !cloudAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        for m in CloudModel.allCases {
            let a = cloudEffectiveAddress(m).trimmingCharacters(in: .whitespacesAndNewlines)
            if !a.isEmpty { return true }
        }
        return false
    }

    // 朗读输出：扬声器 / 耳机；耳机时左右耳各播哪种语言（"A" / "B" / "off"）
    @Published var outputMode: AudioOutput { didSet { save("outputMode", outputMode.rawValue) } }
    @Published var leftEar: String { didSet { save("leftEar", leftEar) } }
    @Published var rightEar: String { didSet { save("rightEar", rightEar) } }
    // 声音克隆朗读：用说话人自己的声音读出译文。打开时加载模型，关掉就卸载省内存
    @Published var voiceClone: Bool {
        didSet {
            save("voiceClone", voiceClone)
            guard voiceClone != oldValue else { return }
            hearLog("声音克隆朗读：\(voiceClone ? "开" : "关")")
            if voiceClone, !voiceCloneCloud { scheduleCloneLoad(delay: 0.3) } else {
                cloneLoadTask?.cancel()
                clearCloneTasks()
                Task { await cloner.unload() }
            }
        }
    }
    @Published private(set) var cloneLoading = false
    @Published private(set) var cloneLoadingSeconds = 0
    /// 正在加载的东西（界面上显示进度用）
    var loadingHint: String? {
        if cloneLoading { return "正在准备语音克隆模型 · \(cloneLoadingSeconds) 秒" }
        if isLoadingPhase { return loadingText }
        return nil
    }
    @Published var asrEngine: String {
        didSet {
            // 自动回退（云端挂了临时换一个）：不写进设置、也不停录音。
            // 用户自己选的还是"云端"，等服务恢复了要换回去——
            // 这里要是保存了、或者把这一段话掐断了，用户会以为是自己设置错了。
            if !cloudRecovery.isApplying {
                save("asrEngine", asrEngine)
                // 用户自己在设置里改的：清掉"回退前的备份"（备份已经没意义了）
                cloudRecovery.clear()
            }
            guard asrEngine != oldValue else { return }
            hearLog("识别引擎改为 \(asrEngine)")
            enforceLanguages()
            if (isRunning || microphoneStartToken != nil) && !cloudRecovery.isApplying { stop(readAfter: false) }
            Task { await reloadIfLocal() }       // 加载新引擎需要的模型，不用的卸掉省内存
        }
    }
    // 翻译引擎："apple" 苹果自带（系统翻译）/ "local" 本地模型（Hy-MT2）/ "" 还没选
    @Published var translationEngine: String {
        didSet {
            // 自动回退时同样不保存、不停录音（见 asrEngine 的说明）
            if !cloudRecovery.isApplying {
                save("translationEngine", translationEngine)
                cloudRecovery.clear()
            }
            guard translationEngine != oldValue else { return }
            hearLog("翻译引擎改为 \(translationEngine)")
            if (isRunning || microphoneStartToken != nil) && !cloudRecovery.isApplying { stop(readAfter: false) }
            if translationEngine == "apple" { Task { await translator.unload() } }   // 用不到本地翻译了，省内存
            Task { await reloadIfLocal() }
        }
    }
    // 后台下载本地模型（苹果自带模式下进行，设置里显示进度）
    @Published private(set) var bgDownloading = false
    @Published private(set) var bgDownloadName = ""
    @Published private(set) var bgDownloadProgress: Double = 0
    @Published private(set) var bgDownloadError: String?
    @Published private(set) var bgDownloadKind: ModelKind?
    @Published private(set) var bgQueue: [ModelKind] = []   // 这次要下载、还没下完的模型（排在后面的显示“等待下载”）
    private struct ModelDownloadRequest {
        var kinds: [ModelKind]
        let switchWhenDone: Bool
        let thenEngine: String?
        let force: Bool
    }
    @Published private var pausedModelDownloads: [ModelDownloadRequest] = []
    private var modelDownloadRequest: ModelDownloadRequest?
    private var modelDownloadTask: Task<Void, Never>?
    private var modelDownloadID = UUID()
    // 让系统弹出苹果翻译语言包下载（ContentView 的 translationTask 使用）
    @Published var translationPrepConfig: TranslationSession.Configuration?
    @Published private(set) var appleNote: String?
    private var pendingLocalSwitch = false

    var appleAvailable: Bool { LiveTextEngineFactory.isSupported }
    /// 语音识别用系统听写（识别引擎选了“苹果自带”）
    var usingAppleASR: Bool { asrEngine == "apple" && appleAvailable }
    /// 翻译用系统翻译（翻译引擎选了“苹果自带”）
    var usingAppleTranslation: Bool { translationEngine == "apple" && appleAvailable }
    /// 说话时用系统听写逐字显示
    private var dualLive: Bool { usingAppleASR }
    /// 当前两个引擎需要的模型是否都齐了（按当前选择判断，用不到的模型不用管）
    var modelsInstalled: Bool {
        _ = modelsRevision
        if translationEngine == "local", modelFiles().gguf == nil { return false }
        return missingSpeechKinds(for: asrEngine).isEmpty
    }

    private static func normalizedASREngine(_ engine: String) -> String {
        engine == "whisper" || engine == "hybrid" ? "sensevoice" : engine
    }

    func missingSpeechKinds(for engine: String) -> [ModelKind] {
        Self.normalizedASREngine(engine) == "sensevoice" && modelFiles().sense == nil ? [.senseVoice] : []
    }

    private var useSense: Bool { asrEngine == "sensevoice" }

    // MARK: - 语言（不同识别引擎支持的语言不同）

    /// iOS 系统听写支持的语言（启动后查询；查到之前为 nil，当作都支持）
    @Published private(set) var appleLangIDs: Set<String>?

    /// 当前引擎能用的语言：语言列表里只显示这些
    var supportedLanguages: [Language] {
        var ids = Set(Language.all.map(\.id))
        if useSense { ids.formIntersection(SenseVoiceRecognizer.languageIDs) }
        if dualLive, let a = appleLangIDs { ids.formIntersection(a) }
        let list = Language.all.filter { ids.contains($0.id) }
        return list.count >= 2 ? list : Language.all
    }

    /// 换了引擎后，原来选的语言不支持了：自动换成支持的语言
    private func enforceLanguages() {
        let ok = supportedLanguages
        let left = ok.contains(langA) ? langA : (ok.first { $0 != langB } ?? ok[0])
        let right = ok.contains(langB) && langB != left ? langB : (ok.first { $0 != left } ?? ok[0])
        if left != langA || right != langB {
            setLanguagePair(left: left, right: right)
            hearLog("当前识别引擎不支持原来的语言，改为 \(langA.name) ⇄ \(langB.name)", .warning)
            showToast("当前识别引擎不支持原来的语言，已改为 \(langA.name) ⇄ \(langB.name)")
        }
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
    /// 正在套用 iCloud 同步过来的设置（这时候不重启麦克风）
    private var applyingSyncedSettings = false

    // 语音增强：系统的降噪 + 回声消除 + 自动增益
    @Published var voiceProcessing: Bool {
        didSet {
            guard voiceProcessing != oldValue else { return }
            save("voiceProcessing", voiceProcessing)
            capture.voiceProcessing = voiceProcessing
            // 语音增强是设在输入节点上的，引擎不停就没法改：
            // 正在收音时改开关，就把麦克风重开一次（录屏时想临时关掉语音增强，
            // 不用先停一次翻译）。
            // 同步过来的设置不在这里重启（那是后台换的，不该打断当前这一句）。
            if isRunning, !applyingSyncedSettings { restartCapture() }
        }
    }
    /// 是否保存完整录音：开启后将同一对话的声音录制到本地 WAV，供历史对话回放
    @Published var saveFullRecording: Bool {
        didSet {
            guard saveFullRecording != oldValue else { return }
            save("saveFullRecording", saveFullRecording)
            fullRecorder.configure(enabled: saveFullRecording, conversationID: conversationID)
            hearLog("保存完整录音：\(saveFullRecording ? "开" : "关")")
        }
    }
    private let fullRecorder = ConversationAudioRecorder()
    private var segStartFrames: [Int: Int64] = [:]

    /// 重开麦克风（改了输入相关的设置时用）
    private func restartCapture() {
        hearLog("重开麦克风（语音增强\(voiceProcessing ? "开" : "关")）")
        capture.stop()
        let intent = startToken
        Task { [weak self] in
            guard let self, self.isRunning, self.startToken == intent else { return }
            do {
                try await self.capture.start()
                guard self.isRunning, self.startToken == intent else {
                    // 晚于停止或切换模式返回：立即停麦并释放音频会话，防止遗留幽灵麦克风
                    self.capture.stop()
                    self.scheduleMicrophoneRelease()
                    return
                }
                AudioRoute.apply(self.outputMode)
            } catch is CancellationError {
                return
            } catch {
                guard self.isRunning, self.startToken == intent else { return }
                hearLog("重开麦克风失败：\(error)", .error)
                self.stop(readAfter: false)
                self.activity = "收音已停止，请重新开始"
                self.showToast("麦克风未能重新连接", seconds: 5)
            }
        }
    }

    private let capture = AudioCapture()
    private let sense = SenseVoiceRecognizer()
    private let translator = LlamaTranslator()
    private let speaker = Speaker()
    private let systemTranslator = SystemTranslator()
    private let cloner = LocalVoiceCloner()
    /// 云端模型服务（自己电脑上跑的那台）
    private let cloud = CloudClient()
    private let clonePipeline = SessionClonePipeline()
    private let cloudRecovery = SessionCloudRecovery()
    private var appleEngines: [LiveTextEngine] = []   // 苹果自带模式：每种语言一个系统听写
    private var appleStopTask: Task<Void, Never>?     // 串行等待上一批系统听写彻底释放，避免触发 SFSpeechErrorDomain Code=16
    private var lastApplePieceRange: (langID: String, start: Double, end: Double)?
    private let languageDetector = SpokenLanguageDetector() // 独立的 sherpa-onnx Whisper-Tiny 语种裁判（不依赖 SenseVoice）

    /// 排队等着处理的句子。
    /// token 是这一句"当前有效任务"的身份：
    /// 超时被放弃的、或者被后来的任务顶掉的旧任务，结果一律不写回（不然会串）。
    private struct ASRJob {
        let itemID: UUID
        let segID: Int
        let samples: [Float]
        let token: UUID
        let generation: Int
        let left: Language
        let right: Language
        let forced: Language?
        let fallback: Language
        let confirmedSpeech: Bool
    }
    private let recognition = SessionRecognitionPipeline<ASRJob>()
    private let translations = SessionTranslationPipeline<MTJob>()
    /// itemID → 当前有效的任务令牌
    private var jobTokens: [UUID: UUID] = [:]
    private var runGen = 0                // 每次停止 +1：停止前排队/进行中的识别和翻译全部作废
    private var working: Bool { !recognition.queue.isIdle }
    private var currentSeg = 0
    private var currentSegStartFrame: Int64 = 0
    private var partialSeg = 0            // 实时气泡（partial）属于第几句
    /// 刚停下来时保留下来的那一条：断句的最后一段声音要挂到它身上（声音克隆用）
    private var stopFlushItemID: UUID?
    /// 停下来那一刻正在说的那句（断句器最后会把它的声音交出来）
    private var stopFlushSegID = 0
    /// 声音克隆服务不可用（已经提醒过，别一直弹）
    private var cloneUnavailableNotified = false
    private let previews = SessionPreviewPipeline()
    private var partialTranslationTarget: Language?
    // iOS 系统听写（逐字显示原文）
    private var live: LiveTextEngine?
    private var liveActive = false
    private var finishedSeg = 0
    private var lastLangID: String?
    private var swapping = false

    // 朗读队列：readIndex 指向下一句要读的译文
    @Published private(set) var readingID: UUID?
    /// 每句正在执行的生成任务。旧任务结束时不能清掉新任务的等待状态。
    @Published private(set) var cloneWorking: [UUID: UUID] = [:]
    /// 真正在出声的那一条（喇叭显示成绿色）。
    /// 只是"轮到它读了"不算：声音还在生成、或者还没开始播，喇叭都还是转圈。
    @Published private(set) var speakingID: UUID?
    /// 本地网络权限没开：界面上弹提示
    @Published var localNetworkHelp = false

    // 对话翻译模式：支持 自由对话（单按钮）/ 并排对话（左右双按钮）/ 面对面（上下分屏双按钮）
    @Published var talkMode: Bool {
        didSet {
            guard talkMode != oldValue else { return }
            save("talkMode", talkMode)
            save("hearLastMode", talkMode)      // 多存一份：万一主的那份丢了还能找回来
            pushConfig()                        // 门槛不一样了（短回答的门槛）
            guard !switchingMode else { return }
            startToken = UUID()                 // 正在等待的"开始收音"作废
            conversationInputLanguage = nil
            if isRunning { Task { await finishRecording(readAfter: false) } }
            else if microphoneStartToken != nil { capture.stop() }
        }
    }
    /// 对话翻译模式的展示方式：自由对话 / 并排对话 / 面对面
    @Published var conversationStyle: ConversationDisplayStyle {
        didSet {
            guard conversationStyle != oldValue else { return }
            save("conversationStyle", conversationStyle.rawValue)
            pushConfig()
            guard !switchingMode else { return }
            startToken = UUID()
            conversationInputLanguage = nil
            if talkMode {
                if isRunning { Task { await finishRecording(readAfter: false) } }
                else if microphoneStartToken != nil { capture.stop() }
            }
        }
    }
    private var switchingMode = false

    /// 当前所处的 4 模式之一
    var currentTranslationMode: AppTranslationMode {
        if !talkMode { return .listening }
        switch conversationStyle {
        case .single: return .singleAuto
        case .sideBySide: return .sideBySide
        case .faceToFace: return .faceToFace
        }
    }

    /// 原子切换翻译模式：仅「并排双键 ↔ 面对面」保留当前屏幕内容；其余任何模式切换均自动归档旧内容并开启空白新对话
    func switchTranslationMode(to mode: AppTranslationMode) {
        let oldMode = currentTranslationMode
        guard mode != oldMode else { return }
        let keepContent = (oldMode == .sideBySide && mode == .faceToFace)
            || (oldMode == .faceToFace && mode == .sideBySide)
        switchingMode = true
        switch mode {
        case .listening:
            talkMode = false
        case .singleAuto:
            talkMode = true
            conversationStyle = .single
        case .sideBySide:
            talkMode = true
            conversationStyle = .sideBySide
        case .faceToFace:
            talkMode = true
            conversationStyle = .faceToFace
        }
        switchingMode = false
        conversationInputLanguage = nil
        if !keepContent && (!items.isEmpty || !partial.isEmpty) {
            newConversation(summarize: false, resumeListening: false)
        } else {
            startToken = UUID()
            if isRunning { Task { await finishRecording(readAfter: false) } }
            else if microphoneStartToken != nil { capture.stop() }
        }
    }
    /// 实时翻译（会议）模式的目标翻译语言（默认中文）：自动识别多国语言并统一翻译为该语言（仅影响翻译目标，不影响语音识别引擎）
    @Published var meetingTargetLang: Language {
        didSet {
            guard meetingTargetLang != oldValue else { return }
            save("meetingTargetLang", meetingTargetLang.id)
        }
    }
    /// 当前是否处于「左右/上下双按钮」按语种点按收听状态
    var usesDualConversationButtons: Bool { talkMode && conversationStyle != .single }
    @Published private(set) var conversationInputLanguage: Language?
    private var talkLang: Language?
    private var conversationFlush: Task<Void, Never>?
    private var finishingInput = false
    private var readIndex = 0
    private var readerTask: Task<Void, Never>?
    private var readerGen = 0
    private var oneShot = false
    private var manualSpeaker = false {
        didSet { save("manualSpeakerOutput", manualSpeaker) }
    }

    // 当前这一页对话（自动保存到历史）
    private(set) var conversationID = UUID() {
        didSet {
            guard oldValue != conversationID else { return }
            speakerQueue.cancel()
            speakerTracker = SpeakerTracker()
            clonePipeline.reset()
        }
    }
    private var conversationCreated = Date()

    init() {
        let d = UserDefaults.standard
        langA = Language.find(d.string(forKey: "langA") ?? "zh")
        langB = Language.find(d.string(forKey: "langB") ?? "en")
        speakOutput = d.object(forKey: "speakOutput") as? Bool ?? true
        showReadingIcon = d.object(forKey: "showReadingIcon") as? Bool ?? true
        liveActivityOnlyTranslation =
            d.object(forKey: "liveActivityOnlyTranslation") as? Bool ?? false
        useContext = d.object(forKey: "useContext") as? Bool ?? true
        sensitivity = d.object(forKey: "sensitivity") as? Double ?? 12
        silenceMs = d.object(forKey: "silenceMs") as? Double ?? 700
        glossary = d.string(forKey: "glossary") ?? ""
        hfHost = d.string(forKey: "hfHost") ?? "huggingface.co"
        let savedOutput = AudioOutput(rawValue: d.string(forKey: "outputMode") ?? "") ?? .speaker
        outputMode = savedOutput
        manualSpeaker = d.bool(forKey: "manualSpeakerOutput") && savedOutput == .speaker
        leftEar = d.string(forKey: "leftEar") ?? "A"
        rightEar = d.string(forKey: "rightEar") ?? "B"
        let savedVoicePref = d.string(forKey: "systemVoicePreference") ?? "auto"
        systemVoicePreference = (savedVoicePref == "male" || savedVoicePref == "female") ? savedVoicePref : "auto"
        voiceClone = d.object(forKey: "voiceClone") as? Bool ?? false
        // 界面已隐藏本地 ZipVoice，统一固定走云端声音克隆（本地代码保留，后续如需恢复可重新放开）
        voiceCloneCloud = true
        if d.object(forKey: "voiceCloneCloud") as? Bool == false {
            d.set(true, forKey: "voiceCloneCloud")
        }
        let savedCloudCloneModel = d.string(forKey: "cloudCloneModel") ?? "qwen3"
        cloudCloneModel = (savedCloudCloneModel == "edge_tts") ? "edge_tts" : "qwen3"
        // init 里属性还没初始化完，只能用局部变量，不能直接读 self.cloudAddress
        let cloudAddr = d.string(forKey: "cloudAddress") ?? ""
        cloudAddress = cloudAddr
        let initialASRScheme = d.string(forKey: "cloudASRScheme") ?? "sensevoice+whisper"
        cloudASRScheme = initialASRScheme
        // 先放到局部变量里：init 还没结束，读 self 的属性编译不过
        let accessTok = d.string(forKey: "cloudAccessToken") ?? ""
        cloudAccessToken = accessTok
        CloudClient.accessToken = accessTok
        let cloudOwn = d.object(forKey: "cloudModelAddress") as? [String: String] ?? [:]
        cloudModelAddress = cloudOwn
        let cloudClient = cloud
        Task {
            await cloudClient.setAddresses(
                asr: Self.effectiveAddress(fallback: cloudAddr, own: cloudOwn[CloudModel.asr.rawValue] ?? ""),
                mt: Self.effectiveAddress(fallback: cloudAddr, own: cloudOwn[CloudModel.mt.rawValue] ?? ""),
                clone: Self.effectiveAddress(fallback: cloudAddr, own: cloudOwn[CloudModel.clone.rawValue] ?? ""))
            await cloudClient.setSharedAddress(cloudAddr)
            await cloudClient.setASRScheme(initialASRScheme)
        }
        // 引擎默认都用苹果自带（不用下载模型，打开就能用）
        let canApple = LiveTextEngineFactory.isSupported

        // 迁移旧版本：原来只有一个 engineMode（apple/local 同时管识别和翻译），拆成独立的翻译引擎
        let oldEngine = d.string(forKey: "engineMode") ?? ""
        let savedTranslation = d.string(forKey: "translationEngine") ?? ""
        if !savedTranslation.isEmpty {
            translationEngine = savedTranslation
        } else if oldEngine == "local" {
            translationEngine = "local"          // 老用户选了本地模型，保留
        } else {
            translationEngine = canApple ? "apple" : "local"
        }

        // 识别引擎：老用户沿用原来的选择，新用户默认苹果自带
        let savedASR = d.string(forKey: "asrEngine") ?? ""
        if !savedASR.isEmpty {
            let normalized = Self.normalizedASREngine(savedASR)
            asrEngine = normalized
            if savedASR != normalized { d.set(normalized, forKey: "asrEngine") }
        } else {
            asrEngine = canApple ? "apple" : "sensevoice"
        }
        // 严格模式（只连配对过的电脑）：
        // 这里只赋值（属性带观察者，init 里赋值不会触发观察者）；
        // 要读就用下面的局部变量——init 没结束前读 self 的属性编译不过。
        let strictOn = d.object(forKey: "cloudStrictMode") as? Bool ?? false
        cloudStrictMode = strictOn
        if let der = d.data(forKey: "cloudPinnedRoot"), !der.isEmpty {
            LocalServerTrust.pinRoot(der)
            cloudRootFingerprint = Self.certFingerprint(der)
        }
        LocalServerTrust.setStrictMode(strictOn)
        voiceProcessing = d.object(forKey: "voiceProcessing") as? Bool ?? true
        saveFullRecording = d.object(forKey: "saveFullRecording") as? Bool ?? false
        inputSource = d.string(forKey: "inputSource") ?? "phone"
        // 上次用的模式一定要记住：不管存的是 Bool 还是 NSNumber 都能读回来
        if let v = d.object(forKey: "talkMode") as? Bool {
            talkMode = v
        } else if d.object(forKey: "talkMode") != nil {
            talkMode = d.bool(forKey: "talkMode")
        } else {
            talkMode = d.bool(forKey: "hearLastMode")
        }
        let savedStyle = d.string(forKey: "conversationStyle") ?? ConversationDisplayStyle.sideBySide.rawValue
        conversationStyle = ConversationDisplayStyle(rawValue: savedStyle) ?? .sideBySide
        let savedMeetingTarget = d.string(forKey: "meetingTargetLang") ?? "zh"
        meetingTargetLang = Language.find(savedMeetingTarget)
        hearLog("启动：\(talkMode ? "对话翻译模式（\(conversationStyle.title)）" : "实时翻译模式（译为\(meetingTargetLang.name)）")")
        speaker.onAudioActivityChanged = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let id = self.speaker.isEmittingAudio ? self.readingID : nil
                if self.speakingID != id { self.speakingID = id }
            }
        }
        // 播完了：这时候可以考虑把麦克风放开（不然音频会话一直占着）
        speaker.onPlaybackFinished = { [weak self] in
            Task { @MainActor in self?.releaseMicrophoneIfIdle() }
        }
        // Instantiate the controller at app startup so iOS activities from an earlier process are removed.
        _ = HearLiveActivityController.shared
        // 采集层要停音频会话的时候，问一下"现在有没有在出声"
        // （判断完到真正停掉之间，可能刚好开始播下一句）
        capture.isSpeakingNow = { [weak self] in
            self?.speaker.isPlaying ?? false
        }
        capture.voiceProcessing = voiceProcessing
        AudioRoute.useHeadsetMic = inputSource == "headset"

        clonePipeline.onWorkChanged = { [weak self] work in self?.cloneWorking = work }
        clonePipeline.fixedReferenceProvider = {
            let store = FixedVoiceSampleStore.shared
            guard let ref = store.loadReference() else { return nil }
            return (ref, store.preferOverLive)
        }
        capture.onHealthChanged = { [weak self] health in
            self?.captureHealth = health
        }
        capture.onRecordingBlock = { [fullRecorder] block, muted in
            fullRecorder.append(samples: block.samples, captureStartFrame: block.startFrame, muted: muted)
        }
        capture.segmenter.onEvent = { [weak self] e in
            DispatchQueue.main.async { self?.handle(e) }
        }
        pushConfig()

        // 查一下 iOS 系统听写支持哪些语言；然后检查一遍当前选的语言
        Task { [weak self] in
            let ids = await LiveTextEngineFactory.supportedLanguageIDs(Language.all)
            guard let self else { return }
            self.appleLangIDs = ids
            self.enforceLanguages()
        }

        // 插上耳机：自动改为耳机朗读；拔掉：改回扬声器（正在聆听时先暂停朗读）
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            Task { @MainActor in self?.routeChanged(reason) }
        }

        // 本地网络权限被系统拒了：弹提示告诉用户去哪儿开
        NotificationCenter.default.addObserver(
            forName: .hearLocalNetworkDenied, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.localNetworkHelp = true
                hearLog("本地网络权限没开：请到 设置 → 隐私与安全性 → 本地网络 → 听见 里打开", .warning)
            }
        }

        // iCloud 同步过来的设置：直接换上，不用提示用户重开 App
        NotificationCenter.default.addObserver(
            forName: .hearCloudSettingsApplied, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadSyncedSettings()
            }
        }

        // 内存不够了（系统要杀我们）：先把大模型卸掉，能保住 App 不退出
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reclaimMemory() }
        }

        // 切到别的 App：别在后台继续出声，但别的照旧。
        //
        // 麦克风留着听（实时翻译不能断），网络也留着
        // （切到别的软件以后，电脑那边的翻译和声音克隆服务还要接着调用，
        //   不然切一下 App 这段对话就断了）。
        // 只是喇叭停下来：用户不在跟前听，吵得慌。
        translator.setGPUAllowed(UIApplication.shared.applicationState != .background)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [translator] _ in
            translator.setGPUAllowed(false)
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [translator] _ in
            translator.setGPUAllowed(true)
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.inBackground = true
                self.playbackToken = UUID()      // 还没播的请求全部作废
                self.stopReading()
                if !self.isRunning { self.endLiveActivity() }
                self.persist()
                hearLog("切到后台：停止朗读（翻译和云端服务继续跑）", .info)
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.inBackground = false
                self.refreshHeadset()
                // 回到前台：把后台攒下的译文接着读出来
                self.kickReader()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                HearLiveActivityController.shared.dismissAll()
            }
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

        // 持久化的引擎选择本身没有被临时回退改写。
        cloudRecovery.clear()
    }

    // MARK: - 朗读输出（扬声器 / 耳机）

    /// 刷新“是否连着耳机”，并在耳机已断开时实时同步回手机扬声器与手机麦克风
    func refreshHeadset() {
        headsetConnected = AudioRoute.headphonesLikelyConnected()
        guard !headsetConnected else { return }
        let usedHeadsetOutput = outputMode == .headphones
        let usedHeadsetInput = inputSource == "headset"
        if usedHeadsetOutput {
            outputMode = .speaker
            if isRunning { stopReading() }
            AudioRoute.apply(.speaker)
        }
        if usedHeadsetInput {
            inputSource = "phone"
        }
        if usedHeadsetOutput || usedHeadsetInput {
            hearLog("耳机已断开，收音或朗读已自动改回手机")
        }
    }

    /// 切换声音来源；正在聆听时马上重新接麦克风
    private func applyInputSource() {
        AudioRoute.useHeadsetMic = inputSource == "headset"
        hearLog("声音来源切换为\(inputSource == "headset" ? "耳机麦克风" : "手机麦克风")")
        guard isRunning, !applyingSyncedSettings else { return }
        restartCapture()
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .newDeviceAvailable:
            refreshHeadset()
            guard outputMode != .speaker || !manualSpeaker else { return }
            // 蓝牙耳机在扬声器模式下不一定看得到，所以再临时取消强制扬声器检查一次
            if !headsetConnected { headsetConnected = AudioRoute.detectHeadphones() }
            guard headsetConnected else { return }
            let switched = outputMode != .headphones
            outputMode = .headphones
            AudioRoute.apply(.headphones)
            if switched { hearLog("检测到耳机，朗读改为耳机") }
            kickReader()
        case .oldDeviceUnavailable, .categoryChange, .override, .routeConfigurationChange:
            refreshHeadset()
        default:
            refreshHeadset()
        }
    }

    @discardableResult
    func setAudioOutput(_ output: AudioOutput) -> Bool {
        if output == .speaker { manualSpeaker = true }
        guard output != outputMode else { return true }
        let haptic = UINotificationFeedbackGenerator()
        if output == .headphones {
            try? AudioRoute.activate()
            headsetConnected = AudioRoute.detectHeadphones()
            guard headsetConnected else {
                AudioRoute.apply(.speaker)
                haptic.notificationOccurred(.warning)
                hearLog("切换耳机朗读：未检测到耳机")
                return false
            }
            manualSpeaker = false
        } else {
            if isRunning { stopReading() }
        }
        outputMode = output
        AudioRoute.apply(output)
        kickReader()
        hearLog("朗读输出切换为\(outputMode == .speaker ? "扬声器" : "耳机")")
        haptic.notificationOccurred(.success)
        return true
    }

    func earLabel(_ slot: String) -> String {
        switch slot {
        case "A": return langA.name
        case "B": return langB.name
        default: return "不播放"
        }
    }

    // MARK: - 模型状态（设置页显示）

    enum ModelKind: Sendable { case translation, senseVoice, voiceClone }

    struct ModelStatus {
        let name: String
        let detail: String
        let installed: Bool
    }

    /// 模型文件变动后加一，让设置页刷新
    @Published private(set) var modelsRevision = 0

    var translationStatus: ModelStatus {
        _ = modelsRevision
        if let u = modelFiles().gguf {
            return .init(name: u.lastPathComponent,
                         detail: ModelManager.format(cachedSize(u, folder: false)), installed: true)
        }
        return .init(name: "Hy-MT2-1.8B", detail: "未下载", installed: false)
    }

    var senseStatus: ModelStatus {
        _ = modelsRevision
        if let f = modelFiles().sense {
            return .init(name: "SenseVoice-Small",
                         detail: ModelManager.format(cachedSize(f, folder: true)), installed: true)
        }
        return .init(name: "SenseVoice-Small", detail: "未下载", installed: false)
    }

    var cloneStatus: ModelStatus {
        _ = modelFiles()            // 模型变动后让大小缓存重新计算
        let name = ZipVoiceModel.displayName
        if cloneInstalled {
            let folder = ZipVoiceModel.directory
            var detail = ModelManager.format(cachedSize(folder, folder: true))
            if cloneLoading { detail += " · 加载中" }

            return .init(name: name, detail: detail, installed: true)
        }
        return .init(name: name, detail: "未下载", installed: false)
    }

    func isInstalled(_ kind: ModelKind) -> Bool {
        _ = modelsRevision
        switch kind {
        case .translation: return modelFiles().gguf != nil
        case .senseVoice: return modelFiles().sense != nil
        case .voiceClone: return cloneInstalled
        }
    }

    /// 当前引擎选择下，这个模型是否正在被用到（用不到的模型不需要加载/下载）
    func isKindInUse(_ kind: ModelKind) -> Bool {
        switch kind {
        case .translation: return translationEngine == "local"
        case .senseVoice: return useSense
        case .voiceClone: return voiceClone
        }
    }

    private var cloneInstalled: Bool {
        if let c = cloneCache, c.rev == modelsRevision { return c.ok }
        let ok = ZipVoiceModel.installed
        cloneCache = (modelsRevision, ok)
        return ok
    }
    private var cloneCache: (rev: Int, ok: Bool)?

    // 模型文件的位置和大小：界面每次刷新都会用到，查一次就记住，模型文件变动（modelsRevision 变了）才重新查。
    // 以前每次刷新都去遍历模型文件夹算大小，说话、朗读时界面刷新很频繁，会造成卡顿
    private var fileCache: (rev: Int, gguf: URL?, sense: URL?)?
    private var sizeCache: [String: Int64] = [:]

    private func modelFiles() -> (gguf: URL?, sense: URL?) {
        if let c = fileCache, c.rev == modelsRevision { return (c.gguf, c.sense) }
        let g = ModelManager.currentGGUF()
        let sv = SenseVoiceRecognizer.installedFolder()
        fileCache = (modelsRevision, g, sv)
        sizeCache.removeAll()
        return (g, sv)
    }

    private func cachedSize(_ u: URL, folder: Bool) -> Int64 {
        if let v = sizeCache[u.path] { return v }
        let v = folder ? ModelManager.folderSize(u) : ModelManager.fileSize(u)
        sizeCache[u.path] = v
        return v
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

    func isModelDownloadPaused(_ kind: ModelKind) -> Bool {
        pausedModelDownloads.contains { $0.kinds.contains(kind) }
    }

    func pauseModelDownload(_ kind: ModelKind) {
        guard bgDownloading, bgDownloadKind == kind,
              var request = modelDownloadRequest, !isModelDownloadPaused(kind) else { return }
        request.kinds = bgQueue
        pausedModelDownloads.append(request)
        modelDownloadTask?.cancel()
    }

    func resumeModelDownload(_ kind: ModelKind) {
        guard !bgDownloading,
              let index = pausedModelDownloads.firstIndex(where: { $0.kinds.contains(kind) }) else { return }
        let request = pausedModelDownloads.remove(at: index)
        startBackgroundDownload(kinds: request.kinds, switchWhenDone: request.switchWhenDone,
                                thenEngine: request.thenEngine, force: request.force)
    }

    func prepareForModelImport(_ kind: ModelKind) async {
        if isModelDownloadPaused(kind) {
            if bgDownloadKind == kind { await modelDownloadTask?.value }
            clearPausedModelDownload(kind)
        }
    }

    private func clearPausedModelDownload(_ kind: ModelKind) {
        guard let index = pausedModelDownloads.firstIndex(where: { $0.kinds.contains(kind) }) else { return }
        pausedModelDownloads[index].kinds.removeAll { $0 == kind }
        if pausedModelDownloads[index].kinds.isEmpty { pausedModelDownloads.remove(at: index) }
    }

    func selectGGUF(_ url: URL) async {
        if isRunning, translationEngine == "local" { stop(readAfter: false) }
        ModelManager.select(url)
        await translator.unload()
        modelsRevision += 1
        await reloadIfLocal()
    }

    /// 设置 → 下载与导入：下载（或删除后重新下载）某个模型，进度显示在设置里
    func redownload(_ kind: ModelKind) async {
        guard !bgDownloading else { return }
        if kind == .voiceClone {
            startBackgroundDownload(kinds: [.voiceClone], switchWhenDone: false, force: true)
            return
        }
        if isInstalled(kind) {
            if isRunning, isKindInUse(kind) { stop(readAfter: false) }
            switch kind {
            case .translation:
                await translator.unload()
                // 不删原来那个模型：下载器是"下到临时文件再换名"的，
                // 下失败（断网、文件不对）时，原来那个还能用。
                // 先删了的话，一下失败就变成"没模型可用"了。
            case .senseVoice:
                if !senseRequiresRestart { await sense.unload() }

            case .voiceClone:
                clearCloneTasks()
                await cloner.unload()

            }
            modelsRevision += 1
            // 当前引擎用得到这个模型才需要等它下载完再用
            if isKindInUse(kind) { phase = .loading("正在重新下载模型，完成后自动加载") }
        }
        startBackgroundDownload(kinds: [kind], switchWhenDone: isKindInUse(kind), force: true)
    }

    // MARK: - 模型

    func bootstrap() async {
        guard phase == .checking || phase == .needsModels || phaseIsFailed else { return }
        // 上次退出不正常（崩溃 / 被系统杀掉）：先查出来，提示用户
        if let prev = CrashGuard.shared.checkPreviousRun() {
            hearLog(prev, .warning)
            // 提示只显示第一句，完整的调用栈在日志里
            let head = prev.split(separator: "\n").first.map(String.init) ?? prev
            showToast(head, seconds: 6)
        }
        // 记下"这次在跑"，退出时删掉；下次打开还在就说明上次是不正常结束的
        CrashGuard.shared.markRunning()
        // 上次加载声音克隆时 App 退出了（多半是内存不够）：这次先关掉，免得一打开就闪退
        let d = UserDefaults.standard
        if d.bool(forKey: Self.clonePendingKey) {
            d.removeObject(forKey: Self.clonePendingKey)
            if voiceClone, !voiceCloneCloud {
                hearLog("上次加载声音克隆时 App 退出了，已自动关闭声音克隆（可用内存 \(Self.freeMB()) MB）", .warning)
                voiceClone = false
                showToast("上次加载声音克隆时 App 退出，已自动关闭声音克隆")
            }
        }
        hearLog("启动：可用内存 \(Self.freeMB()) MB")
        defer { if voiceClone, !voiceCloneCloud { scheduleCloneLoad(delay: 3) } }   // 其他模型准备好以后再加载声音克隆
        // 还没选引擎（老版本数据异常）：不自动加载模型，等用户在设置里选
        if asrEngine.isEmpty || translationEngine.isEmpty {
            phase = .ready
            return
        }
        // 全都用苹果自带：不需要任何模型，检查一下苹果翻译的语言包就行
        if usingAppleASR && usingAppleTranslation {
            phase = .ready
            prepareAppleTranslation()
            return
        }
        if modelsInstalled {
            await loadModels()
        } else {
            phase = .needsModels
        }
    }

    // MARK: - 引擎选择

    /// 用苹果自带的系统听写 + 系统翻译（不用下载模型）
    func chooseApple() {
        guard appleAvailable else { return }
        if isRunning { stop(readAfter: false) }
        stopLiveEngine()
        stopAppleASR()
        asrEngine = "apple"
        translationEngine = "apple"
        phase = .ready
        hearLog("引擎：苹果自带")
        prepareAppleTranslation()
    }

    /// 首次使用选择“下载”：下载翻译模型和识别模型
    func chooseLocalAndDownload() async {
        // 只下载当前引擎选择真正需要的模型
        await downloadModels()
    }

    /// 切到本地翻译（模型已下载）
    func switchToLocal() async {
        if isRunning { stop(readAfter: false) }
        stopAppleASR()
        translationEngine = "local"
        hearLog("引擎：本地翻译")
        if modelsInstalled { await loadModels() } else { phase = .needsModels }
    }

    /// 后台下载本地模型：期间继续用当前引擎，设置里显示进度，下载完自动切换。
    /// kinds：要下载哪些模型；不指定就下载当前识别引擎缺的全部模型
    /// thenEngine：下载完后切换到这个识别引擎
    func startBackgroundDownload(kinds: [ModelKind]? = nil, switchWhenDone: Bool = true,
                                 thenEngine: String? = nil, force: Bool = false) {
        guard !bgDownloading else { return }
        let list: [ModelKind]
        if let kinds {
            list = force ? kinds : kinds.filter { !isInstalled($0) }
        } else {
            var need = missingSpeechKinds(for: asrEngine)
            if translationEngine == "local", !isInstalled(.translation) { need.insert(.translation, at: 0) }
            list = need
        }
        guard !list.isEmpty else { return }
        let id = UUID()
        modelDownloadID = id
        list.forEach(clearPausedModelDownload)
        modelDownloadRequest = ModelDownloadRequest(kinds: list, switchWhenDone: switchWhenDone,
                                                    thenEngine: thenEngine, force: force)
        bgDownloading = true
        bgDownloadError = nil
        bgDownloadProgress = 0
        bgQueue = list
        hearLog("后台下载本地模型：\(list.map(Self.kindName).joined(separator: "、"))")
        modelDownloadTask = Task {
            UIApplication.shared.isIdleTimerDisabled = true
            var ok = false
            let host: String
            if list.contains(where: { $0 != .voiceClone }) {
                host = await HostPicker.best()
                hfHost = host
            } else {
                host = hfHost
            }
            do {
                for kind in list {
                    try Task.checkCancellation()
                    bgDownloadKind = kind
                    bgDownloadName = Self.kindName(kind)
                    bgDownloadProgress = 0
                    let onProgress: @Sendable (Double) -> Void = { p in
                        Task { @MainActor in
                            guard self.modelDownloadID == id, self.bgDownloadKind == kind,
                                  !self.isModelDownloadPaused(kind) else { return }
                            self.bgDownloadProgress = p
                        }
                    }
                    switch kind {
                    case .translation: _ = try await ModelManager.downloadGGUF(host: host, progress: onProgress)
                    case .senseVoice: try await SenseVoiceRecognizer.download(host: host, force: force, progress: onProgress)
                    case .voiceClone:
                        try await ZipVoiceModel.download(progress: onProgress)
                        cloneLoadTask?.cancel()
                        clearCloneTasks()
                        await cloner.unload()
                    }
                    bgDownloadKind = nil              // 下载完立刻收起进度条
                    bgQueue.removeAll { $0 == kind }
                    clearPausedModelDownload(kind)
                    modelsRevision += 1
                    if kind == .voiceClone, voiceClone, !voiceCloneCloud { scheduleCloneLoad(delay: 0.3) }
                }
                ok = true
            } catch {
                if !Task.isCancelled {
                    hearLog("后台下载失败：\(error)", .error)
                    HostPicker.reset()
                    bgDownloadError = "下载失败：\(error.localizedDescription)"
                }
            }
            // 先结束“下载中”的显示，再去切换或加载模型（加载要好几秒，不用一直挂着 100%）
            bgDownloading = false
            bgDownloadKind = nil
            bgQueue = []
            UIApplication.shared.isIdleTimerDisabled = isRunning
            modelDownloadRequest = nil
            defer { if modelDownloadID == id { modelDownloadTask = nil } }
            // 为了换识别引擎而下载：下载完就切过去（切换时会自动加载模型）
            if ok, !Task.isCancelled, let then = thenEngine, then != asrEngine {
                hearLog("模型下载完成，识别引擎切换为 \(then)")
                asrEngine = then
                return
            }
            guard ok, modelsInstalled else {
                if force, modelsInstalled { await loadModels() }
                else if case .loading = phase { phase = .needsModels }
                return
            }
            hearLog("模型下载完成")
            // 只为下载声音克隆（switchWhenDone == false）就到此为止，不用加载翻译/识别模型
            guard switchWhenDone else { return }
            if isRunning {
                pendingLocalSwitch = true     // 正在对话：停止实时翻译后再加载
                activity = "模型已下载，停止实时翻译后加载"
            } else {
                await loadModels()
            }
        }
    }

    static func kindName(_ kind: ModelKind) -> String {
        switch kind {
        case .translation: return "翻译模型 Hy-MT2"
        case .senseVoice: return "语音识别模型 SenseVoice"
        case .voiceClone: return "声音克隆模型 ZipVoice"
        }
    }

    /// 苹果翻译真的失败了：这时才提示用户
    ///
    /// 失败最常见的原因是语言包没装好（苹果自己报 unsupportedSourceLanguage），
    /// 所以这里要说清楚可以怎么办，而不只是说"不支持"。
    private func appleTranslationFailed(_ error: Error? = nil) {
        guard usingAppleTranslation else { return }
        let a = langA
        let b = !talkMode ? meetingTargetLang : langB
        var msg = "苹果翻译暂时用不了（\(a.name) → \(b.name)）"
        if let error { msg += "：\(Self.appleErrorText(error))" }
        msg += "，请到苹果翻译应用中下载对应的语言；也可以在设置里改用云端或本地翻译。"
        appleNote = msg
        hearLog(msg, .warning)
        // 再要一次语言包：系统会重新弹一次下载窗（只弹一次，别反复烦人）
        askAppleDownloadAgain()
    }

    /// 气泡上显示的翻译失败文案：使用苹果翻译引擎且缺少语言包/不支持目标语种时，补充引导到苹果「翻译」App 下载对应语言
    private func translationFailureMessage(for error: Error) -> String {
        let base = error.localizedDescription
        guard usingAppleTranslation else { return "（翻译失败：\(base)）" }
        let desc = String(describing: error)
        let isMissingAppleModel = desc.contains("unsupportedSourceLanguage")
            || desc.contains("unsupportedTargetLanguage")
            || desc.contains("unsupportedLanguagePairing")
            || desc.contains("notInstalled")
            || desc.contains("TranslationError")
            || (error as? LiveTextError) == .unsupportedLanguage
        if isMissingAppleModel {
            return "（翻译失败：\(base)，请到苹果翻译应用中下载对应的语言）"
        }
        return "（翻译失败：\(base)）"
    }

    /// 再要一次苹果翻译的语言包（系统会重新弹下载窗）
    private func askAppleDownloadAgain() {
        guard usingAppleTranslation, !appleDownloadAsked else { return }
        appleDownloadAsked = true
        Task {
            let src = await systemTranslator.canonical(langA)
            let tgt = await systemTranslator.canonical(langB)
            // 换一份新的配置：系统就会重新跑一遍翻译任务，再弹一次下载窗
            translationPrepConfig = TranslationSession.Configuration(source: src, target: tgt)
        }
    }

    /// 把苹果翻译的报错说成人话
    static func appleErrorText(_ error: Error) -> String {
        // TranslationError 的 cause 在描述里，直接翻一下
        let s = String(describing: error)
        if s.contains("unsupportedSourceLanguage") { return "源语言不支持（多半是语言包没装）" }
        if s.contains("unsupportedTargetLanguage") { return "目标语言不支持（多半是语言包没装）" }
        if s.contains("unsupportedLanguagePairing") { return "苹果翻译不支持这个语言方向" }
        if s.contains("notInstalled") { return "语言包还没装" }
        return error.localizedDescription
    }

    /// 检查苹果翻译的语言包；没下载就让系统弹出下载
    func prepareAppleTranslation() {
        guard usingAppleTranslation else { return }
        let a = langA, b = langB
        appleDownloadAsked = false
        Task {
            await systemTranslator.reset()
            await systemTranslator.loadSupportedLanguages()
            // 苹果翻译的语言标识得用苹果自己的写法（有的写 "en-US"，有的只写 "en"），
            // 写错了它就当"这个语言不支持"，语言包也下不下来。
            let src = await systemTranslator.canonical(a)
            let tgt = await systemTranslator.canonical(b)
            switch await systemTranslator.availability(a, b) {
            case .installed:
                appleNote = nil
            case .needsDownload:
                appleNote = "需要苹果翻译的 \(a.name)、\(b.name) 语言包（系统会弹窗让你下载）"
            case .unsupported:
                appleNote = "苹果翻译不支持 \(a.name) 到 \(b.name)"
            }
            // 不管状态是什么，都给系统一份配置：
            // 只有 .translationTask 能让系统弹语言包下载，
            // 少了这一步语言包永远装不上，翻译就会一直报 unsupportedSourceLanguage。
            // 语言没换就别换配置，免得系统反复弹下载框。
            if translationPrepConfig?.source != src || translationPrepConfig?.target != tgt {
                translationPrepConfig = TranslationSession.Configuration(source: src, target: tgt)
            }
        }
    }

    /// 系统语言包下载完成（或用户关掉了下载窗口）
    func appleTranslationPrepared(_ ok: Bool) {
        if ok {
            appleNote = nil
        } else if usingAppleTranslation {
            appleNote = "苹果翻译的语言包没下载好，会改用别的引擎来翻译"
        }
        Task { await systemTranslator.reset() }
        hearLog(ok ? "苹果翻译语言包已就绪" : "苹果翻译语言包没有下载", ok ? .info : .warning)
    }

    private var phaseIsFailed: Bool { if case .failed = phase { return true }; return false }

    func downloadModels(forceTranslation: Bool = false) async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = isRunning }
        let host = await HostPicker.best()
        hfHost = host
        do {
            if translationEngine == "local", forceTranslation || ModelManager.currentGGUF() == nil {
                phase = .downloading("翻译模型 Hy-MT2", 0)
                _ = try await ModelManager.downloadGGUF(host: host) { p in
                    Task { @MainActor in self.setProgress("翻译模型 Hy-MT2", p) }
                }
                modelsRevision += 1
            }
            // 只下载当前识别引擎要用的语音识别模型
            for kind in missingSpeechKinds(for: asrEngine) {
                let name = Self.kindName(kind)
                phase = .downloading(name, 0)
                let onProgress: @Sendable (Double) -> Void = { p in
                    Task { @MainActor in self.setProgress(name, p) }
                }
                try await SenseVoiceRecognizer.download(host: host, progress: onProgress)
                modelsRevision += 1
            }
            await loadModels()
        } catch {
            hearLog("下载失败：\(error)", .error)
            HostPicker.reset()
            phase = .failed("下载失败：\(error.localizedDescription)\n请检查网络后重试。")
        }
    }

    /// 只在仍处于同一个下载阶段时更新进度，避免迟到的回调覆盖后续状态
    private func setProgress(_ name: String, _ p: Double) {
        if case .downloading(let n, _) = phase, n == name { phase = .downloading(name, p) }
    }

    /// 正在加载模型的次数（>0 说明还有模型在加载）
    @Published private var modelLoadCount = 0
    /// 每次加载的编号：只有最新那次的结果算数，旧的不要覆盖状态
    private var loadGen = 0
    /// 当前正在加载的模型名称与阶段起始时间（用于精确显示“正在准备识别/翻译/语音克隆模型 · N 秒”）
    private var loadingStageName = "模型"
    private var loadingStageStart = Date()

    /// 当前选择需要的本地识别、翻译和声音克隆是否还有未完成加载。
    var isAnyModelLoading: Bool {
        if isLoadingPhase || cloneLoading { return true }
        return modelLoadCount > 0
    }

    private var needsLocalVoiceClone: Bool {
        voiceClone && !voiceCloneCloud
    }

    /// 实时翻译开始前的统一模型检查。只检查当前真正会使用的本地模型。
    private func allSelectedLocalModelsLoaded() async -> Bool {
        if useSense, !(await sense.isLoaded) { return false }
        if translationEngine == "local", !(await translator.isLoaded) { return false }
        return true
    }

    private func finishModelLoading(start: Date, gen: Int) async {
        if needsLocalVoiceClone, !(await cloner.isLoaded) {
            await loadClonerIfNeeded(allowDuringModelLoading: true)
        }
        guard gen == loadGen, !Task.isCancelled else { return }
        guard await allSelectedLocalModelsLoaded() else {
            phase = .failed("本地识别或翻译模型还未就绪，请检查模型配置或重新加载。")
            return
        }
        let cloneReady = await cloner.isLoaded
        guard gen == loadGen, !Task.isCancelled else { return }
        phase = .ready
        hearLog("识别与翻译就绪，用时 \(Int(Date().timeIntervalSince(start)))s，可用内存 \(Self.freeMB()) MB")
        showToast(needsLocalVoiceClone && !cloneReady
                  ? "可以开始翻译 · 暂用系统声音朗读"
                  : "模型加载完成，可以开始翻译了", seconds: 5, placement: .modelStatus)
    }

    func loadModels() async {
        if senseRequiresRestart, useSense {
            phase = .failed(Self.senseRestartMessage)
            return
        }
        // 每次加载都拿一个新编号：同时来了好几次加载（换引擎、下载完成等）时，
        // 只有最后一次的结果算数，不然旧的那次会先把"加载完成"提示弹出来，
        // 但其实还有模型在加载，一按翻译键又被拦下。
        if activeToast?.placement == .modelStatus { dismissToast() }
        loadGen += 1
        let gen = loadGen
        modelLoadCount += 1
        defer { modelLoadCount -= 1 }
        let wantsSense = useSense
        let sf = SenseVoiceRecognizer.installedFolder()
        let needLocalMT = translationEngine == "local"
        let mtPath = ModelManager.currentGGUF()?.path
        guard !needLocalMT || mtPath != nil, !wantsSense || sf != nil else {
            phase = .needsModels
            return
        }
        if !wantsSense, !senseRequiresRestart, await sense.isLoaded { await sense.unload() }
        if !needLocalMT, await translator.isLoaded { await translator.unload() }
        let start = Date()
        let svLoaded = wantsSense ? await sense.isLoaded : false
        let mtLoaded = await translator.isLoaded
        guard gen == loadGen, !Task.isCancelled else { return }
        let needSV = wantsSense && !svLoaded
        let needMT = needLocalMT && (!mtLoaded || needSV)
        if !needSV && !needMT {
            await finishModelLoading(start: start, gen: gen)
            return
        }
        // 加载识别和翻译模型前，先等声音克隆结束再卸掉：
        // 按顺序加载，降低模型初始化的内存峰值。
        cloneLoadTask?.cancel()
        try? await Task.sleep(nanoseconds: 50_000_000)   // 让被取消的任务有机会跑到设置 cloneLoading 的那一步
        // 注意：Swift 不允许 await 出现在 && / || 右侧，逐个取值
        var cloneBusy = cloneLoading
        var cloneHasModel = await cloner.isLoaded
        if cloneBusy || cloneHasModel {
            phase = .loading("正在等待声音克隆加载完成…")
            while cloneBusy {
                try? await Task.sleep(nanoseconds: 200_000_000)
                cloneBusy = cloneLoading
            }
            clearCloneTasks()
            cloneHasModel = await cloner.isLoaded
            if cloneHasModel { await cloner.unload() }
        }
        // 当前正在加载的模型名称与该阶段起始时间，用于精确提示“正在准备识别/翻译/语音克隆模型 · N 秒”
        loadingStageName = needSV ? "识别模型" : "翻译模型"
        loadingStageStart = start
        // 每秒刷新一次已用时间，让用户一眼看出是哪个模型在加载、用了多久
        let ticker = Task { @MainActor [weak self] in
            var warnedStage: String?
            while !Task.isCancelled {
                guard let self else { break }
                let stage = self.loadingStageName
                let stageSecs = max(0, Int(Date().timeIntervalSince(self.loadingStageStart)))
                let totalSecs = max(0, Int(Date().timeIntervalSince(start)))
                if stageSecs > 120 && warnedStage != stage {
                    warnedStage = stage
                    hearLog("\(stage)加载已超过 2 分钟（总耗时 \(totalSecs) 秒）", .warning)
                }
                let msg = "正在准备\(stage) · \(stageSecs) 秒"
                // 旧的加载任务别去改状态（新一轮加载已经在跑了）
                if gen == self.loadGen, case .loading = self.phase { self.phase = .loading(msg) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { ticker.cancel() }
        if gen == loadGen { phase = .loading("正在准备\(loadingStageName) · 0 秒") }
        do {
            // 一个一个加载：同时加载几个大模型，内存峰值太高会被系统强制退出
            guard gen == loadGen, !Task.isCancelled else { return }
            if needSV, let sf {
                loadingStageName = "识别模型"
                loadingStageStart = Date()
                if gen == loadGen { phase = .loading("正在准备识别模型 · 0 秒") }
                if mtLoaded { await translator.unload() }
                guard gen == loadGen, !Task.isCancelled else { return }
                try await sense.load(folder: sf)
                guard gen == loadGen, !Task.isCancelled else { return }
            }
            if needMT {
                loadingStageName = "翻译模型"
                loadingStageStart = Date()
                if gen == loadGen { phase = .loading("正在准备翻译模型 · 0 秒") }
            }
            try await loadMTIfNeeded(needMT, path: mtPath ?? "")
            // 又来了新的加载任务：这次的结果作废，交给新的那次去设状态
            guard gen == loadGen else {
                hearLog("有新的模型加载任务，忽略这次的结果", .warning)
                return
            }
            if needsLocalVoiceClone, !(await cloner.isLoaded) {
                loadingStageName = "语音克隆模型"
                loadingStageStart = Date()
                if gen == loadGen { phase = .loading("正在准备语音克隆模型 · 0 秒") }
            }
            await finishModelLoading(start: start, gen: gen)
        } catch {
            guard gen == loadGen, !Task.isCancelled else { return }
            hearLog("模型加载失败：\(error)", .error)
            if isRunning { stop(readAfter: false) }
            if let failure = error as? SenseVoiceRecognizer.LoadFailure {
                phase = .failed(failure.localizedDescription)
            } else {
                phase = .failed("模型加载失败：\(error.localizedDescription)\n可以在 设置 → 运行日志 查看详情。")
            }
        }
    }

    private nonisolated func loadMTIfNeeded(_ need: Bool, path: String) async throws {
        guard need else { return }
        let t0 = Date()
        hearLog("翻译模型：开始加载 \((path as NSString).lastPathComponent)")
        try await translator.load(path: path)
        hearLog("翻译模型：加载完成，用时 \(Int(Date().timeIntervalSince(t0)))s")
    }

    private var importingTranslation = false

    /// 验证模型能启动以后才安装。磁盘空间不足或文件损坏时，保留原模型。
    func importModel(_ url: URL) async {
        guard !importingTranslation else { return }
        importingTranslation = true
        defer { importingTranslation = false }
        do {
            let staging = try await Task.detached(priority: .utility) {
                try ModelManager.stageGGUF(from: url)
            }.value
            defer { try? FileManager.default.removeItem(at: staging) }
            if isRunning, translationEngine == "local" { stop(readAfter: false) }
            let local = translationEngine == "local"
            if local { phase = .loading("正在验证翻译模型…") }
            await translator.unload()
            do {
                try await translator.load(path: staging.path)
            } catch {
                await reloadIfLocal()
                throw error
            }
            await translator.unload()
            let destination = ModelManager.modelsDir.appendingPathComponent(url.lastPathComponent)
            try ModelManager.installModelFile(staging, at: destination)
            ModelManager.select(destination)
            modelsRevision += 1
            bgDownloadError = nil
            hearLog("已导入翻译模型：\(url.lastPathComponent)")
            await reloadIfLocal()
        } catch {
            if isLoadingPhase {
                if modelsInstalled { await reloadIfLocal() } else { phase = .needsModels }
            }
            hearLog("导入翻译模型失败：\(error)", .error)
            bgDownloadError = "导入失败：\(error.localizedDescription)"
        }
    }

    /// 设置 → 导入 SenseVoice 模型（文件夹）
    func importSenseVoice(_ url: URL) async {
        do {
            if isRunning, useSense { stop(readAfter: false) }
            if !senseRequiresRestart { await sense.unload() }
            try SenseVoiceRecognizer.importFolder(from: url)
            modelsRevision += 1
            bgDownloadError = nil
            hearLog("已导入 SenseVoice 模型：\(url.lastPathComponent)")
            await reloadIfLocal()
        } catch {
            hearLog("导入 SenseVoice 模型失败：\(error)", .error)
            bgDownloadError = "导入失败：\(error.localizedDescription)"
        }
    }

    /// 设置 → 导入包含 ZipVoice 和 Vocos 的模型文件夹。
    func importVoiceClone(_ url: URL) async {
        do {
            cloneLoadTask?.cancel()
            clearCloneTasks()
            await cloner.unload()
            try await Task.detached(priority: .utility) { try ZipVoiceModel.importFolder(url) }.value
            modelsRevision += 1
            bgDownloadError = nil
            hearLog("已导入声音克隆模型")
            if voiceClone, !voiceCloneCloud { scheduleCloneLoad(delay: 0.5) }
        } catch {
            hearLog("导入声音克隆模型失败：\(error)", .error)
            bgDownloadError = "导入失败：\(error.localizedDescription)"
        }
    }

    /// 引擎变了就按当前选择重新加载；模型没齐时什么都不做
    private func reloadIfLocal() async {
        guard !asrEngine.isEmpty, !translationEngine.isEmpty, modelsInstalled else { return }
        await loadModels()
    }

    // MARK: - 开始 / 停止

    func toggle() async {
        guard !usesDualConversationButtons else { return }
        dismissToast()
        if isRunning { await finishRecording(); return }
        if microphoneStartToken == startToken {
            startToken = UUID()
            capture.stop()
            activity = ""
            return
        }
        _ = await beginListening(feedback: true)
    }

    func toggleConversationInput(_ lang: Language) async {
        guard usesDualConversationButtons, inputFinishToken == nil, !switchingConversation else { return }
        dismissToast()
        let sameLanguage = conversationInputLanguage == lang
        if conversationInputLanguage != nil || isRunning { endConversationInput() }
        if sameLanguage { return }

        let token = UUID()
        startToken = token
        conversationInputLanguage = lang
        // 采集层先交完上一种语言的尾句，下一轮再切换语言和听写引擎。
        let flush = conversationFlush
        await flush?.value
        for _ in 0..<8 {
            guard startToken == token, !appleEngines.isEmpty, working else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard startToken == token, talkMode, conversationInputLanguage == lang else { return }
        talkLang = lang
        if !(await beginListening(intent: token, feedback: true)), startToken == token {
            conversationInputLanguage = nil
            talkLang = nil
            finishConversationReading(intent: token, clearActivity: false)
        }
    }

    private func endConversationInput() {
        conversationInputLanguage = nil
        let token = UUID()
        startToken = token
        guard isRunning else {
            capture.stop()
            finishConversationReading(intent: token)
            return
        }
        hearLog("对话翻译：暂停收音")
        finishingInput = true
        isRunning = false
        meter.level = 0
        UIApplication.shared.isIdleTimerDisabled = false
        muteGeneration += 1
        capture.muted = false
        translator.cancelPreview()
        cancelASRPreview()
        cancelMTPreview()
        conversationFlush = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
                self.capture.stop { completion.resume() }
            }
            guard !Task.isCancelled else { return }
            self.conversationFlush = nil
            self.finishingInput = false
            self.talkLang = nil
            self.finishedSeg = max(self.finishedSeg, self.currentSeg)
            self.partial = ""; self.partialTranslation = ""; self.partialTranslationTarget = nil; self.partialSource = nil
            self.scheduleMicrophoneRelease()
            self.finishConversationReading(intent: token)
        }
    }

    private func finishConversationReading(intent: UUID, clearActivity: Bool = true) {
        Task { [weak self] in
            guard let self else { return }
            await self.conversationFlush?.value
            for _ in 0..<150 {
                guard intent == self.startToken, self.working else { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard intent == self.startToken, self.conversationInputLanguage == nil, !self.isRunning else { return }
            self.talkLang = nil
            self.stopAppleASR()
            if clearActivity { self.activity = "" }
            self.kickReader()
        }
    }

    /// 开始收音的令牌：每次开始换一个新的。
    /// 用户在等待（要麦克风权限、等模型加载）期间又点了暂停、切模式了，
    /// 令牌就变了，这一次启动自动作废——不会莫名其妙开始录音。
    private var startToken = UUID()
    private var microphoneStartToken: UUID?

    /// 打开麦克风开始收音（实时翻译和对话翻译共用）
    private var needsMemoryRecovery = false
    private var reclaimingMemory = false
    private var repeatedMemoryWarning = false
    private var lastMemoryWarning: ContinuousClock.Instant?
    private var localOptionalWorkPaused = false
    private var senseRequiresRestart = false
    private static let senseRestartMessage = "本机识别未能恢复，请关闭后重新打开听见。"
#if DEBUG || HEAR_SPEECH_REGRESSION
    private var runningSpeechRegression = false

    func runSpeechRegression(progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        guard !runningSpeechRegression, !isRunning, !finishingInput, microphoneStartToken == nil,
              recognition.queue.isIdle, !isAnyModelLoading, !reclaimingMemory,
              !recognition.isRecovering, !senseRequiresRestart else {
            throw NSError(domain: "Hear.SpeechRegression", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "请先结束录音并等待模型就绪，再运行回归。",
            ])
        }
        guard let folder = SenseVoiceRecognizer.installedFolder() else {
            throw NSError(domain: "Hear.SpeechRegression", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "请先安装本机 SenseVoice。",
            ])
        }
        runningSpeechRegression = true
        defer { runningSpeechRegression = false }
        let wasLoaded = await sense.isLoaded
        let result: Result<URL, Error>
        do {
            result = .success(try await SpeechRegression.run(sense: sense, folder: folder, config: segmenterConfig(),
                                                              reportProgress: progress))
        } catch {
            result = .failure(error)
        }
        if !wasLoaded, !useSense { await sense.unload() }
        return try result.get()
    }
#endif
    private var inputFinishToken: UUID?
    private var switchingConversation = false

    private func beginListening(intent: UUID? = nil, feedback: Bool = false) async -> Bool {
#if DEBUG || HEAR_SPEECH_REGRESSION
        guard !runningSpeechRegression else { return false }
#endif
        guard inputFinishToken == nil, !switchingConversation, !reclaimingMemory,
              microphoneStartToken != startToken else { return false }
        let token = intent ?? UUID()
        if intent == nil { startToken = token }
        guard token == startToken else { return false }
        microphoneStartToken = token
        defer { if microphoneStartToken == token { microphoneStartToken = nil } }
        if useSense, senseRequiresRestart {
            showToast(Self.senseRestartMessage, seconds: 6)
            return false
        }
        let resumeOptionalWork = localOptionalWorkPaused && Self.freeMB() >= 850
        if resumeOptionalWork { localOptionalWorkPaused = false }
        if needsMemoryRecovery {
            needsMemoryRecovery = false
            await loadModels()
            guard token == startToken else { return false }
        }
        // 还没选引擎：提示去设置里选
        if asrEngine.isEmpty || translationEngine.isEmpty {
            showToast("请先到 功能设置 → 引擎 里选择语音识别和翻译引擎")
            return false
        }
        // 本地模型还没加载好：不开始，在按钮上方提示一下
        // 用 isAnyModelLoading（把声音克隆也算进去），不然刚提示"可以开始翻译"、
        // 其实还有模型在加载的时候，一按就说不让开始
        if isAnyModelLoading {
            // 按钮上方本来就显示"正在准备模型 · N 秒"，不用再弹一次提示
            return false
        }
        let selectedModelsLoaded = await allSelectedLocalModelsLoaded()
        guard token == startToken else { return false }
        guard selectedModelsLoaded else {
            showToast("还有本地模型没有加载完成，请稍候", seconds: 3)
            return false
        }
        if useSense, await sense.isDecoding {
            guard token == startToken else { return false }
            showToast("本机识别还在收尾，请稍后再试")
            return false
        }
        guard token == startToken else { return false }
        guard phase == .ready else { return false }
        let permissionGranted = await AudioCapture.requestPermission()
        // 等权限的时候用户已经松手/停了：这一次启动作废
        guard token == startToken else {
            hearLog("开始收音：等待期间启动请求已取消", .info)
            return false
        }
        guard permissionGranted else {
            activity = "请在 设置 → 听见 里允许使用麦克风"
            return false
        }
        if resumeOptionalWork, needsLocalVoiceClone, !(await cloner.isLoaded) {
            guard token == startToken, !reclaimingMemory else { return false }
            await loadClonerIfNeeded()
        }
        guard token == startToken, !reclaimingMemory else { return false }
        // 已经插着耳机就用耳机朗读（除非用户手动选了扬声器）；耳机已拔掉就改回扬声器
        // 注意：这里不强制改输出路由，避免开始聆听时麦克风被重新配置
        // 音频会话也先不碰：capture.start() 会按"要麦克风"把会话设成 .playAndRecord。
        // 在这之前先改一次类别，等于让音频路由白白变一次，
        // 系统会重新配置引擎，麦克风刚接上又被打断（以前就是这样：刚开始就听不稳）。
        let hasHeadphones = AudioRoute.headphonesLikelyConnected()
        if outputMode == .speaker, hasHeadphones, !manualSpeaker {
            outputMode = .headphones
            hearLog("检测到耳机，朗读改为耳机")
        }
        if outputMode == .headphones, !hasHeadphones { outputMode = .speaker }
        headsetConnected = hasHeadphones
        if inputSource == "headset", !hasHeadphones { inputSource = "phone" }   // 没耳机就用手机麦克风
        if feedback { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        activity = "正在打开麦克风…"
        if saveFullRecording {
            CloudSync.shared.restoreCloudRecordingToLocalIfNeeded(conversationID)
            CloudSync.shared.activeRecordingID = conversationID
        } else {
            CloudSync.shared.activeRecordingID = nil
        }
        fullRecorder.configure(enabled: saveFullRecording, conversationID: conversationID)
        do {
            try await capture.start()
        } catch is CancellationError {
            return false
        } catch {
            guard token == startToken else { return false }
            // 刚加载完声音克隆模型时，内存紧张会让麦克风起不来（硬件直接拒绝启动）：
            // 先把声音克隆模型卸掉再试一次，麦克风通常就能正常起来
            let clonerLoaded = await cloner.isLoaded
            guard token == startToken else { return false }
            if clonerLoaded {
                hearLog("麦克风启动失败，先卸载声音克隆模型再试一次", .warning)
                await cloner.unload()
                guard token == startToken else { return false }
                do {
                    try await capture.start()
                } catch is CancellationError {
                    return false
                } catch {
                    guard token == startToken else { return false }
                    hearLog("麦克风启动失败：\(error)", .error)
                    activity = "麦克风启动失败：\(error.localizedDescription)"
                    showToast("麦克风启动失败，请看日志", seconds: 4)
                    return false
                }
            } else {
                hearLog("麦克风启动失败：\(error)", .error)
                activity = "麦克风启动失败：\(error.localizedDescription)"
                showToast("麦克风启动失败，请看日志", seconds: 4)
                return false
            }
        }
        guard token == startToken else {
            // 开麦异步排队期间用户已点停止或切模式：立刻停麦，避免系统橙色麦灯常亮
            capture.stop()
            scheduleMicrophoneRelease()
            return false
        }
        AudioRoute.apply(outputMode)
        isRunning = true
        if !talkMode {
            HearLiveActivityController.shared.start(liveActivityState())
            liveActivityHeartbeat?.cancel()
            liveActivityHeartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { return }
                    guard let self, self.isRunning else { return }
                    self.publishLiveActivity()
                }
            }
        }
        if dualLive { startAppleASR() }
        if talkMode, let l = talkLang {
            hearLog("对话翻译：开始收听\(l.displayName)")
            activity = "正在听\(l.name)"
        } else {
            hearLog("开始实时翻译：\(langA.displayName) ⇄ \(langB.displayName)，朗读\(outputMode == .speaker ? "扬声器" : "耳机")")
            activity = "正在聆听"
        }
        UIApplication.shared.isIdleTimerDisabled = true
        return true
    }

    /// 在实时翻译按钮上方显示几秒钟的提示
    func showToast(_ text: String, seconds: Double = 2.5, placement: ToastPlacement = .controls) {
        activeToast = Toast(text: text, placement: placement)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.activeToast = nil
        }
    }

    /// 立刻收起提示（用户点了按钮就不要再占着屏幕）
    func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        activeToast = nil
    }

    /// 停完以后把麦克风放开：别的 App（比如录音机）要能录到声音。
    ///
    /// 音频会话一直停在"可录音"而且是激活的，麦克风就被我们占住了，
    /// 别的 App 录出来是静音。正在朗读的时候不能停会话（会把声音切断），
    /// 就等读完再放。
    private func releaseMicrophoneIfIdle(attempt: Int = 0) {
        guard !capture.isRunning else { return }      // 还在收音，不能放
        if speaker.isPlaying {
            // 还在出声：等一会儿再看（最多等 3 秒）。
            // 播完以后播放器会回调 onPlaybackFinished，那时再看一次，
            // 免得"等超时了就放弃了"，音频会话一直占着不放。
            if attempt < 10 {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self?.releaseMicrophoneIfIdle(attempt: attempt + 1)
                }
            }
            return
        }
        // 真要放开之前再看一眼：
        // 刚才判断"没在出声"到现在，可能刚好开始播下一句——
        // 那就不能把会话停掉（会把声音切断）
        if speaker.isPlaying { return }
        capture.releaseSession()
    }

    private func reclaimMemory() async {
        let now = ContinuousClock.now
        let repeated = lastMemoryWarning.map { $0.duration(to: now) <= .seconds(8) } ?? false
        lastMemoryWarning = now
        if reclaimingMemory {
            repeatedMemoryWarning = true
            return
        }
        reclaimingMemory = true
        repeatedMemoryWarning = repeated
        defer { reclaimingMemory = false }
        hearLog("收到内存不足警告：可用内存 \(Self.freeMB()) MB", .warning)
        CrashGuard.shared.updateMarker(memoryWarning: true)
        localOptionalWorkPaused = true
        cloneLoadTask?.cancel()
        if !usingCloudClone { clearCloneTasks() }
        if !usingCloudASR { speakerQueue.cancel() }
        await CloneCache.shared.evictMemory()
        await cloner.unload()
        await localSpeaker.unload()
        let free = Self.freeMB()
        let usesLocalCore = useSense || translationEngine == "local"
        guard usesLocalCore, !needsMemoryRecovery, repeatedMemoryWarning || free < 450 else {
            hearLog("已释放本机声音克隆和说话人资源，可用内存 \(free) MB")
            return
        }
        loadGen += 1
        stop(readAfter: false)
        phase = .checking
        if !senseRequiresRestart { await sense.unload() }
        await translator.unload()
        needsMemoryRecovery = true
        phase = .ready
        showToast("内存仍不足，已暂停翻译。可以重新开始。", seconds: 6)
        hearLog("内存压力持续，已暂停并卸载本机识别和翻译", .warning)
    }

    /// 延后一点再放开麦克风。
    /// 停完以后马上要朗读的话，先让朗读把音频会话激活起来，别把声音切断了。
    private func scheduleMicrophoneRelease() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.releaseMicrophoneIfIdle()
        }
    }

    /// Stop accepting input, then give the VAD tail and already queued audio
    /// a chance to produce original text before archiving or ending the session.
    private func finishRecording(readAfter: Bool = true) async {
        guard inputFinishToken == nil else { return }
        let token = UUID()
        inputFinishToken = token
        defer { if inputFinishToken == token { inputFinishToken = nil } }
        startToken = UUID()
        finishingInput = true
        isRunning = false
        endLiveActivity()
        meter.level = 0
        UIApplication.shared.isIdleTimerDisabled = false
        await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
            capture.stop { completion.resume() }
        }
        guard inputFinishToken == token else { return }
        finishingInput = false
        scheduleMicrophoneRelease()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(12))
        while !recognition.queue.isIdle, clock.now < deadline,
              inputFinishToken == token {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { break }
        }
        guard inputFinishToken == token else { return }
        stop(readAfter: false, keepTranslations: true)
    }

    /// readAfter：停止后是否接着朗读没读的句子（只有用户自己点停止时才读）
    func stop(readAfter: Bool = true, keepTranslations: Bool = false) {
        inputFinishToken = nil
        let wasRunning = isRunning
        if wasRunning { hearLog("停止实时翻译") }
        restartTask?.cancel()
        restartTask = nil
        conversationInputLanguage = nil
        conversationFlush?.cancel()
        conversationFlush = nil
        finishingInput = false
        talkLang = nil
        startToken = UUID()          // 正在等待的"开始收音"全部作废
        capture.stop()
        fullRecorder.flush()
        if CloudSync.shared.activeRecordingID == conversationID {
            CloudSync.shared.activeRecordingID = nil
            if saveFullRecording {
                CloudSync.shared.scheduleSync(delay: 1.5)
            }
        }
        muteGeneration += 1
        capture.muted = false
        isRunning = false
        endLiveActivity()
        meter.level = 0
        activity = ""
        UIApplication.shared.isIdleTimerDisabled = false
        runGen += 1
        recognition.cancel()
        translations.cancelCorrection()
        if keepTranslations {
            // 正常停录让已提交的译文继续；作废尚未交给翻译线的旧识别任务。
            jobTokens = jobTokens.filter { translations.submitted($0.key) }
        } else {
            let store = ConversationStore.shared
            for (id, page) in translations.pendingPages where page != conversationID {
                guard let item = store.load(page)?.items.first(where: { $0.id == id }) else { continue }
                store.commitTranslation(conversationID: page, itemID: id, expectedSource: item.sourceText,
                                        translation: "（翻译失败：收尾任务已中断）", done: true)
            }
            translations.cancelTranslations()
            jobTokens.removeAll()
            translator.cancelCurrent()
        }
        translator.cancelPreview()
        cancelASRPreview()
        cancelMTPreview()
        stopLiveEngine()
        stopAppleASR()
        finishedSeg = max(finishedSeg, currentSeg)
        // 麦克风放开（不占着，别的 App 才能录到声音）
        scheduleMicrophoneRelease()
        // 整句话可能还没识别完（界面上是虚线框）：按了暂停，这句也要留在记录里，不能丢
        stopFlushItemID = nil
        stopFlushSegID = currentSeg
        flushPartial()
        partial = ""; partialTranslation = ""; partialTranslationTarget = nil; partialSource = nil
        finishUnfinished()
        // 录音结束后不再自动补读（仅在聆听中由「自动朗读译文」开关统一控制）
        readIndex = items.count
        if pendingLocalSwitch {
            pendingLocalSwitch = false
            Task { await switchToLocal() }
        }
    }

    /// 停止时还没说完的那一句（实时气泡里的虚线内容）：变成一条正常的记录留下来
    private func flushPartial() {
        var text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("…") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard !text.isEmpty, text != "…", SpeechTextFilter.isMeaningful(text) else { return }
        let src = partialSource ?? (!talkMode ? langA : (lastLangID == langB.id ? langB : langA))
        let tgt = !talkMode ? meetingTargetLang : (src == langA ? langB : langA)
        var item = TranslationItem(source: src, target: tgt, sourceText: text,
                                   sourceSide: (!talkMode || src == langA) ? .left : .right)
        if let range = fullRecorder.timeRangeToCurrent(startFrame: currentSegStartFrame) {
            item.audioStartSec = range.start
            item.audioEndSec = range.end
        }
        carryPreview(into: &item)
        items.append(item)
        stopFlushItemID = item.id      // 断句器最后一段声音会挂到这条上
        hearLogText("暂停：保留了一句还没说完的（", String(text.prefix(40)) + "）")
        persist()
    }

    private func carryPreview(into item: inout TranslationItem) {
        guard !partialTranslation.isEmpty else { return }
        item.translated = partialTranslation
        item.previewTarget = partialTranslationTarget == item.target ? nil : partialTranslationTarget
        item.beginTranslationRevision()
    }

    /// 停止时还没翻译完的句子：原文还在的就留着，并且接着把译文补上
    /// （一个字都没有的才删掉，不然按暂停会把刚识别出来的内容丢掉）
    private func finishUnfinished() {
        for index in items.indices where !items[index].done {
            let item = items[index]
            guard !translations.submitted(item.id) else { continue }
            guard Self.hasRealText(item.sourceText) else {
                items[index].sourceText = "（这段识别未完成）"
                items[index].applyTranslation("（翻译失败：没有可用原文）", done: true)
                continue
            }
            items[index].beginTranslationRevision()
            let token = UUID()
            jobTokens[item.id] = token
            enqueueTranslation(MTJob(itemID: item.id, token: token, gen: runGen,
                                      text: item.sourceText, src: item.source, tgt: item.target,
                                      samples: [], isApple: false))
        }
        persist()
    }

    func swapLanguages() {
        setLanguagePair(left: langB, right: langA)
    }

    func clear() {
        stopReading()
        items.removeAll(); partial = ""; partialTranslation = ""; partialTranslationTarget = nil; partialSource = nil
        readIndex = 0
    }

    /// 左上角“清空”：清掉当前屏幕（内容已自动保存在历史里），正在聆听时继续聆听，记到新的一页
    func clearPage() {
        if isRunning || finishingInput {
            newConversation(summarize: false, resumeListening: isRunning && !talkMode)
        } else {
            guard !switchingConversation, inputFinishToken == nil else { return }
            archiveConversation(summarize: false)
        }
    }

    // MARK: - 对话保存 / 新建

    /// 把当前页保存到历史（保留已有的总结）
    ///
    /// 已经译完的照存；**还没译完但已经认出原文的也存**：
    /// 停完马上新建对话的时候，补翻译的活儿还在后台跑，
    /// 原文要是没存下来，那句话就彻底没了。
    private var transcriptSaveTask: Task<Void, Never>?

    private func persistSoon() {
        guard transcriptSaveTask == nil else { return }
        transcriptSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            self?.persist()
        }
    }

    func persist() {
        transcriptSaveTask?.cancel()
        transcriptSaveTask = nil
        let saved = items.filter { $0.done || Self.hasRealText($0.sourceText) }.map { item in
            var snapshot = item
            snapshot.translationPending = nil
            return snapshot
        }
        ConversationStore.shared.saveTranscript(id: conversationID, createdAt: conversationCreated,
                                                 langA: langA, langB: langB, items: saved)
    }

    /// 这句原文是真的有内容（不是"…"这种占位）
    private static func hasRealText(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t != "…"
    }

    /// 把译文写回去。
    ///
    /// 用户可能已经新建对话了（当前页已经不是刚才那页了），
    /// 那就写回存档里的那一条——不能因为切页就把这句话弄丢。
    private func applyTranslation(_ id: UUID, _ text: String, done: Bool,
                                  conversation: UUID, expectedSource: String) {
        if conversation == conversationID, let item = items.first(where: { $0.id == id }) {
            guard item.sourceText == expectedSource else { return }
            update(id, text, done: done)
            persist()
        } else {
            ConversationStore.shared.commitTranslation(conversationID: conversation, itemID: id,
                                                      expectedSource: expectedSource, translation: text, done: done)
        }
    }

    /// 等这一页的译文补完（最多等这么久）。
    /// 停录时没译完的句子会在后台接着译，等它们译完再总结才对。
    private func waitTranslationsDone(conversation: UUID, seconds: Double = 20) async {
        let store = ConversationStore.shared
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let c = store.load(conversation) else { return }
            if !c.items.contains(where: { !$0.done }) { return }   // 都译完了
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// 新建一页。summarize = true 时在后台用默认模板总结刚才那一页
    func newConversation(summarize: Bool, resumeListening: Bool = false) {
        guard !switchingConversation, inputFinishToken == nil else { return }
        switchingConversation = true
        if microphoneStartToken != nil, !isRunning { capture.stop() }
        startToken = UUID()
        Task { [weak self] in
            guard let self else { return }
            defer { self.switchingConversation = false }
            if self.isRunning || self.finishingInput { await self.finishRecording(readAfter: false) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !self.speakerQueue.isIdle, ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { break }
            }
            self.archiveConversation(summarize: summarize)
            if resumeListening {
                self.switchingConversation = false
                _ = await self.beginListening()
            }
        }
    }

    private func archiveConversation(summarize: Bool) {
        persist()
        fullRecorder.close()
        if CloudSync.shared.activeRecordingID == conversationID {
            CloudSync.shared.activeRecordingID = nil
        }
        if saveFullRecording {
            CloudSync.shared.scheduleSync(delay: 1.0)
        }
        segStartFrames.removeAll()
        let oldID = conversationID
        // 有内容就算：原文已经认出来了、译文还在补，也值得总结
        let hadContent = items.contains { $0.done || Self.hasRealText($0.sourceText) }
        clear()
        conversationID = UUID()
        conversationCreated = Date()
        lastLangID = nil
        hearLog("新建对话\(summarize && hadContent ? "，后台总结上一页" : "")")
        if summarize && hadContent {
            // 等这一页的译文补完再总结：
            // 立刻总结的话，用的是半截内容（译文还没出来的那些句子就没了）。
            Task { [weak self] in
                await self?.waitTranslationsDone(conversation: oldID)
                SummaryService.shared.generate(conversationID: oldID,
                                              templateID: SummaryTemplate.defaultID)
            }
        }
    }

    // MARK: - 朗读队列
    /// App 现在在后台吗（用户切到别的 App 了）
    private var inBackground = false
    /// 每次朗读请求的身份。切到后台就换一个新的：
    /// 还没开始播的请求全部作废（后台不自动出声，
    /// 克隆声音回来的时候也不该突然播出来）。
    private var playbackToken = UUID()
    /// 已经跟苹果要过语言包下载了（别反复弹窗）
    private var appleDownloadAsked = false
    //
    // 戴耳机：译文出来就从耳机读，边听边读，麦克风不暂停（耳机声音不会被录进去）。
    // 扬声器：聆听中不读；停止实时翻译后，从上次没读完的那句开始往后读；
    //        再点开始实时翻译，立刻停止朗读（实时翻译优先），下次从被打断的那句重新读。
    // 点某一句：从这句开始往后读；之后的自动朗读也从这句往后接着读。

    /// 现在能不能自动朗读
    ///
    /// 只有「要不要出声」这一件事受后台影响：
    /// 翻译、声音克隆的请求在后台照旧发出去（电脑那边照常干活）。
    private var autoReadAllowed: Bool {
        // 仅在正在聆听且开启「自动朗读译文」时自动播报（扬声器与耳机统一受 speakOutput 控制）；
        // 录音结束后不再自动补读。
        !inBackground && speakOutput && isRunning
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
            // 读完了：没在收音的话就把麦克风放开
            releaseMicrophoneIfIdle()
        }
        while !Task.isCancelled, g == readerGen, readIndex < items.count {
            let item = items[readIndex]
            guard item.done else { break }                  // 还在翻译，翻译完会再叫醒
            if !oneShot && !autoReadAllowed { break }
            if item.canReadAloud {
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
        speakingID = nil
        if wasReading { speaker.stop() }
        muteGeneration += 1
        capture.muted = false
        // 朗读停了：没在收音的话就把麦克风放开
        scheduleMicrophoneRelease()
    }

    /// 点某一句：从这句开始往后读；正在读这句时再点一下就停止
    func tapRead(_ item: TranslationItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { replay(item); return }
        if readingID == item.id { stopReading(); return }
        clonePipeline.allowRetry(item.id)
        stopReading()
        readIndex = i
        // 点读与自动朗读行为保持一致：扬声器模式下 speak() 会自动静音麦克风并在播完 400ms 后恢复，
        // 戴耳机模式保持全双工直接朗读。
        // 能连续读（自动朗读开、戴耳机，或已停止聆听）就一直往后读；否则只读这一句
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

    private struct PreviewTiming {
        let segment: Int
        let start: ContinuousClock.Instant
        var loggedSource = false
        var loggedTranslation = false
    }

    private var previewTiming: PreviewTiming?

    private func handle(_ e: Segmenter.Event) {
        // 已经停止：停止前还没送到的断句事件一律丢弃
        // （最后那句的"结束"要接住：它带着这段声音，声音克隆要用）
        if !isRunning && !finishingInput && inputFinishToken == nil {
            switch e {
            case .started, .partial: return
            case .ended: break
            default: break
            }
        }
        switch e {
        case .level(let l):
            meter.level = isRunning ? l : 0
        case .started(let id, let startFrame):
            cancelMTPreview()
            currentSeg = id
            currentSegStartFrame = startFrame
            segStartFrames[id] = startFrame
            previewTiming = PerformanceLog.isEnabled ? PreviewTiming(segment: id, start: .now) : nil
            partialSeg = id
            partial = "…"; partialTranslation = ""; partialTranslationTarget = nil; partialSource = forcedLang
            live?.markSegmentStart(id, frame: startFrame)
            for eng in appleEngines { eng.markSegmentStart(id, frame: startFrame) }
            hearLog("断句：检测到说话（第 \(id) 句）")
        case .partial(let id, let samples):
            // 系统听写在工作时由它出原文；否则用当前引擎识别最新的声音
            guard !liveActive, appleEngines.isEmpty else { return }
            previews.recognition.submit((id, samples)) { [weak self] generation in
                await self?.previewLoop(generation)
            }
        case .ended(let id, let samples, let endFrame, let confirmedSpeech):
            let segStart = segStartFrames.removeValue(forKey: id) ?? currentSegStartFrame
            let audioRange = fullRecorder.timeRange(startFrame: segStart, endFrame: endFrame)
            let alreadyDone = id <= finishedSeg
            finishedSeg = max(finishedSeg, id)
            live?.markSegmentEnd(id, frame: endFrame)
            for eng in appleEngines { eng.markSegmentEnd(id, frame: endFrame) }
            hearLog("断句：一句话结束，时长 \(String(format: "%.1f", Double(samples.count) / 16000)) 秒")
            // 立刻打断这句的实时预览，让整句识别和翻译马上开始
            if partialSeg == id {
                translator.cancelPreview()
                cancelASRPreview()
                cancelMTPreview()
            }
            // 先把这句（实时预览的文字）放进对话，整句识别完再替换，屏幕上不会空一下
            let mine = partialSeg == id
            let forced = forcedLang
            let meetingMode = !talkMode
            let src = forced ?? (mine ? partialSource : nil)
                ?? (meetingMode ? langA : ((lastLangID == langB.id) ? langB : langA))
            let tgt = meetingMode ? meetingTargetLang : (src == langA ? langB : langA)
            // 已经停下来了：这一句不会再走整句识别，
            // 但这段声音要留下来（声音克隆的样本），译文等下接着补。
            // 收尾中的最后一句仍需完成识别。
            if !isRunning && !finishingInput && inputFinishToken == nil {
                if id == stopFlushSegID, let fid = stopFlushItemID {
                    stopFlushItemID = nil
                    if let idx = items.firstIndex(where: { $0.id == fid }) {
                        if let audioRange, items[idx].audioStartSec == nil {
                            items[idx].audioStartSec = audioRange.start
                            items[idx].audioEndSec = audioRange.end
                            persist()
                        }
                        rememberReference(fid, samples: samples, text: items[idx].sourceText)
                        hearLog("暂停：这一段声音留给声音克隆用")
                        // 样本到手了就赶紧去生成（等到朗读时现做，要多等好几秒）
                        if items[idx].done, !items[idx].translated.isEmpty {
                            _ = prepareClone(fid)
                        }
                    }
                }
                finishedSeg = max(finishedSeg, id)
                return
            }
            // 上一轮停下来残留的断句事件，别重复加一条
            if alreadyDone {
                hearLog("断句：第 \(id) 句是重复事件，跳过", .warning)
                return
            }
            var item = TranslationItem(source: src, target: tgt,
                                       sourceText: mine && !partial.isEmpty ? partial : "…",
                                       sourceSide: (meetingMode || src == langA) ? .left : .right)
            if let audioRange {
                item.audioStartSec = audioRange.start
                item.audioEndSec = audioRange.end
            }
            if mine { carryPreview(into: &item) }
            items.append(item)
            if mine { partial = ""; partialTranslation = ""; partialTranslationTarget = nil; partialSource = nil }
            previews.textBySegment[id] = nil
            // 声音样本先记下来（声音克隆要用）：
            // 整句识别要好几秒，用户随时可能点停止，
            // 等识别完再记就来不及了（那样只能退回系统声音朗读）
            rememberReference(item.id, samples: samples, text: item.sourceText)
            let token = UUID()
            jobTokens[item.id] = token
            let job = ASRJob(itemID: item.id, segID: id, samples: samples, token: token, generation: runGen,
                             left: langA, right: langB, forced: forced, fallback: src,
                             confirmedSpeech: confirmedSpeech)
            let local = useSense
            let seconds = Double(samples.count) / 16_000
            let timeout = usingCloudASR ? CloudInferencePolicy.asrBudget(forSamples: samples.count) + 5
                : min(28, 8 + seconds + (usingAppleASR ? 3 : 0))
            recognition.queue.submit(job, timeout: .seconds(timeout), onOverflow: { [weak self] job in
                self?.markJobFailed(job.itemID, token: job.token, reason: "识别恢复期间音频已积满")
            }) { [weak self] job in
                guard let self, self.runGen == job.generation else { return }
                if self.usingAppleASR {
                    await self.processApple(job)
                } else {
                    await self.process(job)
                }
            } timedOut: { [weak self] job in
                guard let self, self.isCurrentJob(job.itemID, token: job.token) else { return }
                self.markJobFailed(job.itemID, token: job.token, reason: "识别超时")
                if local, self.useSense, !self.recognition.isRecovering { self.recoverSenseVoice() }
            }
            recognition.keepRecoveryBuffer()
        case .discarded(let id):
            segStartFrames.removeValue(forKey: id)
            finishedSeg = max(finishedSeg, id)
            if partialSeg == id {
                cancelMTPreview()
                partial = ""; partialTranslation = ""; partialTranslationTarget = nil; partialSource = nil
            }
            previews.textBySegment[id] = nil
        case .noise(let n, let t):
            if isRunning { hearLog(String(format: "环境噪声 %.0f dB，说话触发阈值 %.0f dB", n, t)) }
        }
    }

    // MARK: - 实时预览（说话过程中）

    /// 识别线：上一次识别一结束就拿最新的声音再识别，不等翻译
    private func cancelASRPreview() {
        previews.recognition.cancel()
        previews.localRecognitionCadence = PreviewCadence()
    }

    private func previewLoop(_ generation: UUID) async {
        while !Task.isCancelled, let newest = previews.recognition.newest(for: generation) {
            // 正式识别优先。翻译队列不妨碍下一句的原文预览。
            let cloudPreview = usingCloudASR
            if !cloudPreview,
               let next = previews.localRecognitionCadence.waitUntil(segment: newest.id, now: .now) {
                do { try await Task.sleep(until: next, clock: ContinuousClock()) } catch { return }
                // While waiting the latest snapshot may have been replaced.
                continue
            }
            guard let job = previews.recognition.next(for: generation) else { return }
            let id = job.id
            guard phase == .ready, isRunning, !liveActive, recognition.canPreview,
                  cloudPreview || (!recognition.isRecovering && !senseRequiresRestart),
                  id == currentSeg, id > finishedSeg else { continue }
            if cloudPreview, let retryAt = previews.cloudRecognitionRetryAt, ContinuousClock.now < retryAt { continue }
            let gen = runGen
            let a = langA, b = langB
            let forced = forcedLang
            let meetingMode = !talkMode
            let meetingTarget = meetingTargetLang
            let fallback = forced?.id ?? (meetingMode ? a.id : ((lastLangID == b.id) ? b.id : a.id))
            let cands = meetingMode ? supportedLanguages.map(\.id) : [a.id, b.id]
            // 只识别最近 10 秒，长句也跟得上
            let maxN = 16_000 * 10
            let clipped = job.samples.count > maxN
            let clip = clipped ? Array(job.samples.suffix(maxN)) : job.samples
            let started = ContinuousClock.now
            let r: (lang: String, text: String, correctionAddress: String?, speakerAddress: String?, observedLanguage: String?)
            do {
                r = try await sentenceRecognizer.recognize(clip, candidates: cands, fallback: fallback, preview: true)
            } catch {
                guard !Task.isCancelled, previews.recognition.owns(generation), gen == runGen else { return }
                if error is CancellationError { continue }
                if (error as? CloudClient.CloudError)?.isBusy == true {
                    previews.cloudRecognitionRetryAt = ContinuousClock.now.advanced(by: .seconds(2))
                    hearLog("云端繁忙，实时识别预览稍后恢复")
                } else {
                    hearLog("实时识别失败：\(error)", .warning)
                }
                continue
            }
            guard !Task.isCancelled, previews.recognition.owns(generation), gen == runGen else { return }
            let ended = ContinuousClock.now
            if !cloudPreview { previews.localRecognitionCadence.completed(segment: id, started: started, ended: ended) }
            let elapsed = started.duration(to: ended).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            hearLogText("实时识别 \(String(format: "%.1f", seconds))s：",
                        String(r.1.prefix(30)))
            guard isRunning, id == currentSeg, id > finishedSeg, partialSeg == id,
                  SpeechTextFilter.isMeaningful(r.text),
                  !(outputMode == .speaker && isLikelySpokenEcho(r.text)),
                  let language = forced?.id ?? SpeechTextFilter.resolveLanguage(r.text, detected: r.lang,
                                                                                 candidates: cands, fallback: fallback)
            else { continue }
            let src = meetingMode ? Language.find(language) : (language == b.id ? b : a)
            let tgt = meetingMode ? meetingTarget : (src == a ? b : a)
            partialSource = src
            // 长句：预览窗口只留最近 10 秒，开头会被切掉。
            // 已经认出来的开头别让它消失：
            // 把新快照接到"已经稳定的那一段"后面（滑窗时新快照会丢掉开头、
            // 尾巴又变长了，前后都对不上的时候用重叠部分接上）。
            let stable = previews.textBySegment[id] ?? ""
            let merged = clipped ? SessionPreviewPipeline.merge(stable, r.1) : r.1
            previews.textBySegment[id] = merged      // 记下稳定下来的那段（下次好接）
            partial = (clipped ? "…" : "") + merged
            requestPreviewTranslation(id: id, text: partial, src: src, tgt: tgt)
        }
    }

    /// 系统听写给出的最新文字
    private func liveText() {
        guard liveActive, isRunning, currentSeg > finishedSeg, partialSeg == currentSeg,
              let live else { return }
        let text = live.segmentText(currentSeg).text
        guard SpeechTextFilter.isMeaningful(text),
              !(outputMode == .speaker && isLikelySpokenEcho(text)) else { return }
        let src = (live.languageID == langB.id) ? langB : langA
        partialSource = src
        partial = text
        requestPreviewTranslation(id: currentSeg, text: text, src: src, tgt: src == langA ? langB : langA)
    }

    /// 翻译线：只翻最新的原文，翻完一次再拿最新的，不断修正译文
    private func requestPreviewTranslation(id: Int, text: String, src: Language, tgt: Language) {
        if let timing = previewTiming, timing.segment == id, !timing.loggedSource {
            previewTiming?.loggedSource = true
            let engine: String
            if liveActive || !appleEngines.isEmpty {
                engine = "Apple 听写"
            } else {
                engine = usingCloudASR ? "云端·\(Self.cloudSchemeName(cloudASRScheme))" : "SenseVoice"
            }
            PerformanceLog.record("首条预览原文", engine: engine, since: timing.start)
        }
        previews.translation.submit((id, text, src, tgt)) { [weak self] loop in
            await self?.previewTranslateLoop(loop)
        }
    }

    private func cancelMTPreview() {
        previews.translation.cancel()
        previews.translationRequest = nil
    }

    private func previewTranslateLoop(_ loop: UUID) async {
        while !Task.isCancelled, let p = previews.translation.next(for: loop) {
            let id = p.id
            guard isRunning, id == currentSeg, id > finishedSeg else { continue }
            let gen = runGen
            let request = UUID()
            let engine = translationEngine
            previews.translationRequest = request
            let source = TranslationSource.currentSegment(p.text, language: p.src,
                                                          after: useContext ? previousSegment() : nil)
            let publish: @MainActor @Sendable (String, Bool) -> Void = { [weak self] text, final in
                guard let self, self.previews.translationRequest == request, gen == self.runGen,
                      id == self.partialSeg, id > self.finishedSeg else { return }
                if final { self.previews.translationRequest = nil }
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                // A new draft starts at token one; keep the previous readable draft until it catches up.
                if !final, value.count < self.partialTranslation.count { return }
                self.partialTranslationTarget = p.tgt
                self.partialTranslation = value
                if let timing = self.previewTiming, timing.segment == id, !timing.loggedTranslation {
                    self.previewTiming?.loggedTranslation = true
                    PerformanceLog.record("首条预览译文", engine: engine, since: timing.start)
                }
                self.publishLiveActivity()
            }
            if usingAppleTranslation {
                var out = try? await systemTranslator.translate(source, from: p.src, to: p.tgt)
                if (out ?? "").isEmpty {
                    out = try? await fallbackTranslate(source, from: p.src, to: p.tgt)
                }
                publish(out ?? "", true)
                continue
            }
            let prompt = PromptBuilder.build(text: source, from: p.src, to: p.tgt,
                                             glossary: PromptBuilder.parseGlossary(glossary))
            if usingCloudMT {
                if let retryAt = previews.cloudTranslationRetryAt, ContinuousClock.now < retryAt { continue }
                do {
                    let out = try await cloud.translate(prompt: prompt, src: p.src.id, dst: p.tgt.id, stage: .preview)
                    if !out.isEmpty { hearLogText("云端翻译（预览）：", String(out.prefix(20))) }
                    publish(out, true)
                } catch {
                    guard !Task.isCancelled, previews.translation.owns(loop), gen == runGen else { return }
                    if error is CancellationError { continue }
                    if (error as? CloudClient.CloudError)?.isBusy == true {
                        previews.cloudTranslationRetryAt = ContinuousClock.now.advanced(by: .seconds(2))
                        hearLog("云端繁忙，实时翻译预览稍后恢复")
                    } else {
                        hearLog("云端翻译（预览）失败：\(error)", .warning)
                    }
                }
                continue
            }
            if working { continue }
            let epoch = translator.currentPreviewEpoch
            let out = try? await translator.translate(prompt: prompt, maxNewTokens: 256, previewEpoch: epoch) { text in
                Task { @MainActor in publish(text, false) }
            }
            publish(out ?? "", true)
        }
    }

    private func previousSegment(before index: Int? = nil) -> TranslationItem? {
        items.prefix(index ?? items.count).last {
            SpeechTextFilter.isMeaningful($0.sourceText) && !$0.sourceText.hasPrefix("（")
        }
    }

    private var sentenceRecognizer: SessionSpeechEngine {
        if usingCloudASR { return .cloud(cloud) }
        return .senseVoice(sense)
    }

    private func translateFinal(_ text: String, from src: Language, to tgt: Language,
                                previous: TranslationItem?, stage: CloudClient.TranslationStage = .final,
                                onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        let source = TranslationSource.currentSegment(text, language: src, after: useContext ? previous : nil)
        let out = try await translateAttempt(source, from: src, to: tgt, stage: stage, onPartial: onPartial)
        try Task.checkCancellation()
        let result = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty {
            if src.id == tgt.id { return text }
            throw TranslationResultError.empty
        }
        return result
    }

    private func translateAttempt(_ text: String, from src: Language, to tgt: Language,
                                  stage: CloudClient.TranslationStage,
                                  onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        let engine: SessionTextEngine = usingAppleTranslation ? .system(systemTranslator)
            : (usingCloudMT ? .cloud(cloud) : .local(translator))
        do {
            return try await engine.translate(text: text, source: src, target: tgt,
                                              glossary: glossary, stage: stage, onPartial: onPartial)
        } catch {
            try Task.checkCancellation()
            guard stage == .final, !(error is CancellationError) else { throw error }
            switch engine {
            case .system:
                hearLog("苹果翻译失败：\(error)", .error)
                appleTranslationFailed(error)
                if let out = try? await fallbackTranslate(text, from: src, to: tgt) { return out }
            case .cloud:
                hearLog("云端翻译失败：\(error)", .error)
                let keepEngine = (error as? CloudClient.CloudError)?.shouldKeepConfiguredEngine ?? false
                if !keepEngine, cloudFallbackToApple(.mt, reason: error.localizedDescription) {
                    let alternate: SessionTextEngine = usingAppleTranslation ? .system(systemTranslator) : .local(translator)
                    return try await alternate.translate(text: text, source: src, target: tgt,
                                                         glossary: glossary, onPartial: onPartial)
                }
            case .local:
                break
            }
            throw error
        }
    }

    /// 苹果翻译用不了时的替补：云端优先，其次本地（模型装好而且正在跑才行）
    private func fallbackTranslate(_ text: String, from src: Language, to tgt: Language) async throws -> String {
        let prompt = PromptBuilder.build(text: text, from: src, to: tgt,
                                         glossary: PromptBuilder.parseGlossary(glossary))
        if usingCloudMT {
            hearLog("苹果翻译失败，改用云端翻译")
            return try await cloud.translate(prompt: prompt, src: src.id, dst: tgt.id)
        }
        if isInstalled(.translation) {
            hearLog("苹果翻译失败，改用本地翻译")
            return try await translator.translate(prompt: prompt) { _ in }
        }
        throw LiveTextError.unsupportedLanguage
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
        live.onAudioLoss = { [weak capture] in capture?.noteSpeechInputLoss() }
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
                if currentSeg > finishedSeg { live.markSegmentStart(currentSeg, frame: currentSegStartFrame) }
            } catch {
                hearLog("系统听写不可用（\(lang.name)）：\(error.localizedDescription)，改用 Whisper 实时预览", .warning)
                if gen == runGen { liveActive = false }
            }
        }
    }

    // MARK: - 苹果自带模式（系统听写 + 系统翻译）

    /// 解析苹果系统听写当前应并行监听的候选语种列表（保证 startAppleASR / bestApple / appleUpdated / processApple 完全一致）
    /// 注意：
    /// 1) 聆听翻译模式下，`meetingTargetLang` 仅表示「译为」的目标语言（如泰语），与语音识别语种无关，
    ///    因此仍使用当前引擎支持的主识别语种对 `[left, right]`（默认中/英），避免因目标语种不被系统听写支持导致识别失败；
    /// 2) 并排双键/面对面模式下即使按住某一方按钮（forced != nil），仍同时开双方语种听写，
    ///    这样无论说话人说母语、外语还是中英混说都能准确转写，翻译方向再由 forced 锁定为「译为对方语言」。
    private func appleASRLanguages(left: Language, right: Language, forced: Language?) -> [Language] {
        return [left, right]
    }

    /// 两种语言各开一个系统听写，同时听；每句话取更有把握的那个
    private func startAppleASR() {
        stopAppleASR()
        guard appleAvailable else { return }
        let pendingStop = appleStopTask
        // 后台准备 sherpa-onnx Whisper-Tiny 语种裁判（不阻塞苹果流式听写启动；仅双语自动模式需要）
        if forcedLang == nil {
            let detector = languageDetector
            Task.detached(priority: .utility) { await detector.ensureReady() }
        }
        var engines: [LiveTextEngine] = []
        let gen = runGen
        // 对话翻译只听用户当前选择的语言；实时翻译（会议）模式优先听目标语种与常用外语
        let langs = appleASRLanguages(left: langA, right: langB, forced: forcedLang)
        for lang in langs {
            guard let e = LiveTextEngineFactory.make() else { continue }
            e.onAudioLoss = { [weak capture] in capture?.noteSpeechInputLoss() }
            e.onUpdate = { [weak self] in
                Task { @MainActor in self?.appleUpdated() }
            }
            // 听写自己坏了：告诉用户，并且退回 Whisper 实时预览
            e.onFailure = { [weak self, weak e] msg in
                Task { @MainActor in
                    guard let self, let e, self.runGen == gen else { return }
                    self.appleEngines.removeAll { $0 === e }
                    self.refreshAppleFeed()
                    await e.stop()
                    self.showToast("系统听写出错了（\(msg)）", seconds: 4)
                }
            }
            engines.append(e)
            Task {
                // 必须等上一批 SpeechAnalyzer 彻底 cancelAndFinishNow 释放名额，否则 iOS 会报 Code=16 "Maximum number of recognizers reached"
                if let pendingStop { await pendingStop.value }
                guard isRunning || finishingInput, gen == runGen, dualLive else { return }
                do {
                    do {
                        try await e.start(languageID: lang.id, locale: lang.tts)
                    } catch {
                        let ns = error as NSError
                        if ns.domain == "SFSpeechErrorDomain" && ns.code == 16 {
                            hearLog("系统听写（\(lang.name)）识别器名额暂满，等待 250ms 后重试一次", .warning)
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            guard isRunning || finishingInput, gen == runGen, dualLive else { return }
                            try await e.start(languageID: lang.id, locale: lang.tts)
                        } else {
                            throw error
                        }
                    }
                    guard isRunning || finishingInput, gen == runGen, dualLive else { await e.stop(); return }
                    if currentSeg > finishedSeg { e.markSegmentStart(currentSeg, frame: currentSegStartFrame) }
                } catch {
                    hearLog("系统听写不支持 \(lang.name)：\(error.localizedDescription)", .warning)
                    activity = "系统听写暂不支持 \(lang.name)"
                    await e.stop()
                    // 起不来的听写要从列表里去掉：
                    // 不然"有没有可用的听写"会被误判成有，
                    // Whisper 的实时预览也就不做了，屏幕上一直是省略号
                    if gen == runGen {
                        self.appleEngines.removeAll { $0 === e }
                        self.refreshAppleFeed()
                    }
                }
            }
        }
        appleEngines = engines
        refreshAppleFeed()
    }

    private func refreshAppleFeed() {
        let engines = appleEngines
        capture.onSamples = engines.isEmpty ? nil : { samples in
            for engine in engines { engine.feed(samples) }
        }
    }

    private func stopAppleASR() {
        lastApplePieceRange = nil
        guard !appleEngines.isEmpty else { return }
        capture.onSamples = nil
        let list = appleEngines
        appleEngines = []
        let prev = appleStopTask
        appleStopTask = Task {
            await prev?.value
            for e in list { await e.stop() }
        }
    }

    /// 第 id 句：两个听写里置信度更高的结果。
    /// 不再用 requireFinal 硬淘汰另一路——否则英文听写把中文胡乱听成低置信度 "We to the shoot" 且恰好先定稿时，
    /// 会把中文听写高置信度但尚未定稿的正确结果直接覆盖掉；改为仅给已定稿加小幅加分（+0.12），仍以置信度与字形匹配为主。
    private func bestApple(_ id: Int, requireFinal: Bool = false,
                           languages: [Language]? = nil,
                           preferredLangID: String? = nil) -> (text: String, lang: Language, range: (start: Double, end: Double)?)? {
        let candidates = languages ?? appleASRLanguages(left: langA, right: langB, forced: forcedLang)
        var best: (text: String, lang: Language, conf: Double, range: (start: Double, end: Double)?)?
        for e in appleEngines {
            let isFinal = e.hasFinalText(id)
            if requireFinal, !isFinal { continue }
            let r = e.segmentText(id)
            guard !r.text.isEmpty, let lid = e.languageID,
                  let lang = candidates.first(where: { $0.id == lid }) else { continue }
            // 例如中文听写把英文也写成了英文字母：文字和语言对不上就降分，避免说英文却当成中文；
            // 未定稿阶段 Apple 常不带置信度（回退 0.50），同分时按语义信息量（中日韩单字≈3拉丁字母）破平局；
            // 若 sherpa-onnx Whisper-Tiny 语种裁判已指认语种，给对应语种决定性加分（+2.0），直接压过另一路的幻听。
            let isCJK = ["zh", "ja", "ko"].contains(lang.id)
            let trimmedCount = r.text.filter { !$0.isWhitespace && !$0.isPunctuation }.count
            let infoUnits = Double(trimmedCount) * (isCJK ? 3.0 : 1.0)
            let lengthBonus = min(0.18, infoUnits * 0.006)
            let lidBonus = (preferredLangID == lang.id) ? 2.0 : 0.0
            let score = r.confidence
                + (SpeechTextFilter.matchesLanguage(r.text, lang.id) ? 1.0 : 0.0)
                + (isFinal ? 0.12 : 0.0)
                + lengthBonus
                + lidBonus
            if best == nil || score > best!.conf {
                best = (r.text, lang, score, e.segmentPieceRange(id))
            }
        }
        guard let best else { return nil }
        return (best.text, best.lang, best.range)
    }

    private static func pieceRangesOverlap(_ a: (start: Double, end: Double),
                                           _ b: (start: Double, end: Double)) -> Bool {
        a.start < b.end - 0.05 && a.end > b.start + 0.05
    }

    /// 苹果连续流式听写常把上一句和下一句合在同一个累积 Piece 里；
    /// 逐字跳过标点空白比对：若 `text` 以 `previous` 开头，返回剥离掉已展示前缀后的新增部分。
    private static func stripCommittedPrefix(_ text: String, previous: String) -> (remainder: String, matched: Bool) {
        let prevChars = previous.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard !prevChars.isEmpty else { return (text, false) }
        var pIdx = prevChars.startIndex
        var tIdx = text.startIndex
        while pIdx < prevChars.endIndex && tIdx < text.endIndex {
            let tc = text[tIdx]
            if tc.isWhitespace || tc.isPunctuation {
                tIdx = text.index(after: tIdx)
                continue
            }
            if tc.lowercased() == prevChars[pIdx].lowercased() {
                pIdx = prevChars.index(after: pIdx)
                tIdx = text.index(after: tIdx)
            } else {
                return (text, false)
            }
        }
        guard pIdx == prevChars.endIndex else { return (text, false) }
        while tIdx < text.endIndex && (text[tIdx].isWhitespace || text[tIdx].isPunctuation) {
            tIdx = text.index(after: tIdx)
        }
        return (String(text[tIdx...]).trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    private func appleUpdated() {
        guard !appleEngines.isEmpty, isRunning, currentSeg > finishedSeg, partialSeg == currentSeg,
              let b = bestApple(currentSeg), SpeechTextFilter.isMeaningful(b.text) else { return }
        var displayText = b.text
        // 仅当当前实时片段的时间范围与上一条已提交片段确实重叠（苹果把两段合在同一个累积 Piece 里）时才剥离前缀；
        // 若时间不重叠，说明用户真的连续说了两遍相同的话，不能误吞！
        if let last = items.last, last.source.id == b.lang.id,
           let prevRange = lastApplePieceRange, prevRange.langID == b.lang.id,
           let currRange = b.range,
           Self.pieceRangesOverlap(currRange, (prevRange.start, prevRange.end)) {
            let stripped = Self.stripCommittedPrefix(displayText, previous: last.sourceText)
            if stripped.matched {
                if stripped.remainder.isEmpty || !SpeechTextFilter.isMeaningful(stripped.remainder) {
                    return
                }
                displayText = stripped.remainder
            } else {
                let normPrev = last.sourceText.filter { !$0.isWhitespace && !$0.isPunctuation }
                let normCurr = displayText.filter { !$0.isWhitespace && !$0.isPunctuation }
                if !normCurr.isEmpty && normPrev.hasPrefix(normCurr) {
                    return
                }
            }
        }
        // 并排双键/面对面模式下，按了哪一侧按钮，src 就固定是该侧语种、目标就固定是另一侧语种
        let srcLang = forcedLang ?? b.lang
        partialSource = srcLang
        partial = displayText
        let targetLang = !talkMode ? meetingTargetLang : (srcLang == langA ? langB : langA)
        requestPreviewTranslation(id: currentSeg, text: displayText, src: srcLang, tgt: targetLang)
    }

    /// 等系统听写把这一段定稿（最多等这么久）。
    ///
    /// 以前是固定等 700 毫秒：话短的话定稿早，话长的话 700 毫秒还在半路上，
    /// 拿到的就是半截（甚至空）文本，然后就被当成"没听清"了。
    /// 现在等到"这段结束了而且有字"为止。
    private func waitAppleFinal(_ segID: Int) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(2500))
        var lowConfFinalSeenAt: ContinuousClock.Instant?
        while !appleEngines.isEmpty, clock.now < deadline, !Task.isCancelled {
            let allFinal = appleEngines.allSatisfy { $0.hasFinalText(segID) }
            if allFinal { return }
            let hasHighConfFinal = appleEngines.contains { e in
                guard e.hasFinalText(segID), let lid = e.languageID else { return false }
                let r = e.segmentText(segID)
                return !r.text.isEmpty && r.confidence >= 0.75 && SpeechTextFilter.matchesLanguage(r.text, lid)
            }
            if hasHighConfFinal { return }
            // 若某路只给出了低置信度定稿（例如英文把中文误听成 conf=0.51 的乱码），
            // 再多等最多 1.2 秒让真正说话的那路语种完成定稿，避免 0ms 提前结束导致误选乱码。
            if appleEngines.contains(where: { $0.hasFinalText(segID) }) {
                if let firstAt = lowConfFinalSeenAt {
                    if clock.now >= firstAt.advanced(by: .milliseconds(1200)) { return }
                } else {
                    lowConfFinalSeenAt = clock.now
                }
            }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
    }

    private func processApple(_ job: ASRJob) async {
        let (samples, itemID, segID, gen, token) = (job.samples, job.itemID, job.segID, job.generation, job.token)
        let languages = appleASRLanguages(left: job.left, right: job.right, forced: job.forced)
        activity = "识别中…"
        let started = PerformanceLog.isEnabled ? ContinuousClock.now : nil
        // 并发跑两个任务（零额外延迟）：
        // 1) 等苹果系统听写定稿（高置信度定稿立即返回，低置信度最多多等 1.2s 等另一路定稿）
        // 2) sherpa-onnx Whisper-Tiny 语种裁判（~60ms）判定本句真实语种
        // 并排双键/面对面模式下即使 forced != nil，也同时用双语候选给 ASR 转写（支持混说或说对方语言），
        // 识别完成后由 job.forced 锁定归属方并强制翻译成另一侧语言。
        let lidCandidates = languages.map(\.id)
        let detector = languageDetector
        let lidTask: Task<String?, Never> = Task.detached(priority: .userInitiated) {
            await detector.detectLanguage(samples: samples, candidates: lidCandidates)
        }
        await waitAppleFinal(segID)
        let detectedLID: String? = await lidTask.value
        guard !Task.isCancelled, gen == runGen else { return }
        // 这一句已经被放弃/顶掉了：结果不要了
        guard isCurrentJob(itemID, token: token) else { return }
        // 诊断日志：逐路打印各语种系统听写引擎的定稿状态、置信度、得分、字数及语种裁判结论
        let diag = appleEngines.map { e -> String in
            let lid = e.languageID ?? "?"
            let fin = e.hasFinalText(segID)
            let r = e.segmentText(segID)
            let match = SpeechTextFilter.matchesLanguage(r.text, lid)
            let sc = r.confidence + (match ? 1.0 : 0.0) + (fin ? 0.12 : 0.0) + (detectedLID == lid ? 2.0 : 0.0)
            return String(format: "%@[final=%@ conf=%.2f match=%@ score=%.2f %d字]",
                          lid, fin ? "T" : "F", r.confidence, match ? "T" : "F", sc, r.text.count)
        }.joined(separator: " | ")
        hearLog("系统听写评分(第\(segID)句, 裁判=\(detectedLID ?? "无"))：\(diag.isEmpty ? "无活跃引擎" : diag)")
        // 听写这一段有没有出字：综合比较所有语种引擎（优先听从语种裁判指认的那一路）
        let dict = bestApple(segID, requireFinal: false, languages: languages, preferredLangID: detectedLID)
        var spoken = dict?.text ?? ""
        var src = job.forced ?? dict?.lang ?? job.fallback
        var pieceRange = dict?.range
        if !SpeechTextFilter.isMeaningful(spoken) {
            // 听写最后那几百毫秒没出字：不能把这句话删掉！
            // 先用本地识别再认一遍这段声音；还是没有就标成"没听清"留着，
            // 至少用户还能长按改，不至于白说了。
            guard isCurrentJob(itemID, token: token) else { return }
            let recovered = await localRecover(samples: samples, fallbackLang: src, languages: languages)
            guard !Task.isCancelled, gen == runGen, isCurrentJob(itemID, token: token) else { return }
            if let r = recovered {
                spoken = r.text
                src = r.lang
                pieceRange = nil
            } else if let r = bestApple(segID, languages: languages) {
                spoken = r.text
                src = r.lang
                pieceRange = r.range
            } else if let existing = items.first(where: { $0.id == itemID }),
                      Self.hasRealText(existing.sourceText),
                      SpeechTextFilter.isMeaningful(existing.sourceText) {
                // 实时预览阶段已经识别出了有效原文，定稿阶段若未能再次取到，直接保留该原文并完成翻译，不要覆盖成“翻译失败”。
                spoken = existing.sourceText
                src = existing.source
                hearLog("系统听写：定稿超时，沿用实时预览原文继续翻译", .info)
            } else {
                PerformanceLog.record("整句识别", engine: "Apple 听写", since: started, outcome: "无结果")
                hearLog("系统听写：这一段没听清，留着让用户改", .warning)
                if let i = items.firstIndex(where: { $0.id == itemID }) {
                    jobTokens[itemID] = nil
                    if !Self.hasRealText(items[i].sourceText) { items[i].sourceText = "（没听清）" }
                    items[i].applyTranslation("（翻译失败：识别未完成）", done: true)
                    persist()
                }
                activity = isRunning ? "正在聆听" : ""
                kickReader()
                return
            }
        }
        let meetingMode = !talkMode
        let leading = meetingMode ? true : (src == job.left)
        let tgt = meetingMode ? meetingTargetLang : (leading ? job.right : job.left)
        if !meetingMode, job.left == langA && job.right == langB { lastLangID = src.id }
        PerformanceLog.record("整句识别", engine: "Apple 听写", since: started)
        hearLogText("系统听写（\(src.name)）：", String(spoken.prefix(40)))

        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        // 仅当新旧两句命中的苹果 Piece 时间范围真正重叠时，才视为同一累积片段执行去重/剥离前缀；
        // 时间不重叠说明用户真的连续说了两遍相同的话（如连续说三次 "I like dogs."），必须全部保留！
        let prevRange = lastApplePieceRange
        let isSameOverlappingPiece: Bool = {
            guard let currRange = pieceRange, let prevRange, prevRange.langID == src.id else { return false }
            return Self.pieceRangesOverlap(currRange, (prevRange.start, prevRange.end))
        }()
        if idx > 0, isSameOverlappingPiece {
            let prev = items[idx - 1]
            if prev.source.id == src.id {
                let normPrev = prev.sourceText.filter { !$0.isWhitespace && !$0.isPunctuation }
                let normCurr = spoken.filter { !$0.isWhitespace && !$0.isPunctuation }
                if !normPrev.isEmpty && !normCurr.isEmpty {
                    let stripped = Self.stripCommittedPrefix(spoken, previous: prev.sourceText)
                    if stripped.matched {
                        if stripped.remainder.isEmpty || !SpeechTextFilter.isMeaningful(stripped.remainder) {
                            if let endSec = items[idx].audioEndSec {
                                items[idx - 1].audioEndSec = endSec
                            }
                            if let currRange = pieceRange {
                                lastApplePieceRange = (src.id, currRange.start, currRange.end)
                            }
                            removeItem(itemID)
                            jobTokens[itemID] = nil
                            hearLog("系统听写：同一语音片段完全重复，已自动去重", .info)
                            persist()
                            activity = isRunning ? "正在聆听" : ""
                            kickReader()
                            return
                        } else {
                            spoken = stripped.remainder
                            hearLog("系统听写：已剥离同一片段重复前缀，保留新增内容", .info)
                        }
                    } else if normPrev.hasPrefix(normCurr) {
                        if let endSec = items[idx].audioEndSec {
                            items[idx - 1].audioEndSec = endSec
                        }
                        removeItem(itemID)
                        jobTokens[itemID] = nil
                        hearLog("系统听写：同一语音片段已包含在上一句中，已自动去重", .info)
                        persist()
                        activity = isRunning ? "正在聆听" : ""
                        kickReader()
                        return
                    }
                }
            }
        }
        if let currRange = pieceRange {
            lastApplePieceRange = (src.id, currRange.start, currRange.end)
        } else {
            lastApplePieceRange = nil
        }
        items[idx].updateTranscript(spoken, source: src, target: tgt,
                                    side: leading ? .left : .right, recognizedLanguage: src.id)
        rememberReference(itemID, samples: samples, text: spoken)
        // 翻译排到另一条队列（跟识别分开）；即使聆听模式下源语种与目标语种一致（如中英混说），也正常送翻译处理混杂外语
        enqueueTranslation(MTJob(itemID: itemID, token: token, gen: gen, text: spoken,
                                  src: src, tgt: tgt, samples: samples,
                                  isApple: true))
    }

    /// 听写没给出结果时：用本地的识别再认一遍这段声音。
    /// （认出来了就保住这句话；认不出来也不删，标成"没听清"）
    private func localRecover(samples: [Float], fallbackLang: Language,
                              languages: [Language]) async -> (text: String, lang: Language)? {
        guard !senseRequiresRestart, !recognition.isRecovering else { return nil }
        let cands = languages.map(\.id)
        do {
            guard await sense.isLoaded else { return nil }
            let r = try await sense.recognize(samples, candidates: cands, fallback: fallbackLang.id, preview: false)
            guard SpeechTextFilter.isMeaningful(r.text),
                  let language = SpeechTextFilter.resolveLanguage(r.text, detected: r.language,
                                                                  candidates: cands, fallback: fallbackLang.id),
                  let lang = languages.first(where: { $0.id == language }) else { return nil }
            hearLogText("系统听写没出字，本地补认成功：", String(r.text.prefix(30)))
            return (r.text, lang)
        } catch {
            return nil
        }
    }

    // MARK: - 整句识别和翻译

    private struct MTJob {
        let itemID: UUID
        let token: UUID
        let gen: Int
        let text: String
        let src: Language
        let tgt: Language
        let samples: [Float]
        /// 这一句是不是系统听写来的（翻译失败时的处理不一样）
        let isApple: Bool
        var correctionAddress: String? = nil
        var queuedAt: ContinuousClock.Instant? = nil
    }

    private func enqueueTranslation(_ job: MTJob) {
        let page = conversationID
        var request = job
        if PerformanceLog.isEnabled { request.queuedAt = .now }
        translations.submit(request, item: job.itemID, page: page) { [weak self] job in
            await self?.translateItem(job, conversation: page)
        } timedOut: { [weak self] job in
            guard let self, self.isCurrentJob(job.itemID, token: job.token) else { return }
            self.applyTranslation(job.itemID, "（翻译失败：这一句等太久了）", done: true,
                                  conversation: page, expectedSource: job.text)
            self.jobTokens[job.itemID] = nil
            self.translations.finished(job.itemID)
            self.activity = self.isRunning ? "正在聆听" : ""
            self.kickReader()
        }
    }

    private func translateItem(_ job: MTJob, conversation: UUID) async {
        let id = job.itemID
        let token = job.token
        guard !Task.isCancelled, isCurrentJob(id, token: token) else { return }
        let rows = conversation == conversationID ? items : (ConversationStore.shared.load(conversation)?.items ?? [])
        guard let index = rows.firstIndex(where: { $0.id == id && $0.sourceText == job.text }) else {
            jobTokens[id] = nil
            translations.finished(id)
            return
        }
        let hasPreview = !rows[index].translated.isEmpty
        let previous = rows[..<index].last { SpeechTextFilter.isMeaningful($0.sourceText) }
        if conversation == conversationID {
            items[index].beginTranslationRevision()
            activity = "翻译中…"
        }
        translator.cancelPreview()
        let engine = translationEngine
        let started = PerformanceLog.isEnabled ? ContinuousClock.now : nil
        if let queuedAt = job.queuedAt {
            PerformanceLog.record("整句翻译排队", engine: engine, since: queuedAt)
        }
        let result: String
        do {
            result = try await translateFinal(job.text, from: job.src, to: job.tgt, previous: previous) { part in
                guard !hasPreview else { return }
                Task { @MainActor in
                    guard conversation == self.conversationID else { return }
                    self.update(id, part, done: false, token: token)
                }
            }
        } catch {
            guard !Task.isCancelled, isCurrentJob(id, token: token) else { return }
            PerformanceLog.record("整句翻译", engine: engine, since: started, outcome: "失败")
            hearLog("翻译失败：\(error)", .error)
            completeTranslation(job, translationFailureMessage(for: error), conversation: conversation)
            if job.isApple, conversation == conversationID {
                if usingAppleTranslation { appleTranslationFailed() } else { prepareAppleTranslation() }
            }
            return
        }
        guard !Task.isCancelled, isCurrentJob(id, token: token) else { return }
        PerformanceLog.record("整句翻译", engine: engine, since: started)
        completeTranslation(job, result, conversation: conversation)
        // 只对正在收音的同一页进行后台校正。
        if isRunning, conversation == conversationID, job.gen == runGen,
           !recognition.queue.hasPendingJobs, let address = job.correctionAddress {
            let revision = itemVersions[id] ?? 0
            translations.startCorrection { [weak self] in
                guard let self else { return }
                await self.whisperCorrect(id: id, samples: job.samples, src: job.src,
                                          oldText: job.text, gen: job.gen, revision: revision,
                                          cloudAddress: address)
            }
        }
    }

    private func completeTranslation(_ job: MTJob, _ result: String, conversation: UUID) {
        jobTokens[job.itemID] = nil
        translations.finished(job.itemID)
        applyTranslation(job.itemID, result, done: true, conversation: conversation, expectedSource: job.text)
        if conversation == conversationID {
            activity = isRunning ? "正在聆听" : ""
            kickReader()
        }
    }

    /// 采集结束前保留原来的语言，确保尾句按录制时的语言处理。
    private var forcedLang: Language? { usesDualConversationButtons || finishingInput ? talkLang : nil }

    var isLoadingPhase: Bool { if case .loading = phase { return true }; return false }
    var loadingText: String? { if case .loading(let m) = phase { return m }; return nil }

    /// 这个任务还是不是这一句"当前有效"的任务。
    /// 超时被放弃的、或者被新任务顶掉的旧任务，结果一律丢掉（不然会串）
    private func isCurrentJob(_ itemID: UUID, token: UUID) -> Bool {
        jobTokens[itemID] == token
    }

    /// 一句卡住太久被放弃了：标成失败（朗读队列才跳过它继续往后）
    private func markJobFailed(_ itemID: UUID, token: UUID, reason: String = "这一句等太久了") {
        guard isCurrentJob(itemID, token: token) else { return }
        jobTokens[itemID] = nil
        if let index = items.firstIndex(where: { $0.id == itemID }), !Self.hasRealText(items[index].sourceText) {
            items[index].sourceText = "（未取得原文，可长按修改）"
        }
        // 一定要有终态：
        // 不然这条一直"翻译中"，朗读队列碰到第一句没做完的就停了
        // （后面的话一句都读不出来）。
        update(itemID, "（翻译失败：\(reason)）", done: true)
        activity = recognition.isRecovering ? "正在恢复本机识别…" : (isRunning ? "正在聆听" : "")
        persist()
        kickReader()
    }

    private func recoverSenseVoice() {
        guard !recognition.isRecovering else { return }
        guard let folder = SenseVoiceRecognizer.installedFolder() else {
            stopAfterSenseFailure(.failed)
            return
        }
        activity = "正在恢复本机识别…"
        recognition.recover(repair: { [sense] in
            try await sense.recover(folder: folder)
        }) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .recovered:
                hearLog("SenseVoice：超时恢复完成")
                self.activity = self.isRunning ? "正在聆听" : ""
            case .failed, .timedOut:
                self.stopAfterSenseFailure(outcome)
            }
        }
    }

    private func stopAfterSenseFailure(_ outcome: SenseVoiceRecovery.Outcome) {
        senseRequiresRestart = true
        stop(readAfter: false, keepTranslations: true)
        activity = Self.senseRestartMessage
        showToast(Self.senseRestartMessage, seconds: 6)
        hearLog("SenseVoice 恢复结束（\(outcome)），已停止收音并保留已显示的内容", .warning)
    }

    /// 删掉一条（识别结果没有意义时）
    private func removeItem(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: i)
        if i < readIndex { readIndex -= 1 }
        kickReader()
    }

    private func process(_ job: ASRJob) async {
        let (samples, itemID, gen, token) = (job.samples, job.itemID, job.generation, job.token)
        // 模型还在加载：先把这句话留着，加载好马上识别
        if phase != .ready {
            // 上面已经有"正在准备模型 · N 秒"的提示了，这里不再重复
            activity = ""
            while isLoadingPhase, gen == runGen {
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
            }
        }
        guard !Task.isCancelled, gen == runGen, isCurrentJob(itemID, token: token) else { return }
        guard phase == .ready else {
            markJobFailed(itemID, token: token)
            return
        }
        let a = job.left, b = job.right
        let meetingMode = !talkMode
        let meetingTarget = meetingTargetLang
        activity = usingCloudASR ? "云端识别中…" : "SenseVoice 识别中…"
        let forced = job.forced
        let fallback = forced?.id ?? (meetingMode ? a.id : job.fallback.id)
        // 并排双键/面对面模式下（forced != nil）仍传双语候选给识别引擎，确保混说或说对方语言也能准确转写，
        // 最终翻译目标再由 forced 强制锁定为对方语言。
        let cands = meetingMode ? supportedLanguages.map(\.id) : [a.id, b.id]
        let correctionAddress: String?
        let speakerAddress: String?
        let detected: String
        let observedLanguage: String?
        let text: String
        let t0 = ContinuousClock.now
        let engineName = usingCloudASR ? "云端·\(Self.cloudSchemeName(cloudASRScheme))" : "SenseVoice"
        do {
            // 识别中，实时预览先让路。
            let use = recognition.beginFinal()
            defer { recognition.endFinal(use) }
            let engine = sentenceRecognizer
            let result = try await engine.recognize(samples, candidates: cands, fallback: fallback,
                                                     confirmedSpeech: job.confirmedSpeech)
            detected = result.lang
            observedLanguage = result.observedLanguage
            text = result.text
            correctionAddress = result.correctionAddress
            speakerAddress = result.speakerAddress
            PerformanceLog.record("整句识别", engine: engineName, since: t0)
            let seconds = Double(PerformanceLog.milliseconds(since: t0)) / 1_000
            hearLogText("整句识别（\(engineName)）\(String(format: "%.1f", seconds))s：",
                    String(text.prefix(40)))
        } catch {
            guard !Task.isCancelled, gen == runGen, isCurrentJob(itemID, token: token) else { return }
            PerformanceLog.record("整句识别", engine: engineName, since: t0, outcome: "失败")
            hearLog("识别失败：\(error)", .error)
            let cloudError = error as? CloudClient.CloudError
            let keepEngine = cloudError?.shouldKeepConfiguredEngine ?? false
            if usingCloudASR, !keepEngine {
                cloudFallbackToApple(.asr, reason: error.localizedDescription)
            }
            if gen == runGen, isCurrentJob(itemID, token: token) {
                activity = "识别失败"
                if let index = items.firstIndex(where: { $0.id == itemID }) {
                    if !Self.hasRealText(items[index].sourceText) {
                        items[index].sourceText = "（识别失败，可长按修改）"
                    }
                    let reason = cloudError?.isBusy == true ? "云端识别繁忙，重试后仍未完成" : "识别未完成"
                    items[index].applyTranslation("（翻译失败：\(reason)）", done: true)
                    jobTokens[itemID] = nil
                    persist()
                    kickReader()
                }
            }
            return
        }
        guard gen == runGen else { return }              // 已经停止：结果丢弃
        guard isCurrentJob(itemID, token: token) else { return }   // 这一句已经被放弃/顶掉
        if outputMode == .speaker && isLikelySpokenEcho(text) {
            hearLogText("丢弃疑似扬声器回声复录：", String(text.prefix(30)), .info)
            removeItem(itemID)
            jobTokens[itemID] = nil
            activity = isRunning ? "正在聆听" : ""
            return
        }
        // 语种与预览用同一规则，识别失败时已有译文仍可读。
        guard SpeechTextFilter.isMeaningful(text),
              let language = forced?.id ?? SpeechTextFilter.resolveLanguage(text, detected: detected,
                                                                            candidates: cands, fallback: fallback)
        else {
            if !text.isEmpty {
                hearLogText("丢弃可疑识别结果（\(detected)）：", String(text.prefix(30)), .warning)
            }
            if !isCurrentJob(itemID, token: token) { return }
            if items.first(where: { $0.id == itemID })?.translated.isEmpty == false {
                update(itemID, "（翻译失败：识别未完成）", done: true, token: token)
                persist()
                kickReader()
            } else {
                removeItem(itemID)
            }
            jobTokens[itemID] = nil
            activity = isRunning ? "正在聆听" : ""
            return
        }
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        let src = meetingMode ? Language.find(language) : (language == b.id ? b : a)
        let tgt = meetingMode ? meetingTarget : (src == a ? b : a)
        if !meetingMode, a == langA && b == langB { lastLangID = src.id }
        // 保存可验证的第三方语种，方便之后切换语言时把历史气泡移到正确的一侧。
        let recognizedLanguage = observedLanguage.flatMap { observed -> String? in
            guard !cands.contains(observed), Language.all.contains(where: { $0.id == observed }),
                  SpeechTextFilter.matchesLanguage(text, observed) else { return nil }
            return observed
        } ?? src.id
        var item = items[idx]
        item.updateTranscript(text, source: src, target: tgt, side: meetingMode ? .left : (src == a ? .left : .right),
                              recognizedLanguage: recognizedLanguage)
        let localSpeakerFolder: URL? = {
            guard speakerTrackingEnabled, !usingCloudASR, !localOptionalWorkPaused,
                  let folder = SenseVoiceRecognizer.installedFolder(),
                  LocalSpeakerEmbedder.isInstalled(in: folder) else { return nil }
            return folder
        }()
        let shouldIdentify = speakerTrackingEnabled && !talkMode &&
            (speakerAddress != nil || localSpeakerFolder != nil)
        if shouldIdentify { item.speakerTracked = true }
        guard let idx2 = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx2] = item
        let id = itemID
        rememberReference(id, samples: samples, text: text)

        // 原文已经显示出来了，翻译排到另一条队列：
        // 上一句翻得慢也不挡着下一句的原文；即使聆听模式下源语种与目标语种相同（如中英混说），也正常送翻译处理外语部分。
        persist()
        enqueueTranslation(MTJob(itemID: itemID, token: token, gen: gen, text: text,
                                  src: src, tgt: tgt, samples: samples,
                                  isApple: false, correctionAddress: correctionAddress))
        if shouldIdentify {
            if let speakerAddress {
                enqueueSpeaker(samples, for: itemID, source: .cloud(speakerAddress))
            } else if let localSpeakerFolder {
                enqueueSpeaker(samples, for: itemID, source: .local(localSpeakerFolder))
            }
        }
    }

    @Published var speakerTrackingEnabled = (UserDefaults.standard.object(forKey: "speakerTrackingEnabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(speakerTrackingEnabled, forKey: "speakerTrackingEnabled")
            if !speakerTrackingEnabled {
                speakerQueue.cancel()
                speakerTracker = SpeakerTracker()
                Task { await localSpeaker.unload() }
            }
        }
    }

    private enum SpeakerSource {
        case cloud(String)
        case local(URL)
    }

    private struct SpeakerJob {
        let samples: [Float]
        let itemID: UUID
        let conversation: UUID
        let source: SpeakerSource
    }

    private let speakerQueue = SessionJobQueue<SpeakerJob>(timeout: .seconds(10))
    private let localSpeaker = LocalSpeakerEmbedder()
    private var speakerTracker = SpeakerTracker()

    private func enqueueSpeaker(_ samples: [Float], for itemID: UUID, source: SpeakerSource) {
        guard samples.count >= 22_400, speakerQueue.pendingCount < 3 else { return }
        let job = SpeakerJob(samples: Array(samples.prefix(160_000)), itemID: itemID,
                             conversation: conversationID, source: source)
        speakerQueue.submit(job) { [weak self] job in
            guard let self else { return }
            let embedding: [Float]?
            do {
                switch job.source {
                case .cloud(let address):
                    embedding = try await self.cloud.speakerEmbedding(samples: job.samples, address: address)
                case .local(let folder):
                    embedding = try await self.localSpeaker.embedding(samples: job.samples, folder: folder)
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                hearLog("说话人识别失败：\(error)", .warning)
                return
            }
            guard let embedding,
                  !Task.isCancelled, job.conversation == self.conversationID,
                  let index = self.items.firstIndex(where: { $0.id == job.itemID }),
                  self.items[index].speakerManuallySet != true else { return }
            let lastID = self.items.compactMap(\.speakerID).max() ?? 0
            guard let id = self.speakerTracker.assign(embedding, after: lastID) else { return }
            let speaker = self.items.first { $0.speakerID == id }
            self.items[index].speakerID = id
            self.items[index].speakerName = speaker?.speakerName
            self.items[index].speakerDetails = speaker?.speakerDetails
            if self.items[index].done, self.items[index].translationError == nil {
                _ = self.prepareClone(job.itemID)
            }
            self.persistSoon()
            self.publishLiveActivity()
        } timedOut: { _ in }
    }

    func editSpeaker(in conversation: UUID, itemID: UUID, change: ConversationSpeakerEdit) {
        if conversation == conversationID {
            if items.editSpeaker(itemID: itemID, change: change, reservedThrough: speakerTracker.lastID) {
                persist()
                publishLiveActivity()
            }
        } else {
            ConversationStore.shared.editSpeaker(conversationID: conversation, itemID: itemID, change: change)
        }
    }

    /// 用 Whisper 再识别一遍这句（按 SenseVoice 判断出的语言），明显不同就替换原文并重新翻译
    private func whisperCorrect(id: UUID, samples: [Float], src: Language, oldText: String,
                                gen: Int, revision: Int, cloudAddress: String) async {
        guard gen == runGen, !Task.isCancelled, (itemVersions[id] ?? 0) == revision,
              let i = items.firstIndex(where: { $0.id == id }),
              items[i].sourceText == oldText else { return }
        items[i].beginTranslationRevision()
        defer {
            if (itemVersions[id] ?? 0) == revision,
               let current = items.firstIndex(where: { $0.id == id }),
               items[current].translationPending == true {
                items[current].translationPending = nil
            }
            if gen == runGen && !Task.isCancelled { kickReader() }
        }
        let t0 = Date()
        guard let text = try? await cloud.correctTranscription(samples: samples, language: src.id,
                                                               address: cloudAddress) else { return }
        guard gen == runGen, !Task.isCancelled, (itemVersions[id] ?? 0) == revision else { return }
        let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
        guard SpeechTextFilter.isMeaningful(text), SpeechTextFilter.matchesLanguage(text, src.id) else {
            hearLog("Whisper 校正 \(secs)s：没把握，保留 SenseVoice 结果")
            return
        }
        guard Self.clearlyDifferent(oldText, text) else {
            hearLog("Whisper 校正 \(secs)s：基本一致")
            return
        }
        guard translations.isIdle, let i = items.firstIndex(where: { $0.id == id }) else { return }
        // 用户手改过这一句的话，就别再自动改写了：
        // 手改的版本才是用户要的（"我改的" 优先于 "机器觉得更准"）。
        if items[i].sourceText != oldText {
            hearLog("Whisper 校正：这一句已经改过了，不动它", .info)
            return
        }
        hearLogText("Whisper 校正 \(secs)s：「", String(oldText.prefix(30)) + "」→「" + String(text.prefix(30)) + "」")
        let tgt = items[i].target
        let previous = previousSegment(before: i)
        do {
            let out = try await translateFinal(text, from: src, to: tgt, previous: previous, stage: .revision) { _ in }
            guard gen == runGen else { return }
            // 期间又被人改过（手改或者又校正了一次）：这次的结果是旧的，丢掉
            guard (itemVersions[id] ?? 0) == revision,
                  let current = items.firstIndex(where: { $0.id == id }),
                  items[current].sourceText == oldText else { return }
            let wasReading = readingID == id
            if wasReading { stopReading() }
            items[current].sourceText = text
            items[current].corrected = true
            itemVersions[id] = revision + 1
            rememberReference(id, samples: samples, text: text)
            update(id, out, done: true)
            persist()
            if wasReading {
                readIndex = min(readIndex, current)
                kickReader()
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  gen == runGen, (itemVersions[id] ?? 0) == revision else { return }
            let level: LogLevel = (error as? CloudClient.CloudError)?.isBusy == true ? .info : .warning
            hearLog("校正后重新翻译未完成，保留原有译文：\(error)", level)
        }
    }

    /// 两次识别结果是不是“明显不同”：去掉标点、空格、大小写后比较，差 2 个字以上
    /// （很短的句子差 1 个字也算）
    static func clearlyDifferent(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> [Character] { Array(s.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let x = norm(a), y = norm(b)
        if x == y { return false }
        if x.isEmpty || y.isEmpty { return true }
        // 编辑距离
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = x[i - 1] == y[j - 1] ? prev[j - 1] : min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            prev = cur
        }
        let d = prev[y.count]
        return d >= 2 || (d == 1 && max(x.count, y.count) <= 8)
    }

    /// 等克隆声音生成好，最多等这么久。
    /// 超时了就先用系统声音念，克隆任务继续在后台跑（下次念同一句就直接有了）。
    private func waitClone(_ task: Task<CloneAudio?, Never>, seconds: Double) async -> CloneAudio? {
        let box = CloneOutcome()
        // 后台等着克隆出结果
        let watcher = Task { box.set(await task.value) }
        let deadline = Date().addingTimeInterval(seconds)
        while !box.isFinished, Date() < deadline {
            // 被取消了（退后台、用户点了停止）：立刻不等了。
            // 不看这个的话，Task.sleep 被取消会立刻返回，
            // 这个循环就在主线程上空转到 30/60 秒期限，界面卡住。
            if Task.isCancelled {
                hearLog("朗读：等克隆声音时被取消了，不等了", .info)
                return nil
            }
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                return nil
            }
        }
        if box.isFinished { return box.result }
        // 超时：不等了，先用系统声音
        return nil
    }

    /// 朗读一条译文：决定左右耳、声音和音高
    private func speak(_ item: TranslationItem) async {
        guard item.canReadAloud else { return }
        let text = item.translated
        // 这次朗读的身份：切到后台、或者被用户停了，就不要再出声
        let token = playbackToken

        // 译文是 A 语言还是 B 语言
        let slot = item.target == langA ? "A" : (item.target == langB ? "B" : "?")
        var pan: Float = 0
        if outputMode == .headphones, slot != "?" {
            let l = leftEar == slot, r = rightEar == slot
            if !l && !r { return }                       // 两耳都不播这种语言
            pan = (l && r) ? 0 : (l ? -1 : 1)
        }

        AudioRoute.apply(outputMode)
        // 扬声器外放模式下播报译文时始终静音麦克风（戴耳机 .headphones 保持全双工不静音），
        // 避免 Speaker 独立引擎 / AVSpeechSynthesizer 放出的译文声被麦克风回采为新原文。
        let mute = outputMode == .speaker && isRunning
        // 声音克隆：优先直接命中已完成的按句缓存（即使后续切换本地/云端、打开历史或服务暂时离线，也 0ms 秒播，绝不再提示「克隆服务不可用」）
        let cloneWait: Double = 60
        var cloned: CloneAudio?
        // 发了请求但没拿到声音 = 服务不可用；连请求都没发 = 这句没有声音样本
        var cloneAsked = false
        if voiceClone {
            let itemKey = itemCloneCacheKey(id: item.id, lang: item.target.id, text: text)
            if let cached = await CloneCache.shared.get(itemKey) {
                hearLog("声音克隆：命中已克隆句缓存，直接播放")
                cloned = cached
            } else {
                // ?? 的右边不能带 await（自动闭包里不支持异步），所以分开写
                var task = clonePipeline.existing(item.id)
                if task == nil { task = prepareClone(item.id) }
                if let t = task {
                    cloneAsked = true
                    cloned = await waitClone(t, seconds: cloneWait)
                    if Task.isCancelled || inBackground { return }
                }
            }
        }
        hearLog("朗读：\(item.target.displayName)，\(outputMode == .speaker ? "扬声器" : (pan < 0 ? "左耳" : (pan > 0 ? "右耳" : "双耳")))，\(cloned != nil ? "克隆原声" : "系统声音")")
        // 开了声音克隆却没拿到克隆声音：提醒一下
        if voiceClone, cloned == nil {
            if cloneAsked {
                // 请求发出去了但没等到声音：服务不可用
                hearLog("未取得可播放的克隆声音，改用系统声音朗读", .warning)
                if !cloneUnavailableNotified {
                    cloneUnavailableNotified = true
                    showToast("克隆声音暂不可用，已改用系统声音朗读", seconds: 4)
                }
            } else {
                // 连请求都没发：说清楚是什么原因（说得太短、太长、开关当时关着……）
                let (reason, level) = cloneMissingReason(item)
                hearLog("改用系统声音朗读（\(reason)）", level)
            }
        } else if cloned != nil {
            cloneUnavailableNotified = false
        }
        // 切到后台了：别出声（用户不在跟前听，吵得慌）。
        // 注意：上面等克隆声音的那段照样等完了——
        // 电脑那边的克隆请求要跑完，声音存着，回前台就能直接播。
        if inBackground { return }
        // 等克隆声音这段时间里可能已经切到后台、或者用户停了朗读：
        // 这时候一句都不该再出声（后台不自动播放）
        guard !inBackground, token == playbackToken, readingID == item.id else {
            hearLog("朗读：这一句不用播了（切到后台或者被取消）", .info)
            return
        }
        var myMuteGen = 0
        if mute {
            muteGeneration += 1
            myMuteGen = muteGeneration
            capture.muted = true
        }
        if outputMode == .speaker { recordSpokenTTS(text) }
        defer {
            if outputMode == .speaker { recordSpokenTTS(text) }
            // 连续朗读多句时，必须核对 muteGeneration（每次关麦自增）：
            // 若下一句已在 400ms 残响窗口内开始播放并再次关麦，旧句的延迟开麦回调直接作废，
            // 彻底杜绝“第 2 句播到一半被第 1 句的定时器把麦打开”的回声漏洞。
            if mute {
                let expectedMuteGen = myMuteGen
                Task { @MainActor [weak self] in
                    // 缩短残响静音尾窗至 150ms（原 400ms 容易切掉用户下一句开头），
                    // 且仅核对 muteGeneration，避免 playbackToken 变化导致麦克风卡在静音状态。
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard let self,
                          self.muteGeneration == expectedMuteGen else { return }
                    self.capture.muted = false
                }
            }
        }
        if let cloned {
            let outcome = await speaker.play(samples: cloned.samples, sampleRate: Double(cloned.sampleRate), pan: pan)
            switch outcome {
            case .played:
                break
            case .cancelled:
                // 播放途中被人停了（用户停了朗读 / 切到后台）：
                // 千万别再退回系统声音——那会造成"明明停了却又出声"
                hearLog("朗读：这一句被取消了，不出声", .info)
                return
            case .failed:
                // 克隆声音放不出来，退回系统声音，别让用户听个寂寞
                // （但如果这时用户已经停了朗读、或者切到后台了，就别再出声）
                if Task.isCancelled || inBackground || token != playbackToken || readingID != item.id { return }
                let fallbackVoice = preferredSystemVoice(for: item)
                await speaker.speak(SpeakRequest(text: text, locale: item.target.tts, voice: fallbackVoice, pan: pan))
            }
        } else {
            let sysVoice = preferredSystemVoice(for: item)
            await speaker.speak(SpeakRequest(text: text, locale: item.target.tts, voice: sysVoice, pan: pan))
        }
    }

    /// 按「系统朗读声音」设置解析本句应使用的系统音色（支持自动跟随说话人性别或固定男/女声）
    private func preferredSystemVoice(for item: TranslationItem) -> AVSpeechSynthesisVoice? {
        let gender: AVSpeechSynthesisVoiceGender?
        switch systemVoicePreference {
        case "male":
            gender = .male
        case "female":
            gender = .female
        case "default":
            gender = nil
        default:
            // "auto"：优先用说话人资料里的性别，其次用原声基频估算的性别
            switch item.speakerDetails?.gender {
            case .male:
                gender = .male
            case .female:
                gender = .female
            case nil:
                gender = detectedGenders[item.id]
            }
        }
        return Speaker.bestVoice(for: item.target.tts, gender: gender)
    }

    private func recordDetectedGender(_ gender: AVSpeechSynthesisVoiceGender, for id: UUID) {
        if detectedGenders[id] == nil {
            detectedGenderOrder.append(id)
            if detectedGenderOrder.count > 200 {
                let oldest = detectedGenderOrder.removeFirst()
                detectedGenders.removeValue(forKey: oldest)
            }
        }
        detectedGenders[id] = gender
    }

    // MARK: - 修改原文后重新翻译

    /// 每次外放关麦/主动开麦自增，用于防止连续朗读时上一句的 400ms 延迟开麦任务误开下一句的麦克风
    private var muteGeneration = 0

    /// 最近通过扬声器播报的译文队列，用于极短窗口（2.5s）的近完全一致回声兜底过滤
    private var recentSpokenTTS: [(text: String, at: Date)] = []

    private func recordSpokenTTS(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentSpokenTTS.append((trimmed, Date()))
        if recentSpokenTTS.count > 4 {
            recentSpokenTTS.removeFirst(recentSpokenTTS.count - 4)
        }
    }

    private func isLikelySpokenEcho(_ recognized: String) -> Bool {
        SpeechTextFilter.isLikelySpokenEcho(recognized, recentSpoken: recentSpokenTTS)
    }

    /// 每一句的版本号：改了原文就 +1。
    /// 翻译回来的时候核对版本，对不上就丢掉——
    /// 否则连续改同一句时，会出现"新原文配旧译文"。
    private var itemVersions: [UUID: Int] = [:]

    func retryTranslation(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.canRetryTranslation else { return }
        editSource(id, to: item.sourceText)
    }

    /// 修改任意历史对话里某条记录的原文，保存并重新翻译
    func editSource(in targetConversationID: UUID, itemID: UUID, to newText: String) {
        if targetConversationID == conversationID {
            editSource(itemID, to: newText)
            return
        }
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if readingID == itemID { stopReading() }
        guard let info = ConversationStore.shared.updateSourceText(
            conversationID: targetConversationID, itemID: itemID, to: text
        ) else { return }
        itemVersions[itemID] = (itemVersions[itemID] ?? 0) + 1
        let version = itemVersions[itemID] ?? 0
        hearLogText("历史对话重新翻译原文：", String(text.prefix(40)))
        Task {
            do {
                if translationEngine == "local" {
                    while isLoadingPhase { try? await Task.sleep(nanoseconds: 200_000_000) }
                    guard phase == .ready else { throw TranslatorError.notLoaded }
                }
                let result = try await translateFinal(text, from: info.source, to: info.target,
                                                      previous: info.previous) { _ in }
                guard itemVersions[itemID] == version else { return }
                ConversationStore.shared.commitTranslation(
                    conversationID: targetConversationID, itemID: itemID,
                    expectedSource: text, translation: result, done: true
                )
            } catch {
                guard itemVersions[itemID] == version else { return }
                hearLog("历史对话重新翻译失败：\(error)", .error)
                ConversationStore.shared.commitTranslation(
                    conversationID: targetConversationID, itemID: itemID,
                    expectedSource: text,
                    translation: translationFailureMessage(for: error), done: true
                )
            }
        }
    }

    func editSource(_ id: UUID, to newText: String) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = items.firstIndex(where: { $0.id == id }), !text.isEmpty,
              text != items[i].sourceText || items[i].canRetryTranslation else { return }
        if readingID == id { stopReading() }
        let src = items[i].source, tgt = items[i].target
        // 记下是哪一页：用户可能已经切到别的对话去了，
        // 译完要写回原来那一页，不能因为切页就把这次修改弄丢
        let convID = conversationID
        items[i].sourceText = text
        jobTokens[id] = nil
        translations.finished(id)
        items[i].done = true
        items[i].beginTranslationRevision()
        // 版本号 +1：前一次翻译回来的时候版本对不上，就不要了
        itemVersions[id] = (itemVersions[id] ?? 0) + 1
        let version = itemVersions[id] ?? 0
        persist()
        hearLogText("重新翻译原文：", String(text.prefix(40)))
        let previous = previousSegment(before: i)
        Task {
            do {
                // 本地翻译模型还在加载时先等它就绪
                if translationEngine == "local" {
                    while isLoadingPhase { try? await Task.sleep(nanoseconds: 200_000_000) }
                    guard phase == .ready else { throw TranslatorError.notLoaded }
                }
                let result = try await translateFinal(text, from: src, to: tgt, previous: previous) { _ in }
                // 期间又改过这一句：这次的结果是旧的，丢掉
                guard itemVersions[id] == version else {
                    hearLog("重新翻译：这一句已经改过了，这次的结果不用", .info)
                    return
                }
                // 写回原来那一页（用户可能已经切页了）
                applyTranslation(id, result, done: true, conversation: convID, expectedSource: text)
            } catch {
                guard itemVersions[id] == version else { return }
                hearLog("重新翻译失败：\(error)", .error)
                applyTranslation(id, translationFailureMessage(for: error), done: true,
                                 conversation: convID, expectedSource: text)
            }
            persist()
            kickReader()
        }
    }

    private func update(_ id: UUID, _ text: String, done: Bool, token: UUID? = nil) {
        // 旧任务的结果不写回（不然会把新任务的结果覆盖掉）
        if let token, jobTokens[id] != token { return }
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].done && !done { return }
        let oldText = items[i].translated
        items[i].applyTranslation(text, done: done)
        let changed = oldText != items[i].translated
        publishLiveActivity()
        // 播报开关只决定自动播放。译文定稿后仍准备克隆声音，供用户点按播放。
        if done, voiceClone, items[i].translationError == nil {
            if changed { discardCloneTask(id) }
            _ = prepareClone(id)
        }
    }

    private var liveActivityHeartbeat: Task<Void, Never>?

    private func liveActivityState() -> HearLiveActivityAttributes.ContentState {
        let hasLiveTranslation = !partial.isEmpty && !partialTranslation.isEmpty
        let item = hasLiveTranslation ? nil : (items.last { !$0.translated.isEmpty } ?? items.last)
        let namedSpeaker: String? = {
            guard let raw = item?.speakerName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  raw != "未分配",
                  raw.range(of: "^说话人\\s*\\d+$", options: .regularExpression) == nil else {
                return nil
            }
            return raw
        }()
        return HearLiveActivityAttributes.ContentState(
            sourceText: String((hasLiveTranslation ? displayedPartial
                                : item?.displayedSource(using: chineseDisplayLanguage) ?? "").prefix(320)),
            translatedText: String((hasLiveTranslation ? displayedPartialTranslation
                                    : item?.displayedTranslation(using: chineseDisplayLanguage) ?? "").prefix(320)),
            sourceLanguage: (hasLiveTranslation ? partialSource : item?.source)?.name ?? langA.name,
            targetLanguage: (hasLiveTranslation ? partialTranslationTarget : item?.displayedTranslationTarget)?.name ?? langB.name,
            speaker: namedSpeaker,
            speakerGender: item?.speakerDetails?.gender?.rawValue,
            translationOnly: liveActivityOnlyTranslation,
            isLive: isRunning,
            updatedAt: Date())
    }

    private func publishLiveActivity() {
        guard isRunning, !talkMode else { return }
        HearLiveActivityController.shared.update(liveActivityState())
    }

    private func endLiveActivity() {
        liveActivityHeartbeat?.cancel()
        liveActivityHeartbeat = nil
        HearLiveActivityController.shared.end(liveActivityState())
    }

    // MARK: - 声音克隆

    private static let clonePendingKey = "zipVoiceLoadPending"
    private var cloneLoadTask: Task<Void, Never>?

    /// 自己填的地址优先，没填就用默认地址
    static func effectiveAddress(fallback def: String, own: String) -> String {
        let o = own.trimmingCharacters(in: .whitespacesAndNewlines)
        return o.isEmpty ? def : o
    }

    /// iCloud 把设置同步过来了：把新设置直接换上，不用重开 App
    func reloadSyncedSettings() {
        applyingSyncedSettings = true
        defer { applyingSyncedSettings = false }
        let d = UserDefaults.standard
        // 在线模型先换：语音克隆走云端的话，本地的克隆模型要卸掉
        let ca = d.string(forKey: "cloudAddress") ?? ""
        if ca != cloudAddress { cloudAddress = ca }
        let cm = d.object(forKey: "cloudModelAddress") as? [String: String] ?? [:]
        if cm != cloudModelAddress { cloudModelAddress = cm }
        let cas = d.string(forKey: "cloudASRScheme") ?? "sensevoice+whisper"
        if cas != cloudASRScheme { cloudASRScheme = cas }
        if !voiceCloneCloud { voiceCloneCloud = true }
        let te = d.string(forKey: "translationEngine") ?? translationEngine
        if te != translationEngine { translationEngine = te }
        let hh = d.string(forKey: "hfHost") ?? "huggingface.co"
        if hh != hfHost { hfHost = hh }
        let a = Language.find(d.string(forKey: "langA") ?? "zh")
        let b = Language.find(d.string(forKey: "langB") ?? "en")
        setLanguagePair(left: a, right: b)
        let so = d.object(forKey: "speakOutput") as? Bool ?? true
        if so != speakOutput { speakOutput = so }
        let showIcon = d.object(forKey: "showReadingIcon") as? Bool ?? true
        if showIcon != showReadingIcon { showReadingIcon = showIcon }
        let liveActivityOnly =
            d.object(forKey: "liveActivityOnlyTranslation") as? Bool ?? false
        if liveActivityOnly != liveActivityOnlyTranslation {
            liveActivityOnlyTranslation = liveActivityOnly
        }
        let uc = d.object(forKey: "useContext") as? Bool ?? true
        if uc != useContext { useContext = uc }
        let sen = d.object(forKey: "sensitivity") as? Double ?? 12
        if abs(sen - sensitivity) > 0.001 { sensitivity = sen }
        let sil = d.object(forKey: "silenceMs") as? Double ?? 700
        if abs(sil - silenceMs) > 0.001 { silenceMs = sil }
        let gl = d.string(forKey: "glossary") ?? ""
        if gl != glossary { glossary = gl }
        let om = AudioOutput(rawValue: d.string(forKey: "outputMode") ?? "") ?? .speaker
        if om != outputMode { outputMode = om }
        if let manual = d.object(forKey: "manualSpeakerOutput") as? Bool, manualSpeaker != manual {
            manualSpeaker = manual
        }
        let le = d.string(forKey: "leftEar") ?? "A"
        if le != leftEar { leftEar = le }
        let re = d.string(forKey: "rightEar") ?? "B"
        if re != rightEar { rightEar = re }
        let vc = d.object(forKey: "voiceClone") as? Bool ?? false
        if vc != voiceClone { voiceClone = vc }
        let eng = Self.normalizedASREngine(d.string(forKey: "asrEngine") ?? asrEngine)
        if eng != asrEngine { asrEngine = eng }
        let vp = d.object(forKey: "voiceProcessing") as? Bool ?? true
        if vp != voiceProcessing { voiceProcessing = vp }
        let sfr = d.object(forKey: "saveFullRecording") as? Bool ?? false
        if sfr != saveFullRecording { saveFullRecording = sfr }
        let isrc = d.string(forKey: "inputSource") ?? "phone"
        if isrc != inputSource { inputSource = isrc }
        let script = ChineseDisplayLanguage(rawValue: d.string(forKey: ChineseDisplayLanguage.preferenceKey) ?? "")
            ?? .simplified
        if script != chineseDisplayLanguage { chineseDisplayLanguage = script }
        let identifySpeakers = (d.object(forKey: "speakerTrackingEnabled") as? Bool) ?? true
        if identifySpeakers != speakerTrackingEnabled { speakerTrackingEnabled = identifySpeakers }
        // 大模型配置、日志设置各自存着，让它们也重新读一遍
        LLMSettings.shared.reloadFromDefaults()
        AppLog.shared.reloadFromDefaults()
        hearLog("iCloud 同步：设置已经直接换上")
    }

    /// 把三个地址告诉客户端
    private func updateCloudAddresses() {
        let a = Self.effectiveAddress(fallback: cloudAddress, own: cloudOwnAddress(.asr))
        let m = Self.effectiveAddress(fallback: cloudAddress, own: cloudOwnAddress(.mt))
        let c = Self.effectiveAddress(fallback: cloudAddress, own: cloudOwnAddress(.clone))
        Task {
            await cloud.setAddresses(asr: a, mt: m, clone: c)
            // 通用服务地址也记下来：某个模型自己的地址连不上时，可以退回用它
            await cloud.setSharedAddress(cloudAddress)
            await cloud.setASRScheme(cloudASRScheme)
        }
    }

    // MARK: - 本地引擎互斥

    /// 是不是"我们的"本地模型引擎（苹果自带、云端都不算，它们不占我们的内存）
    static func isLocalEngine(_ e: String) -> Bool {
        switch e {
        case "sensevoice", "local": return true
        default: return false
        }
    }

    // MARK: - 在线模型（三个接口）

    /// 这个模型现在是不是走云端
    func cloudEnabled(_ model: CloudModel) -> Bool {
        switch model {
        case .asr: return usingCloudASR
        case .mt: return usingCloudMT
        case .clone: return usingCloudClone
        }
    }

    /// 打开或关闭某个模型的云端模式。
    @discardableResult
    func setCloudEnabled(_ model: CloudModel, _ on: Bool) -> String? {
        switch model {
        case .asr:
            if on { asrEngine = "cloud"; return nil }
            if asrEngine == "cloud" {
                asrEngine = "sensevoice"
            }
        case .mt:
            if on { translationEngine = "cloud"; return nil }
            if translationEngine == "cloud" {
                translationEngine = "local"
            }
        case .clone:
            if on { voiceCloneCloud = true; voiceClone = true; return nil }
            // 本地克隆界面已隐藏，关闭云端克隆时直接关闭声音克隆开关
            voiceClone = false
            voiceCloneCloud = true
        }
        return nil
    }

    /// 这个模型自己填的地址（空 = 用默认地址）
    func cloudOwnAddress(_ model: CloudModel) -> String {
        cloudModelAddress[model.rawValue] ?? ""
    }

    func setCloudOwnAddress(_ model: CloudModel, _ addr: String) {
        var d = cloudModelAddress
        if addr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            d.removeValue(forKey: model.rawValue)
        } else {
            d[model.rawValue] = addr
        }
        cloudModelAddress = d
    }

    /// 这个模型实际用的地址
    func cloudEffectiveAddress(_ model: CloudModel) -> String {
        Self.effectiveAddress(fallback: cloudAddress, own: cloudOwnAddress(model))
    }

    /// 界面上显示的状态：未填写 / 正常 / 异常
    /// （用不用云端由"引擎管理"决定，这里只看地址通不通）
    func cloudStatusText(_ model: CloudModel) -> String {
        cloudStatus[model.rawValue] ?? Self.cloudStatusChecking
    }

    /// 共享服务地址（三个模型默认都用它）的状态
    var cloudServiceStatusText: String {
        cloudStatus[Self.cloudServiceKey] ?? Self.cloudStatusChecking
    }

    /// 状态一共这三种
    static let cloudStatusUnset = "未填写"
    static let cloudStatusOK = "正常"
    static let cloudStatusBad = "异常"
    /// 模型还在加载（刚下完、刚起服务）：不是出错，显示成"加载中"
    static let cloudStatusLoading = "加载中"
    static let cloudStatusChecking = "检测中"
    private var cloudStatusRevision = 0
    /// 共享服务地址在状态表里的名字
    static let cloudServiceKey = "service"

    /// 刷新服务地址和三个模型的状态
    func refreshCloudStatus() async {
        cloudStatusRevision += 1
        let revision = cloudStatusRevision
        var status: [String: String] = [:]
        // 要问的地址（去重）：共享服务地址 + 三个模型实际用的地址
        var wanted: [String] = []
        let defAddr = CloudClient.cleanURL(cloudAddress)
        let addresses = Dictionary(uniqueKeysWithValues: CloudModel.allCases.map {
            ($0.rawValue, CloudClient.cleanURL(cloudEffectiveAddress($0)))
        })
        if !defAddr.isEmpty { wanted.append(defAddr) }
        for m in CloudModel.allCases {
            let a = addresses[m.rawValue] ?? ""
            if !a.isEmpty && !wanted.contains(a) { wanted.append(a) }
        }
        // 同一个地址只问一次。kind = 上面跑的是总服务还是单独的 llama-server，
        // health = 各模型的状态。几个地址一起问，谁先回来谁先算，不排队等
        var reachable: Set<String> = []
        var models: [String: [String: String]] = [:]
        var kinds: [String: CloudClient.ServiceKind] = [:]
        await withTaskGroup(of: (String, CloudClient.ProbeResult?).self) { g in
            for a in wanted {
                g.addTask { (a, await CloudClient.probe(address: a)) }
            }
            for await (a, info) in g {
                if let info {
                    reachable.insert(a)
                    kinds[a] = info.kind
                    models[a] = info.health
                }
            }
        }

        guard revision == cloudStatusRevision, !Task.isCancelled else { return }

        var usedAddress: [String: String] = [:]
        // 识别这边要单独记两件事：电脑上跑的是哪个 Whisper、有没有 SenseVoice
        var asrModelName = ""
        var senseState = ""
        var asrSchemes: [String] = []

        // 共享服务地址
        if defAddr.isEmpty {
            status[Self.cloudServiceKey] = Self.cloudStatusUnset
        } else {
            status[Self.cloudServiceKey] = reachable.contains(defAddr) ? Self.cloudStatusOK : Self.cloudStatusBad
        }

        // 三个模型各自的地址（没填就用共享的）
        for m in CloudModel.allCases {
            // 要试的地址：先它自己配的，不行再试通用服务地址
            // （通用服务 8000 会把请求转发给真正干活的模型服务，
            //   所以就算某个模型单独配的地址不通，用它也能正常工作）
            var cands: [String] = []
            let own = addresses[m.rawValue] ?? ""
            if !own.isEmpty { cands.append(own) }
            if !defAddr.isEmpty && !cands.contains(defAddr) { cands.append(defAddr) }
            if cands.isEmpty {
                status[m.rawValue] = Self.cloudStatusUnset
                continue
            }
            var used = ""
            var readiness = CloudModelReadiness.unavailable
            var asrHealth: [String: String] = [:]
            for addr in cands {
                guard reachable.contains(addr), let health = models[addr] else { continue }
                if m == .asr, asrHealth.isEmpty, kinds[addr] == .aggregator { asrHealth = health }
                let current: CloudModelReadiness
                if kinds[addr] == .aggregator {
                    current = CloudModelReadiness(reported: health[m.rawValue], ready: health["\(m.rawValue)_ready"])
                } else {
                    current = m == .asr ? .unknown : CloudModelReadiness(reported: health["status"], ready: nil)
                }
                if current == .ready {
                    readiness = .ready
                    used = addr
                    if m == .asr { asrHealth = health }
                    break
                }
                if current == .loading || (current == .unknown && readiness != .loading) {
                    readiness = current
                }
            }
            let ok = readiness == .ready
            var text = readiness.rawValue
            // 顺便把电脑上跑的是哪个模型写出来：启动时可以按类型选大模型，
            // 手机上一眼就能看到"现在用的是哪个"
            if ok, !used.isEmpty {
                let health = models[used] ?? [:]
                if let name = health["\(m.rawValue)_model"], !name.isEmpty {
                    text += "（\(name)）"
                }
            }
            status[m.rawValue] = text
            usedAddress[m.rawValue] = ok ? used : ""
            if m == .asr {
                // 老版本的服务没报这些字段 → 空（当作不知道，照旧给用户选）
                asrModelName = asrHealth["asr_model"] ?? ""
                senseState = asrHealth["sensevoice"] ?? ""
                let raw = asrHealth["asr_schemes"] ?? ""
                asrSchemes = raw.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }
        if cloudStatus != status { cloudStatus = status }
        if cloudStatusAddress != usedAddress { cloudStatusAddress = usedAddress }
        if cloudASRModelName != asrModelName { cloudASRModelName = asrModelName }
        if cloudSenseVoiceState != senseState { cloudSenseVoiceState = senseState }
        if cloudASRSchemes != asrSchemes { cloudASRSchemes = asrSchemes }
        restorePreferredEngines(using: status)
    }

    /// 设置访问口令（填了以后每个请求都带上它）
    func setCloudAccessToken(_ t: String) {
        let v = t.trimmingCharacters(in: .whitespacesAndNewlines)
        cloudAccessToken = v
        CloudClient.accessToken = v
    }

    // MARK: - 云端证书：配对

    func connectVerifiedCloudAddress(_ address: String, root: Data) {
        UserDefaults.standard.set(root, forKey: "cloudPinnedRoot")
        LocalServerTrust.pinRoot(root)
        cloudStrictMode = true
        cloudRootFingerprint = Self.certFingerprint(root)
        cloudAddress = address
    }

    /// 证书指纹（SHA-256，大写冒号分隔），跟电脑上打印出来的一致
    static func certFingerprint(_ der: Data) -> String {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData),
              let data = SecCertificateCopyData(cert) as Data? else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: - 云端失败时的保底

    private func restorePreferredEngines(using status: [String: String]) {
        guard cloudRecovery.hasBackup else { return }
        let asrWasCloud = cloudRecovery.preferred(.asr) == "cloud" && !usingCloudASR
        let mtWasCloud = cloudRecovery.preferred(.mt) == "cloud" && !usingCloudMT
        let betweenSegments = !isRunning || currentSeg <= finishedSeg
        var stillWaiting = false
        cloudRecovery.applying {
            if asrWasCloud {
                if betweenSegments, recognition.queue.isIdle,
                   status[CloudModel.asr.rawValue]?.hasPrefix(Self.cloudStatusOK) == true {
                    stopLiveEngine()
                    stopAppleASR()
                    asrEngine = "cloud"
                    cloudRecovery.restored(.asr)
                    hearLog("云端语音识别已恢复")
                } else {
                    stillWaiting = true
                }
            }
            if mtWasCloud {
                if status[CloudModel.mt.rawValue]?.hasPrefix(Self.cloudStatusOK) == true {
                    translationEngine = "cloud"
                    cloudRecovery.restored(.mt)
                    hearLog("云端文本翻译已恢复")
                } else {
                    stillWaiting = true
                }
            }
        }
        if !stillWaiting { cloudRecovery.clear() }
    }

    /// 云端失败换引擎后，重新开始聆听的任务（只能有一个，避免麦克风被开两次）
    private var restartTask: Task<Void, Never>?

    /// 云端接口调用失败（网络不稳定、模型没起来、服务挂了）：
    /// 自动换回苹果自带引擎，别让翻译直接停摆。
    /// 返回 true 表示已经切换了。
    @discardableResult
    func cloudFallbackToApple(_ model: CloudModel, reason: String) -> Bool {
        let wasRunning = isRunning
        switch model {
        case .asr:
            guard asrEngine == "cloud" else { return false }
            // 挑一个"真的能用"的：苹果自带优先（iOS 26 以上），
            // 其次是已经装好的本地模型（没装的选了也起不来）
            let fb: String? = appleAvailable ? "apple"
                : (!senseRequiresRestart && isInstalled(.senseVoice) ? "sensevoice" : nil)
            guard let fb else {
                hearLog("云端识别失败，但没有可用的本地引擎，保持原来的设置", .warning)
                showToast("云端识别失败，本地也没有可用的识别模型", seconds: 4)
                return false
            }
            cloudRecovery.remember(asr: asrEngine, mt: translationEngine)
            cloudRecovery.applying { asrEngine = fb }
            if wasRunning, fb == "apple" { startAppleASR() }
        case .mt:
            guard translationEngine == "cloud" else { return false }
            let fb: String? = appleAvailable ? "apple"
                : (isInstalled(.translation) ? "local" : nil)
            guard let fb else {
                hearLog("云端翻译失败，但没有可用的本地模型，保持原来的设置", .warning)
                showToast("云端翻译失败，本地也没有可用的翻译模型", seconds: 4)
                return false
            }
            cloudRecovery.remember(asr: asrEngine, mt: translationEngine)
            cloudRecovery.applying { translationEngine = fb }
        case .clone:
            guard voiceCloneCloud else { return false }
            hearLog("云端克隆暂不可用，这句改用系统声音：\(reason)", .warning)
            return true
        }
        cloudRecovery.schedule { [weak self] in await self?.refreshCloudStatus() }
        hearLog("云端\(model.title)调用失败，临时使用本地引擎：\(reason)", .warning)
        showToast("云端\(model.title)暂不可用，已切换本地引擎", seconds: 4)
        // 换引擎会停掉当前会话，接着把它起回来，翻译不中断。
        // 注意：上面的 asrEngine/translationEngine 改动已经触发了 stop()，
        // 这里必须等它真的停完再开始，否则麦克风会被开两次（AVAudioEngine 崩）。
        if wasRunning {
            restartTask?.cancel()
            restartTask = Task { @MainActor in
                // 等 stop() 收尾
                for _ in 0..<30 {
                    if !self.isRunning { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                // 等模型加载/卸载完
                for _ in 0..<300 {
                    if !self.isAnyModelLoading { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard !Task.isCancelled else { return }
                guard self.phase == .ready, !self.isRunning else { return }
                _ = await self.beginListening()
            }
        }
        return true
    }

    /// 这个 App 现在还能用多少内存（MB）
    static func freeMB() -> Int { Int(os_proc_available_memory() / 1_048_576) }

    /// 过一会儿再加载声音克隆（等其他模型加载完、界面动画结束）
    private func scheduleCloneLoad(delay: Double) {
        cloneLoadTask?.cancel()
        cloneLoadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.loadClonerIfNeeded()
        }
    }

    private func loadClonerIfNeeded(allowDuringModelLoading: Bool = false) async {
        guard !Task.isCancelled, !localOptionalWorkPaused, voiceClone, !voiceCloneCloud,
              cloneInstalled, !cloneLoading else { return }
        if isLoadingPhase, !allowDuringModelLoading { return }
        cloneLoading = true
        cloneLoadingSeconds = 0
        let cloneStart = Date()
        let cloneTicker = Task { @MainActor [weak self] in
            var warned = false
            while !Task.isCancelled {
                let secs = max(0, Int(Date().timeIntervalSince(cloneStart)))
                self?.cloneLoadingSeconds = secs
                if secs > 120 && !warned {
                    warned = true
                    hearLog("语音克隆模型加载已超过 2 分钟", .warning)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer {
            cloneTicker.cancel()
            cloneLoading = false
            cloneLoadingSeconds = 0
            modelsRevision += 1
        }
        if await cloner.isLoaded { return }
        guard !Task.isCancelled, !localOptionalWorkPaused, voiceClone, !voiceCloneCloud else { return }
        let free = Self.freeMB()
        let modelMB = Int(ModelManager.folderSize(ZipVoiceModel.directory) / 1_048_576)
        let required = max(modelMB + 300, 500)
        guard free >= required else {
            hearLog("ZipVoice：可用内存 \(free) MB，低于加载门槛 \(required) MB", .warning)
            showToast("内存不足，暂用系统声音朗读")
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.clonePendingKey)
        defaults.synchronize()
        defer { defaults.removeObject(forKey: Self.clonePendingKey) }
        let start = ContinuousClock.now
        hearLog("ZipVoice：开始加载，本机可用内存 \(free) MB")
        do {
            try await cloner.load()
            guard !Task.isCancelled, voiceClone, !voiceCloneCloud else { return }
            hearLog("ZipVoice：加载完成，可用内存 \(Self.freeMB()) MB，耗时 \(start.duration(to: .now))")
            if !allowDuringModelLoading {
                showToast("本地声音克隆模型已就绪", placement: .modelStatus)
            }
        } catch is CancellationError {
            return
        } catch {
            hearLog("ZipVoice 加载失败：\(error)", .error)
            showToast("本地声音克隆模型加载失败，暂用系统声音朗读")
        }
    }

    private func rememberReference(_ id: UUID, samples: [Float], text: String) {
        clonePipeline.remember(id, samples: samples, text: text, enabled: voiceClone)
        // 后台异步估算原声基频（<1ms），供系统朗读自动区分男声 / 女声使用
        if detectedGenders[id] == nil, samples.count >= 1_600 {
            let slice = samples.count > 48_000 ? Array(samples.prefix(48_000)) : samples
            Task.detached(priority: .utility) { [weak self] in
                guard let f0 = VoiceAnalyzer.estimateF0(slice) else { return }
                let gender: AVSpeechSynthesisVoiceGender = f0 < 165 ? .male : .female
                await MainActor.run {
                    self?.recordDetectedGender(gender, for: id)
                }
            }
        }
    }

    private func cloneReference(for item: TranslationItem) -> SessionClonePipeline.Reference? {
        clonePipeline.reference(for: item, in: items, hasText: Self.hasRealText)
    }

    /// 这句为什么没能用克隆声音（写进日志，别只说一句"没有样本"）
    private func cloneMissingReason(_ item: TranslationItem) -> (String, LogLevel) {
        if !voiceClone { return ("声音克隆开关没有打开", .info) }
        if clonePipeline.didTimeOut(item.id) { return ("这句的云端克隆已超时", .info) }
        if item.translated.isEmpty { return ("这句还没有译文", .warning) }
        if item.translated.hasPrefix("（翻译失败") { return ("这句翻译失败了", .warning) }
        // 克隆模型只会说这几门语言（说译文那门语言，样本是源语言的，这是跨语言克隆）
        if !usingCloudClone, (!ZipVoiceModel.supports(item.target.id) || !ZipVoiceModel.supports(item.source.id)) {
            return ("本地 ZipVoice 仅支持中英文", .info)
        }
        if !usingCloudClone, !cloneInstalled { return ("尚未下载本地 ZipVoice 模型", .warning) }
        if CloudVoiceReference.languageNames[item.target.id] == nil {
            return ("\(item.target.displayName)这个语言声音克隆不支持", .info)
        }
        guard let ref = cloneReference(for: item) else {
            if let issue = clonePipeline.issue(for: item.id) { return (issue, .info) }
            return ("这句没有留到声音样本", .warning)
        }
        let refText = ref.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if refText.isEmpty || refText == "…" {
            let reason = Self.hasRealText(item.sourceText)
                ? "参考文字还没有更新到这句的原文"
                : "声音样本没有可用的参考文字"
            return (reason, .warning)
        }
        return ("克隆任务没有启动", .warning)
    }

    /// 声音克隆的缓存键：语言 + 文字 + 参考音频的指纹。
    ///
    /// 参考音频一定要算进去：同一句话换了说话人（或者换了参考音频），
    /// 克隆出来的声音是不一样的。只用"语言+文字"当键的话，
    /// 换个人说话就会命中上一个人的缓存——听着像别人的声音。
    ///
    /// v4 = 键里加上了参考音频的指纹
    private func itemCloneCacheKey(id: UUID, lang: String, text: String) -> String {
        "item|\(id.uuidString)|\(lang)|\(text)"
    }

    private func cloneCacheKey(lang: String, text: String, ref: [Float]) -> String {
        // 指纹：隔几个采样取一个，算个 FNV-1a（不用整个音频算，太慢）
        var fp: UInt64 = 1469598103934665603
        var i = 0
        while i < ref.count {
            let q = Int(ref[i] * 32767) & 0xFF
            fp = (fp ^ UInt64(q)) &* 1099511628211
            i += 37
        }
        return "v4|\(lang)|\(text)|\(fp)"
    }

    private func discardCloneTask(_ id: UUID) { clonePipeline.cancel(id) }
    private func clearCloneTasks() { clonePipeline.cancelAll() }

    /// 在后台准备克隆声音。已有任务直接复用，避免同一句发出重复请求。
    private func prepareClone(_ id: UUID) -> Task<CloneAudio?, Never>? {
        guard voiceClone, usingCloudClone || !localOptionalWorkPaused, !clonePipeline.didTimeOut(id) else { return nil }
        // 合并同一句的在途请求，成功结果保存在音频缓存，失败允许重试。
        if let existing = clonePipeline.existing(id) { return existing }
        guard let item = items.first(where: { $0.id == id }),
              let ref = cloneReference(for: item),
              item.canReadAloud,
              CloudVoiceReference.languageNames[item.target.id] != nil else { return nil }
        let text = item.translated, lang = item.target.id
        let refText = ref.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.hasRealText(refText) else { return nil }
        // 云端的参考音频沿用既有降噪。
        // 克隆会把参考音频里的环境音一起学过去，
        // 不降噪的话环境音就跟着念出来，听着是"有杂的声音"
        let refSamples = usingCloudClone ? CloudVoiceReference.denoise(ref.samples) : ref.samples
        if !usingCloudClone, (!ZipVoiceModel.supports(lang) || !ZipVoiceModel.supports(item.source.id)) { return nil }
        let cloudModel = (cloudCloneModel == "edge_tts") ? "edge_tts" : "qwen3"
        let genderHint: String = {
            if systemVoicePreference == "male" { return "male" }
            if systemVoicePreference == "female" { return "female" }
            if let f0 = VoiceAnalyzer.estimateF0(ref.samples) {
                return f0 < 165 ? "male" : "female"
            }
            return ""
        }()
        let backend = usingCloudClone ? "cloud-\(cloudModel)" : "zipvoice"
        let key = backend + "-" + cloneCacheKey(lang: lang, text: text + "\n" + refText, ref: ref.samples)
        let itemKey = backend + "-" + itemCloneCacheKey(id: id, lang: lang, text: text)
        let cloner = self.cloner
        let cloud = self.cloud
        let useCloud = usingCloudClone
        return clonePipeline.start(id) { jobID in
            Task<CloneAudio?, Never>.detached(priority: .userInitiated) { [weak self] in
                do {
                    try Task.checkCancellation()
                    // 之前生成过一样的，直接拿来放，不用再等模型算一遍
                    var cached = await CloneCache.shared.get(itemKey)
                    if cached == nil {
                        cached = await CloneCache.shared.get(key)
                    }
                    if let cached {
                        hearLog("声音克隆：命中缓存，直接播放")
                        _ = await CloneCache.shared.put(itemKey, cached)
                        return cached
                    }
                    if useCloud {
                        // 把可用内存一起记上：万一又被系统杀掉，日志里能看出来
                        let memMB = await MainActor.run { Self.freeMB() }
                        hearLogNow("声音克隆（云端 \(cloudModel)）：开始生成（可用内存 \(memMB) MB）")
                        // 语言名要用模型认的那种写法（english/chinese），和本地跑的时候一样
                        let cloudLang = CloudVoiceReference.languageNames[lang] ?? lang
                        let out: CloneAudio
                        do {
                            out = try await cloud.clone(text: text, lang: cloudLang,
                                                        reference: refSamples, referenceText: refText,
                                                        engine: cloudModel, gender: genderHint)
                        } catch {
                            let cloudError = error as? CloudClient.CloudError
                            if cloudError?.isInferenceTimeout == true, !Task.isCancelled {
                                await MainActor.run { self?.clonePipeline.markTimedOut(id, token: jobID) }
                            }
                            let keepEngine = cloudError?.shouldKeepConfiguredEngine ?? false
                            if !Task.isCancelled, !keepEngine {
                                let why = error.localizedDescription
                                await MainActor.run {
                                    if let self, self.clonePipeline.isCurrent(id, token: jobID) {
                                        self.cloudFallbackToApple(.clone, reason: why)
                                    }
                                }
                            }
                            return nil
                        }
                        hearLogNow("声音克隆（云端）：结束，生成 \(String(format: "%.1f", Double(out.samples.count) / Double(out.sampleRate))) 秒声音")
                        _ = await CloneCache.shared.put(itemKey, out)
                        return await CloneCache.shared.put(key, out)
                    }
                    guard await cloner.isLoaded else { return nil }
                    hearLogNow("声音克隆（本地）：开始生成")
                    let out = try await cloner.synthesize(text: text, language: lang,
                                                          reference: ref.samples, referenceText: refText)
                    hearLogNow("声音克隆（本地）：结束，生成 \(String(format: "%.1f", Double(out.samples.count) / Double(out.sampleRate))) 秒声音")
                    // 存进缓存，下次同一句话直接播放
                    _ = await CloneCache.shared.put(itemKey, out)
                    return await CloneCache.shared.put(key, out)
                } catch {
                    guard !Task.isCancelled else { return nil }
                    hearLog("声音克隆生成失败：\(error)", .error)
                    return nil
                }
            }
        }
    }

    // MARK: - 设置

    private func setLanguagePair(left: Language, right: Language) {
        guard left != right, left != langA || right != langB else { return }
        let previous = (left: langA, right: langB)
        swapping = true
        langA = left
        langB = right
        swapping = false
        languagePairChanged(from: previous)
    }

    private func languageChanged(old: Language, isA: Bool) {
        guard !swapping, old != (isA ? langA : langB) else { return }
        let previous = (left: isA ? old : langA, right: isA ? langB : old)
        if langA == langB {               // 两边选成一样时自动对调
            swapping = true
            if isA { langB = old } else { langA = old }
            swapping = false
        }
        languagePairChanged(from: previous)
    }

    private func languagePairChanged(from previous: (left: Language, right: Language)) {
        save("langA", langA.id); save("langB", langB.id)
        resetLanguagePreview()
        updateItemSides(from: previous)
        if usingAppleTranslation { prepareAppleTranslation() }
        if isRunning, dualLive, previous.left != langB || previous.right != langA { startAppleASR() }
    }

    private func updateItemSides(from previous: (left: Language, right: Language)) {
        guard !items.isEmpty else { return }
        let current = (left: langA, right: langB)
        let updated = items.map { original in
            var item = original
            item.updateSide(from: previous, to: current)
            return item
        }
        if updated != items { items = updated }
        persistSoon()
    }

    private func resetLanguagePreview() {
        lastLangID = nil
        cancelASRPreview()
        cancelMTPreview()
        translator.cancelPreview()
        partial = ""
        partialSource = nil
        partialTranslation = ""
        partialTranslationTarget = nil
        previews.translationRequest = nil
        previews.textBySegment.removeAll()
    }

    private func segmenterConfig() -> Segmenter.Config {
        var c = Segmenter.Config()
        c.sensitivityDB = Float(sensitivity)
        c.silenceMs = Int(silenceMs)
        // 对话翻译模式需要识别“好”“是”之类的短回答，
        // 门槛比实时翻译低（400ms → 200ms）
        c.minSpeechMs = usesDualConversationButtons ? 200 : 400
        c.holdMode = usesDualConversationButtons
        return c
    }

    private func pushConfig() {
        capture.updateConfig(segmenterConfig())
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
