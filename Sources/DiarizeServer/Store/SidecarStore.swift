import Foundation

/// Server-only data per recording that the database schema has no column for.
/// Lives in `<archive>/serve/<recordingId>.json`, written atomically. Nothing here is required by the
/// app or the CLI; a recording without a sidecar is rendered with defaults (clock source `createdAt`).
public struct Sidecar: Codable, Sendable, Equatable {
    public struct SyncPoint: Codable, Sendable, Equatable {
        public var wallMs: Int64
        public var audioSec: Double
    }

    public struct Clock: Codable, Sendable, Equatable {
        public var audioStartedAtMs: Int64
        /// `recorder`, `client` or `createdAt`.
        public var source: String
        /// True when no samples arrived within the measuring window and the start time is only approximate.
        public var imprecise: Bool
        public var syncPoints: [SyncPoint]
    }

    public struct Channel: Codable, Sendable, Equatable {
        public var channel: Int
        public var label: String
        public var key: String?
        /// File name inside the recording's folder (`ch01.wav`).
        public var file: String
        public var audioDeletedAt: Date?
    }

    public var recordingId: String
    public var clientRef: String?
    public var sources: [String]
    public var transcribe: String
    public var deleteAudioWhenDone: Bool
    public var clientMeta: JSONValue?
    public var captureQuality: String
    public var bleed: String
    public var micDeviceUID: String?
    public var channels: [Channel]?
    public var clock: Clock?
    public var stoppedAtMs: Int64?
    /// Capture is over and the recording waits for `POST .../transcribe` (`transcribe: "manual"`). Rendered as state `stopped`.
    public var awaitingTranscribe: Bool
    /// Multichannel: dominant input channel per segment id.
    public var segmentChannels: [String: Int]?
    public var startedBy: String?

    public init(recordingId: String, clientRef: String? = nil, sources: [String] = ["mic"], transcribe: String = "onStop",
                deleteAudioWhenDone: Bool = false, clientMeta: JSONValue? = nil, captureQuality: String = "asr",
                bleed: String = "suppress", micDeviceUID: String? = nil, channels: [Channel]? = nil, clock: Clock? = nil,
                stoppedAtMs: Int64? = nil, awaitingTranscribe: Bool = false, segmentChannels: [String: Int]? = nil,
                startedBy: String? = nil) {
        self.recordingId = recordingId
        self.clientRef = clientRef
        self.sources = sources
        self.transcribe = transcribe
        self.deleteAudioWhenDone = deleteAudioWhenDone
        self.clientMeta = clientMeta
        self.captureQuality = captureQuality
        self.bleed = bleed
        self.micDeviceUID = micDeviceUID
        self.channels = channels
        self.clock = clock
        self.stoppedAtMs = stoppedAtMs
        self.awaitingTranscribe = awaitingTranscribe
        self.segmentChannels = segmentChannels
        self.startedBy = startedBy
    }
}

public final class SidecarStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(archivePath: URL) {
        directory = archivePath.appendingPathComponent("serve", isDirectory: true)
    }

    private func url(_ id: String) -> URL {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return directory.appendingPathComponent("\(safe).json")
    }

    public func read(_ id: String) -> Sidecar? {
        lock.withLock {
            guard let data = try? Data(contentsOf: url(id)) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Sidecar.self, from: data)
        }
    }

    public func write(_ sidecar: Sidecar) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try AtomicFile.write(try encoder.encode(sidecar), to: url(sidecar.recordingId))
        }
    }

    /// Read-modify-write under the store lock.
    @discardableResult
    public func update(_ id: String, _ body: (inout Sidecar) -> Void) throws -> Sidecar {
        var s = read(id) ?? Sidecar(recordingId: id)
        body(&s)
        try write(s)
        return s
    }

    public func delete(_ id: String) {
        lock.withLock { try? FileManager.default.removeItem(at: url(id)) }
    }

    /// A random id for this archive, created on first use (`<archive>/serve/instance-id`).
    public func instanceId() -> String {
        lock.withLock {
            let file = directory.appendingPathComponent("instance-id")
            if let s = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
            let id = UUID().uuidString.lowercased()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? AtomicFile.write(Data(id.utf8), to: file)
            return id
        }
    }
}
