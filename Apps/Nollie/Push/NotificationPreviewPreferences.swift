import SwiftUI
import NollieCore

@MainActor
enum NotificationPreviewPreferences {
    static func hidesDetails(defaults: UserDefaults = .standard) -> Bool {
        !policy(defaults: defaults).showPreviews
    }

    static func setHidesDetails(_ hidden: Bool, defaults: UserDefaults = .standard) {
        // Keep the existing positive preference so an earlier privacy choice is never reset.
        defaults.set(!hidden, forKey: NotificationPreviewPolicy.preferenceKey)
    }

    static func policy(defaults: UserDefaults = .standard) -> NotificationPreviewPolicy {
        NotificationPreviewPolicy(
            showPreviews: defaults.object(forKey: NotificationPreviewPolicy.preferenceKey) as? Bool
                ?? NotificationPreviewPolicy.defaultShowPreviews,
            appLockEnabled: defaults.bool(forKey: AppLock.enabledKey),
            cloudAlertsEnabled: defaults.bool(forKey: CloudAlertTransport.enabledKey),
            cloudAccountFingerprint: defaults.string(forKey: CloudAlertTransport.accountKey)
        )
    }

    @discardableResult
    static func mirror(defaults: UserDefaults = .standard) -> Bool {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".demo") != true else { return true }
        do {
            try policy(defaults: defaults).save()
            return true
        } catch {
            // An absent mirror makes the extension use its generic fallback.
            Keychain.delete(account: NotificationPreviewPolicy.account)
            return false
        }
    }
}

private struct NotificationPreviewPolicyModifier: ViewModifier {
    @AppStorage(NotificationPreviewPolicy.preferenceKey) private var previews = NotificationPreviewPolicy.defaultShowPreviews
    @AppStorage(AppLock.enabledKey) private var locked = false
    @AppStorage(CloudAlertTransport.enabledKey) private var cloudEnabled = false
    @AppStorage(CloudAlertTransport.accountKey) private var account = ""

    private var policy: NotificationPreviewPolicy {
        .init(showPreviews: previews, appLockEnabled: locked, cloudAlertsEnabled: cloudEnabled,
              cloudAccountFingerprint: account.isEmpty ? nil : account)
    }

    func body(content: Content) -> some View {
        content.onChange(of: policy, initial: true) { _, _ in
            NotificationPreviewPreferences.mirror()
        }
    }
}

extension View {
    func notificationPreviewPolicy() -> some View { modifier(NotificationPreviewPolicyModifier()) }
}
