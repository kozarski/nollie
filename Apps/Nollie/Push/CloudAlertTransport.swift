import CloudKit
import Foundation
import Observation
import NollieCore
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
struct CloudAlertPermissionClient {
    var status: () async -> UNAuthorizationStatus
    var request: () async throws -> Void
    var register: () -> Void
    var isRegistered: () -> Bool = { false }

    static let system = Self(
        status: { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus },
        request: { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) },
        register: {
            #if os(macOS)
            NSApplication.shared.registerForRemoteNotifications()
            #else
            UIApplication.shared.registerForRemoteNotifications()
            #endif
        },
        isRegistered: {
            #if os(macOS)
            NSApplication.shared.isRegisteredForRemoteNotifications
            #else
            UIApplication.shared.isRegisteredForRemoteNotifications
            #endif
        }
    )
}

/// Explicit opt-in for an account-wide subscription. Each device still controls its own OS permission.
@MainActor
@Observable
final class CloudAlertTransport {
    static let shared = CloudAlertTransport()
    static let enabledKey = "cloudAlerts.enabled.v1"
    static let accountKey = "cloudAlerts.account.v1"
    static let sourceKey = "cloudAlerts.source.v1"

    private(set) var isEnabled: Bool
    private(set) var state: CloudAlertState
    private(set) var issue: String?
    private(set) var isWorking = false
    private(set) var registrationState: CloudAlertRegistrationState = .notRequested
    private(set) var subscriptionState: CloudAlertSubscriptionState = .notChecked
    private(set) var visibleTest: CloudAlertVisibleTest?
    private(set) var visibilityCheckedAt: Date?
    private(set) var visibilityIsLimited = false
    private(set) var visibilityIssue: String?
    private(set) var callbackDiagnostics = CloudAlertCallbackDiagnostics()
    /// A short one-way account digest is useful for comparing two devices without exposing an account ID.
    var accountComparison: String? {
        guard isEnabled else { return nil }
        return defaults.string(forKey: Self.accountKey).map { String($0.prefix(12)) }
    }
    @ObservationIgnored private let store: any CloudAlertStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let permission: CloudAlertPermissionClient
    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let privacyChanged: @MainActor (UserDefaults) -> Void
    @ObservationIgnored private let source: String
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var workID = UUID()
    @ObservationIgnored private var registrationStartedAt: Date?
    @ObservationIgnored private var notificationsAllowed = false
    @ObservationIgnored private var lastCleanup: Date?
    @ObservationIgnored private var accountObservation: CloudAlertAccountObservation?

    init(store: any CloudAlertStore = CloudKitAlertStore(), defaults: UserDefaults = .standard,
         permission: CloudAlertPermissionClient = .system,
         isDemo: Bool = Bundle.main.bundleIdentifier?.hasSuffix(".demo") == true,
         now: @escaping () -> Date = Date.init,
         privacyChanged: @escaping @MainActor (UserDefaults) -> Void = { _ = NotificationPreviewPreferences.mirror(defaults: $0) }) {
        self.store = store; self.defaults = defaults; self.permission = permission
        self.isDemo = isDemo; self.now = now
        self.privacyChanged = privacyChanged
        source = defaults.string(forKey: Self.sourceKey) ?? UUID().uuidString.lowercased()
        defaults.set(source, forKey: Self.sourceKey)
        let enabled = !isDemo && defaults.bool(forKey: Self.enabledKey)
        isEnabled = enabled
        state = enabled ? .checking : .off
        // Creating the service never constructs a CloudKit container or checks an account.
    }

