import Foundation

/// 基于音量的自动断句（VAD）。输入 16kHz 单声道 Float 采样。
/// 说话开始 → 每隔 1 秒给一次“中间结果” → 停顿超过设定时长 → 输出整句。
final class Segmenter {
    struct Config {
        var sensitivityDB: Float = 12     // 高于环境噪声多少 dB 算说话（越小越灵敏）
        var silenceMs: Int = 700          // 停顿多久算一句话结束
        var maxSeconds: Double = 20       // 单句最长时长
        var minSpeechMs: Int = 350        // 太短的声音忽略
    }

    enum Event {
        case level(Float)                 // 0...1，用于界面动画
        case started(Int)
        case partial(Int, [Float])
        case ended(Int, [Float])
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
    private var noiseDB: Float = -60
    private var segID = 0
    private var lastPartialAt = 0
    private var frameCounter = 0

    func reset() {
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

        let threshold = max(noiseDB + config.sensitivityDB, -55)

        if !inSpeech {
            preroll.append(contentsOf: f)
            let keep = sr * 3 / 10        // 保留说话前 300ms
            if preroll.count > keep { preroll.removeFirst(preroll.count - keep) }

            if db > threshold {
                voicedRun += 1
            } else {
                voicedRun = 0
                noiseDB = min(-25, max(-80, noiseDB * 0.95 + db * 0.05))
            }
            if voicedRun >= 3 {
                inSpeech = true
                segID += 1
                speech = preroll
                preroll.removeAll()
                silentRun = 0
                voicedFrames = voicedRun
                lastPartialAt = speech.count
                onEvent?(.started(segID))
            }
        } else {
            speech.append(contentsOf: f)
            if db > threshold - 3 {
                silentRun = 0
                voicedFrames += 1
            } else {
                silentRun += 1
            }
            let silentMs = silentRun * 30
            let maxed = speech.count >= Int(config.maxSeconds * Double(sr))
            if silentMs >= config.silenceMs || maxed {
                finish()
            } else if speech.count - lastPartialAt >= sr {
                lastPartialAt = speech.count
                onEvent?(.partial(segID, speech))
            }
        }
    }

    private func finish() {
        // 去掉尾部大部分静音，只留 ~200ms
        let tailFrames = max(0, silentRun - 7)
        let cut = min(speech.count, tailFrames * frame)
        let audio = Array(speech.prefix(speech.count - cut))
        if voicedFrames * 30 >= config.minSpeechMs {
            onEvent?(.ended(segID, audio))
        }
        inSpeech = false
        speech.removeAll()
        voicedRun = 0; silentRun = 0; voicedFrames = 0
    }
}
