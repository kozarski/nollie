import Foundation
import Observation
import UserNotifications
import NollieCore

/// Everything the companion setup, the Companion page and Software Update know about the push
/// companion on the gateway. The state lives here; the work is in the extensions beside it
/// (install, restart, update, test).
@MainActor
@Observable
final class PushSetupModel {
    static let pluginID = "nollie-push"
    static let heartbeatSeconds: TimeInterval = 10

    /// The status file the companion rewrites on each poll, at `<push dir>/status.json`.
    struct CompanionHeartbeat: Decodable {
        let version: String
        let updatedAt: Double
        var scriptSha256: String? = nil
        var profile: String? = nil
        var connected: Bool? = nil
        var error: String? = nil
        var transport: String? = nil
        var devices: Int? = nil
        /// The last test the companion ran: which one, how many devices it tried, what the relay said.
        var lastTestNonce: String? = nil
        var lastTestDevices: Int? = nil
        var lastTestDetail: String? = nil

        private enum Wire: String, CodingKey {
            case version, profile, connected, transport, devices, error
            case scriptSha256 = "script_sha256"
            case updatedAt = "updated_at"
            case lastTestNonce = "last_test_nonce"
            case lastTestDevices = "last_test_devices"
            case lastTestDetail = "last_test_detail"
        }
    }

    struct InstalledFile: Hashable {
        var name: String
        var directory: String
        var bytes: Int
    }

    enum Credential: Equatable { case sessionToken, needsSignIn, ready(provider: String?) }

    enum TestPhase {
        case idle
        case waiting
        case done(ok: Bool, text: String)

        var isWaiting: Bool {
            switch self {
            case .waiting: true
            case .idle, .done: false
            }
        }
    }

    /// Where a software update stands: the bar, the words under it, the console and how it ended.
    struct UpdateRun {
        var running = false
        /// Fraction done, 0 to 1, spanning the upload, enabling, restarting and the first healthy heartbeat.
        var progress: Double = 0
        var stage = ""
        var console: [String] = []
        var outcome: (ok: Bool, text: String)?
        var consoleOpen = false
        var needsRestart = false
    }

    // MARK: Fixed facts about this build

    static var bundledPluginVersion: String { CompanionBundle.pluginVersion }
    static var bundledScriptSize: Int { CompanionBundle.scriptSize }
    static var bundledScriptSHA256: String { CompanionBundle.scriptSHA256 }

    // MARK: Apple key and address (the own-key path)

    var keyFileName: String?
    var keyData: Data?
    var keyID = ""
    var teamID = ""
    var gatewayURL = ""
    /// The address that the gateway-side companion config currently points at.
    var urlInUse: String?

    // MARK: Companion sign-in

    var companionSecrets: GatewaySecrets?
    var companionSignIn = CompanionSignInState()
    var signInStateConnectionID: UUID?

    // MARK: Wizard progress

    var registering = false
    var registerOutcome: (failed: Bool, text: String)?
    var installing = false
    var installingPlugin = false
    var uploadedAt: Date?
    var installedAt: Date?
    var pluginInstalledAt: Date?
    var pluginResult: String?
    var error: String?
    var installedFiles: [InstalledFile] = []

    // MARK: Restart

    var restartCountdownEnd: Date?
    /// Files are in place on the gateway, which still needs a restart before anything works.
    var restartPending = false
    var restarting = false
    var restartError: String?
    var restartStage = ""
    var restartBegan: Date?
    var restartAskedAt: Date?
    var restartWait: Task<Void, Never>?
    var restartTimer: Task<Void, Never>?

    // MARK: Update

    var update = UpdateRun()
    var updating: Bool { get { update.running } set { update.running = newValue } }
    var updateProgress: Double { get { update.progress } set { update.progress = newValue } }
    var updateStage: String { get { update.stage } set { update.stage = newValue } }
    var updateConsole: [String] { get { update.console } set { update.console = newValue } }
    var updateOutcome: (ok: Bool, text: String)? { get { update.outcome } set { update.outcome = newValue } }
    var showUpdateConsole: Bool { get { update.consoleOpen } set { update.consoleOpen = newValue } }
    var updateNeedsRestart: Bool { get { update.needsRestart } set { update.needsRestart = newValue } }

    // MARK: Test notification

    var testPhase: TestPhase = .idle
    var testStartedAt: Date?
    var testStage = ""
    /// Nonces of pushes that were displayed with the app open (filled in by the notification delegate).
    static var presentedNonces: Set<String> = []
    static var lastPresentedAt: Date?
    /// Test pushes requested this session and still outstanding. Delivery can take over a minute, so a
    /// slow earlier push that lands during a newer attempt still passes it.
    static var testNonces: [String: Date] = [:]
    static let testWait: TimeInterval = 180

