import Foundation
import LocalAuthentication
import Observation
import Security

// MARK: - Card numbers

/// Who issued a card, read from its first digits. Only for the label ("Visa ending 4242") and the
/// security code's length; it never decides whether a card may be used.
public enum CardBrand: String, Codable, CaseIterable, Sendable {
    case visa, mastercard, amex, discover, diners, jcb, unionpay, maestro, card

    /// The brand's own name, in English: it is part of the label the add-on and the helper read.
    public var name: String {
        switch self {
        case .visa: "Visa"
        case .mastercard: "Mastercard"
        case .amex: "American Express"
        case .discover: "Discover"
        case .diners: "Diners Club"
        case .jcb: "JCB"
        case .unionpay: "UnionPay"
        case .maestro: "Maestro"
        case .card: "Card"
        }
    }

    /// The name on screen: the brands' own names, and a plain card in the person's language.
    public var shownName: String {
        self == .card ? String(localized: "Card", table: "Core", comment: "A payment card of no known brand") : name
    }

    /// "Visa ending 4242" on screen, in the person's language.
    public func shownLabel(last4: String) -> String {
        String(localized: "\(shownName) ending \(last4)", table: "Core", comment: "Safety: a payment card and its last four digits: Visa ending 4242")
    }

    /// Digits in the security code on the back (on the front for American Express).
    public var codeLength: Int { self == .amex ? 4 : 3 }
}

public enum CardNumber {
    /// The digits of a typed number, allowing spaces and dashes between them. nil for anything else.
    public static func digits(_ raw: String) -> String? {
        let kept = raw.filter { !$0.isWhitespace && $0 != "-" }
        guard !kept.isEmpty, kept.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return kept
    }

    /// The check digit every card number carries (Luhn).
    public static func passesCheck(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard let value = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                let doubled = value * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += value
            }
        }
        return sum % 10 == 0
    }

    /// A number that could be a real card: 12 to 19 digits with a good check digit.
    public static func valid(_ raw: String) -> String? {
        guard let digits = digits(raw), (12...19).contains(digits.count), passesCheck(digits) else { return nil }
        return digits
    }

    public static func brand(_ digits: String) -> CardBrand {
        func starts(_ low: Int, _ high: Int, length: Int) -> Bool {
            guard digits.count >= length, let lead = Int(digits.prefix(length)) else { return false }
            return (low...high).contains(lead)
        }
        if digits.hasPrefix("4") { return .visa }
        if starts(51, 55, length: 2) || starts(2221, 2720, length: 4) { return .mastercard }
        if starts(34, 34, length: 2) || starts(37, 37, length: 2) { return .amex }
        if digits.hasPrefix("6011") || starts(644, 649, length: 3) || digits.hasPrefix("65") { return .discover }
        if starts(300, 305, length: 3) || digits.hasPrefix("36") || digits.hasPrefix("38") { return .diners }
        if starts(3528, 3589, length: 4) { return .jcb }
        if digits.hasPrefix("62") { return .unionpay }
        if digits.hasPrefix("50") || starts(56, 58, length: 2) || digits.hasPrefix("6") { return .maestro }
        return .card
    }

    public static func lastFour(_ digits: String) -> String { String(digits.suffix(4)) }
}

/// The month and year a card runs out, as printed on it ("12/28").
public struct CardExpiry: Codable, Equatable, Hashable, Sendable {
    public var month: Int
    /// Four digits.
    public var year: Int

    public init?(month: Int, year: Int) {
        guard (1...12).contains(month), (2000...2099).contains(year) else { return nil }
        self.month = month
        self.year = year
    }

    /// "12/28", "12/2028", "1228" or "12 / 28".
    public init?(_ raw: String) {
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        let parts = raw.split(whereSeparator: { $0 == "/" || $0 == "-" }).map { $0.trimmingCharacters(in: .whitespaces) }
        let month: Int?, year: Int?
        if parts.count == 2 {
            month = Int(parts[0]); year = Int(parts[1])
        } else if digits.count == 4 || digits.count == 6 {
            month = Int(digits.prefix(2)); year = Int(digits.dropFirst(2))
        } else {
            return nil
        }
        guard let month, let short = year else { return nil }
        self.init(month: month, year: short < 100 ? 2000 + short : short)
    }

    /// As forms want it: "12/28".
    public var text: String { String(format: "%02d/%02d", month, year % 100) }

    /// True once the month it was printed for is over.
    public func hasRunOut(at date: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        let now = calendar.dateComponents([.year, .month], from: date)
        guard let year = now.year, let month = now.month else { return false }
        return (self.year, self.month) < (year, month)
    }
}

// MARK: - What is saved

