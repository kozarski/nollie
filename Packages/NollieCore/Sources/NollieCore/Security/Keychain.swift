import Foundation
import LocalAuthentication
import Security

/// The app's generic-password Keychain items. When an access group is set, items live there, so
/// the app and its extensions can read the same gateways without an App Group.
public enum Keychain {
    /// The Keychain service for gateways and the small shared bits beside them.
    public static let service = baseBundleID + ".gateways"

    /// The app's own bundle id. An extension or helper reports a longer one, so the first known
    /// suffix is cut off and every process agrees on one id.
    public static var baseBundleID: String {
        let own = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        let suffixes = [".notificationcontent", ".notificationservice", ".notifications", ".background-alerts"]
        for suffix in suffixes {
            if let hit = own.range(of: suffix) { return String(own[..<hit.lowerBound]) }
        }
        return own
    }

    /// Shared access group from `keychain-access-groups`, assigned once at launch. While nil, the default group applies.
    nonisolated(unsafe) public static var accessGroup: String?

    /// Looks like "<team prefix><base id>.shared"; nil if the build has no prefix.
    public static func sharedGroupFromBundle() -> String? {
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String
        guard let prefix, !prefix.isEmpty else { return nil }
        return "\(prefix)\(baseBundleID).shared"
    }

    // MARK: Queries

    /// The attributes every item of ours shares. On the Mac they also select the iOS-style keychain,
    /// because the older file keychain ignores access groups and protection classes.
    static func itemQuery(service: String, account: String? = nil, localOnly: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        // iCloud Keychain must not carry these.
        if localOnly { query[kSecAttrSynchronizable as String] = false }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    /// A control that creates a protected item: `protection` plus the check the person must pass.
    static func makeAccessControl(_ protection: CFString, _ flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        var failure: Unmanaged<CFError>?
        if let control = SecAccessControlCreateWithFlags(nil, protection, flags, &failure) { return control }
        if let failure { throw failure.takeRetainedValue() as Error }
        throw KeychainError(status: errSecParam)
    }

    /// Whether a delete's answer means the item is not there any more.
    static func isGone(_ status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }

    /// One lookup, answered with the status and whatever came back.
    static func lookup(_ request: [String: Any]) -> (status: OSStatus, found: AnyObject?) {
        var found: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &found)
        return (status, found)
    }

    /// The data of the one item `request` names. nil when there is none; anything else that goes
    /// wrong is thrown. `context` is a check that already passed, so no second prompt appears.
    static func readData(_ request: [String: Any], context: LAContext?) throws -> Data? {
        var asked = request
        asked[kSecReturnData as String] = true
        asked[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context { asked[kSecUseAuthenticationContext as String] = context }
        let answer = lookup(asked)
        if answer.status == errSecItemNotFound { return nil }
        if answer.status != errSecSuccess { throw KeychainError(status: answer.status) }
        return answer.found as? Data
    }

    /// A context that can never put up a prompt, for the calls that must stay quiet.
    static func quietContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private static func gatewayQuery(_ account: String) -> [String: Any] {
        itemQuery(service: service, account: account)
    }

    // MARK: Reading and writing

    public static func set(_ data: Data, account: String) throws {
        if memoryOnly { demoStore.put(data, for: account); return }
        let match = gatewayQuery(account)
        let fresh: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        switch SecItemUpdate(match as CFDictionary, fresh as CFDictionary) {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let status = SecItemAdd(match.merging(fresh) { _, new in new } as CFDictionary, nil)
            if status != errSecSuccess { throw KeychainError(status: status) }
        case let other:
            throw KeychainError(status: other)
        }
    }

    public static func get(account: String) -> Data? {
        if memoryOnly { return demoStore.value(for: account) }
        var query = gatewayQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess else { return nil }
        return found as? Data
    }

    public static func delete(account: String) {
        if memoryOnly { demoStore.put(nil, for: account); return }
        let outcome = SecItemDelete(gatewayQuery(account) as CFDictionary)
        _ = outcome
    }

    /// Values are kept as JSON.
    public static func setCodable<T: Encodable>(_ value: T, account: String) throws {
        let json = try JSONEncoder().encode(value)
        try set(json, account: account)
    }

    public static func getCodable<T: Decodable>(_ type: T.Type, account: String) -> T? {
        guard let json = get(account: account) else { return nil }
        let value = try? JSONDecoder().decode(type, from: json)
        return value
    }

    /// Removes every item of one service, whichever group holds it: part of Remove Nollie.
    /// True when nothing is left.
    @discardableResult
    public static func deleteAll(service: String) -> Bool {
        if memoryOnly { demoStore.clear(); return true }
        return isGone(SecItemDelete(itemQuery(service: service) as CFDictionary))
    }

    /// Items saved before the shared group existed are copied into it so the widgets can see them.
    /// Nothing that is already in the group is overwritten, and nothing is removed from the old place.
    public static func migrateToAccessGroupIfNeeded() {
        if memoryOnly { return }
        guard let target = accessGroup else { return }
        var listing = itemQuery(service: service)
        listing[kSecReturnAttributes as String] = true
        listing[kSecReturnData as String] = true
        listing[kSecMatchLimit as String] = kSecMatchLimitAll
        var found: AnyObject?
        guard SecItemCopyMatching(listing as CFDictionary, &found) == errSecSuccess,
              let rows = found as? [[String: Any]] else { return }
        let outside = rows.filter { ($0[kSecAttrAccessGroup as String] as? String) != target }
        for row in outside {
            guard let account = row[kSecAttrAccount as String] as? String,
                  let data = row[kSecValueData as String] as? Data else { continue }
            var copy = gatewayQuery(account)
            copy[kSecValueData as String] = data
            copy[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            _ = SecItemAdd(copy as CFDictionary, nil)
        }
    }

    // MARK: Demo

    /// When true the real Keychain is left alone: items sit in memory and vanish once it is turned off.
    /// The debug demo copy (separate bundle id, ad-hoc signed) cannot use the Keychain at all, so it
    /// stays on throughout. A "Try a demo" session turns it on for its duration, which keeps a demo
    /// away from any saved gateway.
    nonisolated(unsafe) public static var memoryOnly = false
    private static let demoStore = DemoStore()

    /// Forgets everything kept in memory.
    public static func clearMemory() { demoStore.clear() }

    private final class DemoStore: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [String: Data] = [:]
        func value(for key: String) -> Data? { lock.withLock { rows[key] } }
        func put(_ data: Data?, for key: String) { lock.withLock { rows[key] = data } }
        func clear() { lock.withLock { rows.removeAll() } }
    }
}

/// A Keychain call that came back with something other than success.
public struct KeychainError: LocalizedError {
    public let status: OSStatus

    /// The person said no to the Face ID, Touch ID or passcode prompt.
    public var wasCancelled: Bool { status == errSecUserCanceled }

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        let code = String(status)
        return "Keychain error " + code
    }
}
