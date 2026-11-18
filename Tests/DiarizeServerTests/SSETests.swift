import Foundation
import Testing
@testable import DiarizeServer

@Suite struct SSETests {
    @Test func frameFormat() {
        let f = SSEFormatter.frame(ServerEvent("ready", ["recordingId": "rec_1", "state": "done", "segmentCount": 3]))
        #expect(f == "event: ready\ndata: {\"recordingId\":\"rec_1\",\"segmentCount\":3,\"state\":\"done\"}\n\n")
        #expect(SSEFormatter.ping == ": ping\n\n")
        // Text with newlines stays on one data line (JSON escapes it).
        let multi = SSEFormatter.frame(ServerEvent("x", ["t": "a\nb"]))
        #expect(multi.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.count == 1)
    }

    @Test func hubFansOutAndDeliversFirstFramesFirst() async throws {
        let hub = EventHub(pingInterval: .seconds(60))
        let a = hub.subscribe(first: [ServerEvent("snapshot", ["recording": .null])])
        let b = hub.subscribe()
        #expect(hub.subscriberCount == 2)
        hub.publish("state", ["n": 1])
        var ia = a.makeAsyncIterator()
        var ib = b.makeAsyncIterator()
        let a1 = await ia.next(), a2 = await ia.next(), b1 = await ib.next()
        #expect(a1?.hasPrefix("event: snapshot") == true)
        #expect(a2?.hasPrefix("event: state") == true)
        #expect(b1?.hasPrefix("event: state") == true)
        hub.finishAll()
        let end = await ia.next()
        #expect(end == nil)
        #expect(hub.subscriberCount == 0)
    }

    @Test func cancelledSubscriberIsRemoved() async throws {
        let hub = EventHub(pingInterval: .seconds(60))
        let task = Task {
            for await _ in hub.subscribe() {}
        }
        #expect(await waitUntil { hub.subscriberCount == 1 })
        task.cancel()
        #expect(await waitUntil { hub.subscriberCount == 0 })
    }

    @Test func heartbeat() async throws {
        let hub = EventHub(pingInterval: .milliseconds(10))
        var it = hub.subscribe().makeAsyncIterator()
        let first = await it.next()
        #expect(first == SSEFormatter.ping)
        hub.finishAll()
    }

    @Test func throttle() {
        var t = Throttle(intervalMs: 1000)
        let results = [0, 500, 1000, 1999].map { t.allow(atMs: Int64($0)) }
        #expect(results == [true, false, true, false])
    }

    /// The controller publishes state, levels, progress and ready during a recording's life.
    @Test func lifecycleEvents() async throws {
        let s = try TestServer()
        let stream = s.env.events.subscribe()
        let collector = Task { () -> [String] in
            var names: [String] = []
            for await frame in stream {
                guard let line = frame.split(separator: "\n").first, line.hasPrefix("event: ") else { continue }
                names.append(String(line.dropFirst(7)))
                if names.last == "ready" { break }
            }
            return names
        }
        let id = try await s.api(.post, "/v1/recordings", json: "{}").json["id"] as! String
        try await Task.sleep(for: .milliseconds(80))   // a few level ticks at 20 ms
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        await s.controller.waitForAnalyses()
        let names = await collector.value
        #expect(names.first == "state")
        #expect(names.contains("levels"))
        #expect(names.contains("progress"))
        #expect(names.last == "ready")
        #expect(names.filter { $0 == "state" }.count >= 3)   // recording, analyzing, done
    }

    @Test func errorEventOnFailedAnalysis() async throws {
        let s = try TestServer()
        s.analysis.mode = .fail
        let stream = s.env.events.subscribe()
        let collector = Task { () -> String? in
            for await frame in stream where frame.hasPrefix("event: error") { return frame }
            return nil
        }
        let id = try await s.api(.post, "/v1/recordings", json: "{}").json["id"] as! String
        _ = try await s.api(.post, "/v1/recordings/\(id)/stop")
        await s.controller.waitForAnalyses()
        let frame = await collector.value
        #expect(frame?.contains("\"recordingId\":\"\(id)\"") == true)
        #expect(frame?.contains("fake failure") == true)
    }

    /// The real route: the first frame is the snapshot (serverTime ISO + serverTimeMs).
    @Test func eventsRouteStartsWithSnapshot() async throws {
        let s = try TestServer()
        let stream = s.env.events.subscribe(first: [])
        _ = stream
        let snapshotRecording = try await s.controller.current()
        #expect(snapshotRecording == .null)
        // Route-level check: headers and the first bytes (the in-memory client ends the stream after finishAll()).
        let reader = Task { try await s.api(.get, "/v1/events") }
        #expect(await waitUntil { s.env.events.subscriberCount >= 2 })
        s.env.events.finishAll()
        let r = try await reader.value
        #expect(r.status == 200)
        #expect(r.header("Content-Type")?.hasPrefix("text/event-stream") == true)
        #expect(r.body.hasPrefix("event: snapshot\ndata: {"))
        #expect(r.body.contains("\"serverTimeMs\":"))
        #expect(r.body.contains("\"serverTime\":\"20"))
    }
}
