import AppKit
import CloudKit
import NollieCore

@main
struct NollieAlertHelper {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AlertHelperDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class AlertHelperDelegate: NSObject, NSApplicationDelegate {
    private var runner: Task<Void, Never>?
    private var presence: Task<Void, Never>?
    private var accountObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Bundle.main.bundleIdentifier == CloudAlertHelperConfiguration.bundleID,
              let group = Keychain.sharedGroupFromBundle() else { NSApp.terminate(nil); return }
        // Nollie.app dragged to the Trash or deleted: quit and stay quiet. Nothing is deleted.
        if let watched = AppPresence.forThisHelper() {
            guard watched.check() != .gone else { NSApp.terminate(nil); return }
            presence = Task {
                guard await watched.watch() != nil else { return }
                NSApp.terminate(nil)
            }
        }
        Keychain.accessGroup = group
        // No migration, credential prompts or app runtime is initialized here.
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                if let config = CloudAlertHelperConfiguration.read() { self?.recordHealth(config, phase: "accountChanged", pending: 0) }
                NSApp.terminate(nil)
            }
        }
        runner = Task { await observe() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runner?.cancel()
        presence?.cancel()
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    private func observe() async {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nollie Notifications", isDirectory: true)
        let persistence = FileCloudAlertHelperPersistence(directory: directory)
        let cloud = CloudKitAlertStore()
        var failures = 0
        while !Task.isCancelled {
            guard let config = CloudAlertHelperConfiguration.read(), config.enabled, config.isValid else { break }
            do {
                recordHealth(config, phase: "checking", pending: 0)
                // Re-read the shared Keychain so an app sign-in or deleted connection takes effect.
                let store = ConnectionStore()
                guard let connection = store.connection(id: config.connectionID) else { throw CloudAlertHelperFailure.unavailable }
                let source = await HermesCloudAlertOutcomeSource(connection: connection, store: store)
                let observer = CloudAlertHelperObserver(source: source, cloud: cloud, persistence: persistence,
                                                       consent: CloudAlertHelperConfiguration.read,
                                                       gatewayFingerprint: CloudAlertTarget.fingerprint(for: connection.gateway))
                let pending = try await observer.tick(config)
                recordHealth(config, phase: "ready", pending: pending)
                failures = 0
            } catch CloudAlertHelperFailure.invalidConsent { break }
            catch CloudAlertHelperFailure.configurationChanged { continue }
            catch CloudAlertHelperFailure.mainChatUnknown {
                failures = 0
                recordHealth(config, phase: "mainChatUnknown", pending: 0)
            }
            catch CloudAlertHelperFailure.accountChanged { recordHealth(config, phase: "accountChanged", pending: 0); break }
            catch CloudAlertHelperFailure.expired { recordHealth(config, phase: "off", pending: 0); break }
            catch {
                failures += 1
                recordHealth(config, phase: CloudAlertHelperIssue.classify(error).rawValue, pending: 0)
            }
            do { try await Task.sleep(for: .seconds(failures == 0 ? 20 : min(300, CloudAlertOutcomePolicy.retryDelay(attempt: failures)))) }
            catch { break }
        }
        NSApp.terminate(nil)
    }

    private func recordHealth(_ config: CloudAlertHelperConfiguration, phase: String, pending: Int) {
        try? Keychain.setCodable(CloudAlertHelperHealth(consentID: config.consentID, checkedAt: .now,
                                                     phase: phase, pending: pending), account: CloudAlertHelperHealth.account)
    }
}