    func enable() async {
        guard !isDemo else { issue = String(localized: "iCloud alerts are unavailable in the demo app."); return }
        if isWorking { await work?.value; return }
        epoch += 1
        let ticket = epoch
        await serial {
            self.state = .checking; self.issue = nil
            do {
                let account = try await self.store.accountFingerprint()
                guard self.current(ticket) else { return }
                // An explicit enable is fresh consent for this account, not restoration of old consent.
                self.defaults.set(account, forKey: Self.accountKey)
                self.mirrorPrivacy()
                var authorization = await self.permission.status()
                guard self.current(ticket) else { return }
                if authorization == .notDetermined {
                    try await self.permission.request()
                    authorization = await self.permission.status()
                }
                guard self.current(ticket) else { return }
                try await self.checkAccount()
                guard self.current(ticket) else { return }
                try await self.store.installSubscription()
                guard self.current(ticket) else { return }
                try await self.checkSubscription(ticket: ticket)
                guard self.current(ticket) else { return }
                try await self.checkAccount()
                guard self.current(ticket) else { return }
                try await self.store.setEnabled(true)
                guard self.current(ticket) else { return }
                self.setLocalEnabled(true)
                self.applyPermission(authorization)
            } catch { if self.current(ticket) { self.fail(error) } }
        }
    }

    func disable() async {
        let hadConsent = isEnabled || isWorking || defaults.string(forKey: Self.accountKey) != nil
        epoch += 1
        let ticket = epoch
        setLocalEnabled(false)
        state = .off; issue = nil
        subscriptionState = .notChecked
        guard !isDemo, hadConsent else { return }
        await serial {
            guard self.current(ticket), self.defaults.string(forKey: Self.accountKey) != nil else { return }
            do {
                try await self.checkAccount()
                guard self.current(ticket) else { return }
                // Publishers check this record before writing. Removing the subscription follows it.
                try await self.store.setEnabled(false)
                guard self.current(ticket) else { return }
                try await self.store.removeSubscription()
            } catch {
                if self.current(ticket) {
                    self.issue = String(localized: "Alerts are off here. Couldn’t turn them off on your other devices. Try again when iCloud is available.")
                }
            }
        }
    }

    /// Safe for app activation. It never prompts or accesses iCloud while this device is opted out.
    func refresh(checkTestVisibility: Bool = false) async {
        guard isEnabled, !isDemo else { return }
        if isWorking { await work?.value; return }
        let ticket = epoch
        await serial {
            do {
                try await self.checkAccount()
                guard self.current(ticket), self.isEnabled else { return }
                guard try await self.store.enabled() else {
                    self.setLocalEnabled(false); self.state = .off; return
                }
                guard self.current(ticket), self.isEnabled else { return }
                try await self.checkSubscription(ticket: ticket)
                guard self.current(ticket), self.isEnabled else { return }
                let authorization = await self.permission.status()
                guard self.current(ticket), self.isEnabled else { return }
                self.issue = nil
                self.applyPermission(authorization)
                if checkTestVisibility { await self.refreshTestVisibility(ticket: ticket) }
            } catch { if self.current(ticket) { self.fail(error) } }
        }
    }

    /// Call for CKAccountChanged. Re-enabling always requires an explicit choice afterward.
    func accountDidChange() {
        epoch += 1
        let hadConsent = isEnabled || defaults.string(forKey: Self.accountKey) != nil
        setLocalEnabled(false)
        defaults.removeObject(forKey: Self.accountKey)
        mirrorPrivacy()
        subscriptionState = .notChecked
        registrationStartedAt = nil
        notificationsAllowed = false
        state = hadConsent ? .accountChanged : .off
        issue = nil
    }

    func startObservingAccountChanges(center: NotificationCenter = .default) {
        guard accountObservation == nil, !isDemo else { return }
        accountObservation = CloudAlertAccountObservation(center: center) { [weak self] in
            Task { @MainActor [weak self] in self?.accountDidChange() }
        }
    }

    func remoteRegistrationFailed() {
        registrationState = .failed
        registrationStartedAt = nil
        guard isEnabled else { return }
        state = .failed
        // CloudAlertWords.issue matches this English and shows its own line, so it stays in English.
        issue = "Notification registration didn’t finish. Check iCloud again to retry."
    }

    /// The delegate supplies only success, never a device token. CloudKit manages its own token.
    func remoteRegistrationSucceeded() {
        guard !isDemo else { return }
        registrationState = .registered
        registrationStartedAt = nil
        if isEnabled, notificationsAllowed, subscriptionState == .valid,
           state == .registering || state == .ready {
            state = .ready
            issue = nil
        }
    }

