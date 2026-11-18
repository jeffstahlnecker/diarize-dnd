import DiarizeCore
import Foundation
import Testing
@testable import DiarizeServer

@Suite struct RecordingLifecycleTests {
    func start(_ s: TestServer, _ json: String = #"{"title":"Sitzung 3","language":"de","clientRef":"cockpit#s3"}"#) async throws -> Reply {
        try await s.api(.post, "/v1/recordings", json: json, origin: cockpitOrigin)
    }

    func rec(_ r: Reply) -> [String: Any] { r.json }
    func clock(_ r: [String: Any]) -> [String: Any] { r["clock"] as? [String: Any] ?? [:] }

    @Test func startReturnsRecordingWithMeasuredClock() async throws {
        let s = try TestServer()
        s.recorder.framesOnStart = 1600   // 100 ms of audio already captured when first polled
        let before = s.clock.now
        let r = try await start(s)
        #expect(r.status == 201)
        let body = rec(r)
        #expect(body["state"] as? String == "recording")
        #expect(body["title"] as? String == "Sitzung 3")
        #expect(body["clientRef"] as? String == "cockpit#s3")
        #expect(body["transcribe"] as? String == "onStop")
        #expect(body["hasAudio"] as? Bool == true)
        #expect(body["deleteAudioWhenDone"] as? Bool == false)
        #expect(body["channels"] is NSNull)
        let c = clock(body)
        #expect(c["audioStartedAtSource"] as? String == "recorder")
        #expect(c["audioStartedAtMs"] as? Int64 == WallClock.ms(before) - 100)
        #expect((c["audioStartedAt"] as? String).flatMap(ISOTime.parse).map(WallClock.ms) == WallClock.ms(before) - 100)
        let points = try #require(c["syncPoints"] as? [[String: Any]])
        #expect(points.count == 1)
        #expect(points.first?["audioSec"] as? Double == 0)

        let id = try #require(body["id"] as? String)
        #expect(try s.store.recording(id: id)?.processingState == .recording)
        #expect(s.logLines.withLockedValue { $0 }.contains { $0.contains("\(id) started by \"") || $0.contains("\(id) started") })
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        await s.controller.waitForAnalyses()
    }

    @Test func impreciseClockWhenNoSamplesArrive() async throws {
        let s = try TestServer()
        s.recorder.framesOnStart = 0
        let r = try await start(s)
        #expect(r.status == 201)
        #expect(clock(rec(r))["audioStartedAtMs"] as? Int64 == WallClock.ms(s.clock.now))
        let id = rec(r)["id"] as! String
        #expect(s.env.sidecars.read(id)?.clock?.imprecise == true)
        // Stopping with zero samples fails with the permission explanation.
        let stop = try await s.api(.post, "/v1/recordings/\(id)/stop")
        #expect(stop.status == 202)
        #expect(rec(stop)["state"] as? String == "failed")
        #expect((rec(stop)["errorMessage"] as? String)?.contains("Microphone") == true)
    }

    // 13 / mismatch 5
    @Test func secondStartConflictsWithRecordingId() async throws {
        let s = try TestServer()
        let first = rec(try await start(s))
        let r = try await start(s)
        #expect(r.status == 409)
        #expect(r.errorCode == "conflict_recording_active")
        #expect(r.errorDetails?["recordingId"] as? String == first["id"] as? String)
        _ = try await s.api(.post, "/v1/recordings/\(first["id"]!)/stop")
        await s.controller.waitForAnalyses()
    }

    @Test func recordingInAnotherProcessConflictsAndCannotBeStoppedHere() async throws {
        let s = try TestServer()
        let foreign = try s.insertForeignRecording(fileAge: 0)   // file still being written
        let r = try await start(s)
        #expect(r.status == 409)
        #expect(r.errorDetails?["recordingId"] as? String == foreign)

        let caps = try await s.api(.get, "/v1/capabilities")
        #expect((caps.json["recording"] as? [String: Any])?["id"] as? String == foreign)
        #expect((caps.json["orphans"] as? [Any])?.isEmpty == true)

        let stop = try await s.api(.post, "/v1/recordings/\(foreign)/stop")
        #expect(stop.status == 409)
        #expect(stop.errorCode == "wrong_state")
        #expect(stop.errorDetails?["reason"] as? String == "recording_in_other_process")
    }

