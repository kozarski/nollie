import CloudKit
import Foundation
import UserNotifications
import NollieCore

/// The APNs payload stays generic. Only the receiving device can opt into displaying a private preview.
@MainActor
final class CloudAlertNotificationResolver {
    private let store: any CloudAlertStore
    private let policy: () -> NotificationPreviewPolicy?
    private let now: () -> Date

    init(store: any CloudAlertStore = CloudKitAlertStore(),
         policy: @escaping () -> NotificationPreviewPolicy? = NotificationPreviewPolicy.load,
         now: @escaping () -> Date = Date.init) {
        self.store = store; self.policy = policy; self.now = now
    }

    func event(_ eventID: String) async -> CloudAlertEvent? {
        await resolve(eventID).event
    }

    func resolve(_ eventID: String) async -> CloudAlertPreviewResolution {
        guard !Task.isCancelled, CloudAlertEvent.isValidID(eventID) else { return .init(.invalidEvent) }
        guard let original = policy() else { return .init(.policyUnavailable) }
        if let reason = CloudAlertPreviewResolution.policyFailure(original) { return .init(reason) }
        do {
            let account = try await store.accountFingerprint()
            guard original.permitsCloudAccount(account) else { return .init(.accountMismatch) }
            guard policy() == original, !Task.isCancelled else { return .init(.privacyChanged) }
            guard try await store.enabled() else { return .init(.alertsDisabled) }
            guard policy() == original, !Task.isCancelled else { return .init(.privacyChanged) }
            guard let event = try await store.event(eventID) else { return .init(.eventUnavailable) }
            guard event.id == eventID, event.expiresAt > now(), event.createdAt <= now().addingTimeInterval(60),
                  event.expiresAt > event.createdAt,
                  event.expiresAt.timeIntervalSince(event.createdAt) <= CloudAlertEvent.retention,
                  event.source.count == 64, event.source.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                return .init(.invalidEvent)
            }
            guard event.target != nil, event.preview != nil else { return .init(.detailsUnavailable) }
            guard event.target?.isValid == true, event.preview?.isValid == true else { return .init(.invalidEvent) }
            guard try await store.accountFingerprint() == account else { return .init(.accountMismatch) }
            guard policy() == original, !Task.isCancelled else { return .init(.privacyChanged) }
            return .init(.detailsReady, event: event)
        } catch { return .init(.iCloudUnavailable) }
    }

    nonisolated static func eventID(in userInfo: [AnyHashable: Any]) -> String? {
        guard let query = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              query.containerIdentifier == CloudKitAlertStore.containerIdentifier,
              query.subscriptionID == CloudKitAlertStore.subscriptionID,
              query.databaseScope == .private, let id = query.recordID?.recordName,
              CloudAlertEvent.isValidID(id) else { return nil }
        return id
    }
}

/// Only fixed outcomes and a time are retained. No notification text, routes or account identifiers are recorded.
struct CloudAlertPreviewDiagnostic: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case checking, detailsReady, detailsSupplied, policyUnavailable, detailsHidden, appLocked
        case alertsDisabled, accountUnavailable, accountMismatch, eventUnavailable, detailsUnavailable
        case invalidEvent, privacyChanged, iCloudUnavailable, timedOut

        var message: String {
            switch self {
            case .checking: "Checking saved reply details"
            case .detailsReady: "Reply details verified"
            case .detailsSupplied: "Reply details supplied to the system"
            case .policyUnavailable: "Notification privacy settings were unavailable"
            case .detailsHidden: "Hide notification details is on"
            case .appLocked: "App Lock keeps details hidden"
            case .alertsDisabled: "iCloud alerts were off"
            case .accountUnavailable: "The saved iCloud account check was unavailable"
            case .accountMismatch: "The iCloud account check did not match"
            case .eventUnavailable: "The saved alert was unavailable"
            case .detailsUnavailable: "This alert has no saved reply details"
            case .invalidEvent: "The saved alert was invalid or expired"
            case .privacyChanged: "Notification privacy changed during delivery"
            case .iCloudUnavailable: "iCloud could not provide the saved reply"
            case .timedOut: "The system ended the preview lookup"
            }
        }
    }

    static let account = "notifications.previewDiagnostic.v1"
    let outcome: Outcome
    let at: Date

    static func record(_ outcome: Outcome) {
        try? Keychain.setCodable(Self(outcome: outcome, at: .now), account: account)
    }

    static func load() -> Self? { Keychain.getCodable(Self.self, account: account) }
}

struct CloudAlertPreviewResolution: Sendable {
    let outcome: CloudAlertPreviewDiagnostic.Outcome
    let event: CloudAlertEvent?

    init(_ outcome: CloudAlertPreviewDiagnostic.Outcome, event: CloudAlertEvent? = nil) {
        self.outcome = outcome; self.event = event
    }

    static func policyFailure(_ policy: NotificationPreviewPolicy) -> CloudAlertPreviewDiagnostic.Outcome? {
        guard policy.version == 1 else { return .policyUnavailable }
        guard policy.showPreviews else { return .detailsHidden }
        guard !policy.appLockEnabled else { return .appLocked }
        guard policy.cloudAlertsEnabled else { return .alertsDisabled }
        guard let account = policy.cloudAccountFingerprint, account.count == 64,
              account.allSatisfy({ "0123456789abcdef".contains($0) }) else { return .accountUnavailable }
        return nil
    }
}

/// Expiry and an asynchronous fetch can race. The system handler is called exactly once.
final class NotificationDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent
    private var task: Task<Void, Never>?

    init(fallback: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.fallback = fallback.copy() as! UNNotificationContent
        self.handler = handler
    }

    var isFinished: Bool { lock.withLock { handler == nil } }

    /// Decryption may reveal a safe tap destination even when its visible text must stay hidden.
    func updateRouting(_ userInfo: [AnyHashable: Any]) {
        lock.withLock {
            guard handler != nil, let copy = fallback.mutableCopy() as? UNMutableNotificationContent else { return }
            copy.userInfo = userInfo
            fallback = copy.copy() as! UNNotificationContent
        }
    }

    func track(_ task: Task<Void, Never>) {
        let finished = lock.withLock {
            guard handler != nil else { return true }
            self.task = task
            return false
        }
        if finished { task.cancel() }
    }

    @discardableResult
    func finish(_ content: UNNotificationContent? = nil) -> Bool {
        let (completion, running, generic) = lock.withLock { () -> (((UNNotificationContent) -> Void)?, Task<Void, Never>?, UNNotificationContent) in
            let result = (handler, task, fallback)
            handler = nil
            task = nil
            return result
        }
        running?.cancel()
        completion?(content ?? generic)
        return completion != nil
    }
}
