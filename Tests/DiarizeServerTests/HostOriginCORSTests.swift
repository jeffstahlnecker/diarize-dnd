import Foundation
import Testing
@testable import DiarizeServer

/// Conformance rows 1-10 of docs/http-api.md.
@Suite struct HostOriginCORSTests {
    // 1
    @Test func healthWithOkHostAndNoOrigin() async throws {
        let r = try await send(.get, "/v1/health")
        #expect(r.status == 200)
        #expect(r.header("Access-Control-Allow-Origin") == nil)
    }

    @Test func localhostHostIsAccepted() async throws {
        let r = try await send(.get, "/v1/health", host: "localhost:\(testPort)")
        #expect(r.status == 200)
    }

    // 2
    @Test(arguments: ["evil.test", "evil.test:47653", "127.0.0.1", "127.0.0.1:1", "localhost", "127.0.0.1.evil.test:47653"])
    func badHostIsRejected(host: String) async throws {
        let r = try await send(.get, "/v1/health", host: host)
        #expect(r.status == 403)
        #expect(r.errorCode == "invalid_host")
    }

    @Test func missingHostIsRejected() async throws {
        let r = try await send(.get, "/v1/health", host: nil)
        #expect(r.status == 403)
        #expect(r.errorCode == "invalid_host")
    }

    // 3
    @Test func allowedOriginGetsCORSHeaders() async throws {
        let r = try await send(.get, "/v1/health", headers: ["Origin": cockpitOrigin])
        #expect(r.status == 200)
        #expect(r.header("Access-Control-Allow-Origin") == cockpitOrigin)
        #expect(r.header("Vary") == "Origin")
        #expect(r.header("Access-Control-Allow-Credentials") == nil)
        #expect(r.header("Access-Control-Expose-Headers")?.contains("X-Request-Id") == true)
    }

    // 4
    @Test func unknownOriginIsForbiddenWithoutCORSHeaders() async throws {
        let r = try await send(.get, "/v1/health", headers: ["Origin": "https://evil.test"])
        #expect(r.status == 403)
        #expect(r.errorCode == "forbidden_origin")
        #expect(r.header("Access-Control-Allow-Origin") == nil)
        #expect(r.header("Access-Control-Allow-Private-Network") == nil)
    }

    @Test func originMatchIsExact() async throws {
        for origin in ["http://localhost:4173/", "http://localhost", "https://localhost:4173", "http://localhost:41730", "HTTP://LOCALHOST:4173"] {
            let r = try await send(.get, "/v1/health", headers: ["Origin": origin])
            #expect(r.status == 403, "origin \(origin) must not match")
        }
    }

    @Test func noConfiguredOriginsMeansAnyOriginIsRejected() async throws {
        let r = try await send(.get, "/v1/health", headers: ["Origin": cockpitOrigin], origins: [])
        #expect(r.status == 403)
        let noOrigin = try await send(.get, "/v1/health", origins: [])
        #expect(noOrigin.status == 200)
    }

    // 5
    @Test func nullOriginIsRejected() async throws {
        let r = try await send(.get, "/v1/health", headers: ["Origin": "null"])
        #expect(r.status == 403)
        #expect(r.errorCode == "forbidden_origin")
        #expect(r.header("Access-Control-Allow-Origin") == nil)
    }

    // 6
    @Test func preflightFromAllowedOrigin() async throws {
        let r = try await send(.options, "/v1/recordings", headers: [
            "Origin": cockpitOrigin,
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "authorization, content-type",
        ])
        #expect(r.status == 204)
        #expect(r.header("Access-Control-Allow-Origin") == cockpitOrigin)
        #expect(r.header("Access-Control-Allow-Methods") == "GET, POST, PATCH, DELETE, OPTIONS")
        #expect(r.header("Access-Control-Allow-Headers") == "Authorization, Content-Type, X-Request-Id")
        #expect(r.header("Access-Control-Max-Age") == "600")
        #expect(r.header("Vary") == "Origin, Access-Control-Request-Private-Network")
        #expect(r.header("Access-Control-Allow-Private-Network") == nil)
        #expect(r.header("Access-Control-Allow-Credentials") == nil)
    }

    // 7
    @Test func preflightWithPrivateNetworkRequest() async throws {
        let r = try await send(.options, "/v1/recordings", headers: [
            "Origin": cockpitOrigin,
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Private-Network": "true",
        ])
        #expect(r.status == 204)
        #expect(r.header("Access-Control-Allow-Private-Network") == "true")
    }

    // 8
    @Test func preflightFromUnknownOriginIsForbidden() async throws {
        let r = try await send(.options, "/v1/recordings", headers: [
            "Origin": "https://evil.test",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Private-Network": "true",
        ])
        #expect(r.status == 403)
        #expect(r.header("Access-Control-Allow-Origin") == nil)
        #expect(r.header("Access-Control-Allow-Private-Network") == nil)
    }

    @Test func preflightDoesNotNeedAToken() async throws {
        let r = try await send(.options, "/v1/capabilities", headers: [
            "Origin": cockpitOrigin, "Access-Control-Request-Method": "GET",
        ])
        #expect(r.status == 204)
    }

    @Test func preflightStillChecksHost() async throws {
        let r = try await send(.options, "/v1/capabilities", headers: [
            "Origin": cockpitOrigin, "Access-Control-Request-Method": "GET",
        ], host: "evil.test")
        #expect(r.status == 403)
        #expect(r.errorCode == "invalid_host")
    }

    @Test func errorResponsesToAllowedOriginsCarryCORSHeaders() async throws {
        let r = try await send(.get, "/v1/capabilities", headers: ["Origin": cockpitOrigin])
        #expect(r.status == 401)
        #expect(r.header("Access-Control-Allow-Origin") == cockpitOrigin)
    }

    @Test func wildcardIsNeverEmitted() async throws {
        let replies = [
            try await send(.get, "/v1/health", headers: ["Origin": cockpitOrigin]),
            try await send(.options, "/v1/health", headers: ["Origin": cockpitOrigin, "Access-Control-Request-Method": "GET"]),
            try await send(.get, "/v1/capabilities", headers: ["Origin": cockpitOrigin]),
            try await send(.get, "/v1/health", headers: ["Origin": "https://evil.test"]),
        ]
        for r in replies {
            for (field) in r.headers {
                #expect(!field.value.contains("*"), "header \(field.name) contains a wildcard")
            }
        }
    }

    @Test func originPolicyRejectsWildcardsAndJunk() {
        for bad in ["*", "https://*.example.com", "ftp://x.test", "localhost:4173", "http://", "http://x.test/path", "http://x.test:abc", "http://u@x.test", ""] {
            #expect(throws: OriginPolicyError.self) { _ = try OriginPolicy([bad]) }
        }
        #expect(throws: Never.self) {
            let p = try OriginPolicy(["http://localhost:4173", "HTTPS://App.Example.com", "http://localhost:4173"])
            #expect(p.allowed == ["http://localhost:4173", "https://app.example.com"])
        }
    }
}