/// One saved card as Settings lists it and the add-on hears of it: the brand, the last four digits and
/// the name on the card. Never the number. The number and expiry sit in a separate item that asks for
/// Touch ID or the Mac's password on every read (see `KeychainSavedCardBackend`).
public struct SavedCard: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var brand: CardBrand
    public var last4: String
    /// The name on the card, which a helper may type when a form asks for it.
    public var holder: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, brand: CardBrand, last4: String, holder: String, createdAt: Date = Date()) {
        self.id = id
        self.brand = brand
        self.last4 = last4
        self.holder = holder
        self.createdAt = createdAt
    }

    /// "Visa ending 4242": all a helper, a card on screen, a log or Papertrail ever says about a card. Always in
    /// English: the add-on and the helper read it. `shownLabel` is the same on screen in the person's language.
    public var label: String { "\(brand.name) ending \(last4)" }
    public var shownLabel: String { brand.shownLabel(last4: last4) }
}

/// The half that stays locked until the person proves it is them. The security code is not here: the
/// person types it each time, and it is never kept.
public struct CardSecret: Codable, Equatable, Sendable {
    public var number: String
    public var expiry: CardExpiry

    public init(number: String, expiry: CardExpiry) {
        self.number = number
        self.expiry = expiry
    }
}

/// Logs and dumps say there is a card, not what it is.
extension CardSecret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "CardSecret(hidden)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

// MARK: - Storage

/// Storage for saved cards: the Mac Keychain in the app, a plain dictionary in tests and the demo build.
public protocol SavedCardBackend: AnyObject {
    /// Stores a card. Its listing can be read without a prompt; `secret` cannot.
    func add(_ card: SavedCard, secret: Data) throws
    /// Raw secret bytes, or nil when there is no such card. `context` is a check that already passed.
    func read(id: String, context: LAContext?) throws -> Data?
    /// Returns false if the card might still exist.
    @discardableResult func delete(id: String) -> Bool
    /// All listings, with no prompt; nil if reading them failed.
    func list() -> [SavedCard]?
}

/// This Mac's Data Protection Keychain. Each card is two items, neither synced, both for this device only:
/// - a listing under `.cards.list` (brand, last four, name), so the list shows after one check of its own;
/// - the number and expiry under `.cards`, behind Touch ID or the Mac's password every time.
public final class KeychainSavedCardBackend: SavedCardBackend {
    /// Services of their own, so nothing that reads gateways, sign-ins or remembered sign-ins reads these.
    public static let service = Keychain.baseBundleID + ".cards"
    public static let listService = Keychain.baseBundleID + ".cards.list"
    public static var protection: CFString { kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
    /// Touch ID, or the Mac's password when Touch ID is off or out of reach. Asked on every read.
    public static let accessFlags: SecAccessControlCreateFlags = .userPresence

    public init() {}

    public static func query(id: String?, service: String = KeychainSavedCardBackend.service) -> [String: Any] {
        var found = Keychain.itemQuery(service: service, account: id, localOnly: true)
        found[kSecUseDataProtectionKeychain as String] = true
        return found
    }

    public static func secretAttributes(_ card: SavedCard, secret: Data) throws -> [String: Any] {
        var attributes = query(id: card.id)
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrLabel as String] = "Nollie card \(card.label)"
        attributes[kSecAttrAccessControl as String] = try Keychain.makeAccessControl(protection, accessFlags)
        return attributes
    }

    public static func listingAttributes(_ card: SavedCard) throws -> [String: Any] {
        var attributes = query(id: card.id, service: listService)
        attributes[kSecValueData as String] = try JSONEncoder().encode(card)
        attributes[kSecAttrLabel as String] = "Nollie card listing \(card.label)"
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return attributes
    }

    public func add(_ card: SavedCard, secret: Data) throws {
        let first = SecItemAdd(try Self.secretAttributes(card, secret: secret) as CFDictionary, nil)
        if first != errSecSuccess { throw KeychainError(status: first) }
        let second = SecItemAdd(try Self.listingAttributes(card) as CFDictionary, nil)
        if second != errSecSuccess {
            delete(id: card.id)   // no half-saved card
            throw KeychainError(status: second)
        }
    }

    public func read(id: String, context: LAContext?) throws -> Data? {
        try Keychain.readData(Self.query(id: id), context: context)
    }

    @discardableResult public func delete(id: String) -> Bool {
        var allGone = true
        for base in [Self.query(id: id), Self.query(id: id, service: Self.listService)] {
            var request = base
            request[kSecUseAuthenticationContext as String] = Keychain.quietContext()
            if !Keychain.isGone(SecItemDelete(request as CFDictionary)) { allGone = false }
        }
        return allGone
    }

    public func list() -> [SavedCard]? {
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
                  var card = try? JSONDecoder().decode(SavedCard.self, from: blob) else { return nil }
            if let account = row[kSecAttrAccount as String] as? String { card.id = account }
            return card
        }
    }
}