    /// Callers supply a stable outcome key, never an entire message. The key is hashed locally.
    @discardableResult
    func publish(eventKey: String, profile: String, kind: CloudAlertKind,
                 target: CloudAlertTarget? = nil, preview: CloudAlertPreview? = nil) async -> String? {
        guard isEnabled, !isDemo, CloudAlertEvent.permits(profile: profile, connection: target?.connectionID),
              !eventKey.isEmpty, eventKey.utf8.count <= 2048 else { return nil }
        let ticket = epoch
        do {
            try await checkAccount()
            guard current(ticket), isEnabled else { return nil }
            guard try await store.enabled() else { setLocalEnabled(false); state = .off; return nil }
            guard current(ticket), isEnabled else { return nil }
            let event = CloudAlertEvent(source: source, key: eventKey, kind: kind, now: now(), target: target, preview: preview)
            try await store.create(event)
            guard current(ticket), isEnabled else { return nil }
            // Retention is bounded and scoped to this installation's opaque source ID.
            if lastCleanup.map({ now().timeIntervalSince($0) >= 24 * 3600 }) ?? true {
                lastCleanup = now()
                do { try await store.cleanExpired(source: event.source, before: now()) }
                catch { issue = "The alert was saved. Older alert cleanup will retry later." } // Matched in English and never shown.
            }
            return event.id
        } catch {
            if current(ticket) { fail(error) }
            return nil
        }
    }

    /// "Scout started using your Mac", for the iPhone, which shows it with Stop. The chat it routes
    /// to is the task's, on this Mac's gateway; the key carries no secret (it is hashed anyway).
    func publishComputerStarted(profile: String, botName: String, sessionID: String, startedAt: Date,
                                connection: GatewayConnection) async {
        // Nollie Computer names a chat "<profile>/<session>"; the alert routes to the session.
        let session = sessionID.split(separator: "/").last.map(String.init) ?? sessionID
        let target = CloudAlertTarget(connectionID: connection.id, gatewayFingerprint: CloudAlertTarget.fingerprint(for: connection.gateway),
                                      profile: profile, sessionID: session, gatewayIdentity: connection.gatewayIdentity)
        let preview = CloudAlertPreview(title: botName, body: ComputerStartedWords.body(botName: botName))
        await publish(eventKey: "computer/\(profile)/\(session)/\(Int(startedAt.timeIntervalSince1970))", profile: profile,
                      kind: .computerStarted, target: target, preview: preview)
    }

    func sendTest() async -> String? {
        await publish(eventKey: "test:" + UUID().uuidString, profile: "default", kind: .test)
    }

    func checkTest(_ eventID: String) async -> CloudAlertTestStatus? {
        guard isEnabled, !isDemo, CloudAlertEvent.isValidID(eventID) else { return nil }
        let ticket = epoch
        do {
            try await checkAccount()
            guard current(ticket), isEnabled else { return nil }
            guard let event = try await store.event(eventID) else { return CloudAlertTestStatus(stored: false) }
            guard event.kind == .test, event.source == CloudAlertEvent.digest(source), current(ticket), isEnabled else { return nil }
            let receipt = try await store.receipt(eventID)
            guard current(ticket), isEnabled else { return nil }
            return receipt ?? CloudAlertTestStatus(stored: true)
        } catch { if current(ticket) { fail(error) }; return nil }
    }

    /// A receipt confirms a callback or tap, not that a banner was visible. Source-device callbacks are ignored.
    @discardableResult
    func recordReceipt(eventID: String, opened: Bool) async -> Bool {
        guard isEnabled, !isDemo, CloudAlertEvent.isValidID(eventID) else { return false }
        let ticket = epoch
        do {
            try await checkAccount()
            guard current(ticket), isEnabled, try await store.enabled() else { return false }
            guard let event = try await store.event(eventID), event.expiresAt > now(),
                  event.source != CloudAlertEvent.digest(source), current(ticket), isEnabled else { return false }
            try await store.acknowledge(event, opened: opened, at: now())
            return true
        } catch { if current(ticket) { fail(error) }; return false }
    }

