import Foundation
import Hummingbird
import Testing
@testable import DiarizeServer

@Suite struct RoutingTests {
    @Test func healthReturnsServiceInfo() async throws {
        let r = try await send(.get, "/v1/health")
        #expect(r.status == 200)
        #expect(r.json["service"] as? String == "diarize")
        #expect(r.json["apiVersion"] as? Int == 1)
        #expect(r.json["version"] as? String == ServeConfig.defaultVersion)
        #expect(r.json["paired"] as? Bool == false)
        #expect(r.json["serverTime"] is String)
        #expect(r.header("Content-Type")?.hasPrefix("application/json") == true)
    }

    @Test func requestIDIsGeneratedAndEchoed() async throws {
        let generated = try await send(.get, "/v1/health")
        #expect((generated.header("X-Request-Id") ?? "").count >= 4)

        let echoed = try await send(.get, "/v1/health", headers: ["X-Request-Id": "my-id-42"])
        #expect(echoed.header("X-Request-Id") == "my-id-42")

        let tooLong = String(repeating: "a", count: 65)
        let replaced = try await send(.get, "/v1/health", headers: ["X-Request-Id": tooLong])
        #expect(replaced.header("X-Request-Id") != tooLong)
    }

    @Test func unknownRouteUsesErrorEnvelope() async throws {
        let r = try await send(.get, "/v1/nope", headers: ["Authorization": "Bearer dz_good"])
        #expect(r.status == 404)
        #expect(r.errorCode == "not_found")
        let requestId = (r.json["error"] as? [String: Any])?["requestId"] as? String
        #expect(requestId == r.header("X-Request-Id"))
    }

    @Test func pairIsPublicButNotImplementedYet() async throws {
        let r = try await send(.post, "/v1/pair", headers: ["Content-Type": "application/json"], body: "{}")
        #expect(r.status == 501)
        #expect(r.errorCode == "not_implemented")
    }

    @Test func capabilitiesNeedsTokenAndReturnsJSON() async throws {
        let ok = try await send(.get, "/v1/capabilities", headers: ["Authorization": "Bearer dz_good"])
        #expect(ok.status == 200)
        #expect(ok.json["apiVersion"] as? Int == 1)
        #expect((ok.json["languages"] as? [String])?.contains("de") == true)
    }

    @Test func oversizedBodyIsRejected() async throws {
        let r = try await send(
            .post, "/v1/pair",
            headers: ["Content-Type": "application/json"],
            body: "{\"pad\":\"" + String(repeating: "x", count: 70 * 1024) + "\"}"
        )
        #expect(r.status == 413)
        #expect(r.errorCode == "payload_too_large")
    }

    @Test func bindsLoopbackOnly() throws {
        #expect(ServeConfig.bindHost == "127.0.0.1")
        let app = DiarizeHTTPServer.makeApplication(config: try makeTestConfig())
        #expect(app.configuration.address == .hostname("127.0.0.1", port: testPort))
    }

    @Test func defaultPortAndEnvResolution() {
        #expect(ServeConfig.defaultPort == 47653)
        #expect(ServeConfig.resolvePort(flag: nil, environment: [:]) == 47653)
        #expect(ServeConfig.resolvePort(flag: nil, environment: ["DIARIZE_SERVE_PORT": "5000"]) == 5000)
        #expect(ServeConfig.resolvePort(flag: 1234, environment: ["DIARIZE_SERVE_PORT": "5000"]) == 1234)
        #expect(ServeConfig.resolveOrigins(flags: ["http://a.test"], environment: ["DIARIZE_SERVE_ORIGINS": "http://b.test, http://c.test"])
                == ["http://a.test", "http://b.test", "http://c.test"])
    }
}
