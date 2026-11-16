import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
@testable import DiarizeServer

let testPort = 47653
let cockpitOrigin = "http://localhost:4173"
let otherOrigin = "http://localhost:5173"

struct Reply: Sendable {
    var status: Int
    var headers: HTTPFields
    var body: String

    func header(_ name: String) -> String? { HTTPField.Name(name).flatMap { headers[$0] } }

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]) ?? [:]
    }
    var errorCode: String? { (json["error"] as? [String: Any])?["code"] as? String }
}

/// Accepts tokens by exact value, bound to one origin (or any origin when `origin` is nil).
struct StubTokenValidator: TokenValidator {
    var tokens: [String: String?]
    func check(token: String, origin: String?) async -> TokenCheck {
        guard let bound = tokens[token] else { return .invalid }
        if let bound, let origin, bound != origin { return .wrongOrigin }
        return .valid
    }
}

func makeTestConfig(origins: [String] = [cockpitOrigin, otherOrigin]) throws -> ServeConfig {
    ServeConfig(port: testPort, origins: try OriginPolicy(origins))
}

func send(
    _ method: HTTPRequest.Method,
    _ uri: String,
    headers extra: [String: String] = [:],
    host: String? = "127.0.0.1:\(testPort)",
    origins: [String] = [cockpitOrigin, otherOrigin],
    validator: any TokenValidator = StubTokenValidator(tokens: ["dz_good": cockpitOrigin]),
    body: String? = nil
) async throws -> Reply {
    let config = try makeTestConfig(origins: origins)
    let app = DiarizeHTTPServer.makeApplication(config: config, tokenValidator: validator)
    var fields = HTTPFields()
    if let host { fields[Hdr.host] = host }
    for (k, v) in extra { fields[HTTPField.Name(k)!] = v }
    let buffer = body.map { ByteBuffer(string: $0) }
    return try await app.test(.router) { client in
        try await client.execute(uri: uri, method: method, headers: fields, body: buffer) { response in
            Reply(
                status: Int(response.status.code),
                headers: response.headers,
                body: response.body.getString(at: response.body.readerIndex, length: response.body.readableBytes) ?? ""
            )
        }
    }
}
