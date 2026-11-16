import Foundation
import NIOConcurrencyHelpers

/// Static configuration of `diarize serve`.
public struct ServeConfig: Sendable {
    /// The server only ever binds to the loopback interface. There is deliberately no option to change this.
    public static let bindHost = "127.0.0.1"
    public static let defaultPort = 47653
    public static let apiVersion = 1
    public static let defaultVersion = "0.1.0"
    /// Limit for JSON request bodies (uploads are exempt, see docs/http-api.md).
    public static let defaultMaxJSONBodyBytes = 64 * 1024

    public var port: Int
    public var origins: OriginPolicy
    public var version: String
    public var maxJSONBodyBytes: Int

    public init(
        port: Int = ServeConfig.defaultPort,
        origins: OriginPolicy = OriginPolicy(),
        version: String = ServeConfig.defaultVersion,
        maxJSONBodyBytes: Int = ServeConfig.defaultMaxJSONBodyBytes
    ) {
        self.port = port
        self.origins = origins
        self.version = version
        self.maxJSONBodyBytes = maxJSONBodyBytes
    }

    /// Resolve the port: explicit flag, then `DIARIZE_SERVE_PORT`, then the default.
    public static func resolvePort(flag: Int?, environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        if let flag { return flag }
        if let raw = environment["DIARIZE_SERVE_PORT"], let value = Int(raw.trimmingCharacters(in: .whitespaces)) {
            return value
        }
        return defaultPort
    }

    /// Merge `--allow-origin` values with `DIARIZE_SERVE_ORIGINS` (comma separated).
    public static func resolveOrigins(flags: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var result = flags
        if let raw = environment["DIARIZE_SERVE_ORIGINS"] {
            result += raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return result
    }
}

/// The port the server really listens on. Differs from the configured one when `--port 0` is used.
public final class BoundPort: Sendable {
    private let box: NIOLockedValueBox<Int>
    public init(_ initial: Int) { box = NIOLockedValueBox(initial) }
    public var value: Int { box.withLockedValue { $0 } }
    public func set(_ port: Int) { box.withLockedValue { $0 = port } }
}
