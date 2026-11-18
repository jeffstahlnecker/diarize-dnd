import Foundation

/// Injectable wall clock (tests use a fixed or stepping clock).
public struct WallClock: Sendable {
    public var now: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }
    public static let system = WallClock()

    public var nowMs: Int64 { Self.ms(now()) }
    public static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    public static func date(ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}

/// ISO-8601 UTC with millisecond precision, as used by every timestamp in the API.
public enum ISOTime {
    public static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
    public static func string(ms: Int64) -> String { string(WallClock.date(ms: ms)) }

    public static func parse(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: value) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: value)
    }

    /// ISO string or epoch milliseconds (as a decimal string).
    public static func parseFlexible(_ value: String) -> Date? {
        if let ms = Int64(value.trimmingCharacters(in: .whitespaces)) { return WallClock.date(ms: ms) }
        return parse(value)
    }
}

extension JSONValue {
    static func iso(_ date: Date?) -> JSONValue { date.map { .string(ISOTime.string($0)) } ?? .null }
    static func str(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
    static func int<T: BinaryInteger>(_ n: T) -> JSONValue { .number(Double(n)) }
    static func double(_ n: Double, places: Int = 3) -> JSONValue {
        let p = pow(10.0, Double(places))
        return .number((n * p).rounded() / p)
    }
}
