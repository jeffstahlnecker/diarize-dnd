import DiarizeCore
import Foundation
import Testing
@testable import DiarizeServer

@Suite struct SpeakerTests {
    /// One analysed recording with spk_gm (2 segments) and spk_anna (1).
    func seeded() async throws -> TestServer {
        let s = try TestServer()
        let id = try await s.api(.post, "/v1/recordings", json: "{}").json["id"] as! String
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        await s.controller.waitForAnalyses()
        return s
    }

    @Test func listsSpeakersWithStats() async throws {
        let s = try await seeded()
        let r = try await s.api(.get, "/v1/speakers")
        #expect(r.status == 200)
        let speakers = try #require(r.json["speakers"] as? [[String: Any]])
        let gm = try #require(speakers.first { $0["id"] as? String == "spk_gm" })
        #expect(gm["segmentCount"] as? Int == 2)
        #expect(gm["speechSec"] as? Double == 4)
        #expect(gm["recordingCount"] as? Int == 1)
        #expect(gm["label"] is NSNull)
        #expect(gm["createdAt"] is String)
    }

    @Test func patchLabelAndNotes() async throws {
        let s = try await seeded()
        let r = try await s.api(.patch, "/v1/speakers/spk_gm", json: #"{"label":"Sam","notes":"links am Tisch"}"#)
        #expect(r.status == 200)
        #expect(r.json["label"] as? String == "Sam")
        #expect(r.json["notes"] as? String == "links am Tisch")
        #expect(try s.store.speaker(id: "spk_gm")?.label == "Sam")

        let t = try await s.api(.get, "/v1/recordings?limit=1")
        let id = ((t.json["recordings"] as? [[String: Any]])?.first?["id"] as? String)!
        let tr = try await s.api(.get, "/v1/recordings/\(id)/transcript")
        let segs = (tr.json["transcript"] as? [String: Any])?["segments"] as? [[String: Any]]
        #expect(segs?.first?["speakerLabel"] as? String == "Sam")

        let cleared = try await s.api(.patch, "/v1/speakers/spk_gm", json: #"{"label":null}"#)
        #expect(cleared.json["label"] is NSNull)
        #expect(cleared.json["notes"] as? String == "links am Tisch")
        #expect(try await s.api(.patch, "/v1/speakers/spk_gm", json: #"{"label":"\#(String(repeating: "x", count: 101))"}"#).status == 422)
        #expect(try await s.api(.patch, "/v1/speakers/spk_nope", json: #"{"label":"x"}"#).status == 404)
    }

    @Test func mergeMovesSegments() async throws {
        let s = try await seeded()
        let r = try await s.api(.post, "/v1/speakers/spk_anna/merge", json: #"{"into":"spk_gm"}"#)
        #expect(r.status == 200)
        #expect(r.json["id"] as? String == "spk_gm")
        #expect(r.json["segmentCount"] as? Int == 3)
        #expect(try s.store.speaker(id: "spk_anna") == nil)

        #expect(try await s.api(.post, "/v1/speakers/spk_gm/merge", json: #"{"into":"spk_gm"}"#).status == 422)
        #expect(try await s.api(.post, "/v1/speakers/spk_gm/merge", json: #"{"into":"spk_nope"}"#).status == 404)
        #expect(try await s.api(.post, "/v1/speakers/spk_nope/merge", json: #"{"into":"spk_gm"}"#).status == 404)
        #expect(try await s.api(.post, "/v1/speakers/spk_gm/merge", json: "{}").status == 422)
    }
}
