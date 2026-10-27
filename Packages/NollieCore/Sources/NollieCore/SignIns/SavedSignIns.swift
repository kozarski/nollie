import Foundation
import LocalAuthentication
import Observation
import Security

// MARK: - What is saved

/// One saved website sign-in as Settings lists it: the site and the username, never the password.
/// The password and the note sit in a separate item that asks for Touch ID or the Mac's password
/// on every read (see `KeychainSavedSignInBackend`).
public struct SavedSignIn: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var site: String
    public var username: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, site: String, username: String, createdAt: Date = Date()) {
        self.id = id
        self.site = site
        self.username = username
        self.createdAt = createdAt
    }
}

/// The half that stays locked until the person proves it is them: the password, plus an optional
/// note about one-time codes ("Codes come by text to my phone").
public struct SignInSecret: Codable, Equatable, Sendable {
    public var password: String
    public var note: String?

    public init(password: String, note: String? = nil) {
        self.password = password
        let cleaned = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = cleaned.isEmpty ? nil : cleaned
    }

    public var hasNote: Bool { !(note ?? "").isEmpty }
}

/// Logs and dumps say there is a secret, not what it is.
extension SignInSecret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SignInSecret(hidden)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

// MARK: - Site names

/// Sites the way the browser add-on keeps them: a bare, lowercase host name, punycode for other scripts.
public enum SignInSite {
    /// The host inside an address ("https://Login.Example.com/x" gives "login.example.com").
    /// nil for anything that is not a plain site name: an IP address, user info, spaces, one label.
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 300, !trimmed.contains(where: \.isWhitespace) else { return nil }
        guard let bare = bareHost(from: trimmed), let host = asciiHost(bare) else { return nil }
        return isValidHostName(host) ? host : nil
    }

    /// Cuts the scheme, path, query, fragment, port and trailing dots off. nil when user info is present.
    private static func bareHost(from text: String) -> String? {
        var rest = Substring(text)
        if let scheme = rest.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) {
            rest = rest[scheme.upperBound...]
        }
        if let end = rest.firstIndex(where: { "/?#".contains($0) }) { rest = rest[..<end] }
        if rest.contains("@") { return nil }
        if let port = rest.range(of: ":[0-9]{1,5}$", options: .regularExpression) { rest = rest[..<port.lowerBound] }
        while rest.last == "." { rest = rest.dropLast() }
        return rest.isEmpty ? nil : String(rest)
    }

    private static func asciiHost(_ name: String) -> String? {
        if name.allSatisfy(\.isASCII) { return name.lowercased() }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = name.lowercased()
        guard let encoded = parts.encodedHost, encoded.allSatisfy(\.isASCII) else { return nil }
        return encoded.lowercased()
    }

    private static func isValidHostName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.count <= 253, labels.count >= 2, let tld = labels.last, !tld.allSatisfy(\.isNumber) else { return false }
        return labels.allSatisfy { label in
            guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// A saved site covers itself and its subdomains, and never a look-alike with a longer name.
    public static func matches(saved: String, requested: String) -> Bool {
        requested == saved || requested.hasSuffix("." + saved)
    }

    /// The saved sign-in that fits a site best: the most specific site, the older one on a tie.
    public static func best(for requested: String, in items: [SavedSignIn]) -> SavedSignIn? {
        let covering = items.filter { matches(saved: $0.site, requested: requested) }
        return covering.min { a, b in
            if a.site.count != b.site.count { return a.site.count > b.site.count }
            return a.createdAt > b.createdAt
        }
    }
}

// MARK: - Storage

/// Storage for saved sign-ins: the Mac Keychain in the app, a plain dictionary in tests and the demo build.
public protocol SavedSignInBackend: AnyObject {
    /// Stores an item. Its listing (site, username) can be read without a prompt; `secret` cannot.
    func add(_ item: SavedSignIn, secret: Data) throws
    /// Raw secret bytes, or nil when no such item exists. `context` is a check that has already
    /// passed, which spares a second Keychain prompt.
    func read(id: String, context: LAContext?) throws -> Data?
    /// Returns false if the item might still exist.
    @discardableResult func delete(id: String) -> Bool
    /// All entries, with no prompt; nil if reading them failed.
    func list() -> [SavedSignIn]?
}

