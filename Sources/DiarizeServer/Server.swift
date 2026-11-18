import DiarizeCore
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Everything the routes use. Built once per server run (tests build one per request with fakes).
public struct ServerServices: Sendable {
    public var validator: any TokenValidator
    public var tokens: TokenStore
    public var pairing: PairingManager
    public var controller: RecordingController
    public var instanceId: String

    public init(validator: (any TokenValidator)? = nil, tokens: TokenStore, pairing: PairingManager, controller: RecordingController, instanceId: String) {
        self.validator = validator ?? tokens
        self.tokens = tokens
        self.pairing = pairing
        self.controller = controller
        self.instanceId = instanceId
    }

    var env: ServerEnvironment { controller.env }
}

public enum DiarizeHTTPServer {
    /// Assemble the router with all middleware. Exposed for tests (in-memory client, no sockets).
    public static func makeRouter(config: ServeConfig, boundPort: BoundPort, services: ServerServices) -> Router<BasicRequestContext> {
        let router = Router(context: BasicRequestContext.self)
        router.middlewares.add(RequestIDMiddleware())
        router.middlewares.add(RequestLogMiddleware())
        router.middlewares.add(ErrorEnvelopeMiddleware())
        router.middlewares.add(HostCheckMiddleware(port: boundPort))
        router.middlewares.add(BodyLimitMiddleware(maxBytes: config.maxJSONBodyBytes))
        router.middlewares.add(OriginCORSMiddleware(policy: config.origins))
        router.middlewares.add(BearerAuthMiddleware(validator: services.validator))
        Routes(config: config, services: services).register(on: router)
        return router
    }

    /// Build the application bound to `127.0.0.1:<config.port>`.
    public static func makeApplication(
        config: ServeConfig,
        services: ServerServices,
        boundPort: BoundPort? = nil,
        onListening: @escaping @Sendable (Int) -> Void = { _ in }
    ) -> some ApplicationProtocol {
        let port = boundPort ?? BoundPort(config.port)
        let router = makeRouter(config: config, boundPort: port, services: services)
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

    /// Run until SIGINT/SIGTERM, then shut down gracefully: in-flight requests finish, event streams end,
    /// an active recording is closed and kept for later analysis.
    public static func run(config: ServeConfig, services: ServerServices, onListening: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        let app = makeApplication(config: config, services: services, onListening: onListening)
        defer { services.env.events.finishAll() }
        try await app.runService()
        services.env.events.finishAll()
        await services.controller.shutdown()
    }
}

struct Routes: Sendable {
    let config: ServeConfig
    let services: ServerServices

    var controller: RecordingController { services.controller }
    var env: ServerEnvironment { services.env }

    func register(on router: Router<BasicRequestContext>) {
        router.get("/v1/health") { _, _ in health() }
        router.post("/v1/pair") { request, _ in try await pair(request) }
        router.delete("/v1/pair") { request, _ in try unpair(request) }
        router.get("/v1/capabilities") { _, _ in try await capabilities() }

        router.post("/v1/recordings") { request, _ in
            var request = request
            let body = try await Self.readJSONObject(&request, limit: config.maxJSONBodyBytes)
            let origin = request.headers[Hdr.origin]
            let client = BearerAuthMiddleware<BasicRequestContext>.bearerToken(request.headers[Hdr.authorization]).flatMap { services.tokens.entry(for: $0)?.clientName }
            return jsonResponse(try await controller.start(body, origin: origin, clientName: client), status: 201)
        }
        router.get("/v1/recordings") { request, _ in try await list(request) }
        router.get("/v1/recordings/:id") { _, ctx in jsonResponse(try await controller.get(id: try ctx.parameters.require("id"))) }
        router.patch("/v1/recordings/:id") { request, ctx in
            var request = request
            let body = try await Self.readJSONObject(&request, limit: config.maxJSONBodyBytes)
            return jsonResponse(try await controller.patch(id: try ctx.parameters.require("id"), body: body))
        }
        router.delete("/v1/recordings/:id") { request, ctx in
            guard request.uri.queryParameters["confirm"].map(String.init) == "true" else {
                throw APIError.validationFailed([("confirm", "must be true")], message: "Deleting a recording requires ?confirm=true.")
            }
            try await controller.delete(id: try ctx.parameters.require("id"))
            return jsonResponse(["deleted": true])
        }
        router.post("/v1/recordings/:id/stop") { _, ctx in
            jsonResponse(try await controller.stop(id: try ctx.parameters.require("id")), status: 202)
        }
        router.post("/v1/recordings/:id/transcribe") { _, ctx in
            jsonResponse(try await controller.transcribe(id: try ctx.parameters.require("id")), status: 202)
        }
        router.get("/v1/recordings/:id/transcript") { request, ctx in
            let bleed = request.uri.queryParameters["includeBleed"].map(String.init) == "true"
            return jsonResponse(try await controller.transcript(id: try ctx.parameters.require("id"), includeBleed: bleed))
        }
        router.delete("/v1/recordings/:id/audio") { request, ctx in
            var channel: Int?
            if let raw = request.uri.queryParameters["channel"] {
                guard let n = Int(raw), n >= 1 else { throw APIError.validationFailed([("channel", "a 1-based channel number")]) }
                channel = n
            }
            return jsonResponse(try await controller.deleteAudio(id: try ctx.parameters.require("id"), channel: channel))
        }

        router.post("/v1/transcriptions") { request, _ in try await upload(request) }

        router.get("/v1/speakers") { _, _ in try SpeakerRoutes.list(env.store) }
        router.patch("/v1/speakers/:id") { request, ctx in
            var request = request
            let body = try await Self.readJSONObject(&request, limit: config.maxJSONBodyBytes)
            return try SpeakerRoutes.patch(env.store, id: try ctx.parameters.require("id"), body: body)
        }
        router.post("/v1/speakers/:id/merge") { request, ctx in
            var request = request
            let body = try await Self.readJSONObject(&request, limit: config.maxJSONBodyBytes)
            return try SpeakerRoutes.merge(env.store, id: try ctx.parameters.require("id"), body: body)
        }

        router.get("/v1/events") { _, _ in try await events() }
    }

