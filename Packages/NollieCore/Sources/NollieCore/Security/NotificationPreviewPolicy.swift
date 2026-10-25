import Foundation

/// Device-local display preferences mirrored for notification extensions through the shared Keychain.
public struct NotificationPreviewPolicy: Codable, Equatable, Sendable {
    public static let preferenceKey = "notifications.showMessagePreviews"
    public static let defaultShowPreviews = true
    public static let account = "notifications.previewPolicy.v1"
    public let version: Int
    public let showPreviews: Bool
    public let appLockEnabled: Bool
    public let cloudAlertsEnabled: Bool
    public let cloudAccountFingerprint: String?

    public init(showPreviews: Bool, appLockEnabled: Bool, cloudAlertsEnabled: Bool,
                cloudAccountFingerprint: String?) {
        version = 1
        self.showPreviews = showPreviews; self.appLockEnabled = appLockEnabled
        self.cloudAlertsEnabled = cloudAlertsEnabled; self.cloudAccountFingerprint = cloudAccountFingerprint
    }

    public var allowsPreview: Bool { version == 1 && showPreviews && !appLockEnabled }

    public func allowsPreview(matching expected: Self?) -> Bool {
        allowsPreview && (expected == nil || (self == expected && cloudAlertsEnabled))
    }

    public func permitsCloudAccount(_ fingerprint: String) -> Bool {
        allowsPreview && cloudAlertsEnabled && fingerprint.count == 64 && fingerprint == cloudAccountFingerprint
    }

    public static func load() -> Self? {
        guard let policy = Keychain.getCodable(Self.self, account: account), policy.version == 1 else { return nil }
        return policy
    }

    public func save() throws { try Keychain.setCodable(self, account: Self.account) }
}
