import ArgumentParser
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

    func run() async throws {
        let resolvedPort = ServeConfig.resolvePort(flag: port)
        guard (0...65535).contains(resolvedPort) else {
            throw ValidationError("Port must be between 0 and 65535.")
        }
        let origins: OriginPolicy
        do {
            origins = try OriginPolicy(ServeConfig.resolveOrigins(flags: allowOrigin))
        } catch {
            throw ValidationError("\(error)")
        }
        let config = ServeConfig(port: resolvedPort, origins: origins)

        print("diarize serve \(config.version) (API v\(ServeConfig.apiVersion))")
        print("Allowed origins:  \(origins.allowed.isEmpty ? "(none: only clients without an Origin header)" : origins.allowed.joined(separator: ", "))")
        print("Pairing:          not implemented yet; authenticated routes reject every token.")

        try await DiarizeHTTPServer.run(config: config) { actualPort in
            print("Listening on      http://\(ServeConfig.bindHost):\(actualPort)")
        }
    }
}
