import Foundation
import NIOConcurrencyHelpers

/// One server-sent event.
public struct ServerEvent: Sendable, Equatable {
    public var name: String
    public var data: JSONValue
    public init(_ name: String, _ data: JSONValue) {
        self.name = name
        self.data = data
    }
}

public enum SSEFormatter {
    /// `event: <name>\ndata: <json>\n\n`. JSON is compact (one line); any newline is split into
    /// several `data:` lines as the SSE spec requires.
    public static func frame(_ event: ServerEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(event.data)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let data = json.split(separator: "\n", omittingEmptySubsequences: false).map { "data: \($0)" }.joined(separator: "\n")
        return "event: \(event.name)\n\(data)\n\n"
    }

    public static let ping = ": ping\n\n"
}

/// Fan-out of events to every connected `/v1/events` stream.
public final class EventHub: Sendable {
    private struct State {
        var next = 0
        var subscribers: [Int: AsyncStream<String>.Continuation] = [:]
    }

    private let state = NIOLockedValueBox(State())
    private let pingInterval: Duration

    public init(pingInterval: Duration = .seconds(15)) {
        self.pingInterval = pingInterval
    }

    public var subscriberCount: Int { state.withLockedValue { $0.subscribers.count } }

    /// A stream of ready-to-write SSE frames (events and `: ping` comments). `first` frames are delivered before anything else.
    public func subscribe(first: [ServerEvent] = []) -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(512))
        for e in first { continuation.yield(SSEFormatter.frame(e)) }
        let id = state.withLockedValue { s -> Int in
            s.next += 1
            s.subscribers[s.next] = continuation
            return s.next
        }
        let interval = pingInterval
        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                continuation.yield(SSEFormatter.ping)
            }
        }
        continuation.onTermination = { [weak self] _ in
            pinger.cancel()
            self?.state.withLockedValue { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    public func publish(_ event: ServerEvent) {
        let frame = SSEFormatter.frame(event)
        let targets = state.withLockedValue { Array($0.subscribers.values) }
        for c in targets { c.yield(frame) }
    }

    public func publish(_ name: String, _ data: JSONValue) { publish(ServerEvent(name, data)) }

    /// Ends every stream (server shutdown).
    public func finishAll() {
        let targets = state.withLockedValue { s -> [AsyncStream<String>.Continuation] in
            defer { s.subscribers.removeAll() }
            return Array(s.subscribers.values)
        }
        for c in targets { c.finish() }
    }
}

/// Lets at most one item through per interval (progress events).
struct Throttle: Sendable {
    let intervalMs: Int64
    private(set) var lastMs: Int64?

    init(intervalMs: Int64) { self.intervalMs = intervalMs }

    mutating func allow(atMs now: Int64) -> Bool {
        if let last = lastMs, now - last < intervalMs { return false }
        lastMs = now
        return true
    }
}