    // Mismatch 6
    @Test func orphanCanBeStoppedAndIsAnalysed() async throws {
        let s = try TestServer()
        let orphan = try s.insertForeignRecording(fileAge: 3600)
        let caps = try await s.api(.get, "/v1/capabilities")
        #expect(caps.json["recording"] is NSNull)
        let orphans = try #require(caps.json["orphans"] as? [[String: Any]])
        #expect(orphans.map { $0["id"] as? String } == [orphan])

        let stop = try await s.api(.post, "/v1/recordings/\(orphan)/stop")
        #expect(stop.status == 202)
        #expect(rec(stop)["state"] as? String == "analyzing")
        #expect(rec(stop)["durationSec"] as? Double == 1.0)   // header repaired from the file length
        let info = try #require(WAVInfo.read(URL(fileURLWithPath: try s.store.recording(id: orphan)!.sourcePath)))
        #expect(info.dataBytes == 16000 * 4)
        await s.controller.waitForAnalyses()
        #expect(try s.store.recording(id: orphan)?.processingState == .done)
        #expect(s.analysis.runs == [orphan])
    }

    @Test func orphanWithoutAudioFails() async throws {
        let s = try TestServer()
        let orphan = try s.insertForeignRecording(fileAge: nil)
        let stop = try await s.api(.post, "/v1/recordings/\(orphan)/stop")
        #expect(stop.status == 202)
        #expect(rec(stop)["state"] as? String == "failed")
    }

    @Test func stopAnalysesAndTranscriptHasSegmentIds() async throws {
        let s = try TestServer()
        let id = rec(try await start(s))["id"] as! String
        s.recorder.lastSession?.addFrames(16000 * 8)
        s.clock.advance(8)
        let stop = try await s.api(.post, "/v1/recordings/\(id)/stop")
        #expect(stop.status == 202)
        #expect(rec(stop)["state"] as? String == "analyzing")
        #expect(rec(stop)["stoppedAt"] is String)
        #expect(s.recorder.lastSession?.stopped == true)
        await s.controller.waitForAnalyses()

        let t = try await s.api(.get, "/v1/recordings/\(id)/transcript")
        #expect(t.status == 200)
        let transcript = try #require(t.json["transcript"] as? [String: Any])
        let segments = try #require(transcript["segments"] as? [[String: Any]])
        #expect(segments.count == 3)
        #expect(segments.allSatisfy { $0["id"] is Int })
        #expect(segments.first?["speakerId"] as? String == "spk_gm")
        #expect(segments.first?["channel"] is NSNull)
        #expect(segments.first?["bleed"] as? Bool == false)
        let speakers = try #require(transcript["speakers"] as? [[String: Any]])
        #expect(speakers.first { $0["id"] as? String == "spk_gm" }?["segmentCount"] as? Int == 2)
        #expect(transcript["durationSec"] as? Double == 8.1)   // 0.1 s at start + 8 s
        let recording = try #require(t.json["recording"] as? [String: Any])
        #expect(recording["state"] as? String == "done")
        let points = try #require(clock(recording)["syncPoints"] as? [[String: Any]])
        #expect(points.count >= 2)   // start point and the final point at stop
    }

    @Test func transcriptWhileAnalyzingIsNotReady() async throws {
        let s = try TestServer()
        let gate = Gate()
        s.analysis.gate = gate
        let id = rec(try await start(s))["id"] as! String
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        let r = try await s.api(.get, "/v1/recordings/\(id)/transcript")
        #expect(r.status == 409)
        #expect(r.errorCode == "not_ready")
        let busy = try await s.api(.delete, "/v1/recordings/\(id)/audio")
        #expect(busy.status == 409)
        let got = try await s.api(.get, "/v1/recordings/\(id)")
        #expect(rec(got)["state"] as? String == "analyzing")
        #expect((rec(got)["progress"] as? [String: Any])?["step"] is String)
        gate.open()
        await s.controller.waitForAnalyses()
        #expect(try await s.api(.get, "/v1/recordings/\(id)/transcript").status == 200)
    }

