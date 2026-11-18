import Foundation

/// Validated `POST /v1/recordings` body.
struct StartRequest: Sendable {
    struct ChannelEntry: Sendable, Equatable {
        var channel: Int
        var label: String
        var key: String?
    }

    var title: String?
    var language: String?
    var sources: Set<String>
    var micDeviceUID: String?
    var clientRef: String?
    var clientMeta: JSONValue?
    var transcribe: String
    var deleteAudioWhenDone: Bool
    var channelMap: [ChannelEntry]?
    var captureQuality: String
    var bleed: String
}

enum StartValidation {
    static let clientMetaLimit = 4 * 1024
    static let languages = ["auto", "de", "en"]

    static func validate(_ body: [String: JSONValue], devices: [InputDeviceInfo]) throws -> StartRequest {
        var fields: [(String, String)] = []
        func bad(_ f: String, _ m: String) { fields.append((f, m)) }
        func present(_ k: String) -> JSONValue? {
            guard let v = body[k], !v.isNull else { return nil }
            return v
        }

        var title: String?
        if let v = present("title") {
            if let s = v.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), (1...200).contains(s.count) { title = s }
            else { bad("title", "1..200 characters") }
        }
        var language: String?
        if let v = present("language") {
            if let s = v.stringValue, languages.contains(s) { language = s } else { bad("language", "auto, de or en") }
        }
        var sources: Set<String> = ["mic"]
        if let v = present("sources") {
            if let a = v.arrayValue, !a.isEmpty, a.allSatisfy({ ["mic", "system"].contains($0.stringValue ?? "") }) {
                sources = Set(a.compactMap(\.stringValue))
            } else { bad("sources", "a non-empty array of mic and/or system") }
        }
        var micDeviceUID: String?
        if let v = present("micDeviceUID") {
            if let s = v.stringValue, !s.isEmpty, s.count <= 512 { micDeviceUID = s } else { bad("micDeviceUID", "a device uid from capabilities.inputDevices, or null") }
        }
        var clientRef: String?
        if let v = present("clientRef") {
            if let s = v.stringValue, s.count <= 200 { clientRef = s } else { bad("clientRef", "at most 200 characters") }
        }
        var clientMeta: JSONValue?
        if let v = present("clientMeta") {
            if v.objectValue != nil, v.encodedByteCount <= clientMetaLimit { clientMeta = v }
            else { bad("clientMeta", "an object of at most 4 KiB serialised") }
        }
        var transcribe = "onStop"
        if let v = present("transcribe") {
            if let s = v.stringValue, s == "onStop" || s == "manual" { transcribe = s } else { bad("transcribe", "onStop or manual") }
        }
        var deleteAudio = false
        if let v = present("deleteAudioWhenDone") {
            if let b = v.boolValue { deleteAudio = b } else { bad("deleteAudioWhenDone", "a boolean") }
        }
        var quality = "asr"
        if let v = present("captureQuality") {
            if let s = v.stringValue, s == "asr" || s == "archive" { quality = s } else { bad("captureQuality", "asr or archive") }
        }
        var bleed = "suppress"
        if let v = present("bleed") {
            if let s = v.stringValue, s == "suppress" || s == "keep" { bleed = s } else { bad("bleed", "suppress or keep") }
        }

        var channelMap: [StartRequest.ChannelEntry]?
        if let v = present("channelMap") {
            if let list = v.arrayValue, (1...16).contains(list.count) {
                let device = micDeviceUID.flatMap { uid in devices.first { $0.uid == uid } } ?? devices.first(where: \.isDefault)
                if micDeviceUID != nil, device == nil { bad("micDeviceUID", "not a connected input device") }
                var seen = Set<Int>()
                var entries: [StartRequest.ChannelEntry] = []
                for (i, item) in list.enumerated() {
                    guard let o = item.objectValue else { bad("channelMap[\(i)]", "an object"); continue }
                    guard let n = o["channel"]?.numberValue, n == n.rounded(), n >= 1 else {
                        bad("channelMap[\(i)].channel", "a 1-based integer"); continue
                    }
                    let ch = Int(n)
                    if let device, ch > device.channels { bad("channelMap[\(i)].channel", "the device has \(device.channels) input channels"); continue }
                    if seen.contains(ch) { bad("channelMap[\(i)].channel", "duplicate"); continue }
                    seen.insert(ch)
                    var label = ""
                    if let l = o["label"], !l.isNull {
                        if let s = l.stringValue, s.count <= 100 { label = s } else { bad("channelMap[\(i)].label", "0..100 characters") }
                    }
                    var key: String?
                    if let k = o["key"], !k.isNull {
                        if let s = k.stringValue, s.count <= 100 { key = s } else { bad("channelMap[\(i)].key", "0..100 characters") }
                    }
                    entries.append(.init(channel: ch, label: label, key: key))
                }
                channelMap = entries.sorted { $0.channel < $1.channel }
                if sources != ["mic"] { bad("sources", "multichannel recording needs sources [\"mic\"]") }
            } else {
                bad("channelMap", "1..16 entries")
            }
        }

        if !fields.isEmpty { throw APIError.validationFailed(fields, message: "Invalid recording request.") }
        return StartRequest(title: title, language: language, sources: sources, micDeviceUID: micDeviceUID, clientRef: clientRef,
                            clientMeta: clientMeta, transcribe: transcribe, deleteAudioWhenDone: deleteAudio,
                            channelMap: channelMap, captureQuality: quality, bleed: bleed)
    }
}
