import Foundation
import Observation
import Security

// MARK: - Money

/// Amounts as the add-on carries them ("48.99") and as the card says them ("£48.99"). Always the same
/// words, whatever the device's language, so the card and the screen check agree.
public enum PaymentMoney {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// A positive amount with at most two decimal places. nil for anything else.
    public static func amount(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"\A[0-9]{1,9}(\.[0-9]{1,2})?\z"#, options: .regularExpression) != nil,
              let value = Decimal(string: trimmed, locale: posix), value > 0 else { return nil }
        return value
    }

    /// "48.99", always two decimals.
    public static func plain(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = posix
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }

    /// "£48.99", "€12.00", "$5.50", or "48.99 CHF" for a currency without a familiar sign.
    public static func text(_ amount: Decimal, _ currency: String) -> String {
        let symbols = ["GBP": "£", "EUR": "€", "USD": "$"]
        if let symbol = symbols[currency] { return symbol + plain(amount) }
        return "\(plain(amount)) \(currency)"
    }

    /// The currency a person most likely pays in: their region's, else pounds.
    public static func homeCurrency(_ locale: Locale = .current) -> String {
        let code = locale.currency?.identifier ?? "GBP"
        return code.count == 3 ? code.uppercased() : "GBP"
    }
}

// MARK: - The person's choices

/// The choices in Settings › Cards. Off and asking by default.
public struct PaymentSettings: Codable, Equatable, Sendable {
    /// "Skip the card under a limit on sites I've paid before". Off to start.
    public var quickPay: Bool
    /// The limit for quick pay, in `currency`.
    public var quickLimit: Decimal
    /// The currency the person pays in. A total in any other currency is refused.
    public var currency: String

    public init(quickPay: Bool = false, quickLimit: Decimal = 20, currency: String = PaymentMoney.homeCurrency()) {
        self.quickPay = quickPay
        self.quickLimit = quickLimit
        self.currency = currency
    }

    /// The limits Settings offers.
    public static let limits: [Decimal] = [10, 20, 50, 100]
}

/// A site this Mac has filled a card into after the person's yes. Only the site and when.
public struct PaidSite: Codable, Equatable, Sendable {
    public var site: String
    public var at: Date

    public init(site: String, at: Date) {
        self.site = site
        self.at = at
    }
}

/// What the rules keep: the person's choices and the sites paid before. On the Mac it is a Keychain item
/// of its own (this device only, never synced), which a helper's shell can't read or change.
public struct PaymentRuleState: Codable, Equatable, Sendable {
    public var settings: PaymentSettings
    public var paid: [PaidSite]

    public init(settings: PaymentSettings = PaymentSettings(), paid: [PaidSite] = []) {
        self.settings = settings
        self.paid = paid
    }

    public var paidSites: Set<String> { Set(paid.map(\.site)) }

    /// Remembers a site after a payment there, newest first, at most 500.
    public mutating func remember(_ site: String, at date: Date = Date()) {
        paid.removeAll { $0.site == site }
        paid.insert(PaidSite(site: site, at: date), at: 0)
        if paid.count > 500 { paid.removeLast(paid.count - 500) }
    }
}

/// Where the rules' state lives: the Keychain on the Mac, memory in tests and the demo build.
public protocol PaymentRuleBackend: AnyObject {
    func load() -> PaymentRuleState?
    func save(_ state: PaymentRuleState) throws
}

public final class KeychainPaymentRuleBackend: PaymentRuleBackend {
    public static let service = Keychain.baseBundleID + ".cards.rules"
    private static let account = "rules"

    public init() {}

    public static func query() -> [String: Any] {
        var found = Keychain.itemQuery(service: service, account: account, localOnly: true)
        found[kSecUseDataProtectionKeychain as String] = true
        return found
    }

    public func load() -> PaymentRuleState? {
        guard let data = try? Keychain.readData(Self.query(), context: Keychain.quietContext()) else { return nil }
        return try? JSONDecoder().decode(PaymentRuleState.self, from: data)
    }

    public func save(_ state: PaymentRuleState) throws {
        let data = try JSONEncoder().encode(state)
        let update = SecItemUpdate(Self.query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var attributes = Self.query()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Nollie card rules"
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added != errSecSuccess { throw KeychainError(status: added) }
    }
}

public final class MemoryPaymentRuleBackend: PaymentRuleBackend {
    public var state: PaymentRuleState?
    public init(_ state: PaymentRuleState? = nil) { self.state = state }
    public func load() -> PaymentRuleState? { state }
    public func save(_ state: PaymentRuleState) throws { self.state = state }
}

/// The person's choices and the sites paid before, for Settings and for the rules.
@MainActor
@Observable
public final class PaymentRuleStore {
    public private(set) var state: PaymentRuleState
    private let backend: any PaymentRuleBackend

    public init(backend: any PaymentRuleBackend) {
        self.backend = backend
        state = backend.load() ?? PaymentRuleState()
    }

    public var settings: PaymentSettings { state.settings }

    public func update(_ change: (inout PaymentSettings) -> Void) throws {
        var next = state
        change(&next.settings)
        try backend.save(next)
        state = next
    }

    public func remember(_ site: String, at date: Date = Date()) {
        var next = state
        next.remember(site, at: date)
        if (try? backend.save(next)) != nil { state = next }
    }
}

// MARK: - The rules

/// One payment a helper asks for, as the add-on carries it.
public struct PaymentAttempt: Equatable, Sendable {
    public var bot: String
    public var site: String
    public var total: Decimal
    public var currency: String

