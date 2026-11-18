import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// A failure that is rendered as the documented error envelope (docs/http-api.md, "Errors").
public struct APIError: Error, Sendable {
    public var status: Int
    public var code: String
    public var message: String
    public var details: [String: JSONValue]?
    public var headers: [String: String]

    public init(status: Int, code: String, message: String, details: [String: JSONValue]? = nil, headers: [String: String] = [:]) {
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
    public static func pairingCodeInvalid(_ message: String = "Wrong, expired or used pairing code.") -> APIError {
        APIError(status: 403, code: "pairing_code_invalid", message: message)
    }
    public static func pairingRateLimited(retryAfter: Int) -> APIError {
        APIError(status: 429, code: "pairing_rate_limited",
                 message: "Too many wrong pairing codes. A new code was printed in the terminal.",
                 details: ["retryAfterSec": .number(Double(retryAfter))],
                 headers: ["Retry-After": String(retryAfter)])
    }
    public static func notFound(_ message: String = "Not found.") -> APIError {
        APIError(status: 404, code: "not_found", message: message)
    }
    public static func conflictRecordingActive(recordingId: String) -> APIError {
        APIError(status: 409, code: "conflict_recording_active",
                 message: "A recording is already running (\(recordingId)).",
                 details: ["recordingId": .string(recordingId)])
    }
    public static func wrongState(_ state: String, reason: String? = nil, message: String) -> APIError {
        var details: [String: JSONValue] = ["state": .string(state)]
        if let reason { details["reason"] = .string(reason) }
        return APIError(status: 409, code: "wrong_state", message: message, details: details)
    }
    public static func notReady(state: String) -> APIError {
        APIError(status: 409, code: "not_ready", message: "The transcript is not ready (state \(state)).",
                 details: ["state": .string(state)])
    }
    public static func payloadTooLarge(limit: Int) -> APIError {
        APIError(status: 413, code: "payload_too_large", message: "Request body exceeds \(limit) bytes.",
                 details: ["limitBytes": .number(Double(limit))])
    }
    public static func unsupportedMediaType(_ message: String = "Not a supported audio container (WAV, MP3, MP4/M4A).") -> APIError {
        APIError(status: 415, code: "unsupported_media_type", message: message)
    }
    /// `fields`: (field, message) pairs, rendered as `details.fields: [{field, message}]`.
    public static func validationFailed(_ fields: [(String, String)], message: String = "Invalid request.") -> APIError {
        APIError(status: 422, code: "validation_failed", message: message, details: [
            "fields": .array(fields.map { .object(["field": .string($0.0), "message": .string($0.1)]) }),
        ])
    }
    public static func captureFailed(_ message: String, hint: String) -> APIError {
        APIError(status: 422, code: "capture_failed", message: message, details: ["hint": .string(hint)])
    }
    public static func insufficientStorage(freeBytes: Int64) -> APIError {
        APIError(status: 507, code: "insufficient_storage", message: "Less than 2 GiB free on the archive volume.",
                 details: ["freeBytes": .number(Double(freeBytes))])
    }
    public static func modelsUnavailable() -> APIError {
        APIError(status: 503, code: "models_unavailable", message: "The ASR/diarization models are not available.")
    }
    public static func notImplemented(_ message: String) -> APIError {
        APIError(status: 501, code: "not_implemented", message: message)
    }
    public static func internalError(_ message: String = "Unexpected error.") -> APIError {
        APIError(status: 500, code: "internal", message: message)
    }
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
        var body: [String: JSONValue] = [
            "code": .string(api.code),
            "message": .string(api.message),
            "requestId": .string(requestID),
        ]
        if let details = api.details { body["details"] = .object(details) }
        var response = jsonResponse(.object(["error": .object(body)]), status: api.status)
        for (name, value) in api.headers {
            if let field = HTTPField.Name(name) { response.headers[field] = value }
        }
        return response
    }

    static func mapHTTPStatus(_ status: Int) -> APIError {
        switch status {
        case 400: return .badRequest("Bad request.")
        case 404: return .notFound()
        case 405: return APIError(status: 405, code: "method_not_allowed", message: "Method not allowed.")
        case 413: return APIError(status: 413, code: "payload_too_large", message: "Payload too large.")
        case 415: return APIError(status: 415, code: "unsupported_media_type", message: "Unsupported media type.")
        default:
            return APIError(status: status, code: status >= 500 ? "internal" : "bad_request", message: "Request failed.")
        }
    }
}

func jsonResponse(_ value: JSONValue, status: Int = 200) -> Response {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
    var headers = HTTPFields()
    headers[.contentType] = "application/json; charset=utf-8"
    headers[.cacheControl] = "no-store"
    return Response(
        status: HTTPResponse.Status(code: status),
        headers: headers,
        body: ResponseBody(byteBuffer: ByteBuffer(bytes: [UInt8](data)))
    )
}
