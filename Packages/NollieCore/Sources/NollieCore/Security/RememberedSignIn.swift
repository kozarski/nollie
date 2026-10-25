import Foundation
import LocalAuthentication
import Observation
import Security

// MARK: - The sign-in itself

/// Credentials the person chose to keep on this device for a single gateway, which lets a later
/// sign-in skip typing. They get a dedicated Keychain entry (see `KeychainRememberedSignInBackend`)
/// and are deliberately left out of `GatewaySecrets`, so code that duplicates that type cannot copy them.
public struct RememberedSignIn: Codable, Equatable, Sendable, CustomStringConvertible,
                                CustomDebugStringConvertible, CustomReflectable {
    /// Where it was typed. The password goes only there, like a browser's saved password for its own
    /// site. Items saved before this existed have no address and are never used.
    public var gateway: GatewayURL?
    public var password: String
    public var username: String
    public var provider: String

    public init(provider: String, username: String, password: String, gateway: GatewayURL) {
        self.gateway = gateway
        self.password = password
        self.username = username
        self.provider = provider
    }

    /// Only matches the address it was entered for.
    public func belongs(to address: GatewayURL) -> Bool { address == gateway }

    // Logs, `print` and `dump` say a sign-in exists and for which provider, nothing more.
    public var description: String { "RememberedSignIn(provider: " + provider + ", credentials hidden)" }
    public var debugDescription: String { String(describing: self) }
    public var customMirror: Mirror {
        let visible: KeyValuePairs<String, Any> = ["provider": provider]
        return Mirror(reflecting: visible)
    }
}

// MARK: - Storage

/// Where these live: the Keychain on a real device, a simple in-memory stand-in for tests and demos.
public protocol RememberedSignInBackend: RememberedSignInShelf, RememberedSignInLookup {}

/// The half of a backend that changes what is stored.
public protocol RememberedSignInShelf: AnyObject {
    /// A false result means the entry could survive, since the delete did not go through (locked
    /// device). Removing something absent still reports success.
    @discardableResult func delete(account: String) -> Bool
    func write(_ data: Data, account: String) throws
}

/// The half that only looks.
public protocol RememberedSignInLookup: AnyObject {
    /// Lists every account holding an item without unlocking anything. nil means the lookup itself
    /// failed, which is not the same as an empty list.
    func accounts() -> [String]?
    /// The stored bytes, or nil when nothing is there. `context` is a Face ID or passcode check that
    /// already passed, so the system does not ask again.
    func read(account: String, context: LAContext?) throws -> Data?
}

/// Keychain at maximum strictness. Entries never leave this device or sync anywhere, need a
/// passcode to exist, and open only with Touch ID, Face ID or the passcode.
public final class KeychainRememberedSignInBackend: RememberedSignInBackend {
    public init() {}