    // MARK: What the gateway says

    var checkingCompanion = false
    var companionCheckError: String?
    var companionCheckedAt: Date?
    /// Plugin manifest version found on the gateway, or nil if the plugin is absent.
    var installedVersion: String?
    var installedPluginID: String?
    /// The script on the gateway matches the bundled one exactly, byte for byte.
    var installedScriptMatches = false
    var heartbeat: CompanionHeartbeat? {
        didSet {
            if let heartbeat { companionSignIn.observe(heartbeat, at: Date()) }
            if companionSignInRejected {
                restartLater()
                restartPending = false
            }
        }
    }

    // MARK: Derived

    var companionSignInRejected: Bool { companionSignIn.rejected }
    var signInNeedsInstall: Bool { companionSignIn.needsInstall }
    var waitingForSignInHeartbeat: Bool { companionSignIn.waitingForHeartbeat(heartbeat, at: Date()) }

    /// The companion is up but cannot reach the gateway, for a reason other than starting or reloading.
    var hasConnectionFailure: Bool {
        guard let beat = heartbeat, companionSignIn.accepts(beat, at: Date()), beat.connected == false,
              let message = beat.error, !message.isEmpty else { return false }
        return message != "connecting…" && !message.hasPrefix("reloading")
    }

    var addressValid: Bool {
        guard let url = URL(string: gatewayURL.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    var installedOnGateway: Bool {
        uploadedAt != nil && pluginInstalledAt != nil && error == nil && !signInNeedsInstall && !companionSignInRejected
    }

    /// True when the heartbeat is recent and connected, and reports exactly the code bundled in this build.
    var companionHealthy: Bool {
        guard let beat = heartbeat, beat.connected == true, !runningOlderCode, installedScriptMatches else { return false }
        return companionSignIn.accepts(beat, at: Date())
    }

    /// This build's companion already runs here (installed from another device, say): nothing to
    /// upload or restart, this device only registers.
    var alreadyServing: Bool {
        installedVersion == Self.bundledPluginVersion && installedScriptMatches && companionHealthy && !needsRestart
    }

    var runningOlderCode: Bool { heartbeat?.scriptSha256.map { $0 != Self.bundledScriptSHA256 } ?? false }

    /// The plugin on disk is newer than the running one, or the running one has never written a heartbeat.
    var needsRestart: Bool {
        guard let installed = installedVersion else { return false }
        guard let beat = heartbeat else { return true }
        return beat.version != installed || runningOlderCode
    }

    var updateAvailable: Bool {
        guard let installed = installedVersion else { return false }
        return installed != Self.bundledPluginVersion || !installedScriptMatches
    }

    /// From 1.0.12 the companion notices a replaced file by itself. Earlier ones need the gateway restarted.
    var runningCanSelfReload: Bool {
        if installedPluginID != Self.pluginID { return false }
        return heartbeat.map { CompanionBundle.version($0.version, atLeast: [1, 0, 12]) } ?? false
    }

    var startAdvice: String {
        if companionHealthy { return String(localized: "You're connected. Head on to the overview.") }
        if companionSignInRejected { return String(localized: "The gateway turned down the companion's sign-in. Sign in again, then install it. Your Apple key and progress are kept.") }
        if signInNeedsInstall { return String(localized: "The new sign-in is saved. Install it so the companion can reconnect.") }
        if waitingForSignInHeartbeat { return String(localized: "Waiting for the companion to check the new sign-in.") }
        if restartPending { return String(localized: "Installed, but the gateway has not restarted yet, and nothing works until it does. Restart it below.") }
        guard let beat = heartbeat else {
            return installedVersion == nil ? String(localized: "Install the plugin in step 4 first.")
                : String(localized: "No heartbeat yet. Restart the gateway so Hermes loads the plugin, then give it a few seconds.")
        }
        if Date().timeIntervalSince1970 - beat.updatedAt > Self.heartbeatSeconds * 6 { return String(localized: "The companion stopped sending heartbeats. Restart the gateway.") }
        if runningOlderCode || !installedScriptMatches { return String(localized: "The gateway is still running an older companion than the installed one. Restart it.") }
        if beat.connected == false, let why = beat.error, why != "connecting…" {
            return String(localized: "The companion is up but cannot reach the gateway: \(why). Go back, fix the address or sign-in, and install again. It switches within ten seconds, no restart needed.")
        }
        return String(localized: "Connecting…", comment: "The companion is connecting to the gateway")
    }

    // MARK: Credentials

    func credential(for rt: GatewayRuntime) -> Credential { credential(authMode: rt.connection.authMode) }

    func credential(authMode: AuthMode) -> Credential {
        if companionSignInRejected { return .needsSignIn }
        if let secrets = companionSecrets, secrets.bearer != nil { return .ready(provider: secrets.provider) }
        return authMode == .sessionToken ? .sessionToken : .needsSignIn
    }

    func credentialText(for rt: GatewayRuntime) -> String {
        let credential = credential(for: rt)
        if case .ready(let provider) = credential {
            switch (companionHealthy, provider) {
            case (true, let provider?): return String(localized: "connected via \(provider)", comment: "The companion's sign-in; %@ is the sign-in provider")
            case (false, let provider?): return String(localized: "sign-in saved via \(provider)", comment: "The companion's sign-in; %@ is the sign-in provider")
            case (true, nil): return String(localized: "connected", comment: "The companion's sign-in")
            case (false, nil): return String(localized: "sign-in saved", comment: "The companion's sign-in")
            }
        }
        return credential == .sessionToken ? String(localized: "gateway session token", comment: "How the companion signs in")
                                           : String(localized: "not signed in", comment: "The companion's sign-in")
    }

    func appleReady(push: PushRegistrar) -> Bool {
        switch push.authorization {
        case .authorized, .provisional: break
        default: return false
        }
        guard push.registeredAt != nil else { return false }
        return PushRelay.isConfigured ? push.relayRegisteredAt != nil : (keyData != nil && !keyID.isEmpty && teamID.count == 10)
    }

    // MARK: Remembered per connection

    /// Where one connection's remembered facts live.
    private enum Memory {
        static func secrets(_ id: UUID) -> String { "companion-secrets.\(id)" }
        static func finished(_ id: UUID) -> String { "pushSetupCompleted.\(id)" }
    }

    func isCompleted(for rt: GatewayRuntime) -> Bool {
        UserDefaults.standard.bool(forKey: Memory.finished(rt.connection.id))
    }

    func markCompleted(for rt: GatewayRuntime) {
        UserDefaults.standard.set(true, forKey: Memory.finished(rt.connection.id))
    }

    func forgetCompleted(for rt: GatewayRuntime) {
        UserDefaults.standard.removeObject(forKey: Memory.finished(rt.connection.id))
    }

    func restore(for rt: GatewayRuntime) {
        if signInStateConnectionID != rt.connection.id {
            companionSignIn = .restore(connectionID: rt.connection.id)
            signInStateConnectionID = rt.connection.id
        }
        if companionSecrets == nil {
            companionSecrets = Keychain.getCodable(GatewaySecrets.self, account: Memory.secrets(rt.connection.id))
        }
    }

    func rememberCompanionSecrets(for rt: GatewayRuntime) {
        signInStateConnectionID = rt.connection.id
        companionSignIn.save(connectionID: rt.connection.id)
        let account = Memory.secrets(rt.connection.id)
        if let secrets = companionSecrets {
            try? Keychain.setCodable(secrets, account: account)
        } else {
            Keychain.delete(account: account)
        }
    }

    func acceptCompanionSignIn(_ secrets: GatewaySecrets) {
        companionSecrets = secrets
        companionSignIn.signedIn(after: heartbeat?.updatedAt)
        restartLater()
        error = nil
    }

    func signOutCompanion(runtime rt: GatewayRuntime) {
        companionSecrets = nil
        companionSignIn = CompanionSignInState()
        if let heartbeat { companionSignIn.observe(heartbeat, at: Date()) }
        rememberCompanionSecrets(for: rt)
    }

    // MARK: Talking to the gateway's files

    func pushDir(for rt: GatewayRuntime) -> String {
        let home = rt.profileHome ?? "~/.hermes"
        return home + "/push"
    }

    func installCommand(for rt: GatewayRuntime) -> String {
        "bash " + pushDir(for: rt) + "/install.sh"
    }

    /// Raw bytes of a gateway file, nil if it does not exist.
    func readData(_ rt: GatewayRuntime, path: String) async throws -> Data? {
        let ask = [URLQueryItem(name: "path", value: path)]
        let reply: JSONValue
        do {
            reply = try await rt.api.get("/api/files/read", query: ask)
        } catch HermesAPIError.http(404, _) {
            return nil
        }
        guard let url = reply["data_url"]?.stringValue, let cut = url.firstIndex(of: ","),
              let bytes = Data(base64Encoded: String(url[url.index(after: cut)...])) else {
            throw CompanionFileBackup.Failure.unreadable
        }
        return bytes
    }

    /// Text of a gateway file, nil if it does not exist.
    func readText(_ rt: GatewayRuntime, path: String) async throws -> String? {
        guard let bytes = try await readData(rt, path: path) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    func writeFile(_ rt: GatewayRuntime, path: String, data: Data, mime: String) async throws {
        let encoded = "data:" + mime + ";base64," + data.base64EncodedString()
        let body: JSONValue = ["overwrite": true, "data_url": .string(encoded), "path": .string(path)]
        let _: ManagedUploadResult = try await rt.api.send("POST", "/api/files/upload", json: body)
    }

    func enableCompanion(runtime rt: GatewayRuntime) async throws -> JSONValue {
        try await rt.api.send("POST", "/api/dashboard/agent-plugins/\(Self.pluginID)/enable", body: EmptyBody())
    }

    // MARK: Looking at the gateway

    /// Reads the address out of the config the gateway already has, so a fresh install carries on from there.
    func addressFromConfig(runtime rt: GatewayRuntime) async -> String? {
        let key = "HERMES_PUSH_GATEWAY_URL="
        let text = (try? await readText(rt, path: pushDir(for: rt) + "/hermes-push.conf")) ?? nil
        guard let line = text?.split(separator: "\n").first(where: { $0.hasPrefix(key) }) else { return nil }
        let address = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        urlInUse = address.isEmpty ? nil : address
        return urlInUse
    }

    /// Loads everything a screen wants before drawing: saved sign-in, current address and heartbeat.
    func prepare(runtime rt: GatewayRuntime) async {
        companionCheckedAt = nil     // reads as "Checking…" until this visit's answer lands
        restore(for: rt)
        if gatewayURL.isEmpty { gatewayURL = await addressFromConfig(runtime: rt) ?? rt.connection.gateway.description }
        await checkCompanion(runtime: rt)
    }

    /// What the gateway holds about the companion, read in one go.
    private struct Snapshot {
        var version: String?
        var pluginPresent: Bool
        var scriptMatches: Bool
        var heartbeat: CompanionHeartbeat?
    }

    private func snapshot(_ rt: GatewayRuntime, home: String) async throws -> Snapshot {
        let plugin = "\(home)/plugins/\(Self.pluginID)"
        let manifest = try await readText(rt, path: plugin + "/plugin.yaml")
        let script = try await readText(rt, path: plugin + "/hermes_push.py")
        let status = try await readText(rt, path: pushDir(for: rt) + "/status.json")
        return Snapshot(
            version: manifest.map { $0.firstMatch(of: /version: "([^"]+)"/).map { String($0.1) } ?? "?" },
            pluginPresent: manifest != nil,
            scriptMatches: script.map { CompanionBundle.sha256(Data($0.utf8)) == Self.bundledScriptSHA256 } ?? false,
            heartbeat: try status.map { try JSONDecoder().decode(CompanionHeartbeat.self, from: Data($0.utf8)) })
    }

    func checkCompanion(runtime rt: GatewayRuntime) async {
        checkingCompanion = true
        companionCheckError = nil
        defer {
            checkingCompanion = false
            companionCheckedAt = Date()
        }
        guard let home = rt.profileHome else {
            companionCheckError = String(localized: "The gateway did not say where its home folder is.")
            return
        }
        do {
            let found = try await snapshot(rt, home: home)
            installedPluginID = found.pluginPresent ? Self.pluginID : nil
            installedVersion = found.version
            installedScriptMatches = found.scriptMatches
            heartbeat = found.heartbeat
        } catch {
            companionCheckError = error.localizedDescription
        }
    }
}

extension PushSetupModel.CompanionHeartbeat {
    /// Reads the file the companion writes, keys as it spells them.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Wire.self)
        self.init(version: try box.decode(String.self, forKey: .version),
                  updatedAt: try box.decode(Double.self, forKey: .updatedAt),
                  scriptSha256: try box.decodeIfPresent(String.self, forKey: .scriptSha256),
                  profile: try box.decodeIfPresent(String.self, forKey: .profile),
                  connected: try box.decodeIfPresent(Bool.self, forKey: .connected),
                  error: try box.decodeIfPresent(String.self, forKey: .error),
                  transport: try box.decodeIfPresent(String.self, forKey: .transport),
                  devices: try box.decodeIfPresent(Int.self, forKey: .devices),
                  lastTestNonce: try box.decodeIfPresent(String.self, forKey: .lastTestNonce),
                  lastTestDevices: try box.decodeIfPresent(Int.self, forKey: .lastTestDevices),
                  lastTestDetail: try box.decodeIfPresent(String.self, forKey: .lastTestDetail))
    }
}
