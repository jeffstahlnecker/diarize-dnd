import DiarizeCore
import Foundation

/// An input device as listed in `GET /v1/capabilities`.
public struct InputDeviceInfo: Sendable, Equatable {
    public var uid: String
    public var name: String
    public var isDefault: Bool
    public var channels: Int
    public var nominalSampleRate: Double

    public init(uid: String, name: String, isDefault: Bool, channels: Int, nominalSampleRate: Double) {
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
        self.channels = channels
        self.nominalSampleRate = nominalSampleRate
    }

    var json: JSONValue {
        ["uid": .string(uid), "name": .string(name), "isDefault": .bool(isDefault),
         "channels": .int(channels), "nominalSampleRate": .number(nominalSampleRate)]
    }
}

/// What the server asks a recording engine to capture.
public struct CaptureRequest: Sendable {
    public struct Channel: Sendable, Equatable {
        /// 1-based input channel of the device.
        public var channel: Int
        public var fileURL: URL
    }

    public var sources: Set<String>
    public var micDeviceUID: String?
    /// The recording's primary audio file (16 kHz mono Float32 WAV; the mixdown in multichannel mode).
    public var outputURL: URL
    /// Multichannel mode: one file per mapped input channel.
    public var channels: [Channel]?
    /// `asr` (16 kHz Float32) or `archive` (device rate, at most 48 kHz, 16-bit PCM). Multichannel only.
    public var captureQuality: String
}

/// Live input levels in 0...1 (perceptual). `nil` = source not captured.
public struct LevelReading: Sendable, Equatable {
    public var mic: Double?
    public var system: Double?
    public var channels: [ChannelLevel]?

    public struct ChannelLevel: Sendable, Equatable {
        public var channel: Int
        public var level: Double
    }

    public init(mic: Double?, system: Double?, channels: [ChannelLevel]?) {
        self.mic = mic
        self.system = system
        self.channels = channels
    }
}

/// One running capture.
public protocol RecordingSession: AnyObject, Sendable {
    func start() async throws
    func stop() async throws
    /// Frames on the recording's 16 kHz timeline captured so far (audio position = frames / 16000).
    var framesCaptured: Int { get }
    func levels() -> LevelReading
    /// Bytes written per mapped channel (multichannel only).
    func channelBytes() -> [Int: Int]
}

extension RecordingSession {
    public func channelBytes() -> [Int: Int] { [:] }
}

/// Seam over the real recorder (`AudioRecorderEngine`) so tests run without a microphone.
public protocol RecordingEngine: Sendable {
    func inputDevices() -> [InputDeviceInfo]
    func makeSession(_ request: CaptureRequest) throws -> any RecordingSession
}

public struct AnalysisOutcome: Sendable, Equatable {
    public var state: RecordingProcessingState
    public var segmentCount: Int
    public init(state: RecordingProcessingState, segmentCount: Int) {
        self.state = state
        self.segmentCount = segmentCount
    }
}

/// Seam over `TranscribePipeline.analyzeExisting` so tests run without Core ML models.
/// Contract: on success the recording row is `done` or `empty` with segments persisted; on failure it may be `failed`.
public protocol AnalysisEngine: Sendable {
    /// Whether models can be loaded (checked before a recording with `transcribe: "onStop"` starts).
    func modelsAvailable() -> Bool
    func analyze(recordingId: String, language: AppConfig.Language?, progress: @escaping @Sendable (String) -> Void) async throws -> AnalysisOutcome
}

/// Audio positions of the recording timeline.
public enum Timeline {
    public static let sampleRate = 16_000.0
}
