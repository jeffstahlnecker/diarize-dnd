import DiarizeCore
import Foundation
import Testing
@testable import DiarizeServer

@Suite struct MultichannelTests {
    let startBody = #"{"title":"Spielabend","micDeviceUID":"USB8","channelMap":[{"channel":1,"label":"Anna","key":"pc.anna"},{"channel":2,"label":"Ben","key":"pc.ben"},{"channel":3,"label":"GM","key":"gm"}],"captureQuality":"archive"}"#

    @Test func startWritesOneFilePerChannel() async throws {
        let s = try TestServer()
        let r = try await s.api(.post, "/v1/recordings", json: startBody)
        #expect(r.status == 201)
        let channels = try #require(r.json["channels"] as? [[String: Any]])
        #expect(channels.map { $0["channel"] as? Int } == [1, 2, 3])
        #expect(channels.map { $0["label"] as? String } == ["Anna", "Ben", "GM"])
        #expect(channels.map { $0["key"] as? String } == ["pc.anna", "pc.ben", "gm"])
        #expect(r.json["captureQuality"] as? String == "archive")

        let session = try #require(s.recorder.lastSession)
        #expect(session.request.micDeviceUID == "USB8")
        #expect(session.request.captureQuality == "archive")
        #expect(session.request.outputURL.lastPathComponent == "mix.wav")
        #expect(session.request.channels?.map(\.fileURL.lastPathComponent) == ["ch01.wav", "ch02.wav", "ch03.wav"])

        let id = r.json["id"] as! String
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        await s.controller.waitForAnalyses()
    }

    @Test func channelMapIsValidatedAgainstTheDevice() async throws {
        let s = try TestServer()
        let tooHigh = try await s.api(.post, "/v1/recordings", json: #"{"micDeviceUID":"USB8","channelMap":[{"channel":9,"label":"X"}]}"#)
        #expect(tooHigh.status == 422)
        let dup = try await s.api(.post, "/v1/recordings", json: #"{"micDeviceUID":"USB8","channelMap":[{"channel":1},{"channel":1}]}"#)
        #expect(dup.status == 422)
        let withSystem = try await s.api(.post, "/v1/recordings", json: #"{"micDeviceUID":"USB8","sources":["mic","system"],"channelMap":[{"channel":1}]}"#)
        #expect(withSystem.status == 422)
        let defaultDevice = try await s.api(.post, "/v1/recordings", json: #"{"channelMap":[{"channel":2}]}"#)
        #expect(defaultDevice.status == 422)   // default device has one channel
        let empty = try await s.api(.post, "/v1/recordings", json: #"{"micDeviceUID":"USB8","channelMap":[]}"#)
        #expect(empty.status == 422)
        let fields = (tooHigh.errorDetails?["fields"] as? [[String: Any]])?.first?["field"] as? String
        #expect(fields == "channelMap[0].channel")
    }

    @Test func perChannelAudioDelete() async throws {
        let s = try TestServer()
        let id = try await s.api(.post, "/v1/recordings", json: startBody).json["id"] as! String
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        await s.controller.waitForAnalyses()
        let dir = URL(fileURLWithPath: try s.store.recording(id: id)!.sourcePath).deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ch02.wav").path))

        let r = try await s.api(.delete, "/v1/recordings/\(id)/audio?channel=2")
        #expect(r.status == 200)
        let channels = try #require(r.json["channels"] as? [[String: Any]])
        #expect(channels.first { $0["channel"] as? Int == 2 }?["audioDeletedAt"] is String)
        #expect(channels.first { $0["channel"] as? Int == 1 }?["audioDeletedAt"] is NSNull)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("ch02.wav").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ch01.wav").path))
        #expect(r.json["hasAudio"] as? Bool == true)

        #expect(try await s.api(.delete, "/v1/recordings/\(id)/audio?channel=7").status == 422)

        let all = try await s.api(.delete, "/v1/recordings/\(id)/audio")
        #expect(all.json["hasAudio"] as? Bool == false)
        for f in ["ch01.wav", "ch03.wav", "mix.wav"] {
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path))
        }
        #expect(try await s.api(.delete, "/v1/recordings/\(id)?confirm=true").status == 200)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    // Mismatch 3: levels event shape.
    @Test func levelsEventInMultichannelMode() throws {
        let reading = LevelReading(mic: 0.8, system: nil, channels: [.init(channel: 1, level: 0.2), .init(channel: 3, level: 0.8)])
        let event = RecordingController.levelsEvent(id: "rec_1", t: 42, reading: reading)
        #expect(event["recordingId"] == "rec_1")
        #expect(event["t"] == 42)
        #expect(event["mic"] == 0.8)
        #expect(event["system"] == .null)
        #expect(event["channels"] == [["channel": 1, "level": 0.2], ["channel": 3, "level": 0.8]])

        let single = RecordingController.levelsEvent(id: "rec_1", t: 1, reading: LevelReading(mic: 0.5, system: nil, channels: nil))
        #expect(single["channels"] == .null)
        #expect(single["mic"] == 0.5)
    }

    @Test func channelAttributionPicksTheLoudestMicrophone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // ch01 loud in 0..1 s, ch02 loud in 1..2 s.
        func write(_ name: String, loudSecond: Int) throws {
            let w = try WAVWriter(url: dir.appendingPathComponent(name), sampleRate: 16000, channels: 1)
            for sec in 0..<2 {
                let amp: Float = sec == loudSecond ? 0.5 : 0.01
                try w.append(samples: (0..<16000).map { amp * sin(Float($0) * 0.1) })
            }
            try w.close()
        }
        try write("ch01.wav", loudSecond: 0)
        try write("ch02.wav", loudSecond: 1)
        var a = RecordingSegment(recordingId: "r", speakerId: nil, startSec: 0.1, endSec: 0.9, text: "a", confidence: nil)
        a.id = 10
        var b = RecordingSegment(recordingId: "r", speakerId: nil, startSec: 1.1, endSec: 1.9, text: "b", confidence: nil)
        b.id = 11
        let map = ChannelAttribution.dominantChannels(segments: [a, b], dir: dir, channels: [
            .init(channel: 1, label: "A", key: nil, file: "ch01.wav"), .init(channel: 2, label: "B", key: nil, file: "ch02.wav"),
        ])
        #expect(map == ["10": 1, "11": 2])
    }

    @Test func transcriptCarriesChannels() async throws {
        let s = try TestServer()
        let id = try await s.api(.post, "/v1/recordings", json: startBody).json["id"] as! String
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        await s.controller.waitForAnalyses()
        // The fake files are silent; attribute by hand as the analysis step would.
        let segs = try s.store.segments(for: id)
        try s.env.sidecars.update(id) { $0.segmentChannels = [String(segs[0].id!): 3, String(segs[1].id!): 1, String(segs[2].id!): 3] }
        let t = try await s.api(.get, "/v1/recordings/\(id)/transcript")
        let transcript = try #require(t.json["transcript"] as? [String: Any])
        let segments = try #require(transcript["segments"] as? [[String: Any]])
        #expect(segments.map { $0["channel"] as? Int } == [3, 1, 3])
        let speakers = try #require(transcript["speakers"] as? [[String: Any]])
        #expect(speakers.first { $0["id"] as? String == "spk_gm" }?["channel"] as? Int == 3)
    }
}
