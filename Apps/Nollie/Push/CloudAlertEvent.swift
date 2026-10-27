import CryptoKit
import Foundation
import NollieCore

enum CloudAlertKind: String, Sendable, Codable {
    case replyReady, needsAttention, test
    /// A helper started using the Mac (Nollie Computer). The iPhone shows it with a Stop button.
    case computerStarted
}

struct CloudAlertTarget: Codable, Equatable, Sendable {
    let connectionID: UUID
    let gatewayFingerprint: String
    let profile: String
    let sessionID: String
    var messageRowID: Int? = nil
    var gatewayIdentity: String? = nil

    var isValid: Bool {
        gatewayFingerprint.count == 64 && gatewayFingerprint.allSatisfy { "0123456789abcdef".contains($0) }
            && CloudAlertEvent.permits(profile: profile, connection: connectionID) && profile.lowercased() != "all"
            && Self.isIdentifier(profile, maximum: 64) && Self.isIdentifier(sessionID, maximum: 255)
            && messageRowID.map { $0 > 0 } != false
            && gatewayIdentity.map(GatewayIdentity.isValid) != false
    }

    static func fingerprint(for gateway: GatewayURL) -> String {
        var components = URLComponents(url: gateway.base, resolvingAgainstBaseURL: false)!
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        return CloudAlertEvent.digest(components.string ?? gateway.description)
    }

    private static func isIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

struct CloudAlertPreview: Codable, Equatable, Sendable {
    static let genericTitle = "Nollie"
    static let genericBody = String(localized: "There’s an update waiting for you in Nollie.")
    let title: String
    let body: String

    init(title: String = genericTitle, body: String) {
        self.title = Self.bounded(title, limit: 64)
        self.body = Self.bounded(body, limit: 240)
    }

    var isValid: Bool {
        !title.isEmpty && !body.isEmpty && title == Self.bounded(title, limit: 64) && body == Self.bounded(body, limit: 240)
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        let scalars = value.unicodeScalars.prefix(limit * 8)
        let printable = String(String.UnicodeScalarView(scalars.filter {
            !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }))
        let line = printable.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var result = ""
        var bytes = 0
        for character in line.prefix(limit) {
            let length = character.utf8.count
            guard bytes + length <= limit * 4 - 3 else { break }
            result.append(character); bytes += length
        }
        if result != line || scalars.count < value.unicodeScalars.count {
            if result.count == limit { result.removeLast() }
            return result + "…"
        }
        return result
    }
}

/// Routing contains no gateway URL or credentials. Optional previews contain only a bounded final answer.
struct CloudAlertEvent: Equatable, Sendable {
    static let recordType = "NollieAlertEventV1"
    static let retention: TimeInterval = 7 * 24 * 3600
    let id: String
    let source: String
    let kind: CloudAlertKind
    let createdAt: Date
    let expiresAt: Date
    var target: CloudAlertTarget? = nil
    var preview: CloudAlertPreview? = nil

    init(source: String, key: String, kind: CloudAlertKind, now: Date,
         target: CloudAlertTarget? = nil, preview: CloudAlertPreview? = nil) {
        self.source = Self.digest(source)
        id = "oa1_" + Self.digest(source + "\u{0}" + key)
        self.kind = kind
        createdAt = now
        expiresAt = now.addingTimeInterval(Self.retention)
        self.target = target?.isValid == true ? target : nil
        self.preview = preview?.isValid == true ? preview : nil
    }

