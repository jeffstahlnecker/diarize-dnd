import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

struct HealthResponse: Codable, Sendable {
    var service: String
    var version: String
    var apiVersion: Int
    var paired: Bool
    var serverTime: String
}

struct CapabilitiesResponse: Codable, Sendable {
    struct Limits: Codable, Sendable { var jsonBodyBytes: Int }
    struct Features: Codable, Sendable { var upload: Bool; var deleteAudio: Bool; var speakerMerge: Bool }
    var apiVersion: Int
    var version: String
    var languages: [String]
    var defaultLanguage: String
    var sources: [String]
    /// TODO(15.4): fill from `AudioInputDevices` via the recording engine.
    var inputDevices: [String]
    var limits: Limits
    var features: Features
    var recording: String?
    var orphans: [String]
}

public enum DiarizeHTTPServer {
    /// Assemble the router with all middleware. Exposed for tests (in-memory client, no sockets).
    public static func makeRouter(
        config: ServeConfig,
        boundPort: BoundPort,
        tokenValidator: any TokenValidator = RejectAllTokenValidator()
    ) -> Router<BasicRequestContext> {
        let router = Router(context: BasicRequestContext.self)
        router.middlewares.add(RequestIDMiddleware())
        router.middlewares.add(RequestLogMiddleware())
        router.middlewares.add(ErrorEnvelopeMiddleware())
        router.middlewares.add(HostCheckMiddleware(port: boundPort))
        router.middlewares.add(BodyLimitMiddleware(maxBytes: config.maxJSONBodyBytes))
        router.middlewares.add(OriginCORSMiddleware(policy: config.origins))
        router.middlewares.add(BearerAuthMiddleware(validator: tokenValidator))

        let version = config.version
        let maxBody = config.maxJSONBodyBytes

        router.get("/v1/health") { _, _ -> Response in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return jsonResponse(HealthResponse(
                service: "diarize",
                version: version,
                apiVersion: ServeConfig.apiVersion,
                // TODO(15.3): true once at least one token exists in the token store.
                paired: false,
                serverTime: formatter.string(from: Date())
            ))
        }

        router.post("/v1/pair") { _, _ -> Response in
            // TODO(15.3): pairing code exchange, token store, rate limit.
            throw APIError.notImplemented("Pairing is not implemented yet.")
        }

        router.get("/v1/capabilities") { _, _ -> Response in
            jsonResponse(CapabilitiesResponse(
                apiVersion: ServeConfig.apiVersion,
                version: version,
                languages: ["auto", "de", "en"],
                defaultLanguage: "de",
                sources: ["mic", "system"],
                inputDevices: [],
                limits: .init(jsonBodyBytes: maxBody),
                features: .init(upload: false, deleteAudio: false, speakerMerge: false),
                recording: nil,
                orphans: []
            ))
        }

        return router
    }

    /// Build the application bound to `127.0.0.1:<config.port>`.
    public static func makeApplication(
        config: ServeConfig,
        boundPort: BoundPort? = nil,
        tokenValidator: any TokenValidator = RejectAllTokenValidator(),
        onListening: @escaping @Sendable (Int) -> Void = { _ in }
    ) -> some ApplicationProtocol {
        let port = boundPort ?? BoundPort(config.port)
        let router = makeRouter(config: config, boundPort: port, tokenValidator: tokenValidator)
        return Application(
            router: router,
            configuration: .init(
                address: .hostname(ServeConfig.bindHost, port: config.port),
                serverName: "diarize"
            ),
            onServerRunning: { channel in
                if let actual = channel.localAddress?.port {
                    port.set(actual)
                    onListening(actual)
                }
            }
        )
    }

    /// Run until SIGINT/SIGTERM, then shut down gracefully (in-flight requests finish).
    public static func run(
        config: ServeConfig,
        tokenValidator: any TokenValidator = RejectAllTokenValidator(),
        onListening: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws {
        let app = makeApplication(config: config, tokenValidator: tokenValidator, onListening: onListening)
        try await app.runService()
    }
}
