import Foundation
import Testing
import NollieCore
@testable import Nollie

@MainActor
struct NotificationPreviewPreferencesTests {
    @Test func freshDeviceShowsDetailsWithoutEnablingCloudAlerts() {
        withDefaults { defaults in
            #expect(!NotificationPreviewPreferences.hidesDetails(defaults: defaults))
            let policy = NotificationPreviewPreferences.policy(defaults: defaults)
            #expect(policy.showPreviews)
            #expect(policy.allowsPreview)
            #expect(!policy.cloudAlertsEnabled)
            #expect(policy.cloudAccountFingerprint == nil)
            #expect(defaults.object(forKey: NotificationPreviewPolicy.preferenceKey) == nil)
        }
    }

    @Test func hideSwitchPreservesAndUpdatesTheExistingPreference() {
        withDefaults { defaults in
            defaults.set(false, forKey: NotificationPreviewPolicy.preferenceKey)
            #expect(NotificationPreviewPreferences.hidesDetails(defaults: defaults))
            NotificationPreviewPreferences.setHidesDetails(false, defaults: defaults)
            #expect(defaults.bool(forKey: NotificationPreviewPolicy.preferenceKey))
            #expect(!NotificationPreviewPreferences.hidesDetails(defaults: defaults))
            NotificationPreviewPreferences.setHidesDetails(true, defaults: defaults)
            #expect(!defaults.bool(forKey: NotificationPreviewPolicy.preferenceKey))
            #expect(NotificationPreviewPreferences.hidesDetails(defaults: defaults))
            #expect(defaults.object(forKey: CloudAlertTransport.enabledKey) == nil)
        }
    }

    @Test func appLockStillOverridesAnExplicitDetailsChoice() {
        withDefaults { defaults in
            NotificationPreviewPreferences.setHidesDetails(false, defaults: defaults)
            defaults.set(true, forKey: AppLock.enabledKey)
            #expect(!NotificationPreviewPreferences.hidesDetails(defaults: defaults))
            #expect(!NotificationPreviewPreferences.policy(defaults: defaults).allowsPreview)
            defaults.set(false, forKey: AppLock.enabledKey)
            #expect(NotificationPreviewPreferences.policy(defaults: defaults).allowsPreview)
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "NotificationPreviewPreferencesTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
}