    // MARK: - Health and pairing

    /// `serverTime` is ISO-8601 like every timestamp; `serverTimeMs` is the same instant in epoch milliseconds.
    func health() -> Response {
        let now = env.clock.now()
        return jsonResponse([
            "service": "diarize", "version": .string(config.version), "apiVersion": .int(ServeConfig.apiVersion),
            "paired": .bool(!services.tokens.isEmpty),
            "serverTime": .iso(now), "serverTimeMs": .int(WallClock.ms(now)),
        ])
    }

    func pair(_ request: Request) async throws -> Response {
        var request = request
        let body = try await Self.readJSONObject(&request, limit: config.maxJSONBodyBytes)
        guard let name = body["clientName"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), (1...60).contains(name.count) else {
            throw APIError.validationFailed([("clientName", "1..60 characters")])
        }
        let code = body["code"]?.stringValue ?? ""
        switch services.pairing.attempt(code) {
        case .success:
            let origin = request.headers[Hdr.origin]
            let issued = try services.tokens.issue(clientName: name, origin: origin)
            env.log("Paired \"\(name)\"\(origin.map { " from \($0)" } ?? " (no Origin)") as \(issued.id).")
            return jsonResponse(["token": .string(issued.token), "tokenId": .string(issued.id),
                                 "instanceId": .string(services.instanceId), "apiVersion": .int(ServeConfig.apiVersion)])
        case .invalid(let renewed):
            throw APIError.pairingCodeInvalid(renewed
                ? "The pairing code had expired or was already used. A new code was printed in the terminal."
                : "Wrong pairing code.")
        case .rateLimited(let retryAfter):
            throw APIError.pairingRateLimited(retryAfter: retryAfter)
        }
    }

    func unpair(_ request: Request) throws -> Response {
        guard let token = BearerAuthMiddleware<BasicRequestContext>.bearerToken(request.headers[Hdr.authorization]) else { throw APIError.unauthorized() }
        let entry = services.tokens.entry(for: token)
        try services.tokens.revoke(token: token)
        env.log("Token \(entry?.id ?? "?") (\"\(entry?.clientName ?? "?")\") revoked by its client.")
        return jsonResponse(["revoked": true])
    }

    // MARK: - Capabilities

    func capabilities() async throws -> Response {
        let devices = env.recordingEngine.inputDevices()
        let free = env.freeBytes(env.appConfig.archivePath)
        let recording = try await controller.current()
        let orphans = try await controller.orphans()
        return jsonResponse([
            "apiVersion": .int(ServeConfig.apiVersion),
            "version": .string(config.version),
            "instanceId": .string(services.instanceId),
            "languages": .array(StartValidation.languages.map { .string($0) }),
            "defaultLanguage": .string(env.appConfig.defaultLanguage.rawValue),
            "sources": ["mic", "system"],
            "inputDevices": .array(devices.map(\.json)),
            "storage": ["archivePath": .string(env.appConfig.archivePath.path), "freeBytes": free.map { .int($0) } ?? .null],
            "limits": ["maxUploadBytes": .int(env.maxUploadBytes), "maxDurationSec": .double(env.maxDurationSec, places: 0),
                       "jsonBodyBytes": .int(config.maxJSONBodyBytes)],
            "features": ["upload": true, "deleteAudio": true, "speakerMerge": true, "multichannel": true],
            "recording": recording,
            "orphans": .array(orphans),
        ])
    }