    /// If the passcode is removed the item is erased, and no backup can bring it back on another device.
    public static var protection: CFString { kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
    /// Separate from `Keychain.service` on purpose. The access-group migration reads every item under
    /// the gateway service, so these would raise a Face ID prompt during launch.
    public static let service: String = Keychain.baseBundleID + ".remembered"
    /// Face ID or Touch ID, falling back to the passcode (the Mac's password) without biometry.
    public static let accessFlags = SecAccessControlCreateFlags.userPresence

    /// Finds one item, or all of them when `account` is nil. Never synchronizable, so iCloud
    /// Keychain cannot carry it.
    public static func query(account: String?) -> [String: Any] {
        Keychain.itemQuery(service: service, account: account, localOnly: true)
    }

    public static func accessControl() throws -> SecAccessControl {
        try Keychain.makeAccessControl(protection, accessFlags)
    }

    /// What a new item is saved with. The access control already holds the protection class, and
    /// setting `kSecAttrAccessible` next to it makes the system refuse the add.
    public static func addAttributes(_ data: Data, account: String) throws -> [String: Any] {
        let guarded = try accessControl()
        return query(account: account).merging([
            kSecValueData as String: data,
            kSecAttrAccessControl as String: guarded,
        ]) { _, fresh in fresh }
    }

    /// True for gone or never present. Any other status leaves the item alone, including
    /// errSecInteractionNotAllowed: a locked device cannot reach the item, and that includes removing it.
    public static func deleted(status: OSStatus) -> Bool { Keychain.isGone(status) }

    /// Interprets a listing result. An empty result is a genuine answer, but a locked device is not:
    /// it hides even attributes (errSecInteractionNotAllowed). We used to read that as zero entries, and
    /// every remembered sign-in vanished until the next relaunch.
    public static func accounts(status: OSStatus, found: AnyObject?) -> [String]? {
        switch status {
        case errSecItemNotFound:
            return []
        case errSecSuccess:
            guard let rows = found as? [[String: Any]] else { return nil }
            return rows.compactMap { $0[kSecAttrAccount as String] as? String }
        default:
            return nil
        }
    }

    public func accounts() -> [String]? {
        // Listing attributes needs no Face ID, and a context forbidden to prompt ensures none shows up.
        let listing = Self.query(account: nil).merging([
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: Keychain.quietContext(),
        ]) { _, fresh in fresh }
        let answer = Keychain.lookup(listing)
        return Self.accounts(status: answer.status, found: answer.found).map { Array(Set($0)).sorted() }
    }

    @discardableResult public func delete(account: String) -> Bool {
        let status = SecItemDelete(Self.query(account: account) as CFDictionary)
        return Self.deleted(status: status)
    }

    public func write(_ data: Data, account: String) throws {
        // Replace by deleting and adding. Updating a protected entry prompts for biometrics while a
        // delete does not, and the password was typed by hand a moment ago anyway.
        delete(account: account)
        let outcome = SecItemAdd(try Self.addAttributes(data, account: account) as CFDictionary, nil)
        if outcome != errSecSuccess { throw KeychainError(status: outcome) }
    }

    public func read(account: String, context: LAContext?) throws -> Data? {
        try Keychain.readData(Self.query(account: account), context: context)
    }
}

/// Dictionary-backed stand-in for the Keychain, used by tests and the demo build.
public final class MemoryRememberedSignInBackend: RememberedSignInBackend {
    /// Plays a locked device: the list of accounts cannot be read.
    public var unreadable = false
    /// Also plays a locked device: nothing can be deleted.
    public var undeletable = false
    /// Reads that came with an already checked context: tests use it to see the prompt's answer opens the item.
    public private(set) var readsWithContext = 0
    public private(set) var items: [String: Data] = [:]

    public init() {}

    public func accounts() -> [String]? {
        unreadable ? nil : items.map(\.key)
    }

    @discardableResult public func delete(account: String) -> Bool {
        if undeletable { return false }
        items.removeValue(forKey: account)
        return true
    }

    public func write(_ data: Data, account: String) throws {
        items.updateValue(data, forKey: account)
    }

    public func read(account: String, context: LAContext?) throws -> Data? {
        readsWithContext += context == nil ? 0 : 1
        return items[account]
    }
}

// MARK: - The vault

/// Keeps track of the gateways holding a remembered sign-in here, plus ways to open, add or forget one.
@MainActor
@Observable
public final class RememberedSignInVault {
    private struct Roster {
        var present: Set<UUID> = []
        var wasRead = false
        var doomed: Set<UUID> = []
    }
    private var roster = Roster()

    /// Gateways that have a remembered sign-in here, learned without prompting.
    public var ids: Set<UUID> { roster.present }
    /// True once the list has been read at least once. A process launched while the device is locked
    /// (by a notification, for instance) cannot read it; until then no gateway counts as remembered,
    /// and none may be dropped on that basis.
    public var isKnown: Bool { roster.wasRead }
    /// Gateways forgotten while the Keychain refused to delete the item (a background launch on a
    /// locked device). The next `reload()` removes them. Until then they are neither offered nor
    /// used, whatever the Keychain still contains.
    public var pendingForgets: Set<UUID> { roster.doomed }