/// This Mac's Data Protection Keychain. Each sign-in is two items, neither synced to iCloud, both
/// for this device only:
/// - a listing under `.signins.list` (site and username), so Settings shows them with no prompt;
/// - the secret under `.signins` (password and note), behind Touch ID or the Mac's password every time.
/// They are apart because the Mac may ask for Touch ID even to read the attributes of a protected item.
public final class KeychainSavedSignInBackend: SavedSignInBackend {
    /// Services of their own, so nothing that reads gateways or remembered sign-ins reads these.
    public static let service = Keychain.baseBundleID + ".signins"
    public static let listService = Keychain.baseBundleID + ".signins.list"
    public static var protection: CFString { kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
    /// Touch ID, or the Mac's password when Touch ID is off or out of reach. Asked on every read.
    public static let accessFlags: SecAccessControlCreateFlags = .userPresence

    public init() {}

    public static func query(id: String?, service: String = KeychainSavedSignInBackend.service) -> [String: Any] {
        var found = Keychain.itemQuery(service: service, account: id, localOnly: true)
        // Prefer the data-protection keychain on macOS too; the older file-based one ignores access control.
        found[kSecUseDataProtectionKeychain as String] = true
        return found
    }

    public static func accessControl() throws -> SecAccessControl {
        try Keychain.makeAccessControl(protection, accessFlags)
    }

    /// The locked half: password and note behind the access control.
    public static func secretAttributes(_ item: SavedSignIn, secret: Data) throws -> [String: Any] {
        var attributes = query(id: item.id)
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrLabel as String] = "Nollie sign-in for \(item.site)"
        attributes[kSecAttrAccessControl as String] = try accessControl()
        return attributes
    }

    /// The open half: site and username, readable without a prompt while the Mac is unlocked.
    public static func listingAttributes(_ item: SavedSignIn) throws -> [String: Any] {
        var attributes = query(id: item.id, service: listService)
        attributes[kSecValueData as String] = try JSONEncoder().encode(item)
        attributes[kSecAttrLabel as String] = "Nollie sign-in listing for \(item.site)"
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return attributes
    }

    public func add(_ item: SavedSignIn, secret: Data) throws {
        let first = SecItemAdd(try Self.secretAttributes(item, secret: secret) as CFDictionary, nil)
        if first != errSecSuccess { throw KeychainError(status: first) }
        let second = SecItemAdd(try Self.listingAttributes(item) as CFDictionary, nil)
        if second != errSecSuccess {
            delete(id: item.id)   // no half-saved sign-in
            throw KeychainError(status: second)
        }
    }

    public func read(id: String, context: LAContext?) throws -> Data? {
        try Keychain.readData(Self.query(id: id), context: context)
    }

    /// Removes both items, matching on the account alone. Deleting needs no Touch ID, but matching
    /// on any other attribute of a protected item would, so nothing else is used.
    @discardableResult public func delete(id: String) -> Bool {
        var allGone = true
        for base in [Self.query(id: id), Self.query(id: id, service: Self.listService)] {
            var request = base
            request[kSecUseAuthenticationContext as String] = Keychain.quietContext()
            if !Keychain.isGone(SecItemDelete(request as CFDictionary)) { allGone = false }
        }
        return allGone
    }

    public func list() -> [SavedSignIn]? {
        var request = Self.query(id: nil, service: Self.listService)
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        request[kSecUseAuthenticationContext as String] = Keychain.quietContext()
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let blob = row[kSecValueData as String] as? Data,
                  var item = try? JSONDecoder().decode(SavedSignIn.self, from: blob) else { return nil }
            if let account = row[kSecAttrAccount as String] as? String { item.id = account }
            return item
        }
    }
}

/// Dictionary that plays the Keychain in tests and the demo build.
public final class MemorySavedSignInBackend: SavedSignInBackend {
    public private(set) var items: [String: (SavedSignIn, Data)] = [:]
    public private(set) var readsWithContext = 0
    public private(set) var reads = 0

    public init() {}

    public func add(_ item: SavedSignIn, secret: Data) throws {
        if items[item.id] != nil { throw KeychainError(status: errSecDuplicateItem) }
        items[item.id] = (item, secret)
    }

    public func read(id: String, context: LAContext?) throws -> Data? {
        reads += 1
        if context != nil { readsWithContext += 1 }
        return items[id]?.1
    }

    @discardableResult public func delete(id: String) -> Bool {
        items.removeValue(forKey: id)
        return true
    }

    public func list() -> [SavedSignIn]? { items.values.map { $0.0 } }
}

// MARK: - Errors

public enum SavedSignInError: LocalizedError, Equatable {
    case badSite, noUsername, noPassword, duplicate(String), cancelled, gone, unreadable, notDeleted