/// Dictionary that plays the Keychain in tests and the demo build.
public final class MemorySavedCardBackend: SavedCardBackend {
    public private(set) var items: [String: (SavedCard, Data)] = [:]
    public private(set) var reads = 0

    public init() {}

    public func add(_ card: SavedCard, secret: Data) throws {
        if items[card.id] != nil { throw KeychainError(status: errSecDuplicateItem) }
        items[card.id] = (card, secret)
    }

    public func read(id: String, context: LAContext?) throws -> Data? {
        reads += 1
        return items[id]?.1
    }

    @discardableResult public func delete(id: String) -> Bool {
        items.removeValue(forKey: id)
        return true
    }

    public func list() -> [SavedCard]? { items.values.map { $0.0 } }
}

// MARK: - Errors

public enum SavedCardError: LocalizedError, Equatable {
    case badNumber, badExpiry, expired, noName, duplicate(String), cancelled, gone, unreadable, notDeleted

    public var errorDescription: String? {
        switch self {
        case .badNumber: return String(localized: "Check the card number.", table: "Core")
        case .badExpiry: return String(localized: "Enter the expiry date like 12/28.", table: "Core")
        case .expired: return String(localized: "This card has run out.", table: "Core")
        case .noName: return String(localized: "Enter the name on the card.", table: "Core")
        case .duplicate(let label): return String(localized: "\(label) is already saved.", table: "Core", comment: "The value is a card: Visa ending 4242")
        case .cancelled: return String(localized: "Nothing was changed.", table: "Core")
        case .gone: return String(localized: "This card isn't saved any more.", table: "Core")
        case .unreadable: return String(localized: "Nollie couldn't read the Keychain. Unlock your Mac and try again.", table: "Core")
        case .notDeleted: return String(localized: "Nollie couldn't remove it. Unlock your Mac and try again.", table: "Core")
        }
    }
}

// MARK: - The store

/// The cards saved on this Mac. Listing them needs no prompt (Settings asks first by itself); reading a
/// number always asks.
@MainActor
@Observable
public final class SavedCardStore {
    public private(set) var items: [SavedCard] = []
    public private(set) var isKnown = false
    /// Called after every change, so the add-on hears the new labels.
    public var onChange: (@MainActor ([SavedCard]) -> Void)?

    private let backend: any SavedCardBackend
    private let authenticate: @MainActor (String) async -> LAContext?

    public init(backend: any SavedCardBackend, authenticate: @escaping @MainActor (String) async -> LAContext?) {
        self.backend = backend
        self.authenticate = authenticate
        reload()
    }

    public func reload() {
        guard let listed = backend.list() else { return }
        let ordered = listed.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        if ordered != items { items = ordered }
        isKnown = true
    }

    /// The card a helper named by its last four digits, or the first saved one.
    public func card(lastFour: String?) -> SavedCard? {
        guard let lastFour else { return items.first }
        return items.first { $0.last4 == lastFour }
    }

    /// Saves a new card. The person proves it is them first (`confirmOwner`), in the screen that adds it.
    @discardableResult
    public func add(number rawNumber: String, expiry rawExpiry: String, holder rawHolder: String,
                    now: Date = Date()) throws -> SavedCard {
        guard let number = CardNumber.valid(rawNumber) else { throw SavedCardError.badNumber }
        guard let expiry = CardExpiry(rawExpiry) else { throw SavedCardError.badExpiry }
        if expiry.hasRunOut(at: now) { throw SavedCardError.expired }
        let holder = rawHolder.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !holder.isEmpty, holder.count <= 80, !holder.contains(where: \.isNumber) else { throw SavedCardError.noName }
        let card = SavedCard(brand: CardNumber.brand(number), last4: CardNumber.lastFour(number), holder: holder, createdAt: now)
        if items.contains(where: { $0.brand == card.brand && $0.last4 == card.last4 }) {
            throw SavedCardError.duplicate(card.label)
        }
        try backend.add(card, secret: try JSONEncoder().encode(CardSecret(number: number, expiry: expiry)))
        changed()
        return card
    }

    public func remove(_ card: SavedCard) throws {
        if !backend.delete(id: card.id) { throw SavedCardError.notDeleted }
        changed()
    }

    /// Asks once with `reason`; the context opens the card afterwards without a second prompt.
    public func confirmOwner(reason: String) async -> LAContext? { await authenticate(reason) }

    /// Opens the number with a check that already passed.
    public func secret(_ card: SavedCard, context: LAContext) throws -> CardSecret {
        let stored: Data?
        do { stored = try backend.read(id: card.id, context: context) } catch { throw SavedCardError.unreadable }
        guard let stored else {
            reload()
            throw SavedCardError.gone
        }
        guard let opened = try? JSONDecoder().decode(CardSecret.self, from: stored) else { throw SavedCardError.unreadable }
        return opened
    }

    private func changed() {
        reload()
        onChange?(items)
    }
}
