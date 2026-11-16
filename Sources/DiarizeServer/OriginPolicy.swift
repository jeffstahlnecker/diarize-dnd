import Foundation

public struct OriginPolicyError: Error, CustomStringConvertible, Equatable {
    public let origin: String
    public let reason: String
    public var description: String { "Invalid origin \"\(origin)\": \(reason)" }
}

/// Exact-match allowlist of browser origins (`scheme://host[:port]`). No wildcards, ever.
public struct OriginPolicy: Sendable, Equatable {
    public private(set) var allowed: [String]

    public init() { allowed = [] }

    /// Validates and normalises (lower-case) every entry; throws on wildcards, paths, or non-http(s) schemes.
    public init(_ origins: [String]) throws {
        var list: [String] = []
        for raw in origins {
            let normalised = try Self.validate(raw)
            if !list.contains(normalised) { list.append(normalised) }
        }
        allowed = list
    }

    public func isAllowed(_ origin: String) -> Bool {
        allowed.contains(origin)
    }

    static func validate(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        func fail(_ reason: String) -> OriginPolicyError { OriginPolicyError(origin: raw, reason: reason) }
        if value.contains("*") { throw fail("wildcards are not allowed") }
        let parts = value.components(separatedBy: "://")
        guard parts.count == 2, parts[0] == "http" || parts[0] == "https" else {
            throw fail("expected scheme://host[:port] with http or https")
        }
        let authority = parts[1]
        guard !authority.isEmpty else { throw fail("host is empty") }
        for forbidden in ["/", "?", "#", "@", " "] where authority.contains(forbidden) {
            throw fail("must not contain a path, query, credentials or spaces")
        }
        if let colon = authority.lastIndex(of: ":") {
            let host = authority[..<colon]
            let port = authority[authority.index(after: colon)...]
            guard !host.isEmpty, let p = Int(port), (1...65535).contains(p) else {
                throw fail("invalid host or port")
            }
        }
        return value
    }
}
