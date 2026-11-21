import Foundation

/// 基于音量的自动断句（VAD）。输入 16kHz 单声道 Float 采样。
/// 说话开始 → 每隔 1 秒给一次“中间结果” → 停顿超过设定时长 → 输出整句。
final class Segmenter {
    struct Config {
        var sensitivityDB: Float = 12     // 高于环境噪声多少 dB 算说话（越小越灵敏）
        var silenceMs: Int = 700          // 停顿多久算一句话结束
        var maxSeconds: Double = 15       // 单句最长时长
        var partialEvery: Double = 0.4    // 说话中每隔多久给一次中间结果（秒）
        var minSpeechMs: Int = 400        // 太短的声音忽略（咳嗽、碰撞声等）
        var holdMode: Bool = false         // 按住说话：门槛放低（短回答也要认出来）
    }

    enum Event {
        case level(Float)                 // 0...1，用于界面动画
        case started(Int)
        case partial(Int, [Float])
        case ended(Int, [Float])
        case discarded(Int)               // 声音太短，不算一句话
        case noise(Float, Float)          // 环境噪声、触发阈值（dB），每隔几秒报告一次，写日志用
    }

    var config = Config()
    var onEvent: ((Event) -> Void)?

    private let sr = 16_000
    private let frame = 480               // 30ms
    private var carry: [Float] = []
    private var preroll: [Float] = []
    private var speech: [Float] = []
    private var inSpeech = false
    private var voicedRun = 0
    private var silentRun = 0
    private var voicedFrames = 0
    private var segID = 0
    private var lastPartialAt = 0
    private var frameCounter = 0
    private var voicedLevel: Float = -40  // 这句话说话声的平均音量，用来判断停顿

    /// 环境噪声（dB）：门限是它加上灵敏度。
    ///
    /// 这里是整个断句的关键，三条规矩：
    ///  1) 说话的时候绝对不拿说话声去估噪声——底噪被估成自己说话那么响，
    ///     门限就抬到下一句根本够不着的地方，
    ///     表现是“上一句译完了，后面怎么说都不出声了”；
    ///  2) 变安静了要赶紧跟上（用户停下来，底噪得马上降下来）；
    ///  3) 变吵了要慢慢跟上，而且只用“明显不是说话”的帧——
    ///     免得用户说话声音不大的时候，底噪一路追着他的声音往上爬，
    ///     爬到门限比声音还高，麦克风就永远聋了。
    private var noiseEstimate: Float = -52

    /// 丢掉当前正在说的这一句（不算一句话的开始/结束），环境噪声的估计留着。
    ///
    /// 朗读译文的时候用：喇叭的声音不能算成用户说的话，
    /// 但环境噪声还得继续估（不然朗读一结束门限就乱跳）。
    func discardCurrent() {
        if inSpeech { onEvent?(.discarded(segID)) }
        carry.removeAll(); preroll.removeAll(); speech.removeAll()
        inSpeech = false; voicedRun = 0; silentRun = 0; voicedFrames = 0
    }

    /// 完全重置：连环境噪声的估计一起清掉。
    ///
    /// 上一轮要是正好在很吵的环境里（或者刚读完一段译文），
    /// 底噪会被估得偏高，高到说话声都够不着——看着像“麦克风坏了”。
    func reset() {
        discardCurrent()
        noiseEstimate = -52
        voicedLevel = -40
    }

    /// 停止时把正在说的那句也交出去
    func flush() {
        if inSpeech { finish() }
        reset()
    }

    func feed(_ samples: [Float]) {
        carry.append(contentsOf: samples)
        var offset = 0
        while carry.count - offset >= frame {
            processFrame(carry[offset..<(offset + frame)])
            offset += frame
        }
        if offset > 0 { carry.removeFirst(offset) }
    }

    private func processFrame(_ f: ArraySlice<Float>) {
        var sum: Float = 0
        for x in f { sum += x * x }
        let rms = (sum / Float(f.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))

        frameCounter += 1
        if frameCounter % 2 == 0 {
            onEvent?(.level(min(1, max(0, (db + 60) / 50))))
        }

        let noise = noiseEstimate
        // 门限不再钉死在 -50：房间很安静的时候（比如没开语音增强、离得远），
        // 说话声可能只有 -55 dB，钉在 -50 就永远够不着门限，
        // 于是“停一会儿再说话”那一句就再也断不出来了。
        let threshold = max(noise + config.sensitivityDB, -68)
        if frameCounter % 167 == 0 { onEvent?(.noise(noise, threshold)) }   // 约 5 秒一次

        if !inSpeech { updateNoise(db, threshold: threshold) }

        if !inSpeech {
            preroll.append(contentsOf: f)
            let keep = sr * 3 / 10        // 保留说话前 300ms
            if preroll.count > keep { preroll.removeFirst(preroll.count - keep) }

            if db > threshold {
                voicedRun += 1
            } else {
                voicedRun = 0
            }
            // 连续高于阈值多久才算开始说话。
            // 按住说话时（holdMode）门槛放低：用户是故意按着按钮的，
            // "好""是"这种一两百毫秒的回答也得收进来。
            let triggerFrames = config.holdMode ? 3 : 5
            if voicedRun >= triggerFrames {
                inSpeech = true
                segID += 1
                speech = preroll
                preroll.removeAll()
                silentRun = 0
                voicedFrames = voicedRun
                voicedLevel = db
                lastPartialAt = speech.count
                onEvent?(.started(segID))
            }
        } else {
            speech.append(contentsOf: f)
            // 停顿：音量回落到“噪声 + 灵敏度的一半”以下，或比这句话的说话音量低 18 dB 以上
            // （第二条让嘈杂环境里也能断句）
            let pauseLevel = max(noise + config.sensitivityDB * 0.5, voicedLevel - 18)
            if db > pauseLevel {
                silentRun = 0
                voicedFrames += 1
                voicedLevel = voicedLevel * 0.97 + db * 0.03
            } else {
                silentRun += 1
            }
            let silentMs = silentRun * 30
            let maxed = speech.count >= Int(config.maxSeconds * Double(sr))
            if silentMs >= config.silenceMs || maxed {
                finish()
            } else if speech.count - lastPartialAt >= Int(config.partialEvery * Double(sr)) {
                lastPartialAt = speech.count
                onEvent?(.partial(segID, speech))
            }
        }
    }

    /// 更新环境噪声的估计（只在没在说话的时候调）。
    private func updateNoise(_ db: Float, threshold: Float) {
        if db < noiseEstimate {
            // 真的安静下来了：赶紧跟上（跟慢了会错过开口那半秒）
            noiseEstimate += (db - noiseEstimate) * 0.5
        } else if db <= threshold {
            // 有点吵了：慢慢跟上（每秒最多涨零点几个 dB）
            noiseEstimate += (db - noiseEstimate) * 0.01
        }
        // 上面的“明显不是说话”那条已经挡住了说话声，这里只管别跑偏
        noiseEstimate = min(-25, max(-80, noiseEstimate))
    }

    private func finish() {
        // 去掉尾部大部分静音，只留 ~200ms
        let tailFrames = max(0, silentRun - 7)
        let cut = min(speech.count, tailFrames * frame)
        let audio = Array(speech.prefix(speech.count - cut))
        if voicedFrames * 30 >= config.minSpeechMs {
            onEvent?(.ended(segID, audio))
        } else {
            onEvent?(.discarded(segID))
        }
        inSpeech = false
        speech.removeAll()
        voicedRun = 0; silentRun = 0; voicedFrames = 0
    }
}
