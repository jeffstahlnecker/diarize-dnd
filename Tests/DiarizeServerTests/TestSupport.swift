import DiarizeCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOConcurrencyHelpers
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
    var errorDetails: [String: Any]? { (json["error"] as? [String: Any])?["details"] as? [String: Any] }
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

// MARK: - Fakes

/// A stepping clock: every read returns the current value; tests move it explicitly.
final class TestClock: @unchecked Sendable {
    private let box: NIOLockedValueBox<Date>
    init(_ start: Date = Date(timeIntervalSince1970: 1_763_150_400)) { box = NIOLockedValueBox(start) }
    var now: Date { box.withLockedValue { $0 } }
    func advance(_ seconds: TimeInterval) { box.withLockedValue { $0 = $0.addingTimeInterval(seconds) } }
    var wall: WallClock { WallClock { [self] in self.now } }
}

final class FakeSession: RecordingSession, @unchecked Sendable {
    let request: CaptureRequest
    private let state = NIOLockedValueBox((frames: 0, started: false, stopped: false))
    let failStart: Bool
    let framesOnStart: Int
    var level: Double = 0.5

    init(request: CaptureRequest, failStart: Bool, framesOnStart: Int) {
        self.request = request
        self.failStart = failStart
        self.framesOnStart = framesOnStart
    }

    func start() async throws {
        if failStart { throw NSError(domain: "FakeRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permission denied"]) }
        try? FileManager.default.createDirectory(at: request.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: request.outputURL.path, contents: WAVHeader.make(format: 3, channels: 1, sampleRate: 16000, bitsPerSample: 32, dataBytes: 0))
        for c in request.channels ?? [] {
            FileManager.default.createFile(atPath: c.fileURL.path, contents: WAVHeader.make(format: 3, channels: 1, sampleRate: 16000, bitsPerSample: 32, dataBytes: 0))
        }
        state.withLockedValue { $0.started = true; $0.frames = framesOnStart }
    }

    func stop() async throws { state.withLockedValue { $0.stopped = true } }
    var framesCaptured: Int { state.withLockedValue { $0.frames } }
    var stopped: Bool { state.withLockedValue { $0.stopped } }
    func addFrames(_ n: Int) { state.withLockedValue { $0.frames += n } }

    func levels() -> LevelReading {
        if let channels = request.channels {
            let list = channels.map { LevelReading.ChannelLevel(channel: $0.channel, level: level) }
            return LevelReading(mic: level, system: nil, channels: list)
        }
        return LevelReading(mic: request.sources.contains("mic") ? level : nil, system: request.sources.contains("system") ? level : nil, channels: nil)
    }

    func channelBytes() -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: (request.channels ?? []).map { ($0.channel, framesCaptured * 4) })
    }
}

final class FakeRecordingEngine: RecordingEngine, @unchecked Sendable {
    let devices: [InputDeviceInfo]
    private let box = NIOLockedValueBox<(sessions: [FakeSession], failStart: Bool, framesOnStart: Int)>(([], false, 1600))

    init(devices: [InputDeviceInfo] = [
        InputDeviceInfo(uid: "BuiltIn", name: "MacBook Pro Microphone", isDefault: true, channels: 1, nominalSampleRate: 48000),
        InputDeviceInfo(uid: "USB8", name: "USB Audio Interface", isDefault: false, channels: 8, nominalSampleRate: 48000),
    ]) {
        self.devices = devices
    }

    var failStart: Bool {
        get { box.withLockedValue { $0.failStart } }
        set { box.withLockedValue { $0.failStart = newValue } }
    }
    var framesOnStart: Int {
        get { box.withLockedValue { $0.framesOnStart } }
        set { box.withLockedValue { $0.framesOnStart = newValue } }
    }
    var lastSession: FakeSession? { box.withLockedValue { $0.sessions.last } }

    func inputDevices() -> [InputDeviceInfo] { devices }

    func makeSession(_ request: CaptureRequest) throws -> any RecordingSession {
        box.withLockedValue { s in
            let session = FakeSession(request: request, failStart: s.failStart, framesOnStart: s.framesOnStart)
            s.sessions.append(session)
            return session
        }
    }
}

