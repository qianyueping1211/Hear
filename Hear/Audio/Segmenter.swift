import Foundation

/// 基于音量的自动断句（VAD）。输入 16kHz 单声道 Float 采样。
/// 说话开始 → 每隔 1 秒给一次“中间结果” → 停顿超过设定时长 → 输出整句。
final class Segmenter {
    struct Config {
        var sensitivityDB: Float = 12     // 高于环境噪声多少 dB 算说话（越小越灵敏）
        var silenceMs: Int = 700          // 停顿多久算一句话结束
        var maxSeconds: Double = 15       // 单句最长时长
        var partialEvery: Double = 0.7    // 说话中每隔多久给一次中间结果（秒）
        var minSpeechMs: Int = 350        // 太短的声音忽略
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
    private var history: [Float] = []     // 最近约 3 秒每帧的音量，用来估计环境噪声
    private var segID = 0
    private var lastPartialAt = 0
    private var frameCounter = 0
    private var voicedLevel: Float = -40  // 这句话说话声的平均音量，用来判断停顿

    func reset() {
        if inSpeech { onEvent?(.discarded(segID)) }
        carry.removeAll(); preroll.removeAll(); speech.removeAll()
        inSpeech = false; voicedRun = 0; silentRun = 0; voicedFrames = 0
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

        history.append(db)
        if history.count > 100 { history.removeFirst(history.count - 100) }
        let noise = noiseFloor()
        let threshold = max(noise + config.sensitivityDB, -50)
        if frameCounter % 167 == 0 { onEvent?(.noise(noise, threshold)) }   // 约 5 秒一次

        if !inSpeech {
            preroll.append(contentsOf: f)
            let keep = sr * 3 / 10        // 保留说话前 300ms
            if preroll.count > keep { preroll.removeFirst(preroll.count - keep) }

            if db > threshold {
                voicedRun += 1
            } else {
                voicedRun = 0
            }
            if voicedRun >= 3 {
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

    /// 环境噪声 = 最近 3 秒音量的第 10 百分位（会随环境自动调整，说话中也会更新）
    private func noiseFloor() -> Float {
        guard history.count >= 10 else { return -50 }
        let sorted = history.sorted()
        return min(-25, max(-75, sorted[sorted.count / 10]))
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