    private let backend: any RememberedSignInBackend
    /// Persists `pendingForgets` between launches; only gateway ids, nothing secret. When nil they
    /// last for this process only (tests, and the demo build whose items vanish with it).
    private let defaults: UserDefaults?
    static let pendingForgetsKey = "rememberedSignIn.pendingForgets"
    nonisolated private static let accountPrefix = "signin."

    public init(backend: any RememberedSignInBackend, defaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.backend = backend
        if let stored = defaults?.stringArray(forKey: Self.pendingForgetsKey) {
            roster.doomed = Set(stored.compactMap(UUID.init(uuidString:)))
        }
        reload()
    }

    /// The device Keychain; memory in the demo copy.
    public static func standard() -> RememberedSignInVault {
        let backend: any RememberedSignInBackend
        let defaults: UserDefaults?
        #if DEBUG
        let inMemory = Keychain.memoryOnly
        #else
        let inMemory = false
        #endif
        if inMemory {
            (backend, defaults) = (MemoryRememberedSignInBackend(), nil)
        } else {
            (backend, defaults) = (KeychainRememberedSignInBackend(), .standard)
        }
        return RememberedSignInVault(backend: backend, defaults: defaults)
    }

    nonisolated static func account(_ id: UUID) -> String { accountPrefix + id.uuidString }

    nonisolated static func id(account: String) -> UUID? {
        guard let cut = account.range(of: accountPrefix), cut.lowerBound == account.startIndex else { return nil }
        return UUID(uuidString: String(account[cut.upperBound...]))
    }

    public func contains(_ id: UUID) -> Bool {
        !pendingForgets.contains(id) && ids.contains(id)
    }

    /// Re-reads the list at launch, on foregrounding and on unlock. Leftover deletions run first. If
    /// the read fails, the last known answer is kept.
    public func reload() {
        let removable = pendingForgets.filter { backend.delete(account: Self.account($0)) }
        removable.forEach { setPending(false, for: $0) }
        guard let names = backend.accounts() else { return }
        let seen = Set(names.compactMap { Self.id(account: $0) }).subtracting(roster.doomed)
        if seen != roster.present { roster.present = seen }
        roster.wasRead = true
    }

    /// No biometrics are needed to delete, so this can run at any time, even as a gateway is removed.
    /// A false return means the Keychain refused (locked device); the sign-in is still treated as
    /// forgotten and wiped at the next opportunity (see `pendingForgets`).
    @discardableResult
    public func forget(_ id: UUID) -> Bool {
        roster.present.remove(id)
        let removed = backend.delete(account: Self.account(id))
        setPending(!removed, for: id)
        return removed
    }

    public func remember(_ signIn: RememberedSignIn, for id: UUID) throws {
        let location = Self.account(id)
        let encoded = try JSONEncoder().encode(signIn)
        try backend.write(encoded, account: location)
        // The new item replaced the one waiting to be deleted, so that delete must not run.
        setPending(false, for: id)
        roster.present.formUnion([id])
    }

    /// Unlocks the sign-in with `context`, a biometric or passcode check that already succeeded.
    /// Returns nil when there is nothing left: forgotten, or deleted when the passcode was removed.
    public func signIn(for id: UUID, context: LAContext?) throws -> RememberedSignIn? {
        if pendingForgets.contains(id) { return nil }
        let location = Self.account(id)
        guard let stored = try backend.read(account: location, context: context) else {
            roster.present.subtract([id])
            return nil
        }
        let decoder = JSONDecoder()
        return try decoder.decode(RememberedSignIn.self, from: stored)
    }

    private func setPending(_ wanted: Bool, for id: UUID) {
        if wanted == roster.doomed.contains(id) { return }
        if wanted { roster.doomed.insert(id) } else { roster.doomed.remove(id) }
        guard let defaults else { return }
        if pendingForgets.isEmpty {
            defaults.removeObject(forKey: Self.pendingForgetsKey)
        } else {
            defaults.set(pendingForgets.map(\.uuidString).sorted(), forKey: Self.pendingForgetsKey)
        }
    }
}
