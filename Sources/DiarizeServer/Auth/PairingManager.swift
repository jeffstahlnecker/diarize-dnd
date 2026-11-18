import Foundation
import Security

/// The one-time pairing code shown in the terminal (`NNN-NNN`).
///
/// - Valid for `validFor` (5 minutes) and for one successful pairing.
/// - Five wrong attempts burn the code: the fifth answer is `rateLimited`, further attempts are refused
///   for `lockSeconds`, and a new code is printed.
/// - When a client tries to pair while the code is expired or already used, a fresh code is printed
///   in the terminal (never sent to the client) and the attempt is answered `invalid`. So a server that has
///   been running for a while never has to be restarted to pair, while the code still only exists in the terminal.
public final class PairingManager: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable {
        case success
        case invalid(renewed: Bool)
        case rateLimited(retryAfter: Int)
    }

    public static let defaultValidFor: TimeInterval = 5 * 60
    public static let defaultMaxFailures = 5
    public static let defaultLockSeconds = 60

    private let lock = NSLock()
    private let clock: WallClock
    private let validFor: TimeInterval
    private let maxFailures: Int
    private let lockSeconds: Int
    private let generate: @Sendable () -> String
    private let onNewCode: @Sendable (String, Date) -> Void

    private var code: String = ""
    private var expiresAt: Date = .distantPast
    private var used = false
    private var failures = 0
    private var lockedUntil: Date = .distantPast

    public init(
        clock: WallClock = .system,
        validFor: TimeInterval = PairingManager.defaultValidFor,
        maxFailures: Int = PairingManager.defaultMaxFailures,
        lockSeconds: Int = PairingManager.defaultLockSeconds,
        generate: @escaping @Sendable () -> String = PairingManager.randomCode,
        onNewCode: @escaping @Sendable (String, Date) -> Void = { _, _ in }
    ) {
        self.clock = clock
        self.validFor = validFor
        self.maxFailures = maxFailures
        self.lockSeconds = lockSeconds
        self.generate = generate
        self.onNewCode = onNewCode
        lock.withLock { renewLocked() }
    }

    /// The current code (for the terminal banner and tests).
    public var currentCode: String { lock.withLock { code } }
    public var currentExpiry: Date { lock.withLock { expiresAt } }

    public func attempt(_ given: String) -> Outcome {
        lock.withLock {
            let now = clock.now()
            if now < lockedUntil {
                return .rateLimited(retryAfter: max(1, Int(lockedUntil.timeIntervalSince(now).rounded(.up))))
            }
            let digits = given.filter(\.isNumber)
            let expected = code.filter(\.isNumber)
            let stale = used || now > expiresAt
            if !stale, digits.count == 6, constantTimeEqual(digits, expected) {
                used = true
                failures = 0
                return .success
            }
            if stale {
                // Nobody can know a code that has not been printed yet: renew without counting a strike.
                renewLocked()
                return .invalid(renewed: true)
            }
            failures += 1
            if failures >= maxFailures {
                failures = 0
                lockedUntil = now.addingTimeInterval(TimeInterval(lockSeconds))
                renewLocked()
                return .rateLimited(retryAfter: lockSeconds)
            }
            return .invalid(renewed: false)
        }
    }

    private func renewLocked() {
        code = generate()
        expiresAt = clock.now().addingTimeInterval(validFor)
        used = false
        failures = 0
        onNewCode(code, expiresAt)
    }

    public static let randomCode: @Sendable () -> String = {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        let n = Int(value % 1_000_000)
        let s = String(format: "%06d", n)
        return "\(s.prefix(3))-\(s.suffix(3))"
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
