import DiarizeCore
import Foundation
import Testing
@testable import DiarizeServer

@Suite struct UploadTests {
    func wav(seconds: Double) -> [UInt8] {
        let frames = Int(seconds * 16000)
        var d = WAVHeader.make(format: 3, channels: 1, sampleRate: 16000, bitsPerSample: 32, dataBytes: UInt32(frames * 4))
        d.append(Data(count: frames * 4))
        return [UInt8](d)
    }

    @Test func uploadIsStoredAndAnalysed() async throws {
        let s = try TestServer()
        let r = try await s.send(.post, "/v1/transcriptions?title=Aufnahme&language=de&clientRef=up1&startedAt=1763150000000",
                                 headers: ["Authorization": "Bearer dz_good", "Content-Type": "audio/wav"], bytes: wav(seconds: 2))
        #expect(r.status == 202)
        #expect(r.json["state"] as? String == "analyzing")
        #expect(r.json["title"] as? String == "Aufnahme")
        #expect(r.json["clientRef"] as? String == "up1")
        #expect(r.json["durationSec"] as? Double == 2)
        let clock = try #require(r.json["clock"] as? [String: Any])
        #expect(clock["audioStartedAtSource"] as? String == "client")
        #expect(clock["audioStartedAtMs"] as? Int64 == 1_763_150_000_000)
        let id = r.json["id"] as! String
        let path = try s.store.recording(id: id)!.sourcePath
        #expect(path.hasPrefix(s.env.appConfig.recordingsDir.path))
        #expect(path.hasSuffix(".wav"))
        await s.controller.waitForAnalyses()
        #expect(try s.store.recording(id: id)?.processingState == .done)
    }

    @Test func notAudioIs415() async throws {
        let s = try TestServer()
        let junk = try await s.send(.post, "/v1/transcriptions", headers: ["Authorization": "Bearer dz_good", "Content-Type": "application/octet-stream"],
                                    bytes: [UInt8]("hello world, not audio".utf8))
        #expect(junk.status == 415)
        let type = try await s.send(.post, "/v1/transcriptions", headers: ["Authorization": "Bearer dz_good", "Content-Type": "text/plain"], bytes: wav(seconds: 1))
        #expect(type.status == 415)
        let files = try FileManager.default.contentsOfDirectory(atPath: s.env.appConfig.recordingsDir.path)
        #expect(files.isEmpty)
    }

    @Test func tooLargeIs413() async throws {
        let s = try TestServer(maxUploadBytes: 64 * 1024)
        let r = try await s.send(.post, "/v1/transcriptions", headers: ["Authorization": "Bearer dz_good", "Content-Type": "audio/wav"], bytes: wav(seconds: 2))
        #expect(r.status == 413)
        #expect(r.errorCode == "payload_too_large")
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.env.appConfig.recordingsDir.path).isEmpty)
    }

    @Test func uploadsAreExemptFromTheJSONLimit() async throws {
        let s = try TestServer()   // 1 MiB upload cap, 64 KiB JSON cap
        let r = try await s.send(.post, "/v1/transcriptions", headers: ["Authorization": "Bearer dz_good", "Content-Type": "audio/x-wav"], bytes: wav(seconds: 4))
        #expect(r.status == 202)
        await s.controller.waitForAnalyses()
    }

    @Test func uploadNeedsAToken() async throws {
        let s = try TestServer()
        #expect(try await s.send(.post, "/v1/transcriptions", headers: ["Content-Type": "audio/wav"], bytes: wav(seconds: 1)).status == 401)
    }

    @Test func sniffing() {
        #expect(Upload.sniff(Array("RIFF\0\0\0\0WAVE".utf8)) == .wav)
        #expect(Upload.sniff(Array("ID3\u{3}".utf8)) == .mp3)
        #expect(Upload.sniff([0xFF, 0xFB, 0x90, 0x00]) == .mp3)
        #expect(Upload.sniff([0, 0, 0, 0x20] + Array("ftypM4A ".utf8)) == .m4a)
        #expect(Upload.sniff(Array("<html>".utf8)) == nil)
    }
}

@Suite struct ClockAndStorageTests {
    @Test func isoFormatHasMilliseconds() {
        let d = Date(timeIntervalSince1970: 1_731_610_801.214)
        #expect(ISOTime.string(d) == "2024-11-14T19:00:01.214Z")
        #expect(ISOTime.parse("2024-11-14T19:00:01.214Z").map(WallClock.ms) == 1_731_610_801_214)
        #expect(ISOTime.parse("2024-11-14T19:00:01Z").map(WallClock.ms) == 1_731_610_801_000)
        #expect(ISOTime.parseFlexible("1731610801214").map(WallClock.ms) == 1_731_610_801_214)
    }

    @Test func sidecarRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SidecarStore(archivePath: dir)
        #expect(store.read("rec_1") == nil)
        var s = Sidecar(recordingId: "rec_1", clientRef: "x", clientMeta: ["consent": ["recording": true]])
        s.clock = .init(audioStartedAtMs: 1000, source: "recorder", imprecise: false, syncPoints: [.init(wallMs: 1000, audioSec: 0)])
        try store.write(s)
        #expect(store.read("rec_1") == s)
        try store.update("rec_1") { $0.clock?.syncPoints.append(.init(wallMs: 31000, audioSec: 30.0)) }
        #expect(store.read("rec_1")?.clock?.syncPoints.count == 2)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
        store.delete("rec_1")
        #expect(store.read("rec_1") == nil)
        let id = store.instanceId()
        #expect(store.instanceId() == id)
    }

    @Test func foreignRecordingFallsBackToCreatedAt() async throws {
        let s = try TestServer()
        let created = Date(timeIntervalSince1970: 1_731_610_800)
        try s.store.insertEmptyRecording(Recording(id: "rec_app", title: "App", sourcePath: "/nonexistent.wav", durationSec: 60, language: "de",
                                                   transcriptMd: "/x.md", transcriptJson: "/x.json", createdAt: created, processingState: .done))
        let r = try await s.api(.get, "/v1/recordings/rec_app")
        let clock = try #require(r.json["clock"] as? [String: Any])
        #expect(clock["audioStartedAtSource"] as? String == "createdAt")
        #expect(clock["audioStartedAtMs"] as? Int64 == 1_731_610_800_000)
        #expect((clock["syncPoints"] as? [Any])?.isEmpty == true)
        #expect(r.json["clientRef"] is NSNull)
        #expect(r.json["sources"] as? [String] == ["mic"])
    }

    @Test func wavRepairPatchesSizes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rep-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var d = WAVHeader.make(format: 3, channels: 2, sampleRate: 16000, bitsPerSample: 32, dataBytes: 0)
        d.append(Data(count: 16000 * 8 + 3))   // 1 s stereo float plus a torn partial frame
        try d.write(to: url)
        #expect(WAVInfo.read(url)?.dataBytes == 0)
        #expect(WAVHeader.repair(url: url).map(Int.init) == 128_000)
        let info = try #require(WAVInfo.read(url))
        #expect(info.channels == 2)
        #expect(info.durationSec == 1)
        // Readable by the archive's own loader.
        let loaded = try AudioLoader.load(url: url)
        #expect(abs(loaded.durationSec - 1) < 0.01)
    }

    @Test func progressEstimate() {
        #expect(ProgressEstimate.fraction(for: "Loading audio …") == 0.05)
        #expect(ProgressEstimate.fraction(for: "Transcribing 412 segments …") == 0.5)
        #expect(ProgressEstimate.fraction(for: "something else") == nil)
    }
}
