import Foundation
import Testing
@testable import DiarizeServer

@Suite struct AuthTests {
    // 9
    @Test func missingTokenIs401() async throws {
        let r = try await send(.get, "/v1/capabilities")
        #expect(r.status == 401)
        #expect(r.errorCode == "unauthorized")
        #expect(r.header("WWW-Authenticate") == "Bearer")
    }

    @Test func malformedAuthorizationIs401() async throws {
        for value in ["dz_good", "Basic dz_good", "Bearer", "Bearer   "] {
            let r = try await send(.get, "/v1/capabilities", headers: ["Authorization": value])
            #expect(r.status == 401, "Authorization: \(value)")
        }
    }

    @Test func unknownTokenIs401() async throws {
        let r = try await send(.get, "/v1/capabilities", headers: ["Authorization": "Bearer dz_nope"])
        #expect(r.status == 401)
    }

    @Test func validTokenWithoutOriginIsAccepted() async throws {
        let r = try await send(.get, "/v1/capabilities", headers: ["Authorization": "bearer dz_good"])
        #expect(r.status == 200)
    }

    @Test func validTokenFromItsOriginIsAccepted() async throws {
        let r = try await send(.get, "/v1/capabilities", headers: ["Authorization": "Bearer dz_good", "Origin": cockpitOrigin])
        #expect(r.status == 200)
        #expect(r.header("Access-Control-Allow-Origin") == cockpitOrigin)
    }

    // 10
    @Test func tokenIssuedToAnotherOriginIsForbidden() async throws {
        let r = try await send(.get, "/v1/capabilities", headers: ["Authorization": "Bearer dz_good", "Origin": otherOrigin])
        #expect(r.status == 403)
        #expect(r.errorCode == "forbidden_origin")
        // The other origin is allowed, so it may read the error.
        #expect(r.header("Access-Control-Allow-Origin") == otherOrigin)
    }

    @Test func healthDoesNotNeedAToken() async throws {
        let r = try await send(.get, "/v1/health")
        #expect(r.status == 200)
    }

    @Test func defaultValidatorRejectsEverythingUntilPairingExists() async throws {
        let r = try await send(.get, "/v1/capabilities", headers: ["Authorization": "Bearer dz_good"], validator: RejectAllTokenValidator())
        #expect(r.status == 401)
    }
}
