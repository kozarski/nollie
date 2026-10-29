import Foundation
import LocalAuthentication
import Observation
import NollieCore

/// Optional lock backed by biometrics or the device passcode. It runs at launch, and when the app
/// returns after the person has been away for more than a few seconds.
@MainActor
@Observable
final class AppLock {
    static let enabledKey = "appLockEnabled"
    /// How long the app can be away before it asks again.
    private static let grace: TimeInterval = 5

    private(set) var isLocked: Bool
    private(set) var lastError: String?
    private var leftAt: Date?

    init() {
        isLocked = AppLock.savedSetting
    }

    private static var savedSetting: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    var isEnabled: Bool {
        get { Self.savedSetting }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            NotificationPreviewPreferences.mirror()
            if newValue == false { isLocked = false }
        }
    }

    /// What the device will ask with, for button text. Settings matches on "Passcode", so it stays in
    /// English; show it through `RememberedSignInCopy.shownMethod(_:)`.
    var biometryName: String {
        let probe = LAContext()
        _ = probe.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        let names: [LABiometryType: String] = [.faceID: "Face ID", .touchID: "Touch ID", .opticID: "Optic ID"]
        return names[probe.biometryType] ?? "Passcode"
    }

    func didEnterBackground() {
        leftAt = .now
    }

    func willEnterForeground() {
        defer { leftAt = nil }
        guard isEnabled, let leftAt else { return }
        if Date.now.timeIntervalSince(leftAt) > Self.grace { isLocked = true }
    }

    func unlock() async {
        let check = LAContext()
        check.localizedCancelTitle = String(localized: "Cancel")
        var unavailable: NSError?
        guard check.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else {
            // No way to authenticate on this device: do not lock the person out.
            lastError = unavailable?.localizedDescription ?? String(localized: "Authentication unavailable")
            isLocked = false
            return
        }
        do {
            let passed = try await check.evaluatePolicy(.deviceOwnerAuthentication,
                                                        localizedReason: String(localized: "Unlock Nollie", comment: "Safety: why Face ID is asked"))
            guard passed else { return }
            (isLocked, lastError) = (false, nil)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