    @Test func manualTranscription() async throws {
        let s = try TestServer()
        let id = rec(try await start(s, #"{"transcribe":"manual"}"#))["id"] as! String
        let stop = try await s.api(.post, "/v1/recordings/\(id)/stop")
        #expect(rec(stop)["state"] as? String == "stopped")
        #expect(rec(stop)["errorMessage"] is NSNull)
        #expect(s.analysis.runs.isEmpty)
        let again = try await s.api(.post, "/v1/recordings/\(id)/stop")
        #expect(again.status == 409)
        #expect(again.errorCode == "wrong_state")

        let t = try await s.api(.post, "/v1/recordings/\(id)/transcribe")
        #expect(t.status == 202)
        #expect(rec(t)["state"] as? String == "analyzing")
        await s.controller.waitForAnalyses()
        #expect(rec(try await s.api(.get, "/v1/recordings/\(id)"))["state"] as? String == "done")
        #expect(try await s.api(.post, "/v1/recordings/\(id)/transcribe").status == 409)
    }

    @Test func transcribeNeedsAudio() async throws {
        let s = try TestServer()
        let id = rec(try await start(s, #"{"transcribe":"manual"}"#))["id"] as! String
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        #expect(try await s.api(.delete, "/v1/recordings/\(id)/audio").status == 200)
        let t = try await s.api(.post, "/v1/recordings/\(id)/transcribe")
        #expect(t.status == 409)
        #expect(t.errorDetails?["reason"] as? String == "audio_deleted")
    }

    @Test func captureFailureCleansUp() async throws {
        let s = try TestServer()
        s.recorder.failStart = true
        let r = try await start(s)
        #expect(r.status == 422)
        #expect(r.errorCode == "capture_failed")
        #expect((r.errorDetails?["hint"] as? String)?.contains("Privacy & Security > Microphone") == true)
        #expect(try s.store.allRecordings().isEmpty)
        s.recorder.failStart = false
        #expect(try await start(s).status == 201)
    }

    @Test func analysisFailureIsReported() async throws {
        let s = try TestServer()
        s.analysis.mode = .fail
        let id = rec(try await start(s))["id"] as! String
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        await s.controller.waitForAnalyses()
        let got = rec(try await s.api(.get, "/v1/recordings/\(id)"))
        #expect(got["state"] as? String == "failed")
        #expect(got["errorMessage"] as? String == "fake failure")
        // Retry is allowed from failed.
        s.analysis.mode = .empty
        #expect(try await s.api(.post, "/v1/recordings/\(id)/transcribe").status == 202)
        await s.controller.waitForAnalyses()
        let t = try await s.api(.get, "/v1/recordings/\(id)/transcript")
        #expect(t.status == 200)
        #expect(((t.json["transcript"] as? [String: Any])?["segments"] as? [Any])?.isEmpty == true)
        #expect((t.json["recording"] as? [String: Any])?["state"] as? String == "empty")
    }

    @Test func deleteAudioWhenDone() async throws {
        let s = try TestServer()
        let id = rec(try await start(s, #"{"deleteAudioWhenDone":true}"#))["id"] as! String
        let path = try s.store.recording(id: id)!.sourcePath
        #expect(FileManager.default.fileExists(atPath: path))
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        await s.controller.waitForAnalyses()
        let got = rec(try await s.api(.get, "/v1/recordings/\(id)"))
        #expect(got["hasAudio"] as? Bool == false)
        #expect(got["audioDeletedAt"] is String)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func audioIsKeptByDefault() async throws {
        let s = try TestServer()
        let id = rec(try await start(s))["id"] as! String
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        await s.controller.waitForAnalyses()
        let path = try s.store.recording(id: id)!.sourcePath
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(rec(try await s.api(.get, "/v1/recordings/\(id)"))["hasAudio"] as? Bool == true)

        let del = try await s.api(.delete, "/v1/recordings/\(id)/audio")
        #expect(del.status == 200)
        #expect(rec(del)["hasAudio"] as? Bool == false)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try await s.api(.delete, "/v1/recordings/\(id)/audio").status == 200)   // idempotent
        // Transcript survives.
        #expect(try await s.api(.get, "/v1/recordings/\(id)/transcript").status == 200)
    }

    @Test func maxDurationStopsTheRecording() async throws {
        let s = try TestServer(maxDurationSec: 0.05)
        let id = rec(try await start(s))["id"] as! String
        let stopped = try await waitUntil { try s.store.recording(id: id)?.processingState != .recording }
        #expect(stopped)
        await s.controller.waitForAnalyses()
        #expect(s.logLines.withLockedValue { $0 }.contains { $0.contains("maximum duration") })
    }

    @Test func validationErrorsListFields() async throws {
        let s = try TestServer()
        let r = try await start(s, #"{"title":"","language":"fr","sources":["camera"],"transcribe":"later","clientMeta":[1]}"#)
        #expect(r.status == 422)
        #expect(r.errorCode == "validation_failed")
        let fields = (r.errorDetails?["fields"] as? [[String: Any]])?.compactMap { $0["field"] as? String } ?? []
        #expect(Set(fields) == ["title", "language", "sources", "transcribe", "clientMeta"])
        let big = String(repeating: "x", count: 5000)
        let meta = try await start(s, #"{"clientMeta":{"a":"\#(big)"}}"#)
        #expect(meta.status == 422)
    }

    @Test func malformedJSONIsBadRequest() async throws {
        let s = try TestServer()
        #expect(try await start(s, "{nope").status == 400)
        let wrongType = try await s.send(.post, "/v1/recordings", headers: ["Authorization": "Bearer dz_good", "Content-Type": "text/plain"], body: "{}")
        #expect(wrongType.status == 400)
    }

    // 15
    @Test func oversizedStartBodyIs413() async throws {
        let s = try TestServer()
        let r = try await start(s, #"{"title":""# + String(repeating: "x", count: 70 * 1024) + #""}"#)
        #expect(r.status == 413)
        #expect(r.errorCode == "payload_too_large")
    }

    @Test func lowDiskIs507() async throws {
        let s = try TestServer(freeBytes: 1024 * 1024 * 1024)
        let r = try await start(s)
        #expect(r.status == 507)
        #expect(r.errorCode == "insufficient_storage")
        #expect(r.errorDetails?["freeBytes"] as? Int == 1024 * 1024 * 1024)
    }

    @Test func missingModelsIs503UnlessManual() async throws {
        let s = try TestServer()
        s.analysis.models = false
        #expect(try await start(s).errorCode == "models_unavailable")
        let manual = try await start(s, #"{"transcribe":"manual"}"#)
        #expect(manual.status == 201)
        _ = try await s.api(.post, "/v1/recordings/\(manual.json["id"]!)/stop")
    }

    // Mismatch 4: list items carry no syncPoints; one recording and the transcript do.
    @Test func listFiltersAndOmitsSyncPoints() async throws {
        let s = try TestServer()
        for ref in ["a", "b", "a"] {
            let id = rec(try await start(s, #"{"clientRef":"\#(ref)","transcribe":"manual"}"#))["id"] as! String
            _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
            s.clock.advance(1)
        }
        let all = try await s.api(.get, "/v1/recordings")
        let items = try #require(all.json["recordings"] as? [[String: Any]])
        #expect(items.count == 3)
        #expect(items.allSatisfy { clock($0)["syncPoints"] == nil })
        #expect(items.allSatisfy { clock($0)["audioStartedAtMs"] is Int64 })

        let a = try await s.api(.get, "/v1/recordings?clientRef=a")
        #expect((a.json["recordings"] as? [Any])?.count == 2)
        let stopped = try await s.api(.get, "/v1/recordings?state=stopped&limit=2")
        #expect((stopped.json["recordings"] as? [Any])?.count == 2)
        let next = try #require(stopped.json["nextBefore"] as? String)
        let rest = try await s.api(.get, "/v1/recordings?before=\(next)")
        #expect((rest.json["recordings"] as? [Any])?.count == 1)
        #expect(rest.json["nextBefore"] is NSNull)
        #expect(try await s.api(.get, "/v1/recordings?limit=0").status == 422)

        let one = rec(try await s.api(.get, "/v1/recordings/\(items[0]["id"]!)"))
        #expect(clock(one)["syncPoints"] is [Any])
    }

    @Test func syncPointsAreSampledWhileRecording() async throws {
        let s = try TestServer()   // fast timing: every 40 ms
        let id = rec(try await start(s))["id"] as! String
        for _ in 0..<5 {
            s.recorder.lastSession?.addFrames(16000)
            s.clock.advance(1)
            try await Task.sleep(for: .milliseconds(45))
        }
        let points = s.env.sidecars.read(id)?.clock?.syncPoints ?? []
        #expect(points.count >= 3)
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.wallMs <= $1.wallMs && $0.audioSec <= $1.audioSec })
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        await s.controller.waitForAnalyses()
    }

    @Test func patchTitleAndClientMeta() async throws {
        let s = try TestServer()
        let id = rec(try await start(s, #"{"clientMeta":{"consent":{"recording":true}}}"#))["id"] as! String
        let r = try await s.api(.patch, "/v1/recordings/\(id)", json: #"{"title":"Neu","clientMeta":{"consent":{"recording":true,"derivative":["pc.anna"]}}}"#)
        #expect(r.status == 200)
        #expect(rec(r)["title"] as? String == "Neu")
        let consent = (rec(r)["clientMeta"] as? [String: Any])?["consent"] as? [String: Any]
        #expect(consent?["derivative"] as? [String] == ["pc.anna"])
        #expect(try s.store.recording(id: id)?.title == "Neu")
        let cleared = try await s.api(.patch, "/v1/recordings/\(id)", json: #"{"clientMeta":null}"#)
        #expect(rec(cleared)["clientMeta"] is NSNull)
        #expect(try await s.api(.patch, "/v1/recordings/\(id)", json: #"{"title":""}"#).status == 422)
        #expect(try await s.api(.patch, "/v1/recordings/rec_nope", json: #"{"title":"x"}"#).status == 404)
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        await s.controller.waitForAnalyses()
    }

    @Test func deleteRecordingNeedsConfirmAndRemovesEverything() async throws {
        let s = try TestServer()
        let id = rec(try await start(s))["id"] as! String
        #expect(try await s.api(.delete, "/v1/recordings/\(id)?confirm=true").status == 409)   // still recording
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        await s.controller.waitForAnalyses()
        let path = try s.store.recording(id: id)!.sourcePath
        #expect(try await s.api(.delete, "/v1/recordings/\(id)").status == 422)
        let r = try await s.api(.delete, "/v1/recordings/\(id)?confirm=true")
        #expect(r.status == 200)
        #expect(try s.store.recording(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(s.env.sidecars.read(id) == nil)
        #expect(try await s.api(.get, "/v1/recordings/\(id)").status == 404)
    }

    @Test func unknownRecordingIs404() async throws {
        let s = try TestServer()
        for (m, p) in [(HTTPMethodBox.get, "/v1/recordings/rec_x"), (.post, "/v1/recordings/rec_x/stop"), (.get, "/v1/recordings/rec_x/transcript")] {
            #expect(try await s.api(m.method, p).status == 404)
        }
    }

    @Test func recordingsAreOrdinaryArchiveRows() async throws {
        let s = try TestServer()
        let id = rec(try await start(s))["id"] as! String
        let row = try #require(try s.store.recording(id: id))
        #expect(row.sourcePath.hasPrefix(s.env.appConfig.recordingsDir.path))
        #expect(row.language == "de")
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        await s.controller.waitForAnalyses()
    }
}

import HTTPTypes
enum HTTPMethodBox {
    case get, post
    var method: HTTPRequest.Method { self == .get ? .get : .post }
}