    // MARK: - Recordings

    func list(_ request: Request) async throws -> Response {
        let q = request.uri.queryParameters
        var query = RecordingController.ListQuery()
        query.clientRef = q["clientRef"].map(String.init).flatMap { $0.isEmpty ? nil : $0 }
        query.state = q["state"].map(String.init).flatMap { $0.isEmpty ? nil : $0 }
        if let raw = q["limit"] {
            guard let n = Int(raw), (1...200).contains(n) else { throw APIError.validationFailed([("limit", "1..200")]) }
            query.limit = n
        }
        if let raw = q["before"] {
            guard let d = ISOTime.parseFlexible(String(raw)) else { throw APIError.validationFailed([("before", "an ISO timestamp")]) }
            query.before = d
        }
        return jsonResponse(try await controller.list(query))
    }

    // MARK: - Upload

    func upload(_ request: Request) async throws -> Response {
        let maxBytes = env.maxUploadBytes
        if let raw = request.headers[Hdr.contentLength], let n = Int(raw), n > maxBytes { throw APIError.payloadTooLarge(limit: maxBytes) }
        let contentType = (request.headers[.contentType] ?? "application/octet-stream").split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        guard Upload.allowedTypes.contains(contentType) else { throw APIError.unsupportedMediaType() }

        let q = request.uri.queryParameters
        var fields: [(String, String)] = []
        let title = q["title"].map(String.init)
        if let title, !(1...200).contains(title.count) { fields.append(("title", "1..200 characters")) }
        let language = q["language"].map(String.init)
        if let language, !StartValidation.languages.contains(language) { fields.append(("language", "auto, de or en")) }
        let clientRef = q["clientRef"].map(String.init)
        if let clientRef, clientRef.count > 200 { fields.append(("clientRef", "at most 200 characters")) }
        var startedAt: Date?
        if let raw = q["startedAt"] {
            startedAt = ISOTime.parseFlexible(String(raw))
            if startedAt == nil { fields.append(("startedAt", "ISO timestamp or epoch milliseconds")) }
        }
        let deleteAudio = q["deleteAudioWhenDone"].map(String.init) == "true"
        if !fields.isEmpty { throw APIError.validationFailed(fields) }

        try env.appConfig.ensureDirectories()
        let file = try await Upload.stream(request.body, into: env.appConfig.recordingsDir, now: env.clock.now(), maxBytes: maxBytes)
        let dto = try await controller.registerUpload(fileURL: file, title: title, language: language, clientRef: clientRef,
                                                      startedAt: startedAt, deleteAudioWhenDone: deleteAudio)
        return jsonResponse(dto, status: 202)
    }

    // MARK: - Events

    func events() async throws -> Response {
        let snapshotRecording = try await controller.current()
        let now = env.clock.now()
        let snapshot = ServerEvent("snapshot", ["serverTime": .iso(now), "serverTimeMs": .int(WallClock.ms(now)), "recording": snapshotRecording])
        let stream = env.events.subscribe(first: [snapshot])
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream; charset=utf-8"
        headers[.cacheControl] = "no-store"
        return Response(status: .ok, headers: headers, body: ResponseBody { writer in
            for await frame in stream {
                try await writer.write(ByteBuffer(string: frame))
            }
            try await writer.finish(nil)
        })
    }

    // MARK: - Helpers

    /// Reads a JSON object body (at most `limit` bytes). An empty body counts as `{}`.
    static func readJSONObject(_ request: inout Request, limit: Int) async throws -> [String: JSONValue] {
        let buffer: ByteBuffer
        do {
            buffer = try await request.collectBody(upTo: limit)
        } catch let e as any HTTPResponseError where e.status == .contentTooLarge {
            throw APIError.payloadTooLarge(limit: limit)
        }
        if buffer.readableBytes == 0 { return [:] }
        let type = request.headers[.contentType]?.lowercased() ?? ""
        guard type.hasPrefix("application/json") else { throw APIError.badRequest("Content-Type must be application/json.") }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(buffer.readableBytesView)), let object = value.objectValue else {
            throw APIError.badRequest("Malformed JSON: expected an object.")
        }
        return object
    }
}

