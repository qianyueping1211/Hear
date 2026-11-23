import Foundation

/// 将同一个对话里的原始音频持续写入本地 WAV 文件（16kHz / 16-bit / 单声道），
/// 并维护 AudioCapture 帧号与录音文件时间的映射，用于历史对话回放高亮与跳转。
final class ConversationAudioRecorder: @unchecked Sendable {
    private static let sampleRate: Int = 16_000
    private static let headerSize: Int = 44

    private let queue = DispatchQueue(label: "hear.audio.fullrecord", qos: .utility)
    private let stateLock = NSLock()

    // 以下状态在 stateLock 保护下读写，保证主线程查时间范围时零阻塞
    private var enabled = false
    private var activeConversationID: UUID?
    private var lastCaptureFrame: Int64?
    private var plannedFrames: Int64 = 0

    // 以下状态只在 queue 串行队列里读写
    private var fileHandle: FileHandle?
    private var openConversationID: UUID?
    private var writtenFrames: Int64 = 0
    private var framesSinceHeaderPatch: Int64 = 0

    /// 启用或切换当前录音所属的对话
    func configure(enabled: Bool, conversationID: UUID) {
        if !enabled {
            stateLock.lock()
            self.enabled = false
            stateLock.unlock()
            queue.async { [weak self] in
                self?.closeFileOnQueue()
            }
            return
        }

        let url = ConversationStore.audioFileURL(for: conversationID)
        let existingFrames = Self.existingFrameCount(at: url)

        stateLock.lock()
        let conversationChanged = activeConversationID != conversationID
        self.enabled = true
        if conversationChanged {
            activeConversationID = conversationID
            plannedFrames = existingFrames
            lastCaptureFrame = nil
        }
        stateLock.unlock()

        if conversationChanged {
            queue.async { [weak self] in
                self?.closeFileOnQueue()
            }
        }
    }

    /// 由 AudioCapture 在采集到每块 16kHz 音频时调用
    func append(samples: [Float], captureStartFrame: Int64, muted: Bool) {
        guard !samples.isEmpty else { return }

        stateLock.lock()
        guard enabled, let convID = activeConversationID else {
            stateLock.unlock()
            return
        }
        plannedFrames += Int64(samples.count)
        lastCaptureFrame = captureStartFrame + Int64(samples.count)
        stateLock.unlock()

        queue.async { [weak self] in
            self?.writeSamplesOnQueue(samples, muted: muted, conversationID: convID)
        }
    }

