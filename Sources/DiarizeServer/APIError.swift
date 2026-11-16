import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// A failure that is rendered as the documented error envelope (docs/http-api.md, "Errors").
public struct APIError: Error, Sendable {
    public var status: Int
    public var code: String
    public var message: String
    public var details: [String: String]?
    public var headers: [String: String]

    public init(status: Int, code: String, message: String, details: [String: String]? = nil, headers: [String: String] = [:]) {
        self.status = status
        self.code = code
        self.message = message
        self.details = details
        self.headers = headers
    }

    public static func badRequest(_ message: String) -> APIError {
        APIError(status: 400, code: "bad_request", message: message)
    }
    public static func unauthorized() -> APIError {
        APIError(status: 401, code: "unauthorized", message: "Missing, unknown or revoked token.",
                 headers: ["WWW-Authenticate": "Bearer"])
    }
    public static func forbiddenOrigin(_ message: String = "This origin is not allowed.") -> APIError {
        APIError(status: 403, code: "forbidden_origin", message: message)
    }
    public static func invalidHost() -> APIError {
        APIError(status: 403, code: "invalid_host", message: "The Host header must be 127.0.0.1:<port> or localhost:<port>.")
    }
    public static func notFound(_ message: String = "Not found.") -> APIError {
        APIError(status: 404, code: "not_found", message: message)
    }
    public static func payloadTooLarge(limit: Int) -> APIError {
        APIError(status: 413, code: "payload_too_large", message: "Request body exceeds \(limit) bytes.",
                 details: ["limitBytes": String(limit)])
    }
    public static func notImplemented(_ message: String) -> APIError {
        APIError(status: 501, code: "not_implemented", message: message)
    }
    public static func internalError() -> APIError {
        APIError(status: 500, code: "internal", message: "Unexpected error.")
    }
}

struct ErrorEnvelope: Codable, Sendable {
    struct Body: Codable, Sendable {
        var code: String
        var message: String
        var details: [String: String]?
        var requestId: String
    }
    var error: Body
}

enum ErrorRendering {
    /// Convert any thrown error to a response in the documented envelope.
    static func response(for error: Error, requestID: String) -> Response {
        let api: APIError
        if let e = error as? APIError {
            api = e
        } else if let e = error as? any HTTPResponseError {
            api = mapHTTPStatus(Int(e.status.code))
        } else {
            api = .internalError()
        }
        let envelope = ErrorEnvelope(error: .init(code: api.code, message: api.message, details: api.details, requestId: requestID))
        var response = jsonResponse(envelope, status: api.status)
        for (name, value) in api.headers {
            if let field = HTTPField.Name(name) { response.headers[field] = value }
        }
        return response
    }

    static func mapHTTPStatus(_ status: Int) -> APIError {
        switch status {
        case 400: return .badRequest("Bad request.")
        case 404: return .notFound()
        case 413: return APIError(status: 413, code: "payload_too_large", message: "Payload too large.")
        case 415: return APIError(status: 415, code: "unsupported_media_type", message: "Unsupported media type.")
        default:
            return APIError(status: status, code: status >= 500 ? "internal" : "bad_request", message: "Request failed.")
        }
    }
}

func jsonResponse<T: Encodable>(_ value: T, status: Int = 200) -> Response {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
    var headers = HTTPFields()
    headers[.contentType] = "application/json; charset=utf-8"
    return Response(
        status: HTTPResponse.Status(code: status),
        headers: headers,
        body: ResponseBody(byteBuffer: ByteBuffer(bytes: [UInt8](data)))
    )
}
