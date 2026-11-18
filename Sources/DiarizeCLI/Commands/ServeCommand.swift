import ArgumentParser
import DiarizeCore
import DiarizeServer
import Foundation

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the local HTTP API on 127.0.0.1 for companion apps (see docs/http-api.md)."
    )

    @Option(name: .long, help: "Port on 127.0.0.1 (0 picks a free port). Default 47653, or DIARIZE_SERVE_PORT.")
    var port: Int?

    @Option(name: .long, parsing: .singleValue, help: "Browser origin allowed to call the API, e.g. http://localhost:4173. Exact match, repeatable, no wildcards. Also DIARIZE_SERVE_ORIGINS (comma separated).")
    var allowOrigin: [String] = []

    @Option(name: .long, help: "Override the archive path (default: as configured for the other commands).")
    var archive: String?

    @Option(name: .long, help: "Cap for uploads (POST /v1/transcriptions) in MiB.")
    var maxUploadMb: Int = 2048

    @Option(name: .long, help: "A recording is stopped automatically after this many hours.")
    var maxDuration: Double = 10

    @Flag(name: .long, help: "Delete every stored token and exit.")
    var revokeAll: Bool = false

    func run() async throws {
        let tokens = try TokenStore(fileURL: TokenStore.defaultFileURL)
        if revokeAll {
            let n = tokens.count
            try tokens.revokeAll()
            print("Revoked \(n) token\(n == 1 ? "" : "s") (\(TokenStore.defaultFileURL.path)).")
            return
        }

        let resolvedPort = ServeConfig.resolvePort(flag: port)
        guard (0...65535).contains(resolvedPort) else { throw ValidationError("Port must be between 0 and 65535.") }
        guard maxUploadMb > 0 else { throw ValidationError("--max-upload-mb must be positive.") }
        guard maxDuration > 0 else { throw ValidationError("--max-duration must be positive.") }
        let origins: OriginPolicy
        do {
            origins = try OriginPolicy(ServeConfig.resolveOrigins(flags: allowOrigin))
        } catch {
            throw ValidationError("\(error)")
        }
        let config = ServeConfig(port: resolvedPort, origins: origins)

        var appConfig = AppConfigLoader.load()
        if let archive { appConfig.archivePath = URL(fileURLWithPath: (archive as NSString).expandingTildeInPath) }

        let log: @Sendable (String) -> Void = { line in
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            print("[\(f.string(from: Date()))] \(line)")
            fflush(stdout)
        }
        let env = try ServerEnvironment.production(
            appConfig: appConfig, maxDurationSec: maxDuration * 3600, maxUploadBytes: maxUploadMb * 1024 * 1024, log: log)
        print("diarize serve \(config.version) (API v\(ServeConfig.apiVersion))")
        print("Archive:          \(appConfig.archivePath.path)")
        print("Allowed origins:  \(origins.allowed.isEmpty ? "(none: only clients without an Origin header)" : origins.allowed.joined(separator: ", "))")
        print("Paired clients:   \(tokens.count)")
        print("Microphone:       opened only when a paired client starts a recording. Stop the server with Ctrl-C.")
        fflush(stdout)
        let pairing = PairingManager(onNewCode: { code, expires in
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            print("Pairing code:     \(code)   (valid until \(f.string(from: expires)), single use)")
            fflush(stdout)
        })
        let services = ServerServices(tokens: tokens, pairing: pairing, controller: RecordingController(env: env),
                                      instanceId: env.sidecars.instanceId())


        try await DiarizeHTTPServer.run(config: config, services: services) { actualPort in
            print("Listening on      http://\(ServeConfig.bindHost):\(actualPort)")
            fflush(stdout)
        }
    }
}