    /// 把断句器的 [startFrame, endFrame] 换算成完整录音文件里的起止时间（秒）
    func timeRange(startFrame: Int64, endFrame: Int64) -> (start: Double, end: Double)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard enabled, let lastCap = lastCaptureFrame, plannedFrames > 0 else { return nil }
        let deltaEnd = max(0, lastCap - endFrame)
        let fileEnd = max(0, plannedFrames - deltaEnd)
        let segFrames = max(0, endFrame - startFrame)
        let fileStart = max(0, fileEnd - segFrames)
        let sr = Double(Self.sampleRate)
        return (Double(fileStart) / sr, Double(fileEnd) / sr)
    }

    /// 停止时给正在说的半句（flushPartial）计算到当前为止的时间范围
    func timeRangeToCurrent(startFrame: Int64) -> (start: Double, end: Double)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard enabled, let lastCap = lastCaptureFrame, plannedFrames > 0 else { return nil }
        let segFrames = max(0, lastCap - startFrame)
        let fileEnd = plannedFrames
        let fileStart = max(0, fileEnd - segFrames)
        let sr = Double(Self.sampleRate)
        return (Double(fileStart) / sr, Double(fileEnd) / sr)
    }

    /// 暂停/停止录音时刷新 WAV 文件头（不清空对话状态，同一对话续录可继续追加）
    func flush() {
        queue.async { [weak self] in
            guard let self else { return }
            self.patchHeaderOnQueue()
            try? self.fileHandle?.synchronize()
        }
    }

    /// 切换到新对话或彻底关闭时调用
    func close() {
        stateLock.lock()
        activeConversationID = nil
        lastCaptureFrame = nil
        plannedFrames = 0
        stateLock.unlock()

        queue.async { [weak self] in
            self?.closeFileOnQueue()
        }
    }

    // MARK: - 磁盘写入（仅在 queue 上调用）

    private func writeSamplesOnQueue(_ samples: [Float], muted: Bool, conversationID: UUID) {
        if openConversationID != conversationID || fileHandle == nil {
            closeFileOnQueue()
            guard openFileOnQueue(for: conversationID) else { return }
        }
        guard let handle = fileHandle else { return }

        var pcm = [Int16](repeating: 0, count: samples.count)
        if !muted {
            for i in samples.indices {
                let v = samples[i].isFinite ? max(-1.0, min(1.0, samples[i])) : 0
                let x = (v * 32767.0).rounded()
                pcm[i] = Int16(max(-32767.0, min(32767.0, x)))
            }
        }
        let data = pcm.withUnsafeBytes { Data($0) }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            writtenFrames += Int64(samples.count)
            framesSinceHeaderPatch += Int64(samples.count)
            if framesSinceHeaderPatch >= Int64(Self.sampleRate * 2) {
                patchHeaderOnQueue()
                framesSinceHeaderPatch = 0
            }
        } catch {
            hearLog("写入完整录音失败：\(error)", .warning)
        }
    }

    private func openFileOnQueue(for conversationID: UUID) -> Bool {
        let dir = ConversationStore.conversationsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = ConversationStore.audioFileURL(for: conversationID)
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path) {
            Self.repairWavHeaderIfNeeded(at: url)
            do {
                let handle = try FileHandle(forUpdating: url)
                let endOffset = try handle.seekToEnd()
                let dataBytes = max(0, Int64(endOffset) - Int64(Self.headerSize))
                fileHandle = handle
                openConversationID = conversationID
                writtenFrames = dataBytes / 2
                framesSinceHeaderPatch = 0
                return true
            } catch {
                hearLog("打开已有完整录音失败：\(error)", .warning)
                return false
            }
        } else {
            let header = Self.makeWavHeader(dataBytes: 0, sampleRate: Self.sampleRate)
            do {
                try header.write(to: url, options: .atomic)
                let handle = try FileHandle(forUpdating: url)
                _ = try handle.seekToEnd()
                fileHandle = handle
                openConversationID = conversationID
                writtenFrames = 0
                framesSinceHeaderPatch = 0
                return true
            } catch {
                hearLog("创建完整录音文件失败：\(error)", .warning)
                return false
            }
        }
    }

    private func patchHeaderOnQueue() {
        guard let handle = fileHandle else { return }
        let dataBytes = UInt32(clamping: writtenFrames * 2)
        let header = Self.makeWavHeader(dataBytes: dataBytes, sampleRate: Self.sampleRate)
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header)
            _ = try handle.seekToEnd()
        } catch {
            hearLog("更新完整录音文件头失败：\(error)", .warning)
        }
    }

    private func closeFileOnQueue() {
        if fileHandle != nil {
            patchHeaderOnQueue()
            try? fileHandle?.synchronize()
            try? fileHandle?.close()
        }
        fileHandle = nil
        openConversationID = nil
        writtenFrames = 0
        framesSinceHeaderPatch = 0
    }

    // MARK: - WAV 工具

    private static func existingFrameCount(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        let bytes = size.int64Value - Int64(headerSize)
        return max(0, bytes / 2)
    }

    private static func makeWavHeader(dataBytes: UInt32, sampleRate: Int) -> Data {
        var data = Data()
        data.reserveCapacity(headerSize)
        func u32(_ v: UInt32) -> Data { var x = v.littleEndian; return withUnsafeBytes(of: &x) { Data($0) } }
        func u16(_ v: UInt16) -> Data { var x = v.littleEndian; return withUnsafeBytes(of: &x) { Data($0) } }
        let riffSize = UInt32(clamping: UInt64(36) + UInt64(dataBytes))
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(u32(riffSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(u32(16))
        data.append(u16(1))                           // PCM
        data.append(u16(1))                           // 单声道
        data.append(u32(UInt32(sampleRate)))
        data.append(u32(UInt32(sampleRate * 2)))      // byteRate
        data.append(u16(2))                           // blockAlign
        data.append(u16(16))                          // bitsPerSample
        data.append(contentsOf: Array("data".utf8))
        data.append(u32(dataBytes))
        return data
    }

    /// 进程异常退出可能导致 WAV 头里的长度滞后于实际文件大小，加载前按实际字节数修复
    static func repairWavHeaderIfNeeded(at url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sizeNum = attrs[.size] as? NSNumber else { return }
        let fileSize = sizeNum.int64Value
        guard fileSize >= Int64(headerSize) else { return }
        let expectedDataBytes = UInt32(clamping: fileSize - Int64(headerSize))
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let existing = try? handle.read(upToCount: headerSize), existing.count == headerSize else { return }
        let currentDataBytes = existing.withUnsafeBytes { ptr -> UInt32 in
            UInt32(littleEndian: ptr.load(fromByteOffset: 40, as: UInt32.self))
        }
        guard currentDataBytes != expectedDataBytes else { return }
        let patched = makeWavHeader(dataBytes: expectedDataBytes, sampleRate: sampleRate)
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: patched)
    }
}
