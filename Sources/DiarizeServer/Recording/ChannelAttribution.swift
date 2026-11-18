@preconcurrency import AVFoundation
import DiarizeCore
import Foundation

/// Basic facts from a canonical WAV header.
struct WAVInfo: Sendable, Equatable {
    var format: Int
    var channels: Int
    var sampleRate: Int
    var bitsPerSample: Int
    var dataBytes: Int

    var durationSec: Double {
        let frameBytes = channels * bitsPerSample / 8
        guard frameBytes > 0, sampleRate > 0 else { return 0 }
        return Double(dataBytes / frameBytes) / Double(sampleRate)
    }

    static func read(_ url: URL) -> WAVInfo? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 44), d.count == 44, d.prefix(4) == Data("RIFF".utf8), d[8..<12] == Data("WAVE".utf8) else { return nil }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        return WAVInfo(format: u16(20), channels: u16(22), sampleRate: u32(24), bitsPerSample: u16(34), dataBytes: u32(40))
    }
}

/// Multichannel: which input channel a transcript segment came from.
///
/// The mixdown is analysed (one segment per utterance); afterwards every segment is assigned the channel whose
/// microphone was loudest over the segment (RMS). With one microphone per person that is the person speaking.
enum ChannelAttribution {
    /// segment id (as string) -> 1-based channel. Channels whose audio is gone are skipped.
    static func dominantChannels(segments: [RecordingSegment], dir: URL, channels: [Sidecar.Channel]) -> [String: Int] {
        var energy: [Int64: [Int: Double]] = [:]
        for c in channels where c.audioDeletedAt == nil {
            guard let file = try? AVAudioFile(forReading: dir.appendingPathComponent(c.file)) else { continue }
            let rate = file.processingFormat.sampleRate
            for s in segments {
                guard let id = s.id else { continue }
                energy[id, default: [:]][c.channel] = rms(file: file, rate: rate, start: s.startSec, end: s.endSec)
            }
        }
        var result: [String: Int] = [:]
        for (id, perChannel) in energy {
            if let best = perChannel.max(by: { $0.value < $1.value }), best.value > 0 { result[String(id)] = best.key }
        }
        return result
    }

    static func rms(file: AVAudioFile, rate: Double, start: Double, end: Double) -> Double {
        let from = AVAudioFramePosition(max(0, start) * rate)
        let count = AVAudioFrameCount(max(0, end - start) * rate)
        guard count > 0, from < file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return 0 }
        file.framePosition = from
        guard (try? file.read(into: buffer, frameCount: count)) != nil, let data = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum = 0.0
        for i in 0..<n { let v = Double(data[0][i]); sum += v * v }
        return (sum / Double(n)).squareRoot()
    }
}
