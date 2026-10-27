#if os(macOS)
import Foundation
import Observation
import NollieCore
import ServiceManagement

@MainActor
struct CloudAlertLoginItemClient {
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    var unregister: () async throws -> Void
    static let system = Self(
        status: { SMAppService.loginItem(identifier: CloudAlertHelperConfiguration.bundleID).status },
        register: { try SMAppService.loginItem(identifier: CloudAlertHelperConfiguration.bundleID).register() },
        unregister: { try await SMAppService.loginItem(identifier: CloudAlertHelperConfiguration.bundleID).unregister() }
    )
}

@MainActor @Observable
final class CloudAlertHelperController {
    static let shared = CloudAlertHelperController()
    static var bundledInThisEdition: Bool {
        #if NOLLIE_DIRECT
        true
        #else
        false
        #endif
    }
    enum State: Equatable { case off, starting, enabled, retrying, signInRequired, needsMainChat, stopped, needsApproval, unavailable, failed }
    private(set) var state: State = .off
    private(set) var message = String(localized: "Background alerts are off.")
    private(set) var isWorking = false
    var isEnabled: Bool { configuration?.enabled == true }
    private var configuration: CloudAlertHelperConfiguration?
    @ObservationIgnored private let loginItem: CloudAlertLoginItemClient
    @ObservationIgnored private let read: () -> CloudAlertHelperConfiguration?
    @ObservationIgnored private let write: (CloudAlertHelperConfiguration) throws -> Void
    @ObservationIgnored private let readHealth: () -> CloudAlertHelperHealth?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isDemo: Bool
    let isAvailable: Bool

    init(loginItem: CloudAlertLoginItemClient = .system,
         read: @escaping () -> CloudAlertHelperConfiguration? = CloudAlertHelperConfiguration.read,
         write: @escaping (CloudAlertHelperConfiguration) throws -> Void = { try $0.save() },
         readHealth: @escaping () -> CloudAlertHelperHealth? = { Keychain.getCodable(CloudAlertHelperHealth.self, account: CloudAlertHelperHealth.account) },
         now: @escaping () -> Date = Date.init,
         defaults: UserDefaults = .standard,
         isDemo: Bool = Bundle.main.bundleIdentifier?.hasSuffix(".demo") == true,
         isAvailable: Bool = CloudAlertHelperController.bundledInThisEdition) {
        self.loginItem = loginItem; self.read = read; self.write = write
        self.readHealth = readHealth; self.now = now
        self.defaults = defaults; self.isDemo = isDemo
        self.isAvailable = isAvailable
        // No registration, Keychain access or consent restoration in the constructor.
    }

    func refresh() {
        guard !isDemo else { state = .unavailable; message = String(localized: "Background alerts are unavailable in the demo app."); return }
        guard isAvailable else { state = .unavailable; message = String(localized: "Background alerts require the direct Mac edition."); return }
        configuration = read()
        guard configuration?.isValid == true, isEnabled else { state = .off; message = String(localized: "Background alerts are off."); return }
        switch loginItem.status() {
        case .enabled: refreshHealth()
        case .requiresApproval: state = .needsApproval; message = String(localized: "Allow Nollie Notifications in System Settings > General > Login Items.")
        case .notFound: state = .unavailable; message = String(localized: "This build doesn’t include the background alert helper.")
        default: state = .stopped; message = String(localized: "Background alerts are not registered. Retry to start them.")
        }
    }

