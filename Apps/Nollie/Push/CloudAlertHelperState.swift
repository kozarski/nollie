import Foundation
import NollieCore

/// Explicit shared consent. Credentials remain in the existing connection Keychain items.
struct CloudAlertHelperConfiguration: Codable, Equatable, Sendable {
    static let account = "cloudAlerts.helper.configuration.v1"
    static let bundleID = "com.coreykozarski.nollie.background-alerts"
    var version = 1
    var enabled: Bool
    let consentID: UUID
    let enabledAt: Date
    let connectionID: UUID
    let profiles: [String]
    let accountFingerprint: String
    let source: String
    /// Supplied by the app's existing main-chat lookup. Older consent records omit this field.
    var canonicalSessions: [String: String]? = nil

    var isValid: Bool {
        version == 1 && !profiles.isEmpty && profiles.count <= 20 && !source.isEmpty
            && accountFingerprint.count == 64
            && accountFingerprint.allSatisfy { "0123456789abcdef".contains($0) }
            && profiles.allSatisfy { Self.permitsProfile($0, connection: connectionID) }
            && (canonicalSessions ?? [:]).allSatisfy { profile, id in
                profile == "default" && profiles.contains(profile) && Self.permitsSessionID(id)
            }
    }

    static func permitsSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count < 256 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    /// A refreshed main-chat identity does not grant new access or reset the notification baseline.
    func hasSameConsent(as other: Self) -> Bool {
        var comparison = other
        comparison.canonicalSessions = canonicalSessions
        return self == comparison
    }

    static func permitsProfile(_ profile: String, connection: UUID? = nil) -> Bool {
        CloudAlertEvent.permits(profile: profile, connection: connection) && profile.lowercased() != "all"
            && !profile.isEmpty && profile.count <= 64
            && profile.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }
    }

    static func read() -> Self? { Keychain.getCodable(Self.self, account: account) }
    func save() throws { try Keychain.setCodable(self, account: Self.account) }
}

struct CloudAlertHelperHealth: Codable, Sendable {
    static let account = "cloudAlerts.helper.health.v1"
    let consentID: UUID
    let checkedAt: Date
    let phase: String
    let pending: Int
}

struct CloudAlertHelperPending: Codable, Equatable, Sendable {
    let id: String
    let source: String
    let kind: CloudAlertKind
    let createdAt: Date
    let expiresAt: Date
    var target: CloudAlertTarget? = nil
    var preview: CloudAlertPreview? = nil
    var attempts = 0
    var nextAttempt: Date

    init(_ event: CloudAlertEvent) {
        id = event.id; source = event.source; kind = event.kind
        createdAt = event.createdAt; expiresAt = event.expiresAt; nextAttempt = event.createdAt
        target = event.target; preview = event.preview
    }
    var event: CloudAlertEvent {
        .init(id: id, source: source, kind: kind, createdAt: createdAt, expiresAt: expiresAt, target: target, preview: preview)
    }
}

/// Only bounded final previews and routing identifiers are retained, never credentials or gateway URLs.
struct CloudAlertHelperJournal: Codable, Sendable {
    var version = 1
    let consentID: UUID
    var seen: [String: Date] = [:]
    var checkpoints: [String: String] = [:]
    var pending: [String: CloudAlertHelperPending] = [:]
    var lastCleanup: Date?

    mutating func prune(now: Date) {
        seen = seen.filter { now.timeIntervalSince($0.value) < CloudAlertEvent.retention }
        pending = pending.filter { now.timeIntervalSince($0.value.createdAt) < 24 * 3600 }
        // Checkpoints are an optimization; clearing them never replays a seen outcome.
        if checkpoints.count > 2_000 { checkpoints = [:] }
    }
}