    public var errorDescription: String? {
        switch self {
        case .badSite: return String(localized: "Enter the site's address, like example.com.", table: "Core")
        case .noUsername: return String(localized: "Enter the username or email for this site.", table: "Core")
        case .noPassword: return String(localized: "Enter the password.", table: "Core")
        case .duplicate(let site): return String(localized: "There's already a sign-in for \(site). Edit that one instead.", table: "Core")
        case .cancelled: return String(localized: "Nothing was shown. Try again when you're ready.", table: "Core")
        case .gone: return String(localized: "This sign-in isn't saved any more.", table: "Core")
        case .unreadable: return String(localized: "Nollie couldn't read the Keychain. Unlock your Mac and try again.", table: "Core")
        case .notDeleted: return String(localized: "Nollie couldn't remove it. Unlock your Mac and try again.", table: "Core")
        }
    }
}

// MARK: - The store

/// The sign-ins saved on this Mac. Listing them never asks; reading a password always does.
@MainActor
@Observable
public final class SavedSignInStore {
    public private(set) var items: [SavedSignIn] = []
    /// False until the list has been read once; before that nothing counts as saved or missing.
    public private(set) var isKnown = false
    /// Called after every change with the saved sites, so the add-on knows what it may ask for.
    public var onChange: (@MainActor ([String]) -> Void)?

    private let backend: any SavedSignInBackend
    /// Touch ID or the Mac's password, shown with this reason. Gives the checked context on a yes.
    private let authenticate: @MainActor (String) async -> LAContext?

    public init(backend: any SavedSignInBackend, authenticate: @escaping @MainActor (String) async -> LAContext?) {
        self.backend = backend
        self.authenticate = authenticate
        reload()
    }

    public var sites: [String] { Set(items.map(\.site)).sorted() }

    public func reload() {
        guard let listed = backend.list() else { return }
        let ordered = listed.sorted { ($0.site, $0.username) < ($1.site, $1.username) }
        // Publish only a real change: redrawing a list for nothing loses the person's place in it.
        if ordered != items { items = ordered }
        isKnown = true
    }

    public func signIn(for site: String) -> SavedSignIn? { SignInSite.best(for: site, in: items) }

    /// Saves a new sign-in, or an edit when `replacing` is given (same id, new details).
    /// There is one sign-in per site.
    @discardableResult
    public func save(site rawSite: String, username rawUsername: String, secret: SignInSecret,
                     replacing: SavedSignIn? = nil) throws -> SavedSignIn {
        guard let site = SignInSite.normalize(rawSite) else { throw SavedSignInError.badSite }
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if username.isEmpty { throw SavedSignInError.noUsername }
        if secret.password.isEmpty { throw SavedSignInError.noPassword }
        if items.contains(where: { $0.site == site && $0.id != replacing?.id }) {
            throw SavedSignInError.duplicate(site)
        }
        let saved = SavedSignIn(id: replacing?.id ?? UUID().uuidString, site: site, username: username,
                                createdAt: replacing?.createdAt ?? Date())
        let encoded = try JSONEncoder().encode(secret)
        // Editing means delete then add again. Changing a protected item would prompt for Touch ID,
        // while the person has only just entered the new details.
        if let old = replacing, !backend.delete(id: old.id) { throw SavedSignInError.notDeleted }
        try backend.add(saved, secret: encoded)
        changed()
        return saved
    }

    public func remove(_ item: SavedSignIn) throws {
        if !backend.delete(id: item.id) { throw SavedSignInError.notDeleted }
        changed()
    }

    /// Asks for Touch ID or the Mac's password, then opens the secret. Throws `.cancelled` on a no.
    public func reveal(_ item: SavedSignIn, reason: String) async throws -> SignInSecret {
        guard let context = await authenticate(reason) else { throw SavedSignInError.cancelled }
        return try secret(item, context: context)
    }

    /// Opens the secret with a check that already passed (the card's Allow asked already).
    public func secret(_ item: SavedSignIn, context: LAContext) throws -> SignInSecret {
        let stored: Data?
        do { stored = try backend.read(id: item.id, context: context) } catch { throw SavedSignInError.unreadable }
        guard let stored else {
            reload()
            throw SavedSignInError.gone
        }
        guard let opened = try? JSONDecoder().decode(SignInSecret.self, from: stored) else {
            throw SavedSignInError.unreadable
        }
        return opened
    }

    /// Asks once with `reason`, for a caller that reads afterwards (the card: one prompt for the whole fill).
    public func confirmOwner(reason: String) async -> LAContext? { await authenticate(reason) }

    private func changed() {
        reload()
        onChange?(sites)
    }
}
