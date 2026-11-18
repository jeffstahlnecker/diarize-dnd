@preconcurrency import AVFoundation
import CoreAudio
import DiarizeCore
import Foundation

/// Multichannel capture: one input channel of a multi-input device per person.
///
/// - One mono file per mapped channel: 16 kHz Float32 (`asr`) or device rate (at most 48 kHz) 16-bit PCM (`archive`).
/// - Plus `mix.wav`, a 16 kHz mono Float32 mixdown of the mapped channels: the recording's primary file and what is analysed.
/// - All files come from one device and one sample stream, so they are sample-aligned and share one clock.
final class MultichannelSession: RecordingSession, @unchecked Sendable {
    enum SessionError: Error, LocalizedError {
        case deviceNotFound(String)
        case channelOutOfRange(Int, Int)
        case engine(String)
        var errorDescription: String? {
            switch self {
            case .deviceNotFound(let uid): return "Input device \(uid) is not connected."
            case .channelOutOfRange(let c, let n): return "Channel \(c) does not exist; the device has \(n) input channels."
            case .engine(let m): return "Audio engine failed to start: \(m)"
            }
        }
    }

    private let request: CaptureRequest
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Timeline.sampleRate, channels: 1, interleaved: false)!

    private var mixWriter: WAVWriter?
    private var floatWriters: [Int: WAVWriter] = [:]
    private var pcmWriters: [Int: PCM16WAVWriter] = [:]
    private var converters: [Int: AVAudioConverter] = [:]
    private var mixConverter: AVAudioConverter?
    private var meters: [Int: SmoothedLevel] = [:]
    private var bytes: [Int: Int] = [:]
    private var frames = 0
    private var inputRate: Double = 0

    init(request: CaptureRequest) throws {
        self.request = request
        for ch in request.channels ?? [] { meters[ch.channel] = SmoothedLevel() }
    }

    func start() async throws {
        let input = engine.inputNode
        if let uid = request.micDeviceUID {
            guard let device = AudioInputDevices.device(forUID: uid) else { throw SessionError.deviceNotFound(uid) }
            var id = device.deviceID
            if let unit = input.audioUnit {
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                     &id, UInt32(MemoryLayout<AudioObjectID>.size))
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SessionError.engine("The input device is not providing a valid format (microphone permission granted?)")
        }
        let available = Int(format.channelCount)
        for ch in request.channels ?? [] where ch.channel > available {
            throw SessionError.channelOutOfRange(ch.channel, available)
        }
        inputRate = format.sampleRate
        let archiveRate = Int(min(48_000, format.sampleRate))

        do {
            mixWriter = try WAVWriter(url: request.outputURL, sampleRate: Int(Timeline.sampleRate), channels: 1)
            for ch in request.channels ?? [] {
                if request.captureQuality == "archive" {
                    pcmWriters[ch.channel] = try PCM16WAVWriter(url: ch.fileURL, sampleRate: archiveRate)
                } else {
                    floatWriters[ch.channel] = try WAVWriter(url: ch.fileURL, sampleRate: Int(Timeline.sampleRate), channels: 1)
                }
            }
        } catch {
            throw SessionError.engine("Could not open the output files: \(error.localizedDescription)")
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw SessionError.engine(error.localizedDescription)
        }
    }

    func stop() async throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try lock.withLock {
            try mixWriter?.close()
            for w in floatWriters.values { try w.close() }
            for w in pcmWriters.values { try w.close() }
        }
    }

    var framesCaptured: Int { lock.withLock { frames } }

    func levels() -> LevelReading {
        let list = lock.withLock {
            (request.channels ?? []).map { LevelReading.ChannelLevel(channel: $0.channel, level: meters[$0.channel]?.current() ?? 0) }
        }
        return LevelReading(mic: list.map(\.level).max() ?? 0, system: nil, channels: list)
    }

    func channelBytes() -> [Int: Int] { lock.withLock { bytes } }

    // MARK: - Audio thread

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let rate = buffer.format.sampleRate
        let channelCount = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let mapped = request.channels ?? []

        func samples(of channel: Int) -> [Float] {
            let idx = channel - 1
            guard idx < channelCount else { return [Float](repeating: 0, count: n) }
            if interleaved {
                let p = data[0]
                return (0..<n).map { p[$0 * channelCount + idx] }
            }
            return Array(UnsafeBufferPointer(start: data[idx], count: n))
        }

        lock.lock()
        defer { lock.unlock() }
        var mix = [Float](repeating: 0, count: n)
        for ch in mapped {
            let s = samples(of: ch.channel)
            meters[ch.channel]?.feed(s)
            for i in 0..<n { mix[i] += s[i] }
            if let w = pcmWriters[ch.channel] {
                let out = rate > 48_000 ? Self.decimate(s, from: rate, to: 48_000) : s
                try? w.append(out)
                bytes[ch.channel, default: 0] += out.count * 2
            } else if let w = floatWriters[ch.channel] {
                let out = resample(s, rate: rate, converter: &converters[ch.channel])
                try? w.append(samples: out)
                bytes[ch.channel, default: 0] += out.count * 4
            }
        }
        if !mapped.isEmpty {
            let scale = 1 / Float(mapped.count).squareRoot()
            for i in 0..<n { mix[i] = max(-1, min(1, mix[i] * scale)) }
        }
        let mix16 = resample(mix, rate: rate, converter: &mixConverter)
        try? mixWriter?.append(samples: mix16)
        frames += mix16.count
    }

    private func resample(_ samples: [Float], rate: Double, converter: inout AVAudioConverter?) -> [Float] {
        if rate == Timeline.sampleRate { return samples }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        if converter == nil || converter?.inputFormat.sampleRate != rate {
            converter = AVAudioConverter(from: inFormat, to: target)
        }
        guard let conv = converter else { return [] }
        let capacity = AVAudioFrameCount(Double(samples.count) * Timeline.sampleRate / rate + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        let state = FeedOnce(inBuffer)
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if state.fed { status.pointee = .noDataNow; return nil }
            state.fed = true
            status.pointee = .haveData
            return state.buffer
        }
        guard error == nil, let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    /// Simple integer-ratio decimation for devices above 48 kHz (archive quality).
    static func decimate(_ s: [Float], from rate: Double, to target: Double) -> [Float] {
        let step = max(1, Int((rate / target).rounded()))
        return stride(from: 0, to: s.count, by: step).map { s[$0] }
    }
}

