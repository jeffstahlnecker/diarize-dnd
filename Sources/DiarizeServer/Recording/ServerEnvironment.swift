import DiarizeCore
import Foundation

/// Everything the routes and the recording controller need, injectable for tests.
public struct ServerEnvironment: Sendable {
    public struct Timing: Sendable {
        /// `levels` events while recording.
        public var levelInterval: Duration = .milliseconds(100)
        /// `(wallMs, audioSec)` sync points while recording.
        public var syncInterval: Duration = .seconds(30)
        /// How often and how long to poll the recorder for the first samples (clock measurement).
        public var clockPollInterval: Duration = .milliseconds(10)
        public var clockPollTimeout: Duration = .seconds(2)
        /// At most one `progress` event per recording per interval.
        public var progressThrottleMs: Int64 = 1000
        /// A `recording` row whose audio file has not been written for this long is an orphan (crashed process).
        public var orphanQuietSeconds: Double = 10
        public init() {}
    }

    public var appConfig: AppConfig
    public var store: SpeakerStore
    public var sidecars: SidecarStore
    public var recordingEngine: any RecordingEngine
    public var analysisEngine: any AnalysisEngine
    public var events: EventHub
    public var clock: WallClock
    public var timing: Timing
    /// Free bytes on the archive volume (`nil` when unknown).
    public var freeBytes: @Sendable (URL) -> Int64?
    public var minFreeBytes: Int64
    public var maxDurationSec: Double
    public var maxUploadBytes: Int
    /// One terminal line (pairings, recording starts and stops).
    public var log: @Sendable (String) -> Void

    public init(
        appConfig: AppConfig,
        store: SpeakerStore,
        recordingEngine: any RecordingEngine,
        analysisEngine: any AnalysisEngine,
        events: EventHub = EventHub(),
        clock: WallClock = .system,
        timing: Timing = Timing(),
        freeBytes: @escaping @Sendable (URL) -> Int64? = ServerEnvironment.volumeFreeBytes,
        minFreeBytes: Int64 = 2 * 1024 * 1024 * 1024,
        maxDurationSec: Double = 10 * 3600,
        maxUploadBytes: Int = 2048 * 1024 * 1024,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.appConfig = appConfig
        self.store = store
        self.sidecars = SidecarStore(archivePath: appConfig.archivePath)
        self.recordingEngine = recordingEngine
        self.analysisEngine = analysisEngine
        self.events = events
        self.clock = clock
        self.timing = timing
        self.freeBytes = freeBytes
        self.minFreeBytes = minFreeBytes
        self.maxDurationSec = maxDurationSec
        self.maxUploadBytes = maxUploadBytes
        self.log = log
    }

    public static let volumeFreeBytes: @Sendable (URL) -> Int64? = { url in
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let v = values?.volumeAvailableCapacityForImportantUsage, v > 0 { return v }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Production wiring: real recorder and pipeline over the configured archive.
    public static func production(appConfig: AppConfig, maxDurationSec: Double, maxUploadBytes: Int,
                                  log: @escaping @Sendable (String) -> Void) throws -> ServerEnvironment {
        try appConfig.ensureDirectories()
        let store = try SpeakerStore(path: appConfig.databasePath)
        return ServerEnvironment(
            appConfig: appConfig, store: store,
            recordingEngine: AudioRecorderEngine(),
            analysisEngine: PipelineAnalysisEngine(config: appConfig, store: store),
            maxDurationSec: maxDurationSec, maxUploadBytes: maxUploadBytes, log: log
        )
    }
}
