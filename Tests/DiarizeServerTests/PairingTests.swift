import Foundation
import Testing
@testable import DiarizeServer

/// Conformance rows 10-12 and the pairing / token rules (docs/http-api.md "Authentication and pairing").
@Suite struct PairingTests {
    func pairBody(_ code: String, name: String = "DM Cockpit") -> String {
        #"{"code":"\#(code)","clientName":"\#(name)"}"#
    }

    func pair(_ s: TestServer, _ code: String, origin: String? = cockpitOrigin) async throws -> Reply {
        var h = ["Content-Type": "application/json"]
        if let origin { h["Origin"] = origin }
        return try await s.send(.post, "/v1/pair", headers: h, body: pairBody(code))
    }

    @Test func codeFormat() {
        for _ in 0..<50 {
            let code = PairingManager.randomCode()
            #expect(code.count == 7)
            #expect(code.range(of: #"^\d{3}-\d{3}$"#, options: .regularExpression) != nil)
        }
    }

    // 11
    @Test func rightCodeIssuesTokenOnce() async throws {
        let s = try TestServer(validator: nil)
        let code = s.currentCode
        let r = try await pair(s, code)
        #expect(r.status == 200)
        let token = try #require(r.json["token"] as? String)
        #expect(token.hasPrefix("dz_"))
        #expect(token.count >= 43 + 3)   // 256 bits base64url
        #expect((r.json["tokenId"] as? String)?.hasPrefix("tok_") == true)
        #expect(r.json["instanceId"] as? String == s.services.instanceId)
        #expect(r.json["apiVersion"] as? Int == 1)
        #expect(r.header("Access-Control-Allow-Origin") == cockpitOrigin)

        let again = try await pair(s, code)
        #expect(again.status == 403)
        #expect(again.errorCode == "pairing_code_invalid")
        // A used code is replaced by a fresh one, printed in the terminal only.
        #expect(s.currentCode != code || s.codes.withLockedValue { $0.count } == 2)
        #expect(s.codes.withLockedValue { $0.count } == 2)
    }

    @Test func codeWithoutDashIsAccepted() async throws {
        let s = try TestServer(validator: nil)
        let r = try await pair(s, s.currentCode.replacingOccurrences(of: "-", with: ""))
        #expect(r.status == 200)
    }

    // 12
    @Test func fiveWrongCodesAreRateLimited() async throws {
        let s = try TestServer(validator: nil)
        let original = s.currentCode
        let wrong = original == "000-000" ? "111-111" : "000-000"
        for i in 1...4 {
            let r = try await pair(s, wrong)
            #expect(r.status == 403, "attempt \(i)")
            #expect(r.errorCode == "pairing_code_invalid")
        }
        let fifth = try await pair(s, wrong)
        #expect(fifth.status == 429)
        #expect(fifth.errorCode == "pairing_rate_limited")
        #expect(fifth.header("Retry-After") == "60")
        #expect(fifth.header("Access-Control-Expose-Headers")?.contains("Retry-After") == true)
        // The code is burnt: a new one is printed, and even the right one is refused during the lock.
        #expect(s.currentCode != original || s.codes.withLockedValue { $0.count } == 2)
        let during = try await pair(s, s.currentCode)
        #expect(during.status == 429)
        s.clock.advance(61)
        let after = try await pair(s, s.currentCode)
        #expect(after.status == 200)
    }

    @Test func expiredCodeIsRenewed() async throws {
        let s = try TestServer(validator: nil)
        let code = s.currentCode
        s.clock.advance(5 * 60 + 1)
        let r = try await pair(s, code)
        #expect(r.status == 403)
        #expect(r.errorCode == "pairing_code_invalid")
        #expect(s.codes.withLockedValue { $0.count } == 2)
        let ok = try await pair(s, s.currentCode)
        #expect(ok.status == 200)
    }

    @Test func clientNameIsValidated() async throws {
        let s = try TestServer(validator: nil)
        for name in ["", String(repeating: "x", count: 61)] {
            let r = try await s.send(.post, "/v1/pair", headers: ["Content-Type": "application/json"], body: pairBody(s.currentCode, name: name))
            #expect(r.status == 422)
            #expect(r.errorCode == "validation_failed")
        }
    }

    @Test func pairedTokenWorksAndIsBoundToItsOrigin() async throws {
        let s = try TestServer(validator: nil)
        let token = try #require(try await pair(s, s.currentCode).json["token"] as? String)

        let ok = try await s.send(.get, "/v1/capabilities", headers: ["Authorization": "Bearer \(token)", "Origin": cockpitOrigin])
        #expect(ok.status == 200)
        let noOrigin = try await s.send(.get, "/v1/capabilities", headers: ["Authorization": "Bearer \(token)"])
        #expect(noOrigin.status == 200)

        // 10 / mismatch 1: allowed origin B with A's token -> 403 WITH CORS headers, so B can read why.
        let other = try await s.send(.get, "/v1/capabilities", headers: ["Authorization": "Bearer \(token)", "Origin": otherOrigin])
        #expect(other.status == 403)
        #expect(other.errorCode == "forbidden_origin")
        #expect(other.header("Access-Control-Allow-Origin") == otherOrigin)
        #expect(other.header("Vary") == "Origin")
    }

    @Test func healthShowsPairedState() async throws {
        let s = try TestServer(validator: nil)
        #expect(try await s.send(.get, "/v1/health").json["paired"] as? Bool == false)
        _ = try await pair(s, s.currentCode)
        #expect(try await s.send(.get, "/v1/health").json["paired"] as? Bool == true)
    }

    @Test func deletePairRevokesTheCallingToken() async throws {
        let s = try TestServer(validator: nil)
        let token = try #require(try await pair(s, s.currentCode).json["token"] as? String)
        let r = try await s.send(.delete, "/v1/pair", headers: ["Authorization": "Bearer \(token)"])
        #expect(r.status == 200)
        #expect(r.json["revoked"] as? Bool == true)
        let after = try await s.send(.get, "/v1/capabilities", headers: ["Authorization": "Bearer \(token)"])
        #expect(after.status == 401)
        #expect(try await s.send(.get, "/v1/health").json["paired"] as? Bool == false)
    }

    @Test func deletePairNeedsAToken() async throws {
        let s = try TestServer(validator: nil)
        #expect(try await s.send(.delete, "/v1/pair").status == 401)
    }

    @Test func tokenFileStoresOnlyHashesWithMode0600() async throws {
        let s = try TestServer(validator: nil, tokenFile: true)
        let token = try #require(try await pair(s, s.currentCode).json["token"] as? String)
        let file = s.dir.appendingPathComponent("config/serve-tokens.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(token))
        #expect(text.contains(TokenStore.hash(token)))
        #expect(text.contains(cockpitOrigin))
        #expect(text.contains("DM Cockpit"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)

        // Survives a restart (a new store reading the same file).
        let reloaded = try TokenStore(fileURL: file)
        #expect(await reloaded.check(token: token, origin: cockpitOrigin) == .valid)
        #expect(await reloaded.check(token: token, origin: otherOrigin) == .wrongOrigin)
        #expect(await reloaded.check(token: token + "x", origin: nil) == .invalid)
        try reloaded.revokeAll()
        #expect(await reloaded.check(token: token, origin: nil) == .invalid)
    }

    @Test func pairingIsLogged() async throws {
        let s = try TestServer(validator: nil)
        _ = try await pair(s, s.currentCode)
        #expect(s.logLines.withLockedValue { $0 }.contains { $0.contains("Paired \"DM Cockpit\" from \(cockpitOrigin)") })
    }
}
