import Foundation
import NollieCore

/// Source of the live-gateway settings. Every key comes from the first place below that has it:
///  1. `HERMES_E2E_*` entries in the runner's environment (xcodebuild passes these along as
///     `TEST_RUNNER_HERMES_E2E_*`);
///  2. a `KEY=VALUE` file outside the repository, at `$HERMES_E2E_ENV_FILE` when that is set and at
///     `~/.config/nollie/e2e.env` otherwise, under the true home folder (the simulator's HOME is
///     sandboxed, so the real one is found through the user id);
///  3. the older `hermes-e2e.json` inside the simulator's temporary directory, which has the keys `url`
///     and `token`.
/// Needed are `HERMES_E2E_URL` and then either `HERMES_E2E_TOKEN` (a session token) or both
/// `HERMES_E2E_USER` and `HERMES_E2E_PASSWORD` (swapped for a session, never kept or logged).
struct LiveGatewaySettings {
    var url: String
    var token: String?
    var user: String?
    var password: String?

    // MARK: finding them

    /// Settings files to try in order; the first one that can be read is used. Paths only, never contents.
    static var settingsFilePaths: [String] {
        let environment = ProcessInfo.processInfo.environment
        if let chosen = environment["HERMES_E2E_ENV_FILE"], !chosen.isEmpty { return [chosen] }
        var homes: [String] = []
        if let host = environment["SIMULATOR_HOST_HOME"], !host.isEmpty { homes.append(host) }
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { homes.append(String(cString: dir)) }
        var counted = Set<String>()
        return homes.filter { counted.insert($0).inserted }.map { $0 + "/.config/nollie/e2e.env" }
    }

    /// Reads a `KEY=VALUE` file: blank lines and `#` comments skipped, an optional `export `, and one
    /// pair of matching quotes stripped from the value. Empty values count as absent.
    static func parse(settingsFile text: String) -> [String: String] {
        var found: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == value.last, quote == "\"" || quote == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { found[key] = value }
        }
        return found
    }

    /// Every setting found, from all three places.
    private static func gathered() -> [String: String] {
        var all = ProcessInfo.processInfo.environment.filter { !$0.value.isEmpty }.filter { $0.key.hasPrefix("HERMES_E2E_") }
        for path in settingsFilePaths {
            guard let fileText = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            all.merge(parse(settingsFile: fileText)) { fromEnvironment, _ in fromEnvironment }
            break
        }
        let legacy = NSTemporaryDirectory() + "hermes-e2e.json"
        if let data = FileManager.default.contents(atPath: legacy), let old = try? JSONDecoder().decode([String: String].self, from: data) {
            for (oldKey, newKey) in [("url", "HERMES_E2E_URL"), ("token", "HERMES_E2E_TOKEN")] where all[newKey] == nil {
                if let value = old[oldKey], !value.isEmpty { all[newKey] = value }
            }
        }
        return all
    }

    /// The settings, if there is an address and a way to sign in.
    static func load() -> LiveGatewaySettings? {
        let all = gathered()
        guard let url = all["HERMES_E2E_URL"] else { return nil }
        let settings = LiveGatewaySettings(url: url, token: all["HERMES_E2E_TOKEN"], user: all["HERMES_E2E_USER"], password: all["HERMES_E2E_PASSWORD"])
        let canSignIn = settings.token != nil || (settings.user != nil && settings.password != nil)
        return canSignIn ? settings : nil
    }

    /// Whether `HERMES_E2E_REQUIRED` is defined, in the environment or in the settings file; if so,
    /// the run insists on having settings, whichever CI it happens on.
    static var isRequired: Bool { gathered()["HERMES_E2E_REQUIRED"] != nil }

    /// Why the live tests would be skipped: which files were tried, which keys turned up and which
    /// are missing. Names only, never values.
    static func whySkipped() -> String {
        let tried = settingsFilePaths.map { path -> String in
            let manager = FileManager.default
            return "\(path) [exists=\(manager.fileExists(atPath: path)) readable=\(manager.isReadableFile(atPath: path))]"
        }
        let all = gathered()
        var missing = all["HERMES_E2E_URL"] == nil ? ["HERMES_E2E_URL"] : []
        let hasLogin = all["HERMES_E2E_TOKEN"] != nil || (all["HERMES_E2E_USER"] != nil && all["HERMES_E2E_PASSWORD"] != nil)
        if !hasLogin { missing.append("HERMES_E2E_TOKEN, or both HERMES_E2E_USER and HERMES_E2E_PASSWORD") }
        let found = all.keys.sorted().joined(separator: ",")
        let lacking = missing.isEmpty ? "none" : missing.joined(separator: ", ")
        return "tried \(tried.joined(separator: ", ")); keys found: \(found); missing: \(lacking)"
    }

    // MARK: signing in

    /// Signs in and returns the gateway address, the auth mode and the secrets that go with it.
    func signIn() async throws -> (gateway: GatewayURL, mode: AuthMode, secrets: GatewaySecrets) {
        let address = try GatewayURL.normalize(url)
        if let token, !token.isEmpty { return (address, .sessionToken, GatewaySecrets(sessionToken: token)) }
        let access = CloudflareAccess()
        let lookup = try? await NativeAuthClient.providers(gateway: address, access: access)
        let providers = lookup ?? []
        let providerName = providers.first { $0.supportsPassword == true }?.name ?? "basic"
        let secrets = try await NativeAuthClient.signInWithPassword(
            gateway: address, provider: providerName, username: user ?? "", password: password ?? "", access: access)
        return (address, .password, secrets)
    }
}

extension GatewaySocket {
    /// Builds a socket the way the app does for a signed-in gateway: bearer sign-ins swap for a
    /// one-time ticket first, and the gateway's Access headers are sent along.
    static func live(gateway: GatewayURL, mode: AuthMode, secrets: GatewaySecrets, api: HermesAPI,
                     onEvent: @escaping @Sendable (GatewayEvent) -> Void = { _ in },
                     onRequest: @escaping RequestHandler = { _ in nil }) -> GatewaySocket {
        @Sendable func oneTimeTicket() async throws -> String? {
            guard mode.usesBearer else { return nil }
            let issued: [String: JSONValue] = try await api.send("POST", "/api/auth/ws-ticket", body: EmptyBody())
            return issued["ticket"]?.stringValue
        }
        let address: GatewaySocket.URLProvider = {
            let ticket = try await oneTimeTicket()
            return (RequestSigner.websocketURL(gateway: gateway, token: secrets.sessionToken, ticket: ticket), secrets.access.headers)
        }
        return GatewaySocket(urlProvider: address, onEvent: onEvent, onState: { _ in }, onServerRequest: onRequest, onReconnected: {})
    }
}

/// Gathers events delivered by a socket callback so a test can wait for a particular one.
actor EventTape {
    private var heard: [GatewayEvent] = []
    func record(_ event: GatewayEvent) { heard.append(event) }
    func first(where matches: (GatewayEvent) -> Bool) -> GatewayEvent? { heard.first(where: matches) }
    func count(where matches: (GatewayEvent) -> Bool) -> Int { heard.filter(matches).count }
}
