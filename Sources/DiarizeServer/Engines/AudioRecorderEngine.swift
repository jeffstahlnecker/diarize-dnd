import CoreAudio
import DiarizeCore
import Foundation

/// Production `RecordingEngine`.
/// - Single source (`mic`, `system`, or both): `DiarizeCore.AudioRecorder`, unchanged, as the app and `diarize record` use it.
/// - Multichannel (`channelMap`): `MultichannelSession`, one file per mapped input channel plus a 16 kHz mixdown.
public struct AudioRecorderEngine: RecordingEngine {
    public init() {}

    public func inputDevices() -> [InputDeviceInfo] {
        let defaultUID = AudioInputDevices.systemDefault()?.uid
        return AudioInputDevices.all().map { device in
            InputDeviceInfo(
                uid: device.uid,
                name: device.name,
                isDefault: device.uid == defaultUID,
                channels: DeviceProbe.inputChannelCount(device.deviceID),
                nominalSampleRate: DeviceProbe.nominalSampleRate(device.deviceID)
            )
        }
    }

    public func makeSession(_ request: CaptureRequest) throws -> any RecordingSession {
        if let channels = request.channels, !channels.isEmpty {
            return try MultichannelSession(request: request)
        }
        var sources: Set<AudioRecorder.Source> = []
        if request.sources.contains("mic") { sources.insert(.mic) }
        if request.sources.contains("system") { sources.insert(.system) }
        let recorder = try AudioRecorder(config: .init(sources: sources, outputURL: request.outputURL, micDeviceUID: request.micDeviceUID))
        return SingleSourceSession(recorder: recorder, sources: sources)
    }
}

final class SingleSourceSession: RecordingSession, @unchecked Sendable {
    let recorder: AudioRecorder
    let sources: Set<AudioRecorder.Source>

    init(recorder: AudioRecorder, sources: Set<AudioRecorder.Source>) {
        self.recorder = recorder
        self.sources = sources
    }

    func start() async throws { try await recorder.start() }
    func stop() async throws { try await recorder.stop() }

    var framesCaptured: Int {
        let received = recorder.samplesReceived
        return max(received[.mic] ?? 0, received[.system] ?? 0)
    }

    func levels() -> LevelReading {
        LevelReading(
            mic: sources.contains(.mic) ? recorder.meter.level(.mic) : nil,
            system: sources.contains(.system) ? recorder.meter.level(.system) : nil,
            channels: nil
        )
    }
}

/// CoreAudio properties that `AudioInputDevices` does not expose.
enum DeviceProbe {
    static func inputChannelCount(_ deviceID: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalSampleRate(_ deviceID: AudioObjectID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }
}