    /// The helper writes health in another process. Read it while the settings view is active.
    /// SwiftUI cancels this task when the view closes or the scene becomes inactive.
    func monitorStatus(wait: @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }) async {
        guard isAvailable, !isDemo else { return }
        while !Task.isCancelled {
            if !isWorking { refresh() }
            do { try await wait() } catch { return }
        }
    }

    func enable(connectionID: UUID, profiles: [String] = ["default"], canonicalSessionID: String? = nil) async {
        guard !isDemo, !isWorking, isAvailable else { return }
        guard defaults.bool(forKey: CloudAlertTransport.enabledKey),
              let fingerprint = defaults.string(forKey: CloudAlertTransport.accountKey),
              let source = defaults.string(forKey: CloudAlertTransport.sourceKey) else {
            state = .failed; message = String(localized: "Turn on iCloud alerts first."); return
        }
        let config = CloudAlertHelperConfiguration(enabled: true, consentID: UUID(), enabledAt: now(),
            connectionID: connectionID, profiles: Array(Set(profiles)).sorted(), accountFingerprint: fingerprint, source: source,
            canonicalSessions: canonicalSessionID.map { ["default": $0] })
        guard config.isValid else { state = .failed; message = String(localized: "Choose a non-private bot for background alerts."); return }
        isWorking = true
        defer { isWorking = false }
        do {
            // A registered helper may have exited after an account change. An explicit opt-in
            // replaces that registration instead of mistaking registration for a live process.
            if loginItem.status() == .enabled || loginItem.status() == .requiresApproval {
                try await revokeAndUnregister()
            }
            // Save consent first so a helper launched immediately by register never guesses a gateway.
            try write(config); configuration = config
            try loginItem.register()
            refresh()
        } catch {
            var disabled = config; disabled.enabled = false
            try? write(disabled); configuration = disabled
            state = .failed; message = String(localized: "Couldn’t enable background alerts. Your existing setup is unchanged.")
        }
    }

    /// Existing consent follows the app's confirmed main chat. This neither registers a service
    /// nor changes its opt-in time, so an upgrade cannot turn old history into a notification backlog.
    func updateCanonicalSession(connectionID: UUID, profile: String = "default", sessionID: String?) {
        guard !isDemo, isAvailable, !isWorking, profile == "default",
              let sessionID, CloudAlertHelperConfiguration.permitsSessionID(sessionID),
              var config = read(), config.enabled, config.isValid, config.profiles == ["default"],
              config.connectionID == connectionID, config.canonicalSessions?[profile] != sessionID else { return }
        config.canonicalSessions = [profile: sessionID]
        do { try write(config); configuration = config }
        catch { state = .failed; message = String(localized: "Couldn’t update the main chat for background alerts. Try again.") }
    }

    /// An explicit retry preserves the durable outbox and original opt-in baseline.
    func retry() async {
        guard !isDemo, isAvailable, !isWorking,
              let config = read(), config.enabled, config.isValid,
              defaults.bool(forKey: CloudAlertTransport.enabledKey),
              defaults.string(forKey: CloudAlertTransport.accountKey) == config.accountFingerprint,
              defaults.string(forKey: CloudAlertTransport.sourceKey) == config.source else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await revokeAndUnregister()
            try write(config); configuration = config
            try loginItem.register()
            state = .starting; message = String(localized: "Starting background alerts.")
        } catch {
            state = .failed; message = String(localized: "Couldn’t restart background alerts. Check Login Items in System Settings.")
            configuration = read()
        }
    }

    private func revokeAndUnregister() async throws {
        if var existing = read() {
            existing.enabled = false
            try write(existing); configuration = existing
        }
        if loginItem.status() != .notRegistered { try await loginItem.unregister() }
    }

    private func refreshHealth() {
        guard let config = configuration else { return }
        guard config.canonicalSessions?["default"] != nil else {
            state = .needsMainChat
            message = String(localized: "Open your main chat in Nollie once to finish setting up background alerts.")
            return
        }
        guard let health = readHealth(), health.consentID == config.consentID else {
            let starting = now().timeIntervalSince(config.enabledAt) < 60
            state = starting ? .starting : .stopped
            message = starting ? String(localized: "Starting background alerts.")
                : String(localized: "The helper hasn’t checked in. Retry to start it.")
            return
        }
        let age = now().timeIntervalSince(health.checkedAt)
        guard age >= -60, age <= 360 else {
            state = .stopped; message = String(localized: "The helper hasn’t checked in recently. Retry to start it.")
            return
        }
        switch health.phase {
        case "ready": state = .enabled; message = String(localized: "The last background check succeeded.")
        case "mainChatUnknown": state = .needsMainChat; message = String(localized: "Open your main chat in Nollie once to finish setting up background alerts.")
        case "checking": state = .starting; message = String(localized: "Checking for finished work.")
        case "retrying": state = .retrying; message = String(localized: "Couldn’t reach your assistant or iCloud. The helper will try again.")
        case "sessionNotFound": state = .needsMainChat; message = String(localized: "The main chat could not be found. Open it in Nollie, then retry background alerts.")
        case "responseInvalid": state = .retrying; message = String(localized: "Couldn’t read the assistant’s response. The helper will try again.")
        case "serverRejected": state = .retrying; message = String(localized: "The assistant rejected a background check. The helper will try again.")
        case "gatewayUnavailable": state = .retrying; message = String(localized: "Couldn’t reach your assistant. The helper will try again.")
        case "iCloudUnavailable": state = .retrying; message = String(localized: "Couldn’t reach iCloud. The helper will try again.")
        case "journalDamaged": state = .failed; message = String(localized: "The saved alert queue could not be read. Background alerts need attention.")
        case "localStorageUnavailable": state = .failed; message = String(localized: "The helper could not access its saved alert queue. Background alerts need attention.")
        case "signInRequired": state = .signInRequired; message = String(localized: "Sign in to this connection again, then retry background alerts.")
        case "accountChanged": state = .stopped; message = String(localized: "The iCloud account changed. Turn iCloud alerts on again before retrying.")
        case "off": state = .stopped; message = String(localized: "iCloud alerts were turned off on another device.")
        default: state = .stopped; message = String(localized: "The helper stopped. Retry to start it.")
        }
    }

    func disable() async {
        guard !isDemo, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        var failed = false
        if var config = read() {
            config.enabled = false
            do { try write(config); configuration = config } catch { failed = true }
        }
        do { try await loginItem.unregister() } catch { failed = true }
        state = failed ? .failed : .off
        message = failed ? String(localized: "Couldn’t fully disable the helper. Check Login Items in System Settings.")
            : String(localized: "Background alerts are off.")
    }
}
#endif