    /// Resolve only the referenced immutable event. A later reply cannot change a notification's destination.
    func openedTarget(eventID: String) async -> CloudAlertTarget? {
        guard isEnabled, !isDemo, CloudAlertEvent.isValidID(eventID) else { return nil }
        let ticket = epoch
        do {
            try await checkAccount()
            guard current(ticket), isEnabled, try await store.enabled() else { return nil }
            guard current(ticket), isEnabled,
                  let event = try await store.event(eventID), event.expiresAt > now(),
                  event.createdAt <= now().addingTimeInterval(60),
                  current(ticket), isEnabled else { return nil }
            if event.source != CloudAlertEvent.digest(source) {
                try await store.acknowledge(event, opened: true, at: now())
            }
            guard current(ticket), isEnabled, let target = event.target, target.isValid else { return nil }
            return target
        } catch { if current(ticket) { fail(error) }; return nil }
    }

    /// Foreground presentation may inspect an event without marking a notification as opened.
    func foregroundEvent(eventID: String) async -> CloudAlertEvent? {
        guard isEnabled, !isDemo, CloudAlertEvent.isValidID(eventID) else { return nil }
        let ticket = epoch
        do {
            try await checkAccount()
            guard current(ticket), isEnabled, try await store.enabled() else { return nil }
            guard current(ticket), isEnabled,
                  let event = try await store.event(eventID), event.id == eventID,
                  event.expiresAt > now(), event.createdAt <= now().addingTimeInterval(60),
                  event.expiresAt > event.createdAt,
                  event.expiresAt.timeIntervalSince(event.createdAt) <= CloudAlertEvent.retention,
                  event.target?.isValid != false, current(ticket), isEnabled else { return nil }
            try await checkAccount()
            guard current(ticket), isEnabled else { return nil }
            return event
        } catch { return nil }
    }

    func recordCallback(_ callback: CloudAlertCallback, result: CloudAlertParseResult) {
        guard isEnabled, !isDemo else { return }
        callbackDiagnostics.record(callback, result: result, at: now())
    }

    private func refreshTestVisibility(ticket: Int) async {
        guard current(ticket), isEnabled else { return }
        visibleTest = nil; visibilityCheckedAt = nil; visibilityIsLimited = false; visibilityIssue = nil
        do {
            let result = try await store.latestUnexpiredTest(at: now())
            guard current(ticket), isEnabled else { return }
            try await checkAccount()
            guard current(ticket), isEnabled else { return }
            visibleTest = result.latest.map { CloudAlertVisibleTest(event: $0, source: source) }
            visibilityCheckedAt = now()
            visibilityIsLimited = result.isLimited
        } catch {
            guard current(ticket), isEnabled else { return }
            visibilityIssue = String(localized: "Couldn’t check test records. Try Check iCloud again.")
        }
    }

    nonisolated static func eventID(from userInfo: [AnyHashable: Any]) -> String? {
        inspectPayload(userInfo).eventID
    }