/// Holds an analysis until the test opens it.
final class Gate: @unchecked Sendable {
    private let box = NIOLockedValueBox<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
    func wait() async {
        await withCheckedContinuation { c in
            let resume = box.withLockedValue { s -> Bool in
                if s.open { return true }
                s.waiters.append(c)
                return false
            }
            if resume { c.resume() }
        }
    }
    func open() {
        let waiters = box.withLockedValue { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for w in waiters { w.resume() }
    }
}

/// Writes two speakers and three segments, or none (`empty`), or fails.
final class FakeAnalysisEngine: AnalysisEngine, @unchecked Sendable {
    enum Mode { case speech, empty, fail }
    let store: SpeakerStore
    private let box = NIOLockedValueBox<(mode: Mode, models: Bool, gate: Gate?, runs: [String])>((.speech, true, nil, []))

    init(store: SpeakerStore) { self.store = store }

    var mode: Mode {
        get { box.withLockedValue { $0.mode } }
        set { box.withLockedValue { $0.mode = newValue } }
    }
    var models: Bool {
        get { box.withLockedValue { $0.models } }
        set { box.withLockedValue { $0.models = newValue } }
    }
    var gate: Gate? {
        get { box.withLockedValue { $0.gate } }
        set { box.withLockedValue { $0.gate = newValue } }
    }
    var runs: [String] { box.withLockedValue { $0.runs } }

    func modelsAvailable() -> Bool { models }

    func analyze(recordingId: String, language: AppConfig.Language?, progress: @escaping @Sendable (String) -> Void) async throws -> AnalysisOutcome {
        box.withLockedValue { $0.runs.append(recordingId) }
        progress("Loading audio …")
        if let gate { await gate.wait() }
        progress("Transcribing 3 segments …")
        switch mode {
        case .fail:
            try store.setProcessingState(recordingId: recordingId, state: .failed, errorMessage: "fake failure")
            throw NSError(domain: "FakeAnalysis", code: 2, userInfo: [NSLocalizedDescriptionKey: "fake failure"])
        case .empty:
            try store.setProcessingState(recordingId: recordingId, state: .empty)
            return AnalysisOutcome(state: .empty, segmentCount: 0)
        case .speech:
            for id in ["spk_gm", "spk_anna"] where try store.speaker(id: id) == nil {
                try store.insertSpeaker(Speaker(id: id))
            }
            let segs = [
                RecordingSegment(recordingId: recordingId, speakerId: "spk_gm", startSec: 0.5, endSec: 3.0, text: "Ihr steht vor dem Tor.", confidence: 0.9),
                RecordingSegment(recordingId: recordingId, speakerId: "spk_anna", startSec: 3.2, endSec: 5.0, text: "Ist der Stein warm?", confidence: 0.8),
                RecordingSegment(recordingId: recordingId, speakerId: "spk_gm", startSec: 5.5, endSec: 7.0, text: "Der Wächter nickt.", confidence: 0.95),
            ]
            try store.replaceSegments(recordingId: recordingId, with: segs)
            try store.setProcessingState(recordingId: recordingId, state: .done)
            return AnalysisOutcome(state: .done, segmentCount: segs.count)
        }
    }
}

// MARK: - Harness

/// One server instance (services persist across requests) on a temp archive.
final class TestServer: @unchecked Sendable {
    let dir: URL
    let config: ServeConfig
    let clock: TestClock
    let recorder: FakeRecordingEngine
    let analysis: FakeAnalysisEngine
    let store: SpeakerStore
    let services: ServerServices
    let codes = NIOLockedValueBox<[String]>([])
    let logLines = NIOLockedValueBox<[String]>([])
    var controller: RecordingController { services.controller }
    var env: ServerEnvironment { services.env }

