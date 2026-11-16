import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

// Middleware order (outermost first), see Server.swift:
// RequestID -> RequestLog -> ErrorEnvelope -> HostCheck -> BodyLimit -> OriginCORS -> BearerAuth -> routes

/// Assigns (or echoes a sanitised client-supplied) `X-Request-Id` and puts it on every response.
struct RequestIDMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        var request = request
        let id = Self.sanitised(request.headers[Hdr.requestID]) ?? Self.generate()
        request.head.headerFields[Hdr.requestID] = id
        var response = try await next(request, context)
        response.headers[Hdr.requestID] = id
        return response
    }

    static func sanitised(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 64 else { return nil }
        let ok = value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
        return ok ? value : nil
    }

    static func generate() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }
}

/// One log line per request. Never logs headers or bodies (no tokens, no transcript text).
struct RequestLogMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let start = DispatchTime.now().uptimeNanoseconds
        let response = try await next(request, context)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let id = request.headers[Hdr.requestID] ?? "-"
        context.logger.info("\(request.method.rawValue) \(request.uri.path) -> \(response.status.code) (\(String(format: "%.1f", ms)) ms) [\(id)]")
        return response
    }
}

/// Turns every thrown error into the documented error envelope.
struct ErrorEnvelopeMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch {
            if !(error is APIError) {
                context.logger.error("unhandled error: \(error)")
            }
            return ErrorRendering.response(for: error, requestID: request.headers[Hdr.requestID] ?? "-")
        }
    }
}

/// DNS-rebinding defence: `Host` must be `127.0.0.1:<port>` or `localhost:<port>`.
struct HostCheckMiddleware<Context: RequestContext>: RouterMiddleware {
    let port: BoundPort

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard Self.isLoopbackHost(request.headers[Hdr.host], port: port.value) else {
            throw APIError.invalidHost()
        }
        return try await next(request, context)
    }

    static func isLoopbackHost(_ host: String?, port: Int) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }
}

/// Rejects oversize JSON bodies announced via `Content-Length` (413). Handlers that read bodies
/// must additionally collect with a limit (chunked bodies carry no length up front).
struct BodyLimitMiddleware<Context: RequestContext>: RouterMiddleware {
    let maxBytes: Int

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if let raw = request.headers[Hdr.contentLength], let length = Int(raw), length > maxBytes {
            throw APIError.payloadTooLarge(limit: maxBytes)
        }
        return try await next(request, context)
    }
}

/// Exact-match Origin allowlist, CORS headers, and Chrome Private Network Access preflight.
///
/// - A request with an `Origin` that is not allowed (or `null`) gets 403 `forbidden_origin` and no CORS headers.
/// - Preflights from allowed origins are answered here (204) and never reach auth.
/// - Errors from inner layers are rendered here so that error responses carry CORS headers too
///   (otherwise the page could not read the error body).
/// - No wildcard, no `Access-Control-Allow-Credentials`.
struct OriginCORSMiddleware<Context: RequestContext>: RouterMiddleware {
    let policy: OriginPolicy

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let origin = request.headers[Hdr.origin] else {
            return try await next(request, context)
        }
        guard policy.isAllowed(origin) else {
            throw APIError.forbiddenOrigin()
        }

        if request.method == .options, request.headers[Hdr.requestMethod] != nil {
            var headers = HTTPFields()
            headers[Hdr.allowOrigin] = origin
            headers[Hdr.allowMethods] = "GET, POST, PATCH, DELETE, OPTIONS"
            headers[Hdr.allowHeaders] = "Authorization, Content-Type, X-Request-Id"
            headers[Hdr.maxAge] = "600"
            headers[Hdr.vary] = "Origin, Access-Control-Request-Private-Network"
            if request.headers[Hdr.requestPrivateNetwork]?.lowercased() == "true" {
                headers[Hdr.allowPrivateNetwork] = "true"
            }
            return Response(status: HTTPResponse.Status(code: 204), headers: headers)
        }

        var response: Response
        do {
            response = try await next(request, context)
        } catch {
            response = ErrorRendering.response(for: error, requestID: request.headers[Hdr.requestID] ?? "-")
        }
        response.headers[Hdr.allowOrigin] = origin
        response.headers[Hdr.vary] = "Origin"
        response.headers[Hdr.exposeHeaders] = "X-Request-Id, Retry-After"
        return response
    }
}

/// Outcome of checking a bearer token.
public enum TokenCheck: Sendable, Equatable {
    case valid
    case invalid
    /// The token exists but was issued to a different origin.
    case wrongOrigin
}

/// Token validation seam. Story 15.3 provides the real implementation (hashed token store, origin binding).
public protocol TokenValidator: Sendable {
    func check(token: String, origin: String?) async -> TokenCheck
}

/// TODO(15.3): replaced by the pairing-backed validator. Until then no token is ever valid,
/// so every authenticated route answers 401.
public struct RejectAllTokenValidator: TokenValidator {
    public init() {}
    public func check(token: String, origin: String?) async -> TokenCheck { .invalid }
}

/// Bearer-token gate. Public routes: `GET /v1/health`, `POST /v1/pair`.
struct BearerAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let validator: any TokenValidator

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if Self.isPublic(method: request.method, path: request.uri.path) {
            return try await next(request, context)
        }
        guard let token = Self.bearerToken(request.headers[Hdr.authorization]) else {
            throw APIError.unauthorized()
        }
        switch await validator.check(token: token, origin: request.headers[Hdr.origin]) {
        case .valid: return try await next(request, context)
        case .invalid: throw APIError.unauthorized()
        case .wrongOrigin: throw APIError.forbiddenOrigin("This token was issued to a different origin.")
        }
    }

    static func isPublic(method: HTTPRequest.Method, path: String) -> Bool {
        (method == .get && path == "/v1/health") || (method == .post && path == "/v1/pair")
    }

    static func bearerToken(_ header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}