    nonisolated static func inspectPayload(_ userInfo: [AnyHashable: Any]) -> CloudAlertPayloadInspection {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return .init(result: .notCloudKit)
        }
        guard let query = notification as? CKQueryNotification else { return .init(result: .unsupportedType) }
        guard let id = query.recordID?.recordName else { return .init(result: .missingRecord) }
        return inspectFields(container: query.containerIdentifier, subscription: query.subscriptionID,
                             scope: query.databaseScope, recordID: id)
    }

    nonisolated static func recognizedEventID(container: String?, subscription: String?,
                                             scope: CKDatabase.Scope, recordID: String) -> String? {
        inspectFields(container: container, subscription: subscription, scope: scope, recordID: recordID).eventID
    }

    nonisolated static func inspectFields(container: String?, subscription: String?,
                                          scope: CKDatabase.Scope, recordID: String) -> CloudAlertPayloadInspection {
        guard container == CloudKitAlertStore.containerIdentifier else { return .init(result: .containerMismatch) }
        guard subscription == CloudKitAlertStore.subscriptionID else { return .init(result: .subscriptionMismatch) }
        guard scope == .private else { return .init(result: .scopeMismatch) }
        guard CloudAlertEvent.isValidID(recordID) else { return .init(result: .invalidRecord) }
        return .init(result: .accepted, eventID: recordID)
    }

    private func checkAccount() async throws {
        let fingerprint = try await store.accountFingerprint()
        guard let expected = defaults.string(forKey: Self.accountKey), fingerprint == expected else {
            accountDidChange()
            throw CloudAlertFailure.accountChanged
        }
    }

    private func checkSubscription(ticket: Int) async throws {
        let value = try await store.subscriptionState()
        guard current(ticket) else { throw CancellationError() }
        subscriptionState = value
        switch value {
        case .valid: return
        case .legacy:
            // Upgrade the existing, explicitly enabled subscription in place. The payload
            // remains generic when an extension cannot read this device's privacy policy.
            try await store.installSubscription()
            guard current(ticket), isEnabled else { throw CancellationError() }
            guard try await store.subscriptionState() == .valid else { throw CloudAlertFailure.subscriptionInvalid }
            guard current(ticket), isEnabled else { throw CancellationError() }
            subscriptionState = .valid
        case .missing: throw CloudAlertFailure.subscriptionMissing
        case .invalid, .notChecked: throw CloudAlertFailure.subscriptionInvalid
        }
    }

    private func setLocalEnabled(_ value: Bool) {
        isEnabled = value
        defaults.set(value, forKey: Self.enabledKey)
        mirrorPrivacy()
        if !value {
            visibleTest = nil; visibilityCheckedAt = nil; visibilityIsLimited = false; visibilityIssue = nil
            callbackDiagnostics = CloudAlertCallbackDiagnostics()
        }
    }

    private func mirrorPrivacy() {
        guard !isDemo else { return }
        // Consent can flip while no settings screen is visible, including when the app is backgrounded.
        privacyChanged(defaults)
    }

    private func applyPermission(_ status: UNAuthorizationStatus) {
        notificationsAllowed = status == .authorized || status == .provisional
        if notificationsAllowed {
            if permission.isRegistered() { registrationState = .registered }
            if registrationState == .registered {
                state = .ready
                return
            }
            state = .registering
            // A pending callback is not success. A later explicit check or activation may retry.
            if registrationStartedAt.map({ now().timeIntervalSince($0) < 30 }) != true {
                registrationState = .waiting
                registrationStartedAt = now()
                permission.register()
            }
        } else {
            registrationStartedAt = nil
            state = .notificationsDenied
        }
    }

    private func current(_ ticket: Int) -> Bool { ticket == epoch && !Task.isCancelled }

    private func serial(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = work
        let id = UUID()
        workID = id; isWorking = true
        let next = Task { @MainActor in
            await previous?.value
            await operation()
        }
        work = next
        await next.value
        if workID == id { work = nil; isWorking = false }
    }

    private func fail(_ error: Error) {
        if error is CancellationError { return }
        if case CloudAlertFailure.accountChanged = error { state = .accountChanged; return }
        if case CloudAlertFailure.unavailable = error { state = .iCloudUnavailable; return }
        // The two subscription issues are matched in English by CloudAlertWords.issue, which shows
        // its own line, so they stay in English.
        if case CloudAlertFailure.subscriptionMissing = error {
            state = .failed; issue = "The iCloud alert subscription is missing. Turn iCloud alerts off and on to recreate it."; return
        }
        if case CloudAlertFailure.subscriptionInvalid = error {
            state = .failed; issue = "The iCloud alert subscription needs updating. Turn iCloud alerts off and on to repair it."; return
        }
        if let cloud = error as? CKError {
            switch cloud.code {
            case .notAuthenticated, .accountTemporarilyUnavailable: state = .iCloudUnavailable
            case .quotaExceeded:
                state = .failed; issue = String(localized: "Your iCloud storage is full. Free some space, then try again.")
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
                state = .failed; issue = String(localized: "iCloud couldn’t be reached. Try again shortly.")
            default:
                state = .failed; issue = String(localized: "iCloud alerts aren’t available in this build or account.")
            }
        } else {
            state = .failed; issue = String(localized: "Couldn’t update iCloud alerts. Try again.")
        }
    }
}

private final class CloudAlertAccountObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol
    init(center: NotificationCenter, changed: @escaping @Sendable () -> Void) {
        self.center = center
        token = center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in changed() }
    }
    deinit { center.removeObserver(token) }
}
