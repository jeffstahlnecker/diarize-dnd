import DiarizeCore
import Foundation

/// Owns the one active capture, the analysis queue and the rendering of recordings.
/// All recording rows are ordinary `recordings` rows in the archive database (the app shows them);
/// server-only data lives in sidecar files (`SidecarStore`).
public actor RecordingController {
    struct Active {
        var id: String
        var session: any RecordingSession
        var tasks: [Task<Void, Never>] = []
    }

    struct Progress {
        var step: String
        var fraction: Double?
        var t: Int64
    }

    public let env: ServerEnvironment
    private var active: Active?
    /// Set while a start is in flight (actor re-entrancy across the recorder's `start()`).
    private var starting = false
    private var progress: [String: Progress] = [:]
    private var throttles: [String: Throttle] = [:]
    private var queued: Set<String> = []
    private var analysisTail: Task<Void, Never>?

    public init(env: ServerEnvironment) {
        self.env = env
    }

    var store: SpeakerStore { env.store }
    var sidecars: SidecarStore { env.sidecars }

    // MARK: - Start

    public func start(_ body: [String: JSONValue], origin: String?, clientName: String?) async throws -> JSONValue {
        let req = try StartValidation.validate(body, devices: env.recordingEngine.inputDevices())

        if starting { throw APIError.conflictRecordingActive(recordingId: active?.id ?? "starting") }
        if let active { throw APIError.conflictRecordingActive(recordingId: active.id) }
        if let other = try store.recordingInProgress().first { throw APIError.conflictRecordingActive(recordingId: other.id) }
        if let free = env.freeBytes(env.appConfig.archivePath), free < env.minFreeBytes {
            throw APIError.insufficientStorage(freeBytes: free)
        }
        if req.transcribe == "onStop", !env.analysisEngine.modelsAvailable() { throw APIError.modelsUnavailable() }

        starting = true
        defer { starting = false }

        try env.appConfig.ensureDirectories()
        let now = env.clock.now()
        let stamp = Self.stamp(now)
        let id = "rec_" + UUID().uuidString
        let title = req.title ?? "Recording \(Self.human(now))"
        let language = req.language ?? env.appConfig.defaultLanguage.rawValue

        var sidecarChannels: [Sidecar.Channel]?
        var captureChannels: [CaptureRequest.Channel]?
        let outputURL: URL
        if let map = req.channelMap {
            let dir = env.appConfig.recordingsDir.appendingPathComponent("rec-\(stamp)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            outputURL = dir.appendingPathComponent("mix.wav")
            sidecarChannels = map.map { .init(channel: $0.channel, label: $0.label, key: $0.key, file: String(format: "ch%02d.wav", $0.channel)) }
            captureChannels = map.map { .init(channel: $0.channel, fileURL: dir.appendingPathComponent(String(format: "ch%02d.wav", $0.channel))) }
        } else {
            outputURL = Self.uniqueURL(env.appConfig.recordingsDir.appendingPathComponent("rec-\(stamp).wav"))
        }

        let baseName = "\(stamp)-recording"
        let stub = Recording(
            id: id, title: title, sourcePath: outputURL.path, durationSec: 0, language: language,
            transcriptMd: env.appConfig.transcriptsDir.appendingPathComponent("\(baseName).md").path,
            transcriptJson: env.appConfig.transcriptsDir.appendingPathComponent("\(baseName).json").path,
            createdAt: now, sourceHash: nil, processingState: .recording
        )
        try store.insertEmptyRecording(stub)
        let sidecar = Sidecar(
            recordingId: id, clientRef: req.clientRef, sources: req.sources.sorted(), transcribe: req.transcribe,
            deleteAudioWhenDone: req.deleteAudioWhenDone, clientMeta: req.clientMeta,
            captureQuality: req.channelMap == nil ? "asr" : req.captureQuality, bleed: req.bleed,
            micDeviceUID: req.micDeviceUID, channels: sidecarChannels,
            startedBy: [clientName.map { "\"\($0)\"" }, origin.map { "from \($0)" }].compactMap { $0 }.joined(separator: " ")
        )
        try sidecars.write(sidecar)

        let session: any RecordingSession
        do {
            session = try env.recordingEngine.makeSession(CaptureRequest(
                sources: req.sources, micDeviceUID: req.micDeviceUID, outputURL: outputURL,
                channels: captureChannels, captureQuality: req.captureQuality))
            active = Active(id: id, session: session)
            try await session.start()
        } catch {
            active = nil
            try? store.deleteRecording(id: id)
            sidecars.delete(id)
            try? FileManager.default.removeItem(at: outputURL)
            for c in captureChannels ?? [] { try? FileManager.default.removeItem(at: c.fileURL) }
            if req.channelMap != nil { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
            throw APIError.captureFailed("Could not start the recorder: \(error.localizedDescription)", hint: Self.captureHint)
        }

        let returnedMs = env.clock.nowMs
        let clock = await measureClock(session: session, fallbackMs: returnedMs)
        try? sidecars.update(id) { $0.clock = clock }
        startBackgroundTasks(id: id, session: session)

        let who = sidecar.startedBy.flatMap { $0.isEmpty ? nil : " by \($0)" } ?? ""
        env.log("Recording \(id) started\(who) -> \(outputURL.path)")
        let dto = try render(id: id, withSync: true)
        env.events.publish("state", ["recording": try render(id: id, withSync: false)])
        return dto
    }

    /// `audioStartedAtMs = now - samples/16000`, measured as soon as the first samples arrive.
    private func measureClock(session: any RecordingSession, fallbackMs: Int64) async -> Sidecar.Clock {
        let deadline = ContinuousClock.now + env.timing.clockPollTimeout
        while ContinuousClock.now < deadline {
            let frames = session.framesCaptured
            if frames > 0 {
                let startMs = env.clock.nowMs - Int64((Double(frames) / Timeline.sampleRate * 1000).rounded())
                return .init(audioStartedAtMs: startMs, source: "recorder", imprecise: false,
                             syncPoints: [.init(wallMs: startMs, audioSec: 0)])
            }
            try? await Task.sleep(for: env.timing.clockPollInterval)
        }
        return .init(audioStartedAtMs: fallbackMs, source: "recorder", imprecise: true, syncPoints: [.init(wallMs: fallbackMs, audioSec: 0)])
    }

    private func startBackgroundTasks(id: String, session: any RecordingSession) {
        let events = env.events
        let clock = env.clock
        let timing = env.timing
        let sidecars = env.sidecars
        let levels = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: timing.levelInterval)
                if Task.isCancelled { break }
                events.publish("levels", Self.levelsEvent(id: id, t: clock.nowMs, reading: session.levels()))
            }
        }
        let sync = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: timing.syncInterval)
                if Task.isCancelled { break }
                let point = Sidecar.SyncPoint(wallMs: clock.nowMs, audioSec: Self.round(Double(session.framesCaptured) / Timeline.sampleRate, 3))
                try? sidecars.update(id) { $0.clock?.syncPoints.append(point) }
            }
        }
        let maxSec = env.maxDurationSec
        let limit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(maxSec))
            if Task.isCancelled { return }
            await self?.stopForLimit(id: id)
        }
        active?.tasks = [levels, sync, limit]
    }

    private func stopForLimit(id: String) async {
        guard active?.id == id else { return }
        env.log("Recording \(id) reached the maximum duration; stopping.")
        _ = try? await stop(id: id)
    }

    /// `levels` payload. In multichannel mode `channels` carries the per-channel levels, `mic` is their maximum
    /// (for clients that draw one meter) and `system` is null.
    static func levelsEvent(id: String, t: Int64, reading: LevelReading) -> JSONValue {
        func lv(_ v: Double?) -> JSONValue { v.map { .double(max(0, min(1, $0)), places: 3) } ?? .null }
        let channels: JSONValue = reading.channels.map { list in
            .array(list.map { ["channel": .int($0.channel), "level": lv($0.level)] })
        } ?? .null
        return ["recordingId": .string(id), "t": .int(t), "mic": lv(reading.mic), "system": lv(reading.system), "channels": channels]
    }

    // MARK: - Stop

    public func stop(id: String) async throws -> JSONValue {
        if let current = active, current.id == id {
            for t in current.tasks { t.cancel() }
            active = nil
            let session = current.session
            try? await session.stop()
            let frames = session.framesCaptured
            let nowMs = env.clock.nowMs
            let audioSec = Self.round(Double(frames) / Timeline.sampleRate, 3)
            try? store.updateRecordingDuration(id: id, durationSec: audioSec)
            let sidecar = try? sidecars.update(id) {
                $0.stoppedAtMs = nowMs
                if frames > 0 { $0.clock?.syncPoints.append(.init(wallMs: nowMs, audioSec: audioSec)) }
            }
            env.log("Recording \(id) stopped after \(String(format: "%.1f", audioSec)) s of audio.")
            if frames == 0 {
                try store.setProcessingState(recordingId: id, state: .failed, errorMessage: Self.noSamplesMessage)
                publishState(id)
                env.events.publish("error", ["recordingId": .string(id), "error": ["code": "capture_failed", "message": .string(Self.noSamplesMessage)]])
                return try render(id: id, withSync: true)
            }
            try finishCapture(id: id, manual: sidecar?.transcribe == "manual")
            return try render(id: id, withSync: true)
        }

        guard let recording = try store.recording(id: id) else { throw APIError.notFound("Unknown recording.") }
        guard recording.processingState == .recording else {
            let state = stateName(recording, sidecars.read(id))
            throw APIError.wrongState(state, message: "The recording is not running (state \(state)).")
        }
        guard isOrphan(recording) else {
            throw APIError.wrongState("recording", reason: "recording_in_other_process",
                                      message: "This recording is being captured by another process (the app or the CLI); stop it there.")
        }
        return try stopOrphan(recording)
    }

    /// A recording left in `recording` state by a crashed process: repair its WAV header(s) and analyse what was written.
    private func stopOrphan(_ recording: Recording) throws -> JSONValue {
        let id = recording.id
        let sidecar = sidecars.read(id)
        let url = URL(fileURLWithPath: recording.sourcePath)
        let info = WAVHeader.repair(url: url).flatMap { _ in WAVInfo.read(url) }
        if let dir = sidecar?.channels.map({ _ in url.deletingLastPathComponent() }) {
            for c in sidecar?.channels ?? [] { WAVHeader.repair(url: dir.appendingPathComponent(c.file)) }
        }
        let nowMs = env.clock.nowMs
        try sidecars.update(id) { $0.stoppedAtMs = nowMs }
        guard let info, info.durationSec > 0 else {
            let msg = "The recording was interrupted and no audio was written."
            try store.setProcessingState(recordingId: id, state: .failed, errorMessage: msg)
            publishState(id)
            return try render(id: id, withSync: true)
        }
        try store.updateRecordingDuration(id: id, durationSec: Self.round(info.durationSec, 3))
        env.log("Orphaned recording \(id) stopped; \(String(format: "%.1f", info.durationSec)) s of audio recovered.")
        try finishCapture(id: id, manual: sidecar?.transcribe == "manual")
        return try render(id: id, withSync: true)
    }

    private func finishCapture(id: String, manual: Bool) throws {
        if manual {
            try store.setProcessingState(recordingId: id, state: .failed, errorMessage: Self.manualMessage(id))
            try sidecars.update(id) { $0.awaitingTranscribe = true }
            publishState(id)
        } else {
            try store.setProcessingState(recordingId: id, state: .analyzing)
            enqueueAnalysis(id)
        }
    }

    // MARK: - Transcribe

    public func transcribe(id: String) throws -> JSONValue {
        guard let recording = try store.recording(id: id) else { throw APIError.notFound("Unknown recording.") }
        let sidecar = sidecars.read(id)
        let state = stateName(recording, sidecar)
        guard ["stopped", "failed", "empty"].contains(state), !queued.contains(id) else {
            throw APIError.wrongState(state, message: "Analysis can only be started in state stopped, failed or empty.")
        }
        guard recording.hasAudio, FileManager.default.fileExists(atPath: recording.sourcePath) else {
            throw APIError.wrongState(state, reason: "audio_deleted", message: "The audio of this recording was deleted.")
        }
        try sidecars.update(id) { $0.awaitingTranscribe = false }
        try store.setProcessingState(recordingId: id, state: .analyzing)
        enqueueAnalysis(id)
        return try render(id: id, withSync: true)
    }

    // MARK: - Analysis queue (one at a time)

    private func enqueueAnalysis(_ id: String) {
        queued.insert(id)
        progress[id] = Progress(step: "Queued", fraction: 0, t: env.clock.nowMs)
        publishState(id)
        let previous = analysisTail
        analysisTail = Task { [weak self] in
            await previous?.value
            await self?.runAnalysis(id)
        }
    }

    /// Waits until every queued analysis has finished (tests, shutdown).
    public func waitForAnalyses() async {
        while let tail = analysisTail {
            await tail.value
            if analysisTail == nil || queued.isEmpty { break }
        }
    }

    private func runAnalysis(_ id: String) async {
        defer {
            queued.remove(id)
            progress[id] = nil
            throttles[id] = nil
        }
        guard let recording = try? store.recording(id: id) else { return }
        let language = AppConfig.Language(rawValue: recording.language)
        reportProgress(id, "Starting analysis")
        do {
            let outcome = try await env.analysisEngine.analyze(recordingId: id, language: language) { [weak self] step in
                Task { await self?.reportProgress(id, step) }
            }
            if let channels = sidecars.read(id)?.channels, !channels.isEmpty {
                let dir = URL(fileURLWithPath: recording.sourcePath).deletingLastPathComponent()
                let segments = (try? store.segments(for: id)) ?? []
                let map = await Task.detached { ChannelAttribution.dominantChannels(segments: segments, dir: dir, channels: channels) }.value
                try? sidecars.update(id) { $0.segmentChannels = map }
            }
            if sidecars.read(id)?.deleteAudioWhenDone == true {
                try? deleteAllAudio(id)
                env.log("Recording \(id): audio deleted after analysis (deleteAudioWhenDone).")
            }
            queued.remove(id)
            progress[id] = nil
            publishState(id)
            let state = (try? store.recording(id: id))?.processingState ?? outcome.state
            env.events.publish("ready", ["recordingId": .string(id), "state": .string(state.rawValue), "segmentCount": .int(outcome.segmentCount)])
            env.log("Recording \(id): analysis \(state.rawValue), \(outcome.segmentCount) segments.")
        } catch {
            let message = error.localizedDescription
            if let r = try? store.recording(id: id), r.processingState == .analyzing {
                try? store.setProcessingState(recordingId: id, state: .failed, errorMessage: message)
            }
            queued.remove(id)
            progress[id] = nil
            publishState(id)
            env.events.publish("error", ["recordingId": .string(id), "error": ["code": "internal", "message": .string(message)]])
            env.log("Recording \(id): analysis failed: \(message)")
        }
    }

    private func reportProgress(_ id: String, _ step: String) {
        guard queued.contains(id) else { return }
        let now = env.clock.nowMs
        let fraction = ProgressEstimate.fraction(for: step)
        progress[id] = Progress(step: step, fraction: fraction, t: now)
        var throttle = throttles[id] ?? Throttle(intervalMs: env.timing.progressThrottleMs)
        if throttle.allow(atMs: now) {
            env.events.publish("progress", ["recordingId": .string(id), "t": .int(now), "step": .string(step), "fraction": fraction.map { .double($0, places: 2) } ?? .null])
        }
        throttles[id] = throttle
    }

    private func publishState(_ id: String) {
        if let dto = try? render(id: id, withSync: false) { env.events.publish("state", ["recording": dto]) }
    }

    // MARK: - Read

    public func get(id: String) throws -> JSONValue { try render(id: id, withSync: true) }

    public struct ListQuery: Sendable {
        public var clientRef: String?
        public var state: String?
        public var limit: Int
        public var before: Date?
        public init(clientRef: String? = nil, state: String? = nil, limit: Int = 20, before: Date? = nil) {
            self.clientRef = clientRef
            self.state = state
            self.limit = limit
            self.before = before
        }
    }

    /// Newest first. Items omit `clock.syncPoints` (fetch one recording or its transcript for those).
    public func list(_ q: ListQuery) throws -> JSONValue {
        var rows = try store.allRecordings().sorted { $0.createdAt > $1.createdAt }
        if let before = q.before { rows = rows.filter { $0.createdAt < before } }
        var picked: [(Recording, Sidecar?)] = []
        var more = false
        for r in rows {
            let sc = sidecars.read(r.id)
            if let ref = q.clientRef, sc?.clientRef != ref { continue }
            if let state = q.state, stateName(r, sc) != state { continue }
            if picked.count == q.limit { more = true; break }
            picked.append((r, sc))
        }
        let items = picked.map { render($0.0, $0.1, withSync: false) }
        let next: JSONValue = more ? .iso(picked.last?.0.createdAt) : .null
        return ["recordings": .array(items), "nextBefore": next]
    }

    public func transcript(id: String, includeBleed: Bool) throws -> JSONValue {
        guard let r = try store.recording(id: id) else { throw APIError.notFound("Unknown recording.") }
        let sc = sidecars.read(id)
        let state = stateName(r, sc)
        if state == "recording" || state == "analyzing" { throw APIError.notReady(state: state) }
        let segments = try store.segments(for: id).sorted { $0.startSec < $1.startSec }
        var labels: [String: String?] = [:]
        for sid in Set(segments.compactMap(\.speakerId)) { labels[sid] = (try? store.speaker(id: sid))??.label }
        let segChannels = sc?.segmentChannels ?? [:]

        var segJSON: [JSONValue] = []
        struct Acc { var count = 0; var sec = 0.0; var channels: [Int: Int] = [:] }
        var acc: [String: Acc] = [:]
        var order: [String] = []
        for s in segments {
            let channel = s.id.flatMap { segChannels[String($0)] }
            // The mixdown is analysed, so every utterance is one segment and none is cross-talk of another:
            // `bleed` is always false and `includeBleed` changes nothing (see docs/http-api.md, Multichannel).
            let bleed = false
            let sid = s.speakerId ?? "spk_unknown"
            segJSON.append([
                "id": s.id.map { .int($0) } ?? .null, "start": .double(s.startSec), "end": .double(s.endSec),
                "speakerId": .str(s.speakerId), "speakerLabel": .str(s.speakerId.flatMap { labels[$0] ?? nil }),
                "text": .string(s.text), "confidence": s.confidence.map { .double($0) } ?? .null,
                "channel": channel.map { .int($0) } ?? .null, "bleed": .bool(bleed),
            ])
            if acc[sid] == nil { order.append(sid) }
            acc[sid, default: Acc()].count += 1
            acc[sid, default: Acc()].sec += s.endSec - s.startSec
            if let channel { acc[sid, default: Acc()].channels[channel, default: 0] += 1 }
        }
        let speakers: [JSONValue] = order.map { sid in
            let a = acc[sid]!
            let channel = a.channels.max { $0.value < $1.value }?.key
            return ["id": .string(sid), "label": .str(labels[sid] ?? nil), "segmentCount": .int(a.count),
                    "speechSec": .double(a.sec, places: 1), "channel": channel.map { .int($0) } ?? .null]
        }
        let transcript: JSONValue = [
            "recordingId": .string(id), "title": .str(r.title), "language": .string(r.language),
            "durationSec": .double(r.durationSec), "createdAt": .iso(r.createdAt),
            "speakers": .array(speakers), "segments": .array(segJSON),
        ]
        return ["recording": render(r, sc, withSync: true), "transcript": transcript]
    }

    /// The active recording, or one being captured by another process (app, CLI), else nil.
    public func current() throws -> JSONValue {
        if let active { return try render(id: active.id, withSync: false) }
        for r in try store.recordingInProgress() where !isOrphan(r) {
            return render(r, sidecars.read(r.id), withSync: false)
        }
        return .null
    }

    public func orphans() throws -> [JSONValue] {
        try store.recordingInProgress().filter { isOrphan($0) }.map { render($0, sidecars.read($0.id), withSync: false) }
    }

    public var activeRecordingId: String? { active?.id }

    // MARK: - Modify

    public func patch(id: String, body: [String: JSONValue]) throws -> JSONValue {
        guard try store.recording(id: id) != nil else { throw APIError.notFound("Unknown recording.") }
        var fields: [(String, String)] = []
        var title: String?
        if let t = body["title"] {
            if let s = t.stringValue, (1...200).contains(s.count) { title = s } else { fields.append(("title", "1..200 characters")) }
        }
        var meta: JSONValue??
        if let m = body["clientMeta"] {
            if m.isNull { meta = .some(nil) }
            else if m.objectValue != nil, m.encodedByteCount <= StartValidation.clientMetaLimit { meta = .some(m) }
            else { fields.append(("clientMeta", "an object of at most 4 KiB serialised, or null")) }
        }
        if !fields.isEmpty { throw APIError.validationFailed(fields, message: "Invalid recording fields.") }
        if let title { try store.updateRecordingTitle(id: id, title: title) }
        if let meta { try sidecars.update(id) { $0.clientMeta = meta } }
        publishState(id)
        return try render(id: id, withSync: true)
    }

    public func deleteAudio(id: String, channel: Int?) throws -> JSONValue {
        guard let r = try store.recording(id: id) else { throw APIError.notFound("Unknown recording.") }
        let sc = sidecars.read(id)
        let state = stateName(r, sc)
        if state == "recording" || state == "analyzing" || queued.contains(id) {
            throw APIError.wrongState(state, message: "Audio cannot be deleted while the recording is \(state).")
        }
        if let channel {
            guard let channels = sc?.channels, let entry = channels.first(where: { $0.channel == channel }) else {
                throw APIError.validationFailed([("channel", "not a recorded channel of this recording")])
            }
            if entry.audioDeletedAt == nil {
                let dir = URL(fileURLWithPath: r.sourcePath).deletingLastPathComponent()
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(entry.file))
                let now = env.clock.now()
                try sidecars.update(id) { s in
                    if let i = s.channels?.firstIndex(where: { $0.channel == channel }) { s.channels?[i].audioDeletedAt = now }
                }
                env.log("Recording \(id): audio of channel \(channel) deleted.")
            }
        } else {
            try deleteAllAudio(id)
            env.log("Recording \(id): audio deleted.")
        }
        publishState(id)
        return try render(id: id, withSync: true)
    }

    private func deleteAllAudio(_ id: String) throws {
        guard let r = try store.recording(id: id) else { return }
        let now = env.clock.now()
        if let channels = sidecars.read(id)?.channels {
            let dir = URL(fileURLWithPath: r.sourcePath).deletingLastPathComponent()
            for c in channels { try? FileManager.default.removeItem(at: dir.appendingPathComponent(c.file)) }
            try sidecars.update(id) { s in
                for i in (s.channels ?? []).indices where s.channels?[i].audioDeletedAt == nil { s.channels?[i].audioDeletedAt = now }
            }
        }
        try store.deleteAudio(id: id, at: now)
    }

    public func delete(id: String) throws {
        guard let r = try store.recording(id: id) else { throw APIError.notFound("Unknown recording.") }
        let sc = sidecars.read(id)
        let state = stateName(r, sc)
        if state == "recording" || state == "analyzing" || queued.contains(id) {
            throw APIError.wrongState(state, message: "A recording cannot be deleted while it is \(state).")
        }
        if let channels = sc?.channels {
            let dir = URL(fileURLWithPath: r.sourcePath).deletingLastPathComponent()
            for c in channels { try? FileManager.default.removeItem(at: dir.appendingPathComponent(c.file)) }
            try store.deleteRecordingAndFiles(id: id)
            if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: dir)
            }
        } else {
            try store.deleteRecordingAndFiles(id: id)
        }
        sidecars.delete(id)
        env.log("Recording \(id) deleted (audio, transcript, row).")
    }

    // MARK: - Upload

    public func registerUpload(fileURL: URL, title: String?, language: String?, clientRef: String?, startedAt: Date?, deleteAudioWhenDone: Bool) throws -> JSONValue {
        let now = env.clock.now()
        let stamp = Self.stamp(now)
        let id = "rec_" + UUID().uuidString
        let baseName = "\(stamp)-upload"
        let stub = Recording(
            id: id, title: title ?? "Upload \(Self.human(now))", sourcePath: fileURL.path,
            durationSec: WAVInfo.read(fileURL)?.durationSec ?? 0,
            language: language ?? env.appConfig.defaultLanguage.rawValue,
            transcriptMd: env.appConfig.transcriptsDir.appendingPathComponent("\(baseName).md").path,
            transcriptJson: env.appConfig.transcriptsDir.appendingPathComponent("\(baseName).json").path,
            createdAt: now, processingState: .analyzing
        )
        try store.insertEmptyRecording(stub)
        let clock = startedAt.map { d in
            Sidecar.Clock(audioStartedAtMs: WallClock.ms(d), source: "client", imprecise: false, syncPoints: [])
        }
        try sidecars.write(Sidecar(recordingId: id, clientRef: clientRef, sources: [], transcribe: "onStop",
                                   deleteAudioWhenDone: deleteAudioWhenDone, clock: clock, startedBy: "upload"))
        env.log("Upload \(id) stored (\(fileURL.lastPathComponent)); analysis queued.")
        enqueueAnalysis(id)
        return try render(id: id, withSync: true)
    }

    // MARK: - Shutdown

    /// Server is stopping: close the capture cleanly so the file stays usable. The recording is left in state
    /// `stopped` (analyse later with `POST .../transcribe`, or in the app).
    public func shutdown() async {
        guard let current = active else { return }
        for t in current.tasks { t.cancel() }
        active = nil
        try? await current.session.stop()
        let frames = current.session.framesCaptured
        try? store.updateRecordingDuration(id: current.id, durationSec: Double(frames) / Timeline.sampleRate)
        let nowMs = env.clock.nowMs
        try? sidecars.update(current.id) { $0.stoppedAtMs = nowMs; $0.awaitingTranscribe = true }
        try? store.setProcessingState(recordingId: current.id, state: .failed, errorMessage: Self.manualMessage(current.id))
        env.log("Server stopping: recording \(current.id) was stopped and kept for later analysis.")
    }

    // MARK: - Rendering

    func render(id: String, withSync: Bool) throws -> JSONValue {
        guard let r = try store.recording(id: id) else { throw APIError.notFound("Unknown recording.") }
        return render(r, sidecars.read(id), withSync: withSync)
    }

    func stateName(_ r: Recording, _ sc: Sidecar?) -> String {
        if r.processingState == .failed, sc?.awaitingTranscribe == true { return "stopped" }
        return r.processingState.rawValue
    }

    func render(_ r: Recording, _ sc: Sidecar?, withSync: Bool) -> JSONValue {
        let isActive = active?.id == r.id
        let state = stateName(r, sc)
        let duration = isActive ? Double(active!.session.framesCaptured) / Timeline.sampleRate : r.durationSec
        let liveBytes = isActive ? active!.session.channelBytes() : [:]

        let channels: JSONValue = sc?.channels.map { list in
            let dir = URL(fileURLWithPath: r.sourcePath).deletingLastPathComponent()
            return .array(list.map { c in
                let bytes = liveBytes[c.channel] ?? Self.fileSize(dir.appendingPathComponent(c.file))
                return ["channel": .int(c.channel), "label": .string(c.label), "key": .str(c.key),
                        "bytes": .int(bytes), "audioDeletedAt": .iso(c.audioDeletedAt)]
            })
        } ?? .null

        let clockStartMs = sc?.clock?.audioStartedAtMs ?? WallClock.ms(r.createdAt)
        var clock: [String: JSONValue] = [
            "audioStartedAt": .string(ISOTime.string(ms: clockStartMs)),
            "audioStartedAtMs": .int(clockStartMs),
            "audioStartedAtSource": .string(sc?.clock?.source ?? "createdAt"),
        ]
        if withSync {
            clock["syncPoints"] = .array((sc?.clock?.syncPoints ?? []).map { ["wallMs": .int($0.wallMs), "audioSec": .double($0.audioSec)] })
        }

        let prog: JSONValue = progress[r.id].map { p in
            ["step": .string(p.step), "fraction": p.fraction.map { .double($0, places: 2) } ?? .null, "t": .int(p.t)]
        } ?? .null

        return [
            "id": .string(r.id),
            "title": .string(r.title ?? ""),
            "state": .string(state),
            "language": .string(r.language),
            "sources": .array((sc?.sources ?? ["mic"]).map { .string($0) }),
            "clientRef": .str(sc?.clientRef),
            "transcribe": .string(sc?.transcribe ?? "onStop"),
            "createdAt": .iso(r.createdAt),
            "stoppedAt": sc?.stoppedAtMs.map { .string(ISOTime.string(ms: $0)) } ?? .null,
            "durationSec": .double(duration),
            "hasAudio": .bool(r.hasAudio),
            "audioDeletedAt": .iso(r.audioDeletedAt),
            "deleteAudioWhenDone": .bool(sc?.deleteAudioWhenDone ?? false),
            "clientMeta": sc?.clientMeta ?? .null,
            "captureQuality": .string(sc?.captureQuality ?? "asr"),
            "channels": channels,
            "errorMessage": state == "stopped" ? .null : .str(r.errorMessage),
            "progress": prog,
            "clock": .object(clock),
        ]
    }

    // MARK: - Helpers

    /// Not captured by this server and the audio file has not grown for `orphanQuietSeconds`.
    func isOrphan(_ r: Recording) -> Bool {
        guard r.processingState == .recording, active?.id != r.id else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: r.sourcePath)
        guard let modified = attrs?[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(modified) > env.timing.orphanQuietSeconds
    }

    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    static func round(_ v: Double, _ places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (v * p).rounded() / p
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: d)
    }

    static func human(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        for i in 2...999 {
            let u = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(i).\(url.pathExtension)")
            if !FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return url.deletingLastPathComponent().appendingPathComponent("\(base)-\(UUID().uuidString).\(url.pathExtension)")
    }

    static let captureHint = """
        Microphone access belongs to the app that runs `diarize serve` (for example Terminal or iTerm): \
        System Settings > Privacy & Security > Microphone. System audio additionally needs \
        System Settings > Privacy & Security > Screen & System Audio Recording. Check that the chosen input device is connected.
        """

    static let noSamplesMessage = """
        No audio samples were received during recording. Possible causes: microphone permission denied for the app \
        that runs `diarize serve` (System Settings > Privacy & Security > Microphone), Screen & System Audio permission \
        denied (system audio), or the wrong input device.
        """

    static func manualMessage(_ id: String) -> String {
        "Not analysed yet. Start the analysis in the app, or with POST /v1/recordings/\(id)/transcribe."
    }
}
