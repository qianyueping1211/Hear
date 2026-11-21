import SwiftUI
import UIKit
import AVFoundation
import Translation
import Security
import CryptoKit
import os

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
        if captureHealth == .backlogged { return "收音正常，正在处理积压音频…" }
        let count = recognitionQueue.pendingCount
        return count > 1 ? "收音正常，\(count) 句等待识别…" : activity
    }
    /// 实时翻译按钮上方的短暂提示（几秒后自动消失）
    @Published private(set) var toast: String?
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
    /// 正在等用户确认的根
    @Published var pendingPairFingerprint: String = ""
    @Published var pendingPairRoot: Data = Data()
    /// 弹出"确认指纹"的提示框
    @Published var showPairConfirm = false

    /// 电脑上没有 SenseVoice 的状态："" = 还不知道（还没问过服务），
    /// "就绪" / "没装"。老版本的服务没这个字段，就当作不知道（照旧给用户选）。
    @Published private(set) var cloudSenseVoiceState: String = ""
    /// 电脑上实际能用的识别方案（服务报上来的清单）。
    /// App 的识别方案列表就是照着它来的：电脑上没装的就一个都不给。
    @Published private(set) var cloudASRSchemes: [String] = []
    /// 每个模型实际连上的地址（模型自己的地址不通、用通用服务地址顶上的，记通用那个）
    @Published private(set) var cloudStatusAddress: [String: String] = [:]
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
    /// 语音识别走云端
    var usingCloudASR: Bool { asrEngine == "cloud" }
    /// 文本翻译走云端
    var usingCloudMT: Bool { translationEngine == "cloud" }
    /// 声音克隆走云端
    var usingCloudClone: Bool { voiceClone && voiceCloneCloud }

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
    /// 本地模型刚加载好（用来提示用户，过几秒自动消失）
    @Published private(set) var modelsJustLoaded = false
    /// 正在加载的东西（界面上显示进度用）
    var loadingHint: String? {
        if cloneLoading { return "正在加载声音克隆模型…" }
        if isLoadingPhase { return loadingText }
        return nil
    }
    @Published var asrEngine: String {
        didSet {
            // 自动回退（云端挂了临时换一个）：不写进设置、也不停录音。
            // 用户自己选的还是"云端"，等服务恢复了要换回去——
            // 这里要是保存了、或者把这一段话掐断了，用户会以为是自己设置错了。
            if !inEngineFallback {
                save("asrEngine", asrEngine)
                // 用户自己在设置里改的：清掉"回退前的备份"（备份已经没意义了）
                clearPreferredEngineBackup()
            }
            guard asrEngine != oldValue else { return }
            hearLog("识别引擎改为 \(asrEngine)")
            enforceLanguages()
            if isRunning && !inEngineFallback { stop(readAfter: false) }
            Task { await reloadIfLocal() }       // 加载新引擎需要的模型，不用的卸掉省内存
        }
    }
    // 翻译引擎："apple" 苹果自带（系统翻译）/ "local" 本地模型（Hy-MT2）/ "" 还没选
    @Published var translationEngine: String {
        didSet {
            // 自动回退时同样不保存、不停录音（见 asrEngine 的说明）
            if !inEngineFallback {
                save("translationEngine", translationEngine)
                clearPreferredEngineBackup()
            }
            guard translationEngine != oldValue else { return }
            hearLog("翻译引擎改为 \(translationEngine)")
            if isRunning && !inEngineFallback { stop(readAfter: false) }
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

    /// 重开麦克风（改了输入相关的设置时用）
    private func restartCapture() {
        hearLog("重开麦克风（语音增强\(voiceProcessing ? "开" : "关")）")
        capture.stop()
        do {
            try capture.start()
            AudioRoute.apply(outputMode)
        } catch {
            hearLog("重开麦克风失败：\(error)", .error)
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
    // 声音克隆：每句话的样本（声音 + 文字），以及提前生成好的克隆朗读
    private var cloneRefs: [UUID: (samples: [Float], text: String)] = [:]
    private var cloneRefOrder: [UUID] = []
    private var lastCloneRef: [String: (samples: [Float], text: String)] = [:]   // 每种语言最近一句够长的样本
    private var cloneTasks: [UUID: Task<CloneAudio?, Never>] = [:]
    private var cloneNote: [UUID: String] = [:]      // 每句样本的情况说明（写日志用）
    private var appleEngines: [LiveTextEngine] = []   // 苹果自带模式：每种语言一个系统听写

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
    }
    private let recognitionQueue = SessionJobQueue<ASRJob>()
    private let translationQueue = SessionJobQueue<MTJob>()
    /// itemID → 当前有效的任务令牌
    private var jobTokens: [UUID: UUID] = [:]
    private var runGen = 0                // 每次停止 +1：停止前排队/进行中的识别和翻译全部作废
    private var working: Bool { !recognitionQueue.isIdle }
    private var currentSeg = 0
    private var partialSeg = 0            // 实时气泡（partial）属于第几句
    /// 刚停下来时保留下来的那一条：断句的最后一段声音要挂到它身上（声音克隆用）
    private var stopFlushItemID: UUID?
    /// 停下来那一刻正在说的那句（断句器最后会把它的声音交出来）
    private var stopFlushSegID = 0
    /// 声音克隆服务不可用（已经提醒过，别一直弹）
    private var cloneUnavailableNotified = false
    // 实时预览分两条线：识别只管出原文，翻译只拿最新的原文去翻，互不等待
    private var previewSamples: (id: Int, samples: [Float])?
    /// 每句实时预览已经认出来的文字（段号 → 文字）。
    /// 预览只认最近 10 秒，长句的开头会被切掉——
    /// 已经认出来的开头别让它消失。
    private var previewText: [Int: String] = [:]
    private var asrPreviewTask: Task<Void, Never>?
    private var asrPreviewGeneration = 0
    private var mtPending: (id: Int, text: String, src: Language, tgt: Language)?
    /// 实时译文是对着哪一句原文翻的。
    /// 说话过程中原文一直在变，译文可能对应的是"上一版"原文——
    /// 停录的时候要拿这个对一下，不然会把旧原文的译文当成新原文的译文存下来。
    private var partialTranslationFor: String = ""
    private var mtPreviewBusy = false
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
    /// 现在有几个识别正在进行。
    /// 只有"正在识别"才算忙——翻译慢的时候不算：
    /// 否则上一句翻译要几十秒，后面那句的实时原文也跟着一起卡住，
    /// 用户看到的就是一直只有省略号。
    private var asrBusyCount = 0
    /// 真正在出声的那一条（喇叭显示成绿色）。
    /// 只是"轮到它读了"不算：声音还在生成、或者还没开始播，喇叭都还是转圈。
    @Published private(set) var speakingID: UUID?
    /// 本地网络权限没开：界面上弹提示
    @Published var localNetworkHelp = false

    // 对话翻译模式：按住某种语言的按钮说话，松开就暂停
    @Published var talkMode: Bool {
        didSet {
            save("talkMode", talkMode)
            save("hearLastMode", talkMode)      // 多存一份：万一主的那份丢了还能找回来
            pushConfig()                        // 门槛不一样了（短回答的门槛）
            startToken = UUID()                 // 正在等待的"开始收音"作废
            if talkMode != oldValue, isRunning { stop(readAfter: false) }
        }
    }
    @Published private(set) var holding: Language?      // 正按着的那种语言
    private var talkLang: Language?                      // 最近一次按住的语言（松开后排队的句子也按它处理）
    private var holdGen = 0
    private var holdReleasing = false                    // 刚松开：把最后一句交出去
    private var readIndex = 0
    private var readerTask: Task<Void, Never>?
    private var readerGen = 0
    private var oneShot = false
    private var manualSpeaker = false     // 戴着耳机时用户手动切到了扬声器

    // 当前这一页对话（自动保存到历史）
    private(set) var conversationID = UUID() {
        didSet {
            guard oldValue != conversationID else { return }
            speakerQueue.cancel()
            speakerTracker = SpeakerTracker()
        }
    }
    private var conversationCreated = Date()

    init() {
        let d = UserDefaults.standard
        langA = Language.find(d.string(forKey: "langA") ?? "zh")
        langB = Language.find(d.string(forKey: "langB") ?? "en")
        speakOutput = d.object(forKey: "speakOutput") as? Bool ?? true
        showReadingIcon = d.object(forKey: "showReadingIcon") as? Bool ?? true
        useContext = d.object(forKey: "useContext") as? Bool ?? true
        sensitivity = d.object(forKey: "sensitivity") as? Double ?? 12
        silenceMs = d.object(forKey: "silenceMs") as? Double ?? 700
        glossary = d.string(forKey: "glossary") ?? ""
        hfHost = d.string(forKey: "hfHost") ?? "huggingface.co"
        outputMode = AudioOutput(rawValue: d.string(forKey: "outputMode") ?? "") ?? .speaker
        leftEar = d.string(forKey: "leftEar") ?? "A"
        rightEar = d.string(forKey: "rightEar") ?? "B"
        voiceClone = d.object(forKey: "voiceClone") as? Bool ?? false
        // 声音克隆默认用云端模型；已经设置过的沿用原选择
        if let v = d.object(forKey: "voiceCloneCloud") as? Bool {
            voiceCloneCloud = v
        } else if d.object(forKey: "voiceCloneCloud") != nil {
            voiceCloneCloud = d.bool(forKey: "voiceCloneCloud")
        } else {
            voiceCloneCloud = true
        }
        // init 里属性还没初始化完，只能用局部变量，不能直接读 self.cloudAddress
        let cloudAddr = d.string(forKey: "cloudAddress") ?? ""
        cloudAddress = cloudAddr
        cloudASRScheme = d.string(forKey: "cloudASRScheme") ?? "sensevoice+whisper"
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
        inputSource = d.string(forKey: "inputSource") ?? "phone"
        // 上次用的模式一定要记住：不管存的是 Bool 还是 NSNumber 都能读回来
        if let v = d.object(forKey: "talkMode") as? Bool {
            talkMode = v
        } else if d.object(forKey: "talkMode") != nil {
            talkMode = d.bool(forKey: "talkMode")
        } else {
            talkMode = d.bool(forKey: "hearLastMode")
        }
        hearLog("启动：\(talkMode ? "对话翻译模式" : "实时翻译模式")")
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
        // 采集层要停音频会话的时候，问一下"现在有没有在出声"
        // （判断完到真正停掉之间，可能刚好开始播下一句）
        capture.isSpeakingNow = { [weak self] in
            self?.speaker.isPlaying ?? false
        }
        capture.voiceProcessing = voiceProcessing
        AudioRoute.useHeadsetMic = inputSource == "headset"

        capture.onHealthChanged = { [weak self] health in
            self?.captureHealth = health
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
            Task { @MainActor in
                guard let self else { return }
                hearLog("收到内存不足警告：可用内存 \(Self.freeMB()) MB，先卸掉本地模型", .warning)
                CrashGuard.shared.updateMarker(memoryWarning: true)
                let usesLocal = Self.isLocalEngine(self.asrEngine) || self.translationEngine == "local"
                self.cloneLoadTask?.cancel()
                self.clearCloneTasks()
                if usesLocal {
                    self.stop(readAfter: false)
                    self.phase = .checking
                    self.showToast("内存不足，已暂停本地识别和翻译", seconds: 6)
                }
                await self.sense.unload()
                await self.translator.unload()
                await self.cloner.unload()
                hearLog("已卸载本地模型，可用内存 \(Self.freeMB()) MB")
                if usesLocal {
                    self.needsMemoryRecovery = true
                    self.phase = .ready
                }
            }
        }

        // 切到别的 App：别在后台继续出声，但别的照旧。
        //
        // 麦克风留着听（实时翻译不能断），网络也留着
        // （切到别的软件以后，电脑那边的翻译和声音克隆服务还要接着调用，
        //   不然切一下 App 这段对话就断了）。
        // 只是喇叭停下来：用户不在跟前听，吵得慌。
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.inBackground = true
                self.playbackToken = UUID()      // 还没播的请求全部作废
                self.stopReading()
                hearLog("切到后台：停止朗读（翻译和云端服务继续跑）", .info)
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.inBackground = false
                // 回到前台：把后台攒下的译文接着读出来
                self.kickReader()
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

        // 到这里所有属性都初始化完了，可以安全地恢复引擎了
        // 上次因为云端连不上自动换过引擎：把用户自己的选择还回去
        restorePreferredEngines()
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
            if outputMode == .headphones {
                // 已经是耳机模式了：重新应用一次路由，让声音真的走耳机
                AudioRoute.apply(.headphones)
                return
            }
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

    enum ModelKind { case translation, senseVoice, voiceClone }

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
                await sense.unload()

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
        let a = langA, b = langB
        var msg = "苹果翻译暂时用不了（\(a.name) → \(b.name)）"
        if let error { msg += "：\(Self.appleErrorText(error))" }
        msg += "。多半是苹果翻译的语言包没装好：系统弹窗里点“下载”装一次就行；也可以在设置里改用云端或本地翻译。"
        appleNote = msg
        hearLog(msg, .warning)
        // 再要一次语言包：系统会重新弹一次下载窗（只弹一次，别反复烦人）
        askAppleDownloadAgain()
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
        systemTranslator.reset()
        appleDownloadAsked = false
        Task {
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
        systemTranslator.reset()
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
    private var modelLoadCount = 0
    /// 每次加载的编号：只有最新那次的结果算数，旧的不要覆盖状态
    private var loadGen = 0

    /// 是不是还有模型在加载（识别/翻译都算）。
    /// 声音克隆不算：克隆在加载的时候是"等它加载完再开始"，不是不让开始。
    var isAnyModelLoading: Bool {
        if isLoadingPhase { return true }
        return modelLoadCount > 0
    }

    func loadModels() async {
        // 每次加载都拿一个新编号：同时来了好几次加载（换引擎、下载完成等）时，
        // 只有最后一次的结果算数，不然旧的那次会先把"加载完成"提示弹出来，
        // 但其实还有模型在加载，一按翻译键又被拦下。
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
        if !wantsSense, await sense.isLoaded { await sense.unload() }
        if !needLocalMT, await translator.isLoaded { await translator.unload() }
        let start = Date()
        let svLoaded = await sense.isLoaded
        let mtLoaded = await translator.isLoaded
        guard gen == loadGen, !Task.isCancelled else { return }
        let needSV = wantsSense && !svLoaded
        let needMT = needLocalMT && (!mtLoaded || needSV)
        if !needSV && !needMT {
            phase = .ready
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
        defer { if voiceClone, !voiceCloneCloud { scheduleCloneLoad(delay: 3) } }
        // 每秒刷新一次已用时间，让用户知道没有卡死
        let ticker = Task { @MainActor in
            var warned = false
            while !Task.isCancelled {
                let secs = Int(Date().timeIntervalSince(start))
                if secs > 120 && !warned {
                    warned = true
                    hearLog("模型加载已超过 2 分钟", .warning)
                }
                let msg = "正在准备模型 · \(secs) 秒"
                // 旧的加载任务别去改状态（新一轮加载已经在跑了）
                if gen == loadGen, case .loading = phase { phase = .loading(msg) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { ticker.cancel() }
        if gen == loadGen { phase = .loading("正在准备模型…") }
        do {
            // 一个一个加载：同时加载几个大模型，内存峰值太高会被系统强制退出
            guard gen == loadGen, !Task.isCancelled else { return }
            if needSV, let sf {
                if mtLoaded { await translator.unload() }
                try await sense.load(folder: sf)
                guard gen == loadGen, !Task.isCancelled else { return }
            }
            try await loadMTIfNeeded(needMT, path: mtPath ?? "")
            // 又来了新的加载任务：这次的结果作废，交给新的那次去设状态
            guard gen == loadGen else {
                hearLog("有新的模型加载任务，忽略这次的结果", .warning)
                return
            }
            // 声音克隆是单独一个任务，可能还在加载：等它好了再说"可以开始翻译"
            if voiceClone, !voiceCloneCloud {
                var busy = cloneLoading
                var waited = 0
                while busy, waited < 120 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    busy = cloneLoading
                    waited += 1
                }
                if busy {
                    hearLog("声音克隆还在加载，先不提示可以开始翻译", .warning)
                    return
                }
            }
            guard gen == loadGen, !Task.isCancelled else { return }
            phase = .ready
            hearLog("全部就绪，用时 \(Int(Date().timeIntervalSince(start)))s，可用内存 \(Self.freeMB()) MB")
            // 加载好了，提示一下（5 秒；用户按了按钮就立刻消失）
            modelsJustLoaded = true
            showToast("模型加载完成，可以开始翻译了", seconds: 5)
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

    /// 设置 → 导入翻译模型（.gguf 文件）。苹果自带模式下只放进“已下载的模型”，不切换、不加载
    func importModel(_ url: URL) async {
        do {
            if isRunning, translationEngine == "local" { stop(readAfter: false) }
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

    /// 设置 → 导入 SenseVoice 模型（文件夹）
    func importSenseVoice(_ url: URL) async {
        do {
            if isRunning, useSense { stop(readAfter: false) }
            await sense.unload()
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
        // 用户动手了就不用再提示"加载完成"
        dismissToast()
        modelsJustLoaded = false
        if isRunning { await finishRecording(); return }
        _ = await beginListening()
    }

    /// 对话翻译模式：按下某种语言的按钮
    func holdBegan(_ lang: Language) async {
        guard holding == nil else { return }
        // 用户动手了就不用再提示"加载完成"
        dismissToast()
        modelsJustLoaded = false
        if isRunning { stop(readAfter: false) }
        let token = UUID()
        startToken = token
        holding = lang
        talkLang = lang
        holdGen += 1
        // 上一句的尾段还在路上：先别把"正在收尾"这个标记清掉，
        // 清了的话尾句到了会被当成"已经停了"直接丢掉。
        if let t = pendingTail, Date().timeIntervalSince(t.at) < 5 {
            holdReleasing = true
        } else {
            pendingTail = nil
            holdReleasing = false
        }
        // 苹果听写：上一段最后一句还在定稿，稍等一下再换听写（否则那句会丢）
        var w = 0
        while !appleEngines.isEmpty, working, w < 8 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            w += 1
        }
        guard startToken == token, holding == lang else { return }
        let ok = await beginListening(intent: token)
        if !ok, startToken == token { holding = nil }
    }

    /// 对话翻译模式：松开按钮 = 暂停收音，这一段说的话继续识别、翻译完
    func holdEnded() {
        guard holding != nil else { return }
        holding = nil
        // 还没开始录音就松手了：这次启动必须作废。
        // 不作废的话，等麦克风权限的弹窗一放开，麦克风就自己开了——用户明明已经松手了。
        startToken = UUID()
        guard isRunning else { return }
        releaseHold()
    }

    private func releaseHold() {
        let g = holdGen
        hearLog("松开按钮：暂停收音")
        startToken = UUID()          // 正在等待的"开始收音"作废
        holdReleasing = true
        // 松手这一刻正在说的那一句（采集层停下来以后会把它交出来）
        let tailSeg = currentSeg
        // 记下它：这一句属于刚才按住的语种
        pendingTail = (seg: tailSeg, lang: talkLang, at: Date())
        isRunning = false
        meter.level = 0
        UIApplication.shared.isIdleTimerDisabled = false
        capture.stop()                 // 把正在说的这一句交出去
        capture.muted = false
        // 松手了就把麦克风放开（别的 App 才录得到声音）
        scheduleMicrophoneRelease()
        translator.cancelPreview()
        cancelASRPreview()
        mtPending = nil
        Task {
            // 等采集层把最后一句交出来（引擎停了以后才 flush，有时要一秒多）。
            // 这期间 holdReleasing 一直是 true：最后那句话才不会被当成"已经停了"丢掉。
            var w = 0
            while w < 40, finishedSeg < tailSeg, currentSeg == tailSeg {
                try? await Task.sleep(nanoseconds: 100_000_000)
                w += 1
            }
            guard g == holdGen else { return }
            holdReleasing = false
            finishedSeg = max(finishedSeg, currentSeg)
            partial = ""; partialTranslation = ""; partialTranslationFor = ""; partialSource = nil
            // 等这一段的识别和翻译做完，再关掉系统听写、开始朗读
            var waited = 0
            while working, waited < 150 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            guard g == holdGen, holding == nil, !isRunning else { return }
            stopAppleASR()
            activity = ""
            kickReader()
        }
    }

    /// 松手以后还在路上的尾句（采集层是异步交付的）。
    /// 记着它的段号和当时按住的语种：
    /// 下一次按住别的语种时，尾句不能被丢掉，也不能算到新的一边头上。
    private var pendingTail: (seg: Int, lang: Language?, at: Date)?

    /// 开始收音的令牌：每次开始换一个新的。
    /// 用户在等待（要麦克风权限、等模型加载）期间松手了、停了、切模式了，
    /// 令牌就变了，这一次启动自动作废——不会莫名其妙开始录音。
    private var startToken = UUID()

    /// 打开麦克风开始收音（实时翻译和对话翻译共用）
    private var needsMemoryRecovery = false
    private var inputFinishToken: UUID?
    private var switchingConversation = false

    private func beginListening(intent: UUID? = nil) async -> Bool {
        guard inputFinishToken == nil, !switchingConversation else { return false }
        let token = intent ?? UUID()
        if intent == nil { startToken = token }
        guard token == startToken else { return false }
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
        guard phase == .ready else { return false }
        guard await AudioCapture.requestPermission() else {
            activity = "请在 设置 → 听见 里允许使用麦克风"
            return false
        }
        // 等权限的时候用户已经松手/停了：这一次启动作废
        guard token == startToken else {
            hearLog("开始收音：等待期间用户已经松开了，不启动", .info)
            return false
        }
        // 声音克隆模型正在加载时先等它加载完：
        // 在等待期间，仍要检查这次手势是否有效。
        if cloneLoading {
            showToast("正在加载声音克隆模型…", seconds: 3)
            for _ in 0..<300 {                     // 最多等 30 秒
                if !cloneLoading { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
                // 等模型的时候用户松手/停了：这次启动作废，别再往下走
                if token != startToken {
                    hearLog("开始收音：等模型期间用户已经松开了，不启动", .info)
                    return false
                }
            }
        }
        guard token == startToken else { return false }
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
        // 扬声器模式：聆听期间完全不播放、不改输出路由，停止后再从没读的那句开始读
        if outputMode == .speaker { stopReading() }
        do {
            try capture.start()
        } catch {
            // 刚加载完声音克隆模型时，内存紧张会让麦克风起不来（硬件直接拒绝启动）：
            // 先把声音克隆模型卸掉再试一次，麦克风通常就能正常起来
            if await cloner.isLoaded {
                hearLog("麦克风启动失败，先卸载声音克隆模型再试一次", .warning)
                await cloner.unload()
                guard token == startToken else { return false }
                do {
                    try capture.start()
                } catch {
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
        if outputMode == .headphones { AudioRoute.apply(.headphones) }
        isRunning = true
        if dualLive { startAppleASR() }
        if talkMode, let l = talkLang {
            hearLog("对话翻译：按住说\(l.displayName)")
            activity = "正在听\(l.name)"
        } else {
            hearLog("开始实时翻译：\(langA.displayName) ⇄ \(langB.displayName)，朗读\(outputMode == .speaker ? "扬声器" : "耳机")")
            activity = "正在聆听"
        }
        UIApplication.shared.isIdleTimerDisabled = true
        return true
    }

    /// 在实时翻译按钮上方显示几秒钟的提示
    func showToast(_ text: String, seconds: Double = 2.5) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// 立刻收起提示（用户点了按钮就不要再占着屏幕）
    func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        toast = nil
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
        holdReleasing = true
        isRunning = false
        meter.level = 0
        UIApplication.shared.isIdleTimerDisabled = false
        await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
            capture.stop { completion.resume() }
        }
        guard inputFinishToken == token else { return }
        holdReleasing = false
        scheduleMicrophoneRelease()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(12))
        while !recognitionQueue.isIdle, clock.now < deadline,
              inputFinishToken == token {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { break }
        }
        guard inputFinishToken == token else { return }
        stop(readAfter: false)
        if readAfter { kickReader() }
    }

    /// readAfter：停止后是否接着朗读没读的句子（只有用户自己点停止时才读）
    func stop(readAfter: Bool = true) {
        inputFinishToken = nil
        let wasRunning = isRunning
        if wasRunning { hearLog("停止实时翻译") }
        restartTask?.cancel()
        restartTask = nil
        holding = nil
        holdReleasing = false
        holdGen += 1
        startToken = UUID()          // 正在等待的"开始收音"全部作废
        capture.stop()
        capture.muted = false
        isRunning = false
        meter.level = 0
        activity = ""
        UIApplication.shared.isIdleTimerDisabled = false
        // 停止收音 = 立刻停止所有识别和翻译：清空排队的句子，打断正在生成的译文
        runGen += 1
        recognitionQueue.cancel()
        correctionTask?.cancel()
        translationQueue.cancel()
        jobTokens.removeAll()
        translator.cancelCurrent()
        translator.cancelPreview()
        cancelASRPreview()
        mtPending = nil
        stopLiveEngine()
        stopAppleASR()
        finishedSeg = max(finishedSeg, currentSeg)
        // 麦克风放开（不占着，别的 App 才能录到声音）
        scheduleMicrophoneRelease()
        // 整句话可能还没识别完（界面上是虚线框）：按了暂停，这句也要留在记录里，不能丢
        stopFlushItemID = nil
        stopFlushSegID = currentSeg
        flushPartial()
        partial = ""; partialTranslation = ""; partialTranslationFor = ""; partialSource = nil
        finishUnfinished()
        if wasRunning && readAfter { kickReader() }   // 停止聆听后，从上次没读完的地方接着读
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
        let src = partialSource ?? (lastLangID == langB.id ? langB : langA)
        let tgt = src == langA ? langB : langA
        var item = TranslationItem(source: src, target: tgt, sourceText: text,
                                   sourceSide: src == langA ? .left : .right)
        // 实时译文必须是对着这一句原文翻的才能用：
        // 说话过程中原文一直在变，旧原文的译文配新原文是错的
        let previewOK = !partialTranslation.isEmpty && partialTranslationFor == text
        item.translated = previewOK ? partialTranslation : ""
        item.done = false
        items.append(item)
        stopFlushItemID = item.id      // 断句器最后一段声音会挂到这条上
        hearLogText("暂停：保留了一句还没说完的（", String(text.prefix(40)) + "）")
        persist()
    }

    /// 停止时还没翻译完的句子：原文还在的就留着，并且接着把译文补上
    /// （一个字都没有的才删掉，不然按暂停会把刚识别出来的内容丢掉）
    private func finishUnfinished() {
        var changed = false
        var pending: [(UUID, String, Language, Language)] = []
        for i in items.indices.reversed() where !items[i].done {
            let text = items[i].sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text == "…" {
                items.remove(at: i)
                if i < readIndex { readIndex -= 1 }
            } else {
                items[i].translated = ""
                pending.append((items[i].id, items[i].sourceText, items[i].source, items[i].target))
            }
            changed = true
        }
        if readIndex > items.count { readIndex = items.count }
        if changed { persist() }
        // 没译完的接着翻（这一步不受"停止"影响，译完这句就齐了）
        // 记住是哪一页：用户可能已经新建对话了，译文要写回原来那一页
        let convID = conversationID
        for (id, text, src, tgt) in pending {
            let version = itemVersions[id] ?? 0
            Task { [weak self] in
                guard let self else { return }
                do {
                    let out = try await self.translateFinal(text, from: src, to: tgt, context: []) { _ in }
                    guard (self.itemVersions[id] ?? 0) == version else { return }
                    self.applyTranslation(id, out, done: true, conversation: convID, expectedSource: text)
                    self.kickReader()          // 译完了，朗读那边等着这句呢
                } catch {
                    hearLog("补翻译失败：\(error)", .error)
                    guard (self.itemVersions[id] ?? 0) == version else { return }
                    self.applyTranslation(id, "（翻译失败）", done: true, conversation: convID, expectedSource: text)
                    self.kickReader()
                }
            }
        }
    }

    func swapLanguages() {
        setLanguagePair(left: langB, right: langA)
    }

    func clear() {
        stopReading()
        items.removeAll(); partial = ""; partialTranslation = ""; partialTranslationFor = ""; partialSource = nil
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
    ///
    /// 已经译完的照存；**还没译完但已经认出原文的也存**：
    /// 停完马上新建对话的时候，补翻译的活儿还在后台跑，
    /// 原文要是没存下来，那句话就彻底没了。
    func persist() {
        let saved = items.filter { $0.done || Self.hasRealText($0.sourceText) }
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
    func newConversation(summarize: Bool) {
        guard !switchingConversation, inputFinishToken == nil else { return }
        switchingConversation = true
        startToken = UUID()
        Task { [weak self] in
            guard let self else { return }
            defer { self.switchingConversation = false }
            if self.isRunning || self.holdReleasing { await self.finishRecording(readAfter: false) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !self.speakerQueue.isIdle, ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { break }
            }
            self.archiveConversation(summarize: summarize)
        }
    }

    private func archiveConversation(summarize: Bool) {
        persist()
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
        // 在后台（切到别的 App 了）不朗读：用户不在跟前听，吵得慌
        !inBackground && speakOutput && (outputMode == .headphones || !isRunning)
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
        capture.muted = false
        // 朗读停了：没在收音的话就把麦克风放开
        scheduleMicrophoneRelease()
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
        // （最后那句的"结束"要接住：它带着这段声音，声音克隆要用）
        if !isRunning && !holdReleasing && inputFinishToken == nil {
            switch e {
            case .started, .partial: return
            case .ended: break
            default: break
            }
        }
        switch e {
        case .level(let l):
            meter.level = isRunning ? l : 0
        case .started(let id):
            currentSeg = id
            partialSeg = id
            partial = "…"; partialTranslation = ""; partialSource = forcedLang
            live?.markSegmentStart(id)
            for eng in appleEngines { eng.markSegmentStart(id) }
            hearLog("断句：检测到说话（第 \(id) 句）")
        case .partial(let id, let samples):
            // 系统听写在工作时由它出原文；否则用 Whisper 不停地识别最新的声音
            guard !liveActive, appleEngines.isEmpty else { return }
            previewSamples = (id, samples)
            if asrPreviewTask == nil {
                let generation = asrPreviewGeneration
                asrPreviewTask = Task { await previewLoop(generation) }
            }
        case .ended(let id, let samples):
            let alreadyDone = id <= finishedSeg
            finishedSeg = max(finishedSeg, id)
            live?.markSegmentEnd(id)
            for eng in appleEngines { eng.markSegmentEnd(id) }
            hearLog("断句：一句话结束，时长 \(String(format: "%.1f", Double(samples.count) / 16000)) 秒")
            // 立刻打断这句的实时预览，让整句识别和翻译马上开始
            translator.cancelPreview()
            cancelASRPreview()
            mtPending = nil
            // 先把这句（实时预览的文字）放进对话，整句识别完再替换，屏幕上不会空一下
            let mine = partialSeg == id
            // 尾句属于上一次按住的那种语言，不能算到新按住的这边头上
            let tailLang = (id == pendingTail?.seg) ? pendingTail?.lang : nil
            let src = tailLang ?? forcedLang ?? (mine ? partialSource : nil)
                ?? ((lastLangID == langB.id) ? langB : langA)
            let tgt = src == langA ? langB : langA
            // 已经停下来了：这一句不会再走整句识别，
            // 但这段声音要留下来（声音克隆的样本），译文等下接着补。
            // 松手收尾（对话模式）不算"已经停下来了"：
            // 那最后一句要照常处理，不然松手时说的最后一句就丢了
            if !isRunning && !holdReleasing && inputFinishToken == nil {
                if id == stopFlushSegID, let fid = stopFlushItemID {
                    stopFlushItemID = nil
                    if let idx = items.firstIndex(where: { $0.id == fid }) {
                        rememberReference(fid, samples: samples, text: items[idx].sourceText,
                                          lang: items[idx].source.id)
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
                                       sourceSide: src == langA ? .left : .right)
            // 实时译文必须是对着这一句原文翻的才能用：
            // 说话过程中原文一直在变，旧原文的译文配新原文是错的
            let previewOK = mine && !partialTranslation.isEmpty
                && partialTranslationFor == item.sourceText
            item.translated = previewOK ? partialTranslation : ""
            items.append(item)
            if mine { partial = ""; partialTranslation = ""; partialTranslationFor = ""; partialSource = nil }
            previewText[id] = nil
            // 尾句处理完了：标记清掉
            if id == pendingTail?.seg {
                pendingTail = nil
                holdReleasing = false
            }
            // 声音样本先记下来（声音克隆要用）：
            // 整句识别要好几秒，用户随时可能点停止，
            // 等识别完再记就来不及了（那样只能退回系统声音朗读）
            rememberReference(item.id, samples: samples, text: item.sourceText, lang: src.id)
            let token = UUID()
            jobTokens[item.id] = token
            let job = ASRJob(itemID: item.id, segID: id, samples: samples, token: token, generation: runGen,
                             left: langA, right: langB, forced: tailLang ?? forcedLang, fallback: src)
            recognitionQueue.submit(job) { [weak self] job in
                guard let self, self.runGen == job.generation else { return }
                if self.usingAppleASR {
                    await self.processApple(job)
                } else {
                    await self.process(job)
                }
            } timedOut: { [weak self] job in
                self?.markJobFailed(job.itemID, token: job.token)
            }
        case .discarded(let id):
            finishedSeg = max(finishedSeg, id)
            if partialSeg == id { partial = ""; partialTranslation = ""; partialTranslationFor = ""; partialSource = nil }
            previewText[id] = nil
        case .noise(let n, let t):
            if isRunning { hearLog(String(format: "环境噪声 %.0f dB，说话触发阈值 %.0f dB", n, t)) }
        }
    }

    // MARK: - 实时预览（说话过程中）

    /// 识别线：上一次识别一结束就拿最新的声音再识别，不等翻译
    private func cancelASRPreview() {
        asrPreviewGeneration += 1
        asrPreviewTask?.cancel()
        asrPreviewTask = nil
        previewSamples = nil
    }

    private func previewLoop(_ generation: Int) async {
        defer { if generation == asrPreviewGeneration { asrPreviewTask = nil } }
        while !Task.isCancelled, generation == asrPreviewGeneration, let job = previewSamples {
            previewSamples = nil
            let id = job.id
            // 云端正式识别优先。翻译慢时，仍继续显示新句的预览。
            guard phase == .ready, isRunning, !liveActive, useSense || asrBusyCount == 0,
                  id == currentSeg, id > finishedSeg else { continue }
            let gen = runGen
            let a = langA, b = langB
            let forced = forcedLang
            let fallback = forced?.id ?? ((lastLangID == b.id) ? b.id : a.id)
            let cands = forced.map { [$0.id] } ?? [a.id, b.id]
            // 只识别最近 10 秒，长句也跟得上
            let maxN = 16_000 * 10
            let clipped = job.samples.count > maxN
            let clip = clipped ? Array(job.samples.suffix(maxN)) : job.samples
            let t0 = Date()
            let r: (lang: String, text: String, correctionAddress: String?, speakerAddress: String?)
            do {
                r = try await sentenceRecognizer.recognize(clip, candidates: cands, fallback: fallback, preview: true)
            } catch {
                // 预览失败只影响这一次预览，不改引擎：
                // 整句识别要是也失败，那边自然会回退（见 process）。
                // 预览本来就是"尽力而为"，为它把用户的引擎换掉不合适。
                hearLog("实时识别失败：\(error)", .warning)
                continue
            }
            hearLogText("实时识别 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s：",
                        String(r.1.prefix(30)))
            var src = forced ?? ((r.0 == b.id) ? b : a)
            // 按已经出来的字马上判断语言：字是英文就放英文侧，是汉字就放中文侧，不等整句
            if forced == nil, !SpeechTextFilter.matchesLanguage(r.1, src.id) {
                let other = src == a ? b : a
                if SpeechTextFilter.matchesLanguage(r.1, other.id) { src = other }
            }
            guard !Task.isCancelled, generation == asrPreviewGeneration, gen == runGen,
                  isRunning, id == currentSeg, id > finishedSeg, partialSeg == id,
                  SpeechTextFilter.isMeaningful(r.1),
                  forced != nil || SpeechTextFilter.matchesLanguage(r.1, src.id) else { continue }
            partialSource = src
            // 长句：预览窗口只留最近 10 秒，开头会被切掉。
            // 已经认出来的开头别让它消失：
            // 把新快照接到"已经稳定的那一段"后面（滑窗时新快照会丢掉开头、
            // 尾巴又变长了，前后都对不上的时候用重叠部分接上）。
            let stable = previewText[id] ?? ""
            let merged = clipped ? Self.mergePreview(stable, r.1) : r.1
            previewText[id] = merged      // 记下稳定下来的那段（下次好接）
            partial = (clipped ? "…" : "") + merged
            requestPreviewTranslation(id: id, text: partial, src: src, tgt: src == a ? b : a)
        }
    }

    /// 系统听写给出的最新文字
    private func liveText() {
        guard liveActive, isRunning, currentSeg > finishedSeg, partialSeg == currentSeg,
              let live else { return }
        let text = live.segmentText(currentSeg).text
        guard SpeechTextFilter.isMeaningful(text) else { return }
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
            if usingAppleTranslation {
                var out = try? await systemTranslator.translate(p.text, from: p.src, to: p.tgt)
                if (out ?? "").isEmpty {
                    out = try? await fallbackTranslate(p.text, from: p.src, to: p.tgt)
                }
                if let out, !out.isEmpty, gen == runGen, id == partialSeg, id > finishedSeg {
                    partialTranslation = out
                    partialTranslationFor = p.text
                }
                continue
            }
            if usingCloudMT {
                let prompt = PromptBuilder.build(text: p.text, from: p.src, to: p.tgt, context: [],
                                                 glossary: PromptBuilder.parseGlossary(glossary))
                do {
                    let out = try await cloud.translate(prompt: prompt, src: p.src.id, dst: p.tgt.id)
                    if !out.isEmpty {
                        hearLogText("云端翻译（预览）：", String(out.prefix(20)))
                        if gen == runGen, id == partialSeg, id > finishedSeg {
                            partialTranslation = out
                            partialTranslationFor = p.text
                        }
                    }
                } catch {
                    // 预览翻译失败也不改引擎（同上）
                    hearLog("云端翻译（预览）失败：\(error)", .warning)
                }
                continue
            }
            // 本地翻译模型和 Whisper 共用 GPU：整句在识别/翻译时，预览翻译先让路
            if working { continue }
            let epoch = translator.currentPreviewEpoch
            let prompt = PromptBuilder.build(text: p.text, from: p.src, to: p.tgt, context: [],
                                             glossary: PromptBuilder.parseGlossary(glossary))
            let out = try? await translator.translate(prompt: prompt, maxNewTokens: 256, previewEpoch: epoch) { t in
                Task { @MainActor in
                    if gen == self.runGen, id == self.partialSeg, id > self.finishedSeg {
                        self.partialTranslation = t
                        self.partialTranslationFor = p.text
                    }
                }
            }
            if let out, !out.isEmpty, gen == runGen, id == partialSeg, id > finishedSeg { partialTranslation = out }
        }
    }

    /// 按当前翻译引擎翻译一句定稿的原文。
    /// 苹果翻译不带上下文和术语表；本地翻译带上，并用部分译文回调做实时显示。
    private var sentenceRecognizer: SessionSpeechEngine {
        if usingCloudASR { return .cloud(cloud) }
        return .senseVoice(sense)
    }

    private func translateFinal(_ text: String, from src: Language, to tgt: Language,
                                context: [String], onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        let engine: SessionTextEngine = usingAppleTranslation ? .system(systemTranslator)
            : (usingCloudMT ? .cloud(cloud) : .local(translator))
        do {
            return try await engine.translate(text: text, source: src, target: tgt, context: context,
                                              glossary: glossary, onPartial: onPartial)
        } catch {
            try Task.checkCancellation()
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
                    return try await alternate.translate(text: text, source: src, target: tgt, context: context,
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
        let prompt = PromptBuilder.build(text: text, from: src, to: tgt, context: [],
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
        // 对话翻译模式只听按住的那种语言
        let langs = forcedLang.map { [$0] } ?? [langA, langB]
        for lang in langs {
            guard let e = LiveTextEngineFactory.make() else { continue }
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
                do {
                    try await e.start(languageID: lang.id, locale: lang.tts)
                    guard isRunning || holdReleasing, gen == runGen, dualLive else { await e.stop(); return }
                    if currentSeg > finishedSeg { e.markSegmentStart(currentSeg) }
                } catch {
                    hearLog("系统听写不支持 \(lang.name)：\(error.localizedDescription)", .warning)
                    activity = "系统听写暂不支持 \(lang.name)"
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
        guard !appleEngines.isEmpty else { return }
        capture.onSamples = nil
        let list = appleEngines
        appleEngines = []
        Task { for e in list { await e.stop() } }
    }

    /// 第 id 句：两个听写里置信度更高的结果
    private func bestApple(_ id: Int, requireFinal: Bool = false,
                           languages: [Language]? = nil) -> (text: String, lang: Language)? {
        let candidates = languages ?? [langA, langB]
        var best: (text: String, lang: Language, conf: Double)?
        for e in appleEngines {
            if requireFinal, !e.hasFinalText(id) { continue }
            let r = e.segmentText(id)
            guard !r.text.isEmpty, let lid = e.languageID,
                  let lang = candidates.first(where: { $0.id == lid }) else { continue }
            // 例如中文听写把英文也写成了英文字母：文字和语言对不上就降分，避免说英文却当成中文
            let score = r.confidence + (SpeechTextFilter.matchesLanguage(r.text, lang.id) ? 1 : 0)
            if best == nil || score > best!.conf { best = (r.text, lang, score) }
        }
        guard let best else { return nil }
        return (best.text, best.lang)
    }

    private func appleUpdated() {
        guard !appleEngines.isEmpty, isRunning, currentSeg > finishedSeg, partialSeg == currentSeg,
              let b = bestApple(currentSeg), SpeechTextFilter.isMeaningful(b.text) else { return }
        partialSource = b.lang
        partial = b.text
        requestPreviewTranslation(id: currentSeg, text: b.text, src: b.lang, tgt: b.lang == langA ? langB : langA)
    }

    /// 把新的快照接到已经稳定的那一段后面。
    ///
    /// 预览窗口只有 10 秒：说得久了，窗口会往前挪，
    /// 新快照既不是旧的延长（开头没了），也不是旧的截断。
    /// 这时候找"旧的结尾 == 新的开头"的最长重叠，把尾巴接上去，
    /// 已经认出来的开头就不会白白丢掉。
    static func mergePreview(_ old: String, _ new: String) -> String {
        if old.isEmpty { return new }
        if new.hasPrefix(old) { return new }          // 新的更长
        if old.hasPrefix(new) { return old }          // 新的更短（截断）
        let maxOverlap = min(old.count, new.count)
        if maxOverlap > 0 {
            for n in stride(from: maxOverlap, through: 2, by: -1) {
                if old.hasSuffix(String(new.prefix(n))) {
                    return old + String(new.dropFirst(n))
                }
            }
        }
        // 实在对不上：标出来，别装作是一句完整的话
        return old + " … " + new
    }

    /// 等系统听写把这一段定稿（最多等这么久）。
    ///
    /// 以前是固定等 700 毫秒：话短的话定稿早，话长的话 700 毫秒还在半路上，
    /// 拿到的就是半截（甚至空）文本，然后就被当成"没听清"了。
    /// 现在等到"这段结束了而且有字"为止。
    private func waitAppleFinal(_ segID: Int) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(2500))
        while !appleEngines.isEmpty, clock.now < deadline, !Task.isCancelled {
            if appleEngines.contains(where: { $0.hasFinalText(segID) }) { return }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
    }

    private func processApple(_ job: ASRJob) async {
        let (samples, itemID, segID, gen, token) = (job.samples, job.itemID, job.segID, job.generation, job.token)
        let languages = [job.left, job.right]
        activity = "识别中…"
        // 等系统听写把这句话定稿（最多 2.5 秒）
        await waitAppleFinal(segID)
        guard !Task.isCancelled, gen == runGen else { return }
        // 这一句已经被放弃/顶掉了：结果不要了
        guard isCurrentJob(itemID, token: token) else { return }
        // 听写这一段有没有出字
        let dict = bestApple(segID, requireFinal: true, languages: languages)
        var spoken = dict?.text ?? ""
        var src = job.forced ?? dict?.lang ?? job.fallback
        if !SpeechTextFilter.isMeaningful(spoken) {
            // 听写最后那几百毫秒没出字：不能把这句话删掉！
            // 先用本地识别再认一遍这段声音；还是没有就标成"没听清"留着，
            // 至少用户还能长按改，不至于白说了。
            guard isCurrentJob(itemID, token: token) else { return }
            let recovered = await localRecover(samples: samples, fallbackLang: src, languages: languages)
            guard !Task.isCancelled, gen == runGen, isCurrentJob(itemID, token: token) else { return }
            if let r = recovered ?? bestApple(segID, languages: languages) {
                spoken = r.text
                src = r.lang
            } else {
                hearLog("系统听写：这一段没听清，留着让用户改", .warning)
                if let i = items.firstIndex(where: { $0.id == itemID }) {
                    jobTokens[itemID] = nil
                    items[i].sourceText = "（没听清）"
                    items[i].translated = ""
                    items[i].done = true
                    persist()
                }
                activity = isRunning ? "正在聆听" : ""
                kickReader()
                return
            }
        }
        let leading = src == job.left
        let tgt = leading ? job.right : job.left
        if job.left == langA && job.right == langB { lastLangID = src.id }
        hearLogText("系统听写（\(src.name)）：", String(spoken.prefix(40)))

        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        let old = items[idx]
        let preview = old.source == src ? old.translated : ""
        var item = TranslationItem(
            id: itemID, source: src, target: tgt, sourceText: spoken, translated: preview,
            speakerID: old.speakerID, speakerName: old.speakerName,
            speakerDetails: old.speakerDetails, speakerTracked: old.speakerTracked,
            speakerManuallySet: old.speakerManuallySet,
            sourceSide: leading ? .left : .right, recognizedLanguage: src.id)
        let shouldIdentify = speakerTrackingEnabled && !talkMode && speakerAddress != nil
        if shouldIdentify { item.speakerTracked = true }
        guard let idx2 = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx2] = item
        rememberReference(itemID, samples: samples, text: spoken, lang: src.id)
        // 翻译排到另一条队列（跟识别分开）
        enqueueTranslation(MTJob(itemID: itemID, token: token, gen: gen, text: spoken,
                                  src: src, tgt: tgt, context: [], samples: samples,
                                  isApple: true))
        if shouldIdentify, let speakerAddress {
            enqueueSpeaker(samples, for: itemID, address: speakerAddress)
        }
        _ = preview
    }

    /// 听写没给出结果时：用本地的识别再认一遍这段声音。
    /// （认出来了就保住这句话；认不出来也不删，标成"没听清"）
    private func localRecover(samples: [Float], fallbackLang: Language,
                              languages: [Language]) async -> (text: String, lang: Language)? {
        let cands = languages.map(\.id)
        do {
            guard await sense.isLoaded else { return nil }
            let r = try await sense.recognize(samples, candidates: cands, fallback: fallbackLang.id)
            guard SpeechTextFilter.isMeaningful(r.1) else { return nil }
            let lang = languages.first { $0.id == r.0 } ?? fallbackLang
            hearLogText("系统听写没出字，本地补认成功：", String(r.1.prefix(30)))
            return (r.1, lang)
        } catch {
            return nil
        }
    }

    // MARK: - 整句识别和翻译

    private var correctionTask: Task<Void, Never>?

    private struct MTJob {
        let itemID: UUID
        let token: UUID
        let gen: Int
        let text: String
        let src: Language
        let tgt: Language
        let context: [String]
        let samples: [Float]
        /// 这一句是不是系统听写来的（翻译失败时的处理不一样）
        let isApple: Bool
        var correctionAddress: String? = nil
    }

    private func enqueueTranslation(_ job: MTJob) {
        translationQueue.submit(job) { [weak self] job in
            await self?.translateItem(job)
        } timedOut: { [weak self] job in
            self?.markJobFailed(job.itemID, token: job.token)
        }
    }

    /// 翻译一句：译文出来以后写回去
    private func translateItem(_ job: MTJob) async {
        let id = job.itemID
        let token = job.token
        guard !Task.isCancelled, job.gen == runGen, isCurrentJob(id, token: token) else { return }
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        // 语言和预览一致时先保留预览译文，最终译文出来后再替换，避免闪烁
        let preview = items[idx].source == job.src ? items[idx].translated : ""
        activity = "翻译中…"
        translator.cancelPreview()        // 正在跑的实时预览翻译先让路
        let result: String
        do {
            result = try await translateFinal(job.text, from: job.src, to: job.tgt,
                                              context: job.context) { partialText in
                // 有预览译文时，等最终结果完整再替换；没有预览时边生成边显示
                guard preview.isEmpty else { return }
                Task { @MainActor in self.update(id, partialText, done: false, token: token) }
            }
        } catch {
            guard !Task.isCancelled, job.gen == runGen, isCurrentJob(id, token: token) else { return }
            hearLog("翻译失败：\(error)", .error)
            update(id, "（翻译失败：\(error.localizedDescription)）", done: true, token: token)
            // 系统听写这条线：翻译失败要另外处理（可能是语言包没下）
            if job.isApple {
                if usingAppleTranslation { appleTranslationFailed() } else { prepareAppleTranslation() }
            }
            kickReader()
            return
        }
        guard job.gen == runGen else { return }        // 翻译中途被停止：stop() 已经收尾
        guard isCurrentJob(id, token: token) else { return }
        update(id, result, done: true, token: token)
        jobTokens[id] = nil                            // 这一句处理完了
        persist()
        activity = isRunning ? "正在聆听" : ""
        kickReader()
        // SenseVoice + Whisper 校正：后面没有排队的句子时，用 Whisper 再识别一遍，有明显差别就替换。
        // 放在后台跑：校正很慢，不能挡住用户刚说的下一句。
        if correctionTask == nil, !recognitionQueue.hasPendingJobs, let address = job.correctionAddress {
            let revision = itemVersions[id] ?? 0
            correctionTask = Task { [weak self] in
                guard let self else { return }
                defer { self.correctionTask = nil }
                await self.whisperCorrect(id: id, samples: job.samples, src: job.src,
                                          oldText: job.text, gen: job.gen, revision: revision,
                                          cloudAddress: address)
            }
        }
    }

    /// 对话翻译模式下按住的语言（实时翻译模式为 nil）
    private var forcedLang: Language? { talkMode ? talkLang : nil }

    var isLoadingPhase: Bool { if case .loading = phase { return true }; return false }
    var loadingText: String? { if case .loading(let m) = phase { return m }; return nil }

    /// 这个任务还是不是这一句"当前有效"的任务。
    /// 超时被放弃的、或者被新任务顶掉的旧任务，结果一律丢掉（不然会串）
    private func isCurrentJob(_ itemID: UUID, token: UUID) -> Bool {
        jobTokens[itemID] == token
    }

    /// 一句卡住太久被放弃了：标成失败（朗读队列才跳过它继续往后）
    private func markJobFailed(_ itemID: UUID, token: UUID) {
        guard isCurrentJob(itemID, token: token) else { return }
        jobTokens[itemID] = nil
        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return }
        // 一定要有终态：
        // 不然这条一直"翻译中"，朗读队列碰到第一句没做完的就停了
        // （后面的话一句都读不出来）。
        items[i].translated = "（翻译失败：这一句等太久了）"
        items[i].done = true
        persist()
        kickReader()
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
        activity = usingCloudASR ? "云端识别中…" : "SenseVoice 识别中…"
        let forced = job.forced
        let fallback = forced?.id ?? job.fallback.id
        let cands = forced.map { [$0.id] } ?? [a.id, b.id]
        let correctionAddress: String?
        let speakerAddress: String?
        let detected: String
        let text: String
        let t0 = Date()
        do {
            // 识别中，实时预览先让路。
            asrBusyCount += 1
            defer { asrBusyCount = max(0, asrBusyCount - 1) }
            let engine = sentenceRecognizer
            let result = try await engine.recognize(samples, candidates: cands, fallback: fallback)
            detected = result.lang
            text = result.text
            correctionAddress = result.correctionAddress
            speakerAddress = result.speakerAddress
            // 日志里写清楚这次用的是哪个引擎（云端就写"云端"和用的哪个方案）
            let engineName: String
            if usingCloudASR {
                engineName = "云端·\(Self.cloudSchemeName(cloudASRScheme))"
            } else {
                engineName = "SenseVoice"
            }
            hearLogText("整句识别（\(engineName)）\(String(format: "%.1f", Date().timeIntervalSince(t0)))s：",
                    String(text.prefix(40)))
        } catch {
            guard !Task.isCancelled, gen == runGen, isCurrentJob(itemID, token: token) else { return }
            hearLog("识别失败：\(error)", .error)
            let keepEngine = (error as? CloudClient.CloudError)?.shouldKeepConfiguredEngine ?? false
            if usingCloudASR, !keepEngine {
                cloudFallbackToApple(.asr, reason: error.localizedDescription)
            }
            if gen == runGen, isCurrentJob(itemID, token: token) {
                activity = "识别失败"
                if let index = items.firstIndex(where: { $0.id == itemID }) {
                    if !Self.hasRealText(items[index].sourceText) {
                        items[index].sourceText = "（识别失败，可长按修改）"
                    }
                    items[index].translated = ""
                    items[index].done = true
                    jobTokens[itemID] = nil
                    persist()
                    kickReader()
                }
            }
            return
        }
        guard gen == runGen else { return }              // 已经停止：结果丢弃
        guard isCurrentJob(itemID, token: token) else { return }   // 这一句已经被放弃/顶掉
        var src = forced ?? ((detected == b.id) ? b : a)
        // Whisper 判断的语言和文字对不上（例如说英文却判成中文）：按文字改成另一种语言
        if forced == nil, !SpeechTextFilter.matchesLanguage(text, src.id) {
            let other = src == a ? b : a
            if SpeechTextFilter.matchesLanguage(text, other.id) { src = other }
        }
        let tgt = (src == a) ? b : a
        if a == langA && b == langB { lastLangID = src.id }

        // 没意义的、或者文字和语言对不上的（例如说中文却出来俄文）都当成噪声丢掉
        guard SpeechTextFilter.isMeaningful(text),
              forced != nil || SpeechTextFilter.matchesLanguage(text, src.id) else {
            if !text.isEmpty {
                hearLogText("丢弃可疑识别结果（\(src.name)）：", String(text.prefix(30)), .warning)
            }
            if !isCurrentJob(itemID, token: token) { return }
            removeItem(itemID)
            activity = isRunning ? "正在聆听" : ""
            return
        }
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        // 语言和预览一致时先保留预览译文，最终译文出来后再替换，避免闪烁
        let old = items[idx]
        let preview = old.source == src ? old.translated : ""
        var item = old
        if old.source != src {
            item = TranslationItem(id: itemID, source: src, target: tgt, sourceText: text, translated: preview,
                                   speakerID: old.speakerID, speakerName: old.speakerName, speakerDetails: old.speakerDetails,
                                   speakerTracked: old.speakerTracked, speakerManuallySet: old.speakerManuallySet)
        } else {
            item.sourceText = text
        }
        item.sourceSide = src == a ? .left : .right
        item.recognizedLanguage = Language.all.first { $0.id == detected }?.id
        let shouldIdentify = speakerTrackingEnabled && !talkMode && speakerAddress != nil
        if shouldIdentify { item.speakerTracked = true }
        guard let idx2 = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx2] = item
        let id = itemID
        rememberReference(id, samples: samples, text: text, lang: src.id)

        let context: [String] = useContext
            ? Array(items[..<idx2].filter { Self.hasRealText($0.sourceText) }.suffix(2).map(\.sourceText))
            : []
        // 原文已经显示出来了，翻译排到另一条队列：
        // 上一句翻得慢也不挡着下一句的原文。
        persist()
        enqueueTranslation(MTJob(itemID: itemID, token: token, gen: gen, text: text,
                                  src: src, tgt: tgt, context: context, samples: samples,
                                  isApple: false, correctionAddress: correctionAddress))
        if shouldIdentify, let speakerAddress {
            enqueueSpeaker(samples, for: itemID, address: speakerAddress)
        }
        _ = preview
    }

    @Published var speakerTrackingEnabled = (UserDefaults.standard.object(forKey: "speakerTrackingEnabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(speakerTrackingEnabled, forKey: "speakerTrackingEnabled")
            if !speakerTrackingEnabled {
                speakerQueue.cancel()
                speakerTracker = SpeakerTracker()
            }
        }
    }

    private struct SpeakerJob {
        let samples: [Float]
        let itemID: UUID
        let conversation: UUID
        let address: String
    }

    private let speakerQueue = SessionJobQueue<SpeakerJob>(timeout: .seconds(10))
    private var speakerTracker = SpeakerTracker()

    private func enqueueSpeaker(_ samples: [Float], for itemID: UUID, address: String) {
        guard samples.count >= 22_400, speakerQueue.pendingCount < 3 else { return }
        let job = SpeakerJob(samples: Array(samples.prefix(160_000)), itemID: itemID,
                             conversation: conversationID, address: address)
        speakerQueue.submit(job) { [weak self] job in
            guard let self,
                  let embedding = try? await self.cloud.speakerEmbedding(samples: job.samples, address: job.address),
                  !Task.isCancelled, job.conversation == self.conversationID,
                  let index = self.items.firstIndex(where: { $0.id == job.itemID }),
                  self.items[index].speakerManuallySet != true else { return }
            let lastID = self.items.compactMap(\.speakerID).max() ?? 0
            guard let id = self.speakerTracker.assign(embedding, after: lastID) else { return }
            let speaker = self.items.first { $0.speakerID == id }
            self.items[index].speakerID = id
            self.items[index].speakerName = speaker?.speakerName
            self.items[index].speakerDetails = speaker?.speakerDetails
            self.persist()
        } timedOut: { _ in }
    }

    func editSpeaker(in conversation: UUID, itemID: UUID, change: ConversationSpeakerEdit) {
        if conversation == conversationID {
            if items.editSpeaker(itemID: itemID, change: change, reservedThrough: speakerTracker.lastID) { persist() }
        } else {
            ConversationStore.shared.editSpeaker(conversationID: conversation, itemID: itemID, change: change)
        }
    }

    /// 用 Whisper 再识别一遍这句（按 SenseVoice 判断出的语言），明显不同就替换原文并重新翻译
    private func whisperCorrect(id: UUID, samples: [Float], src: Language, oldText: String,
                                gen: Int, revision: Int, cloudAddress: String) async {
        guard gen == runGen, !Task.isCancelled else { return }
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
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        // 用户手改过这一句的话，就别再自动改写了：
        // 手改的版本才是用户要的（"我改的" 优先于 "机器觉得更准"）。
        if items[i].sourceText != oldText {
            hearLog("Whisper 校正：这一句已经改过了，不动它", .info)
            return
        }
        hearLogText("Whisper 校正 \(secs)s：「", String(oldText.prefix(30)) + "」→「" + String(text.prefix(30)) + "」")
        let tgt = items[i].target
        let context: [String] = useContext
            ? Array(items[..<i].filter { $0.done }.suffix(2).map(\.sourceText))
            : []
        activity = "翻译中…"
        do {
            let out = try await translateFinal(text, from: src, to: tgt, context: context) { _ in }
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
            rememberReference(id, samples: samples, text: text, lang: src.id)
            update(id, out, done: true)
            persist()
            if wasReading {
                readIndex = min(readIndex, current)
                kickReader()
            }
        } catch {
            hearLog("校正后重新翻译失败：\(error)", .error)
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
        // 聆听中用扬声器读（只有点句子时才会）：暂停麦克风，避免把喇叭声音再识别一遍
        let mute = outputMode == .speaker && isRunning
        // 声音克隆：等提前生成好的克隆声音，没有就用系统声音。
        // 云端要等电脑那边算完（自己也要几秒），多给点时间：
        // 宁可多等一会儿用原声，也不要等不及就退回系统声音。
        let cloneWait: Double = 60
        var cloned: CloneAudio?
        // 发了请求但没拿到声音 = 服务不可用；连请求都没发 = 这句没有声音样本
        var cloneAsked = false
        if voiceClone {
            // ?? 的右边不能带 await（自动闭包里不支持异步），所以分开写
            var task = cloneTasks[item.id]
            if task == nil { task = prepareClone(item.id) }
            if let t = task {
                cloneAsked = true
                cloned = await waitClone(t, seconds: cloneWait)
                if Task.isCancelled || inBackground { return }
            }
        }
        hearLog("朗读：\(item.target.displayName)，\(outputMode == .speaker ? "扬声器" : (pan < 0 ? "左耳" : (pan > 0 ? "右耳" : "双耳")))，\(cloned != nil ? "克隆原声" : "系统声音")")
        // 开了声音克隆却没拿到克隆声音：提醒一下
        if voiceClone, cloned == nil {
            if cloneAsked {
                // 请求发出去了但没等到声音：服务不可用
                hearLog("声音克隆服务不可用，改用系统声音朗读", .warning)
                if !cloneUnavailableNotified {
                    cloneUnavailableNotified = true
                    showToast("声音克隆服务不可用，已改用系统声音朗读", seconds: 4)
                }
            } else {
                // 连请求都没发：说清楚是什么原因（说得太短、太长、开关当时关着……）
                hearLog("这句没有声音样本，改用系统声音朗读（\(cloneMissingReason(item))）", .warning)
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
        if mute { capture.muted = true }
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
                await speaker.speak(SpeakRequest(text: text, locale: item.target.tts, pan: pan))
            }
        } else {
            await speaker.speak(SpeakRequest(text: text, locale: item.target.tts, pan: pan))
        }
        if mute {
            try? await Task.sleep(nanoseconds: 300_000_000)
            capture.muted = false
        }
    }

    // MARK: - 修改原文后重新翻译

    /// 长按气泡改了原文：保存新原文，重新翻译并替换译文
    /// 每一句的版本号：改了原文就 +1。
    /// 翻译回来的时候核对版本，对不上就丢掉——
    /// 否则连续改同一句时，会出现"新原文配旧译文"。
    private var itemVersions: [UUID: Int] = [:]

    func editSource(_ id: UUID, to newText: String) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = items.firstIndex(where: { $0.id == id }), !text.isEmpty,
              text != items[i].sourceText else { return }
        if readingID == id { stopReading() }
        let src = items[i].source, tgt = items[i].target
        // 记下是哪一页：用户可能已经切到别的对话去了，
        // 译完要写回原来那一页，不能因为切页就把这次修改弄丢
        let convID = conversationID
        items[i].sourceText = text
        items[i].translated = ""          // 译文清空，界面显示转圈；保持 done，停止实时翻译时不会被当成未完成删掉
        // 版本号 +1：前一次翻译回来的时候版本对不上，就不要了
        itemVersions[id] = (itemVersions[id] ?? 0) + 1
        let version = itemVersions[id] ?? 0
        persist()
        hearLogText("修改原文并重新翻译：", String(text.prefix(40)))
        let context: [String] = useContext
            ? Array(items[..<i].filter { $0.done }.suffix(2).map(\.sourceText))
            : []
        Task {
            do {
                // 本地翻译模型还在加载时先等它就绪
                if translationEngine == "local" {
                    while isLoadingPhase { try? await Task.sleep(nanoseconds: 200_000_000) }
                    guard phase == .ready else { throw TranslatorError.notLoaded }
                }
                let result = try await translateFinal(text, from: src, to: tgt, context: context) { _ in }
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
                applyTranslation(id, "（翻译失败：\(error.localizedDescription)）", done: true,
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
        let changed = items[i].translated != text
        items[i].translated = text
        items[i].done = done
        // 播报开关只决定自动播放。译文定稿后仍准备克隆声音，供用户点按播放。
        if done, voiceClone {
            if changed { discardCloneTask(id) }
            _ = prepareClone(id)
        }
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
        let vcc = d.object(forKey: "voiceCloneCloud") as? Bool ?? false
        if vcc != voiceCloneCloud { voiceCloneCloud = vcc }
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
        let isrc = d.string(forKey: "inputSource") ?? "phone"
        if isrc != inputSource { inputSource = isrc }
        let tm = (d.object(forKey: "talkMode") as? Bool) ?? d.bool(forKey: "talkMode")
        if tm != talkMode { talkMode = tm }
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
            // 关掉云端克隆，切回手机上的 ZipVoice。
            voiceCloneCloud = false
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
        // 云端又通了：把用户原来选的引擎换回去
        // （之前因为网络抖动自动换成了苹果自带，现在要还回去）
        if status[Self.cloudServiceKey] == Self.cloudStatusOK {
            restorePreferredEngines()
        }
    }

    /// 设置访问口令（填了以后每个请求都带上它）
    func setCloudAccessToken(_ t: String) {
        let v = t.trimmingCharacters(in: .whitespacesAndNewlines)
        cloudAccessToken = v
        CloudClient.accessToken = v
    }

    // MARK: - 云端证书：配对

    /// 跟这台电脑配对：取它的签发根，把指纹给用户确认
    func pairWithCloudService() async {
        let addr = cloudAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty else {
            showToast("先填一下通用服务地址")
            return
        }
        do {
            let info = try await CloudClient.pairInfo(address: addr)
            // 指纹我们自己算：用户看到的这一串，必须和真正要存下来的那根证书对得上。
            // 只显示服务报过来的那个不行——中间人换掉证书的话，
            // 屏幕上那串和实际存的就不一样了。
            let local = Self.certFingerprint(info.rootDer)
            guard !local.isEmpty else {
                showToast("拿到的证书看不懂，请确认地址填的是自己那台电脑", seconds: 4)
                return
            }
            if !info.fingerprint.isEmpty, info.fingerprint != local {
                // 服务报的指纹和实际证书对不上：多半是中间人换了证书
                hearLog("配对：服务报的指纹和实际证书对不上，放弃配对", .error)
                showToast("证书指纹对不上（可能有人在中间冒充），没有配对", seconds: 5)
                return
            }
            pendingPairFingerprint = local
            pendingPairRoot = info.rootDer
            showPairConfirm = true
        } catch {
            showToast("配对失败：\(error.localizedDescription)", seconds: 4)
        }
    }

    /// 用户确认过指纹：记下来（以后它重签证书也认）
    func confirmPairing() {
        guard !pendingPairRoot.isEmpty else { return }
        UserDefaults.standard.set(pendingPairRoot, forKey: "cloudPinnedRoot")
        LocalServerTrust.pinRoot(pendingPairRoot)
        cloudRootFingerprint = pendingPairFingerprint
        pendingPairRoot = Data()
        pendingPairFingerprint = ""
        showPairConfirm = false
        showToast("配对好了：以后只认这台电脑的证书", seconds: 3)
    }

    /// 证书指纹（SHA-256，大写冒号分隔），跟电脑上打印出来的一致
    static func certFingerprint(_ der: Data) -> String {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData),
              let data = SecCertificateCopyData(cert) as Data? else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: - 云端失败时的保底

    /// 云端不可用时自动换引擎用：用户原来选的记在这里，
    /// 服务恢复以后自动换回去。
    /// 不能因为一次网络抖动，就把用户自己在设置里选的东西改掉。
    private static let preferredEngineKey = "enginePreferredBeforeFallback"
    /// 自动回退中（这时候改引擎不算"用户改的"，别把备份清掉）
    private var inEngineFallback = false

    /// 记下用户原来选的引擎（只记第一次）
    private func rememberPreferredEngines() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.preferredEngineKey) else { return }
        d.set(asrEngine, forKey: Self.preferredEngineKey + ".asr")
        d.set(translationEngine, forKey: Self.preferredEngineKey + ".mt")
        d.set(true, forKey: Self.preferredEngineKey)
    }

    /// 用户自己改了设置：备份没用了，清掉
    private func clearPreferredEngineBackup() {
        let d = UserDefaults.standard
        guard d.bool(forKey: Self.preferredEngineKey) else { return }
        d.removeObject(forKey: Self.preferredEngineKey)
        d.removeObject(forKey: Self.preferredEngineKey + ".asr")
        d.removeObject(forKey: Self.preferredEngineKey + ".mt")
    }

    /// 云端又通了：把用户原来的选择换回去
    private func restorePreferredEngines() {
        let d = UserDefaults.standard
        guard d.bool(forKey: Self.preferredEngineKey) else { return }
        let a = Self.normalizedASREngine(d.string(forKey: Self.preferredEngineKey + ".asr") ?? "")
        let m = d.string(forKey: Self.preferredEngineKey + ".mt") ?? ""
        clearPreferredEngineBackup()
        guard !a.isEmpty else { return }
        inEngineFallback = true
        defer { inEngineFallback = false }
        if asrEngine != a { asrEngine = a }
        if !m.isEmpty, translationEngine != m { translationEngine = m }
        hearLog("云端服务恢复了：换回你选的引擎（识别 \(a) / 翻译 \(m)）")
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
                : (isInstalled(.senseVoice) ? "sensevoice" : nil)
            guard let fb else {
                hearLog("云端识别失败，但没有可用的本地引擎，保持原来的设置", .warning)
                showToast("云端识别失败，本地也没有可用的识别模型", seconds: 4)
                return false
            }
            rememberPreferredEngines()      // 记下用户原来选的，等服务恢复了换回去
            inEngineFallback = true
            asrEngine = fb
            inEngineFallback = false
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
            rememberPreferredEngines()
            inEngineFallback = true
            translationEngine = fb
            inEngineFallback = false
        case .clone:
            guard voiceCloneCloud else { return false }
            // 云端克隆用不了了：先关掉声音克隆（直接用系统声音读）。
            // 引擎还是云端，下次打开开关再试一次。
            voiceClone = false
        }
        hearLog(model == .clone
                ? "声音克隆服务不可用，已改用系统声音朗读：\(reason)"
                : "云端\(model.title)调用失败，已改为苹果自带引擎：\(reason)", .warning)
        // 服务端自己报错（500 之类）和网络不通，说的话不一样
        let serverSide = reason.contains("云端服务返回")
        if model == .clone {
            showToast("声音克隆服务不可用，已改用系统声音朗读", seconds: 4)
        } else {
            showToast(serverSide
                      ? "云端\(model.title)服务出错了，已经切换为苹果自带引擎"
                      : "由于网络不稳定或模型不可用，已经切换为苹果自带引擎", seconds: 4)
        }
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

    private func loadClonerIfNeeded() async {
        guard !Task.isCancelled, voiceClone, !voiceCloneCloud, cloneInstalled, !cloneLoading else { return }
        if case .loading = phase { return }
        cloneLoading = true
        defer {
            cloneLoading = false
            modelsRevision += 1
        }
        if await cloner.isLoaded { return }
        guard !Task.isCancelled, voiceClone, !voiceCloneCloud else { return }
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
            showToast("本地声音克隆模型已就绪")
        } catch is CancellationError {
            return
        } catch {
            hearLog("ZipVoice 加载失败：\(error)", .error)
            showToast("本地声音克隆模型加载失败，暂用系统声音朗读")
        }
    }

    /// 记下这句话的声音和文字，给声音克隆当样本（只留最近 30 句）
    private func rememberReference(_ id: UUID, samples: [Float], text: String, lang: String) {
        let secs = Double(samples.count) / 16_000
        guard voiceClone else {
            // 录音的时候声音克隆开关是关的：这一句没有样本
            cloneNote[id] = "录音的时候声音克隆开关是关的"
            return
        }
        if secs >= 1.5 && secs <= 12 {
            // 1.5 秒以上、12 秒以内：这一句自己就能当样本
            cloneRefs[id] = (samples, text)
            lastCloneRef[lang] = (samples, text)
            cloneNote[id] = nil
        } else if let last = lastCloneRef[lang] {
            // 太短（不到 1.5 秒，声音特征不够）或者太长（超过 12 秒，
            // 截一段出来和整句文字对不上）：
            // 借用同一种语言最近一句完整的声音（同一个人的声音，效果一样）
            cloneRefs[id] = last
            cloneNote[id] = secs > 12 ? "这句太长了（超过 12 秒），用了上一句的声音"
                                     : "这句太短了，用了上一句的声音"
        } else if secs <= 12 {
            // 还没有别的样本可以借，只能用它自己的
            cloneRefs[id] = (samples, text)
            cloneNote[id] = nil
        } else {
            // 又太短又太长，一句能用的都没有
            cloneNote[id] = "这句太长了（超过 12 秒），没有可用的声音样本"
        }
        cloneRefOrder.removeAll { $0 == id }
        cloneRefOrder.append(id)
        while cloneRefOrder.count > 30 {
            let old = cloneRefOrder.removeFirst()
            cloneRefs[old] = nil
            discardCloneTask(old)
            cloneNote[old] = nil
        }
    }

    /// 这句为什么没能用克隆声音（写进日志，别只说一句"没有样本"）
    private func cloneMissingReason(_ item: TranslationItem) -> String {
        if !voiceClone { return "声音克隆开关没有打开" }
        if item.translated.isEmpty { return "这句还没有译文" }
        if item.translated.hasPrefix("（翻译失败") { return "这句翻译失败了" }
        // 克隆模型只会说这几门语言（说译文那门语言，样本是源语言的，这是跨语言克隆）
        if !usingCloudClone, (!ZipVoiceModel.supports(item.target.id) || !ZipVoiceModel.supports(item.source.id)) {
            return "本地 ZipVoice 仅支持中英文"
        }
        if !usingCloudClone, !cloneInstalled { return "尚未下载本地 ZipVoice 模型" }
        if CloudVoiceReference.languageNames[item.target.id] == nil {
            return "\(item.target.displayName)这个语言声音克隆不支持"
        }
        guard let ref = cloneRefs[item.id] else {
            return cloneNote[item.id] ?? "这句没有留到声音样本"
        }
        let refText = ref.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if refText.isEmpty || refText == "…" {
            return Self.hasRealText(item.sourceText)
                ? "参考文字还没有更新到这句的原文"
                : "声音样本没有可用的参考文字"
        }
        return "克隆任务没有启动"
    }

    /// 声音克隆的缓存键：语言 + 文字 + 参考音频的指纹。
    ///
    /// 参考音频一定要算进去：同一句话换了说话人（或者换了参考音频），
    /// 克隆出来的声音是不一样的。只用"语言+文字"当键的话，
    /// 换个人说话就会命中上一个人的缓存——听着像别人的声音。
    ///
    /// v4 = 键里加上了参考音频的指纹
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

    private func discardCloneTask(_ id: UUID) {
        cloneTasks.removeValue(forKey: id)?.cancel()
        if cloneWorking[id] != nil { cloneWorking.removeValue(forKey: id) }
    }

    private func clearCloneTasks() {
        cloneTasks.values.forEach { $0.cancel() }
        cloneTasks.removeAll()
        if !cloneWorking.isEmpty { cloneWorking.removeAll() }
    }

    /// 在后台准备克隆声音。已有任务直接复用，避免同一句发出重复请求。
    private func prepareClone(_ id: UUID) -> Task<CloneAudio?, Never>? {
        guard voiceClone else { return nil }
        // 已经有一个任务在跑（或者已经生成好了）：直接用，别再发一遍请求
        if let existing = cloneTasks[id] { return existing }
        guard var ref = cloneRefs[id],
              let item = items.first(where: { $0.id == id }),
              item.canReadAloud,
              CloudVoiceReference.languageNames[item.target.id] != nil else { return nil }
        let text = item.translated, lang = item.target.id
        // 参考文字是占位符（"…"）或者空的时候别拿去用：
        // 参考音频和参考文字对不上，模型念出来就是一堆乱响
        var refText = ref.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if refText == "…" { refText = "" }
        // 早期为尽快保存音频，参考文字可能还是“…”占位。
        // 现在这句已经定稿，就用当前原文补齐，避免明明识别成功却无法启动克隆。
        if refText.isEmpty, Self.hasRealText(item.sourceText) {
            refText = item.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            ref.text = refText
            cloneRefs[id] = ref
            lastCloneRef[item.source.id] = ref
            cloneNote[id] = nil
        }
        // 云端的参考音频沿用既有降噪。
        // 克隆会把参考音频里的环境音一起学过去，
        // 不降噪的话环境音就跟着念出来，听着是"有杂的声音"
        let refSamples = usingCloudClone ? CloudVoiceReference.denoise(ref.samples) : ref.samples
        if !usingCloudClone, (!ZipVoiceModel.supports(lang) || !ZipVoiceModel.supports(item.source.id) || refText.isEmpty) { return nil }
        let backend = usingCloudClone ? "cloud" : "zipvoice"
        let key = backend + "-" + cloneCacheKey(lang: lang, text: text + "\n" + refText, ref: ref.samples)
        let cloner = self.cloner
        let cloud = self.cloud
        let useCloud = usingCloudClone
        // 生成中：气泡里的喇叭显示成一直在转的半圈
        let jobID = UUID()
        cloneWorking[id] = jobID
        let t = Task<CloneAudio?, Never>.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                // 之前生成过一样的，直接拿来放，不用再等模型算一遍
                if let cached = await CloneCache.shared.get(key) {
                    hearLog("声音克隆：命中缓存，直接播放")
                    return cached
                }
                if useCloud {
                    // 把可用内存一起记上：万一又被系统杀掉，日志里能看出来
                    let memMB = await MainActor.run { Self.freeMB() }
                    hearLogNow("声音克隆（云端）：开始生成（可用内存 \(memMB) MB）")
                    // 语言名要用模型认的那种写法（english/chinese），和本地跑的时候一样
                    let cloudLang = CloudVoiceReference.languageNames[lang] ?? lang
                    let out: CloneAudio
                    do {
                        out = try await cloud.clone(text: text, lang: cloudLang,
                                                    reference: refSamples, referenceText: refText)
                    } catch {
                        let keepEngine = (error as? CloudClient.CloudError)?.shouldKeepConfiguredEngine ?? false
                        if !Task.isCancelled, !keepEngine {
                            let why = error.localizedDescription
                            await MainActor.run {
                                if self.cloneWorking[id] == jobID {
                                    self.cloudFallbackToApple(.clone, reason: why)
                                }
                            }
                        }
                        return nil
                    }
                    hearLogNow("声音克隆（云端）：结束，生成 \(String(format: "%.1f", Double(out.samples.count) / Double(out.sampleRate))) 秒声音")
                    await CloneCache.shared.put(key, out)
                    return out
                }
                hearLogNow("声音克隆（本地）：开始生成")
                let out = try await cloner.synthesize(text: text, language: lang,
                                                      reference: ref.samples, referenceText: refText)
                hearLogNow("声音克隆（本地）：结束，生成 \(String(format: "%.1f", Double(out.samples.count) / Double(out.sampleRate))) 秒声音")
                // 存进缓存，下次同一句话直接播放
                await CloneCache.shared.put(key, out)
                return out
            } catch {
                hearLog("声音克隆生成失败：\(error)", .error)
                return nil
            }
        }
        cloneTasks[id] = t
        Task { [weak self] in
            _ = await t.value
            guard let self, self.cloneWorking[id] == jobID else { return }
            self.cloneWorking.removeValue(forKey: id)
        }
        return t
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
        persist()
    }

    private func resetLanguagePreview() {
        lastLangID = nil
        cancelASRPreview()
        mtPending = nil
        translator.cancelPreview()
        partial = ""
        partialSource = nil
        partialTranslation = ""
        partialTranslationFor = ""
        previewText.removeAll()
    }

    private func pushConfig() {
        var c = Segmenter.Config()
        c.sensitivityDB = Float(sensitivity)
        c.silenceMs = Int(silenceMs)
        // 对话翻译模式（按住说话）：短回答（"好""是"）也要认出来，
        // 门槛比实时翻译低（400ms → 200ms）
        c.minSpeechMs = talkMode ? 200 : 400
        // 按住说话：连"好""是"这种特别短的回答也要收进来
        c.holdMode = talkMode
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