    init(
        origins: [String] = [cockpitOrigin, otherOrigin],
        validator: (any TokenValidator)? = StubTokenValidator(tokens: ["dz_good": cockpitOrigin]),
        timing: ServerEnvironment.Timing = .fast,
        freeBytes: Int64? = 500 * 1024 * 1024 * 1024,
        maxDurationSec: Double = 3600,
        maxUploadBytes: Int = 1024 * 1024,
        tokenFile: Bool = false
    ) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("diarize-serve-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        config = try makeTestConfig(origins: origins)
        clock = TestClock()
        let appConfig = AppConfig(archivePath: dir.appendingPathComponent("archive"), defaultLanguage: .de)
        try appConfig.ensureDirectories()
        store = try SpeakerStore(path: appConfig.databasePath)
        recorder = FakeRecordingEngine()
        analysis = FakeAnalysisEngine(store: store)
        let logs = logLines
        let env = ServerEnvironment(
            appConfig: appConfig, store: store, recordingEngine: recorder, analysisEngine: analysis,
            events: EventHub(pingInterval: .milliseconds(50)), clock: clock.wall, timing: timing,
            freeBytes: { _ in freeBytes }, maxDurationSec: maxDurationSec, maxUploadBytes: maxUploadBytes,
            log: { line in logs.withLockedValue { $0.append(line) } }
        )
        let codes = self.codes
        let pairing = PairingManager(clock: clock.wall, onNewCode: { code, _ in codes.withLockedValue { $0.append(code) } })
        let tokens = try TokenStore(fileURL: tokenFile ? dir.appendingPathComponent("config/serve-tokens.json") : nil, clock: clock.wall)
        services = ServerServices(validator: validator, tokens: tokens, pairing: pairing,
                                  controller: RecordingController(env: env), instanceId: env.sidecars.instanceId())
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var currentCode: String { services.pairing.currentCode }

    func send(
        _ method: HTTPRequest.Method,
        _ uri: String,
        headers extra: [String: String] = [:],
        host: String? = "127.0.0.1:\(testPort)",
        body: String? = nil,
        bytes: [UInt8]? = nil
    ) async throws -> Reply {
        let app = DiarizeHTTPServer.makeApplication(config: config, services: services)
        var fields = HTTPFields()
        if let host { fields[Hdr.host] = host }
        for (k, v) in extra { fields[HTTPField.Name(k)!] = v }
        let buffer = bytes.map { ByteBuffer(bytes: $0) } ?? body.map { ByteBuffer(string: $0) }
        let headers = fields
        return try await app.test(.router) { client in
            try await client.execute(uri: uri, method: method, headers: headers, body: buffer) { response in
                Reply(
                    status: Int(response.status.code),
                    headers: response.headers,
                    body: response.body.getString(at: response.body.readerIndex, length: response.body.readableBytes) ?? ""
                )
            }
        }
    }

    /// Authenticated JSON call with the stub token.
    func api(_ method: HTTPRequest.Method, _ uri: String, json: String? = nil, origin: String? = nil) async throws -> Reply {
        var h = ["Authorization": "Bearer dz_good"]
        if json != nil { h["Content-Type"] = "application/json" }
        if let origin { h["Origin"] = origin }
        return try await send(method, uri, headers: h, body: json)
    }

    /// Inserts a `recording` row as if another process (the app) had started it.
    func insertForeignRecording(fileAge: TimeInterval?) throws -> String {
        let id = "rec_foreign_" + UUID().uuidString.prefix(8)
        let path = env.appConfig.recordingsDir.appendingPathComponent("\(id).wav")
        if let fileAge {
            var data = WAVHeader.make(format: 3, channels: 1, sampleRate: 16000, bitsPerSample: 32, dataBytes: 0)
            data.append(Data(count: 16000 * 4))   // one second of silence, header left unpatched (crash)
            FileManager.default.createFile(atPath: path.path, contents: data)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-fileAge)], ofItemAtPath: path.path)
        }
        try store.insertEmptyRecording(Recording(id: id, title: "From the app", sourcePath: path.path, durationSec: 0, language: "de",
                                                 transcriptMd: dir.appendingPathComponent("\(id).md").path,
                                                 transcriptJson: dir.appendingPathComponent("\(id).json").path,
                                                 processingState: .recording))
        return id
    }
}

extension ServerEnvironment.Timing {
    static var fast: Self {
        var t = Self()
        t.levelInterval = .milliseconds(20)
        t.syncInterval = .milliseconds(40)
        t.clockPollInterval = .milliseconds(1)
        t.clockPollTimeout = .milliseconds(50)
        t.progressThrottleMs = 1000
        t.orphanQuietSeconds = 10
        return t
    }
}

/// Stateless convenience for the security tests: a fresh server per request.
func send(
    _ method: HTTPRequest.Method,
    _ uri: String,
    headers extra: [String: String] = [:],
    host: String? = "127.0.0.1:\(testPort)",
    origins: [String] = [cockpitOrigin, otherOrigin],
    validator: any TokenValidator = StubTokenValidator(tokens: ["dz_good": cockpitOrigin]),
    body: String? = nil
) async throws -> Reply {
    let server = try TestServer(origins: origins, validator: validator)
    return try await server.send(method, uri, headers: extra, host: host, body: body)
}

func waitUntil(timeout: Duration = .seconds(3), _ condition: @Sendable () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return try await condition()
}