    public init(bot: String, site: String, total: Decimal, currency: String) {
        self.bot = bot
        self.site = site
        self.total = total
        self.currency = currency
    }
}

/// Why the rules said no before anyone was asked, in the add-on's fixed words.
public enum PaymentRefusal: String, Sendable, Equatable {
    case privateBot = "private"
    case notAllowed = "not_allowed"
    case noCard = "no_card"
    case unknownCard = "unknown_card"
    case currency
    case badTotal = "bad_total"
    case badSite = "bad_site"
}

public enum PaymentDecision: Equatable, Sendable {
    /// Ask first's buy card, with Face ID, then the security code on the Mac.
    case ask(firstOnSite: Bool)
    /// The person chose to skip the card for this: the security code on the Mac is still asked.
    case quick
    case refuse(PaymentRefusal)
}

/// Fixed rules, never the helper's judgement:
/// - a private bot never pays, and a helper pays only while its switch is on;
/// - a total in a currency the person doesn't pay in is refused;
/// - the first payment on each site always asks;
/// - every payment asks, unless the person turned on quick pay and this is at or under their limit
///   on a site Nollie filled a card into before. Even then the Mac asks for the security code.
public enum PaymentRules {
    public static let largest: Decimal = 100_000

    public static func decide(_ attempt: PaymentAttempt, settings: PaymentSettings, paidSites: Set<String>,
                              botMayPay: Bool, isPrivate: Bool, hasCard: Bool) -> PaymentDecision {
        if isPrivate { return .refuse(.privateBot) }
        if !botMayPay { return .refuse(.notAllowed) }
        if !hasCard { return .refuse(.noCard) }
        guard let site = SignInSite.normalize(attempt.site), site == attempt.site else { return .refuse(.badSite) }
        guard attempt.total > 0, attempt.total <= largest else { return .refuse(.badTotal) }
        guard attempt.currency == settings.currency else { return .refuse(.currency) }
        // Exactly the same site: a payment on shop.example.com says nothing about pay.example.com.
        let paidHere = paidSites.contains(site)
        if paidHere, settings.quickPay, attempt.total <= settings.quickLimit { return .quick }
        return .ask(firstOnSite: !paidHere)
    }
}

/// What the card showed, kept by the Mac until it fills the card. A fill happens only when the request
/// still says exactly this: the same helper, site, total, currency and card.
public struct PaymentPlan: Equatable, Sendable {
    public var requestID: String
    public var bot: String
    public var site: String
    public var total: Decimal
    public var currency: String
    public var cardID: String
    public var cardLabel: String
    public var words: String

    public init(requestID: String, bot: String, site: String, total: Decimal, currency: String, cardID: String,
                cardLabel: String, words: String) {
        self.requestID = requestID; self.bot = bot; self.site = site; self.total = total
        self.currency = currency; self.cardID = cardID; self.cardLabel = cardLabel; self.words = words
    }

    public func matches(_ request: PaymentRequest) -> Bool {
        request.id == requestID && request.bot == bot && request.site == site && request.currency == currency
            && PaymentMoney.amount(request.total) == total
    }
}

/// The card's words: what, where and with which card, then what the person will be asked on the Mac.
public enum PaymentWords {
    public static func card(total: Decimal, currency: String, site: String, card: SavedCard, firstOnSite: Bool) -> String {
        var lines = ["Pay \(PaymentMoney.text(total, currency)) to \(site) with \(card.label)."]
        if firstOnSite { lines.append("First payment to this site.") }
        lines.append("You type the security code on your Mac.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Reading the checkout

/// What the Mac checks on the helper's screen, read with its own text recognition: that the total the
/// person said yes to is there before it types, and that the card number has gone afterwards.
public enum PaymentScreen {
    /// Every amount written in a line of text: "£1,048.99", "48,99 €", "Total 50".
    public static func amounts(in line: String) -> [Decimal] {
        guard let pattern = try? NSRegularExpression(pattern: #"[0-9][0-9 .,']*[0-9]|[0-9]"#) else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return pattern.matches(in: line, range: range).compactMap { match in
            guard let found = Range(match.range, in: line) else { return nil }
            return amount(String(line[found]))
        }
    }

    /// One written amount: the last "." or "," followed by one or two digits is the decimal point; the
    /// other separators group thousands.
    static func amount(_ written: String) -> Decimal? {
        let text = written.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "'", with: "")
        var whole = text, fraction = ""
        if let mark = text.lastIndex(where: { $0 == "." || $0 == "," }) {
            let after = text[text.index(after: mark)...]
            if (1...2).contains(after.count) {
                whole = String(text[..<mark])
                fraction = String(after)
            }
        }
        whole = whole.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "")
        guard !whole.isEmpty, whole.allSatisfy(\.isNumber), fraction.allSatisfy(\.isNumber) else { return nil }
        return Decimal(string: fraction.isEmpty ? whole : whole + "." + fraction, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// True when the screen shows exactly this total somewhere.
    public static func showsTotal(_ lines: [String], total: Decimal) -> Bool {
        lines.contains { amounts(in: $0).contains(total) }
    }

    /// True while more of the card number than its last four digits is readable on the screen. Each
    /// line on its own and all of them together, digits only, are searched for the first eight digits.
    /// A screen nothing could be read from counts as still showing.
    public static func showsNumber(_ lines: [String], number: String) -> Bool {
        guard !lines.isEmpty else { return true }
        let lead = String(number.prefix(8))
        guard lead.count == 8 else { return true }
        let digitLines = lines.map { $0.filter { $0.isASCII && $0.isNumber } }
        return digitLines.contains { $0.contains(lead) } || digitLines.joined().contains(lead)
    }
}