enum Upload {
    static let allowedTypes: Set<String> = ["audio/wav", "audio/x-wav", "audio/wave", "audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/m4a", "application/octet-stream"]

    enum Kind: String { case wav, mp3, m4a }

    /// RIFF/WAVE, ID3 or an MPEG frame sync, or an ISO-BMFF `ftyp` box.
    static func sniff(_ head: [UInt8]) -> Kind? {
        if head.count >= 12, head[0..<4] == [0x52, 0x49, 0x46, 0x46], head[8..<12] == [0x57, 0x41, 0x56, 0x45] { return .wav }
        if head.count >= 3, head[0..<3] == [0x49, 0x44, 0x33] { return .mp3 }
        if head.count >= 2, head[0] == 0xFF, head[1] & 0xE0 == 0xE0 { return .mp3 }
        if head.count >= 8, head[4..<8] == [0x66, 0x74, 0x79, 0x70] { return .m4a }
        return nil
    }

    /// Streams the body to `<dir>/upload-<stamp>.<ext>` without holding it in memory.
    static func stream<S: AsyncSequence>(_ body: S, into dir: URL, now: Date, maxBytes: Int) async throws -> URL where S.Element == ByteBuffer {
        let tmp = dir.appendingPathComponent(".upload-\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        var total = 0
        var head: [UInt8] = []
        do {
            for try await chunk in body {
                total += chunk.readableBytes
                if total > maxBytes { throw APIError.payloadTooLarge(limit: maxBytes) }
                if head.count < 12 { head += chunk.getBytes(at: chunk.readerIndex, length: min(12 - head.count, chunk.readableBytes)) ?? [] }
                try handle.write(contentsOf: chunk.readableBytesView)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        guard total > 0, let kind = sniff(head) else {
            try? FileManager.default.removeItem(at: tmp)
            throw APIError.unsupportedMediaType()
        }
        let final = RecordingController.uniqueURL(dir.appendingPathComponent("upload-\(RecordingController.stamp(now)).\(kind.rawValue)"))
        try FileManager.default.moveItem(at: tmp, to: final)
        return final
    }
}

enum SpeakerRoutes {
    static func json(_ s: Speaker, _ stats: SpeakerStats?) -> JSONValue {
        ["id": .string(s.id), "label": .str(s.label), "notes": .str(s.notes),
         "segmentCount": .int(stats?.segmentCount ?? 0), "speechSec": .double(stats?.speechTimeSec ?? 0, places: 1),
         "recordingCount": .int(stats?.recordingCount ?? 0), "createdAt": .iso(s.createdAt)]
    }

    static func list(_ store: SpeakerStore) throws -> Response {
        let stats = try store.speakerStats()
        return jsonResponse(["speakers": .array(try store.allSpeakers().map { json($0, stats[$0.id]) })])
    }

    static func patch(_ store: SpeakerStore, id: String, body: [String: JSONValue]) throws -> Response {
        guard try store.speaker(id: id) != nil else { throw APIError.notFound("Unknown speaker.") }
        var fields: [(String, String)] = []
        func value(_ key: String, max: Int) -> String?? {
            guard let v = body[key] else { return nil }
            if v.isNull { return .some(nil) }
            if let s = v.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), s.count <= max { return .some(s.isEmpty ? nil : s) }
            fields.append((key, "null or at most \(max) characters"))
            return nil
        }
        let label = value("label", max: 100)
        let notes = value("notes", max: 2000)
        if !fields.isEmpty { throw APIError.validationFailed(fields, message: "Invalid speaker fields.") }
        if let label { try store.updateLabel(id: id, label: label) }
        if let notes { try store.updateNotes(id: id, notes: notes) }
        let speaker = try store.speaker(id: id)!
        return jsonResponse(json(speaker, try store.speakerStats()[id]))
    }

    static func merge(_ store: SpeakerStore, id: String, body: [String: JSONValue]) throws -> Response {
        guard let into = body["into"]?.stringValue, !into.isEmpty else {
            throw APIError.validationFailed([("into", "the id of the speaker to merge into")])
        }
        if into == id { throw APIError.validationFailed([("into", "must be another speaker")]) }
        guard try store.speaker(id: id) != nil else { throw APIError.notFound("Unknown speaker.") }
        guard try store.speaker(id: into) != nil else { throw APIError.notFound("Unknown target speaker.") }
        try store.mergeSpeakers(from: id, into: into)
        let survivor = try store.speaker(id: into)!
        return jsonResponse(json(survivor, try store.speakerStats()[into]))
    }
}
