import DiarizeCore
import Foundation

/// Production `AnalysisEngine`: runs `TranscribePipeline.analyzeExisting` (diarization, speaker matching, ASR),
/// exactly what the app does after a live recording.
public struct PipelineAnalysisEngine: AnalysisEngine {
    let config: AppConfig
    let store: SpeakerStore

    public init(config: AppConfig, store: SpeakerStore) {
        self.config = config
        self.store = store
    }

    /// FluidAudio downloads missing models on first use, so the pipeline can always try.
    public func modelsAvailable() -> Bool { true }

    public func analyze(recordingId: String, language: AppConfig.Language?, progress: @escaping @Sendable (String) -> Void) async throws -> AnalysisOutcome {
        let bridge = ProgressBridge(progress)
        let pipeline = TranscribePipeline(config: config, store: store, progress: bridge)
        let output = try await pipeline.analyzeExisting(recordingId: recordingId, language: language)
        let state = (try? store.recording(id: recordingId))?.processingState ?? output.recording.processingState
        return AnalysisOutcome(state: state, segmentCount: output.segments.count)
    }
}

private final class ProgressBridge: DiarizeCore.ProgressReporter, @unchecked Sendable {
    let forward: @Sendable (String) -> Void
    init(_ forward: @escaping @Sendable (String) -> Void) { self.forward = forward }
    func step(_ message: String) { forward(message) }
}

/// Maps the pipeline's step messages to an approximate overall fraction (`nil` when unknown).
public enum ProgressEstimate {
    public static func fraction(for step: String) -> Double? {
        let s = step.lowercased()
        let table: [(String, Double)] = [
            ("computing source hash", 0.02), ("hash:", 0.03), ("loading audio", 0.05),
            ("loading diarization models", 0.08), ("running diarization", 0.12), ("stereo split", 0.14),
            ("diarized:", 0.35), ("speaker matching", 0.4), ("loading asr models", 0.45),
            ("transcribing", 0.5), ("persisting", 0.95),
        ]
        for (prefix, value) in table where s.hasPrefix(prefix) { return value }
        return nil
    }
}