private final class FeedOnce: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var fed = false
    init(_ b: AVAudioPCMBuffer) { buffer = b }
}

/// Same scale and smoothing as `AudioLevelMeter`, for any number of channels.
final class SmoothedLevel: @unchecked Sendable {
    private var value = 0.0
    private var lastFeed = 0.0

    func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sum = 0.0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        let db = rms > 0 ? 20 * log10(rms) : -60
        let norm = max(0, min(1, (db + 60) / 60))
        value += (norm - value) * (norm > value ? 0.5 : 0.15)
        lastFeed = Date.timeIntervalSinceReferenceDate
    }

    func current() -> Double {
        let age = Date.timeIntervalSinceReferenceDate - lastFeed
        if age > 0.25 { return value * max(0, 1 - (age - 0.25) / 0.5) }
        return value
    }
}

/// Streaming 16-bit PCM mono WAV writer (archive quality). Sizes are patched on close.
final class PCM16WAVWriter {
    private let handle: FileHandle
    private var dataBytes: UInt32 = 0
    private var closed = false

    init(url: URL, sampleRate: Int) throws {
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: WAVHeader.make(format: 1, channels: 1, sampleRate: UInt32(sampleRate), bitsPerSample: 16, dataBytes: 0))
    }

    func append(_ samples: [Float]) throws {
        guard !closed, !samples.isEmpty else { return }
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * 32767).littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: data)
        dataBytes &+= UInt32(data.count)
    }

    func close() throws {
        guard !closed else { return }
        closed = true
        try WAVHeader.patchSizes(handle: handle, dataBytes: dataBytes)
        try handle.close()
    }

    deinit { try? close() }
}

/// Canonical 44-byte WAV header helpers (also used to repair files left open by a crash).
enum WAVHeader {
    static func make(format: UInt16, channels: UInt16, sampleRate: UInt32, bitsPerSample: UInt16, dataBytes: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 &+ dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(format); u16(channels); u32(sampleRate)
        let blockAlign = channels * bitsPerSample / 8
        u32(sampleRate * UInt32(blockAlign)); u16(blockAlign); u16(bitsPerSample)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    static func patchSizes(handle: FileHandle, dataBytes: UInt32) throws {
        var riff = (36 &+ dataBytes).littleEndian
        var data = dataBytes.littleEndian
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: &riff) { Data($0) })
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: withUnsafeBytes(of: &data) { Data($0) })
    }

    /// A WAV written by `WAVWriter` whose process died before `close()` still has zero sizes in its header.
    /// Patch them from the file length so the audio can be analysed. Returns the data byte count, or nil if not a canonical WAV.
    @discardableResult
    static func repair(url: URL) -> UInt32? {
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 44), head.count == 44,
              head.prefix(4) == Data("RIFF".utf8), head[36..<40] == Data("data".utf8),
              let end = try? handle.seekToEnd(), end >= 44 else { return nil }
        let blockAlign = UInt64(head[32]) | UInt64(head[33]) << 8
        var bytes = end - 44
        if blockAlign > 0 { bytes -= bytes % blockAlign }
        let dataBytes = UInt32(min(bytes, UInt64(UInt32.max - 36)))
        try? patchSizes(handle: handle, dataBytes: dataBytes)
        return dataBytes
    }
}