    init(id: String, source: String, kind: CloudAlertKind, createdAt: Date, expiresAt: Date,
         target: CloudAlertTarget? = nil, preview: CloudAlertPreview? = nil) {
        self.id = id; self.source = source; self.kind = kind
        self.createdAt = createdAt; self.expiresAt = expiresAt
        self.target = target; self.preview = preview
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidID(_ value: String) -> Bool {
        value.count == 68 && value.hasPrefix("oa1_") && value.dropFirst(4).allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// Whether an alert may be made for this bot. The Private list is read afresh: this runs in the
    /// helper and the app, and either may have changed it. Unreadable counts as private.
    static func permits(profile: String, connection: UUID? = nil) -> Bool {
        let name = profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !name.isEmpty && !PrivateBots.isPrivate(name, connection: connection, fresh: true)
    }
}

struct CloudAlertTestStatus: Equatable, Sendable {
    let stored: Bool
    var receivedAt: Date?
    var openedAt: Date?

    var message: String {
        if openedAt != nil { return String(localized: "Opened on another device.") }
        if receivedAt != nil { return String(localized: "Received by Nollie on another device. Check that device for the alert.") }
        if stored { return String(localized: "Saved to iCloud. Delivery to another device is not confirmed yet.") }
        return String(localized: "This test is no longer in iCloud.")
    }
}

struct CloudAlertTestLookup: Equatable, Sendable {
    var latest: CloudAlertEvent?
    var isLimited = false

    static func select(from events: [CloudAlertEvent], at date: Date, isLimited: Bool) -> Self {
        Self(latest: events.filter {
            $0.kind == .test && $0.expiresAt > date && CloudAlertEvent.isValidID($0.id)
        }.max { $0.createdAt < $1.createdAt }, isLimited: isLimited)
    }
}

/// A record read is independent of an APNs callback or a delivery receipt.
struct CloudAlertVisibleTest: Equatable, Sendable {
    let shortID: String
    let createdAt: Date
    let isThisDevice: Bool

    init(event: CloudAlertEvent, source: String) {
        shortID = String(event.id.dropFirst(4).prefix(12))
        createdAt = event.createdAt
        isThisDevice = event.source == CloudAlertEvent.digest(source)
    }
}

// The raw values are fixed names for counting; CloudAlertWords says them for people.
enum CloudAlertCallback: String, CaseIterable, Sendable {
    case remote = "Remote callback"
    case foreground = "Foreground callback"
    case opened = "Notification opened"
}

enum CloudAlertParseResult: String, CaseIterable, Sendable {
    case accepted = "Recognized Nollie alert"
    case notCloudKit = "Not a CloudKit notification"
    case unsupportedType = "Different CloudKit notification type"
    case missingRecord = "Missing record identifier"
    case containerMismatch = "Different or missing container"
    case subscriptionMismatch = "Different or missing subscription"
    case scopeMismatch = "Different database scope"
    case invalidRecord = "Invalid record identifier"
}

struct CloudAlertPayloadInspection: Equatable, Sendable {
    let result: CloudAlertParseResult
    var eventID: String?
}

/// Only bounded counters, timestamps and fixed classifications are retained, never payloads.
struct CloudAlertCallbackDiagnostics: Equatable, Sendable {
    private(set) var callbacks: [CloudAlertCallback: Int] = [:]
    private(set) var results: [CloudAlertParseResult: Int] = [:]
    private(set) var lastCallback: CloudAlertCallback?
    private(set) var lastResult: CloudAlertParseResult?
    private(set) var lastAt: Date?

    mutating func record(_ callback: CloudAlertCallback, result: CloudAlertParseResult, at: Date) {
        callbacks[callback] = min((callbacks[callback] ?? 0) + 1, 1_000_000)
        results[result] = min((results[result] ?? 0) + 1, 1_000_000)
        lastCallback = callback; lastResult = result; lastAt = at
    }
}

enum CloudAlertState: Equatable, Sendable {
    case off, checking, registering, ready, iCloudUnavailable, notificationsDenied, accountChanged, failed

    var message: String {
        switch self {
        case .off: String(localized: "iCloud alerts are off.")
        case .checking: String(localized: "Checking iCloud alerts…")
        case .registering: String(localized: "Waiting for Apple to register this device for alerts…")
        case .ready: String(localized: "iCloud alerts are on.")
        case .iCloudUnavailable: String(localized: "Sign in to iCloud in System Settings to use alerts.")
        case .notificationsDenied: String(localized: "Allow Nollie notifications in Settings to see alerts on this device.")
        case .accountChanged: String(localized: "Your iCloud account changed. Turn alerts on again for this account.")
        case .failed: String(localized: "iCloud alerts need attention.")
        }
    }
}

enum CloudAlertFailure: Error, Sendable {
    case unavailable, invalidRecord, accountChanged, disabled, subscriptionMissing, subscriptionInvalid
}

enum CloudAlertRegistrationState: String, Sendable {
    case notRequested, waiting, registered, failed
}

enum CloudAlertSubscriptionState: String, Sendable {
    case notChecked, valid, legacy, missing, invalid
}
