import CryptoKit
import Foundation
import Security

/// Long-lived bearer tokens issued by pairing.
///
/// - Tokens are `dz_` + 256 random bits (base64url). Only the SHA-256 hash is stored.
/// - The file (default `~/.config/diarize/serve-tokens.json`) is written atomically with mode `0600`.
/// - A token is bound to the `Origin` it was paired from; requests from another origin get 403,
///   requests without an `Origin` (non-browser clients) are accepted.
public final class TokenStore: TokenValidator, @unchecked Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var hash: String
        public var clientName: String
        public var origin: String?
        public var createdAt: Date
        public var lastUsedAt: Date
    }

    private struct FileFormat: Codable {
        var version: Int
        var tokens: [Entry]
    }

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/diarize/serve-tokens.json")
    }

    private let lock = NSLock()
    private var entries: [Entry]
    private let fileURL: URL?
    private let clock: WallClock

    /// `fileURL: nil` keeps tokens in memory only (tests).
    public init(fileURL: URL?, clock: WallClock = .system) throws {
        self.fileURL = fileURL
        self.clock = clock
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode(FileFormat.self, from: data).tokens
        } else {
            entries = []
        }
    }

    public var isEmpty: Bool { lock.withLock { entries.isEmpty } }
    public var count: Int { lock.withLock { entries.count } }
    public var all: [Entry] { lock.withLock { entries } }

    /// Issues a new token; returns the plain token (shown once) and its id.
    public func issue(clientName: String, origin: String?) throws -> (token: String, id: String) {
        let token = "dz_" + Self.base64url(Self.randomBytes(32))
        let id = "tok_" + Self.hex(Self.randomBytes(4))
        let now = clock.now()
        let entry = Entry(id: id, hash: Self.hash(token), clientName: clientName, origin: origin, createdAt: now, lastUsedAt: now)
        try lock.withLock {
            entries.append(entry)
            try persistLocked()
        }
        return (token, id)
    }

    /// Revokes one token. Returns false if it was unknown.
    @discardableResult
    public func revoke(token: String) throws -> Bool {
        let h = Self.hash(token)
        return try lock.withLock {
            let before = entries.count
            entries.removeAll { $0.hash == h }
            guard entries.count != before else { return false }
            try persistLocked()
            return true
        }
    }

    public func revokeAll() throws {
        try lock.withLock {
            entries.removeAll()
            try persistLocked()
        }
    }

    public func entry(for token: String) -> Entry? {
        let h = Self.hash(token)
        return lock.withLock { entries.first { $0.hash == h } }
    }

    public func check(token: String, origin: String?) async -> TokenCheck {
        let h = Self.hash(token)
        return lock.withLock {
            guard let index = entries.firstIndex(where: { Self.constantTimeEqual($0.hash, h) }) else { return .invalid }
            let entry = entries[index]
            if let origin, let bound = entry.origin, bound != origin { return .wrongOrigin }
            // Persist `lastUsedAt` at most once a minute to keep request handling cheap.
            let now = clock.now()
            if now.timeIntervalSince(entry.lastUsedAt) > 60 {
                entries[index].lastUsedAt = now
                try? persistLocked()
            }
            return .valid
        }
    }

    // MARK: - Persistence

    private func persistLocked() throws {
        guard let fileURL else { return }
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(FileFormat(version: 1, tokens: entries))
        try AtomicFile.write(data, to: fileURL, mode: 0o600)
    }

    // MARK: - Crypto helpers

    static func hash(_ token: String) -> String {
        hex(Array(SHA256.hash(data: Data(token.utf8))))
    }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// Write-to-temp-then-rename, with explicit POSIX permissions on the final file.
enum AtomicFile {
    static func write(_ data: Data, to url: URL, mode: Int16 = 0o644) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: NSNumber(value: mode)]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        if rename(tmp.path, url.path) != 0 {
            let err = errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }
}
