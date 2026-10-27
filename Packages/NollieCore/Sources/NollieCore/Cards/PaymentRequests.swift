import Foundation

/// A helper's request to pay, as the workflow add-on keeps it while it is open
/// (`GET /api/plugins/nollie-workflow/payments/requests`). It holds no card details.
public struct PaymentRequest: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var bot: String
    public var site: String
    /// As the helper read it from the checkout: "48.99".
    public var total: String
    public var currency: String
    /// The last four digits of the card the helper named, or nil for the first saved card.
    public var card: String?
    /// The helper's Cua computer (`local:dev`).
    public var computer: String
    /// "waiting", "prepared", "approved", "filling", "showing" or "done".
    public var state: String
    /// Whether the Mac's rules put the card up (false: quick pay).
    public var ask: Bool?
    /// "card" when the person said yes on the card, "quick" when quick pay spared it.
    public var approver: String?
    public var createdAt: Int

    public init(id: String, bot: String, site: String, total: String, currency: String, card: String? = nil,
                computer: String = "local:dev", state: String, ask: Bool? = nil, approver: String? = nil, createdAt: Int = 0) {
        self.id = id; self.bot = bot; self.site = site; self.total = total; self.currency = currency; self.card = card
        self.computer = computer; self.state = state; self.ask = ask; self.approver = approver; self.createdAt = createdAt
    }

    public var attempt: PaymentAttempt? {
        PaymentMoney.amount(total).map { PaymentAttempt(bot: bot, site: site, total: $0, currency: currency) }
    }
}

/// One payment, for the list in Settings › Cards: when, which helper, where, how much, which card ending.
public struct PaymentHistoryEntry: Decodable, Equatable, Sendable, Identifiable {
    public var at: Int
    public var bot: String
    public var site: String
    public var total: String?
    public var currency: String?
    /// The last four digits.
    public var card: String?
    /// "paid", "declined", "no_answer", "refused", "cancelled", "expired", "failed" and the like.
    public var outcome: String
    public var approver: String?
    public var id: String { "\(at)-\(bot)-\(site)-\(outcome)" }

    public init(at: Int, bot: String, site: String, total: String? = nil, currency: String? = nil, card: String? = nil,
                outcome: String, approver: String? = nil) {
        self.at = at; self.bot = bot; self.site = site; self.total = total; self.currency = currency; self.card = card
        self.outcome = outcome; self.approver = approver
    }
}

/// Why the Mac did not fill a card in, in the add-on's fixed words (never free text).
public enum PaymentFailure: String, Error, Sendable, Equatable {
    case totalNotShown = "total_not_shown"
    case changed
    case computerUnavailable = "computer_unavailable"
    case fillFailed = "fill_failed"
    case touchID = "touch_id"
    case notSavedHere = "not_saved_here"
    case privateBot = "private"
    case fillUnavailable = "fill_unavailable"
}

/// A card as the add-on hears of it: never the number.
public struct PaymentCardLabel: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var brand: CardBrand
    public var last4: String
    public var holder: String

    public init(_ card: SavedCard) {
        id = card.id; brand = card.brand; last4 = card.last4; holder = card.holder
    }

    public init(id: String, brand: CardBrand, last4: String, holder: String) {
        self.id = id; self.brand = brand; self.last4 = last4; self.holder = holder
    }

    /// In English: the add-on and the helper read it. `shownLabel` is the same on screen.
    public var label: String { "\(brand.name) ending \(last4)" }
    public var shownLabel: String { brand.shownLabel(last4: last4) }
}

/// A helper's "Can pay with my cards" switch.
public struct PaymentSwitch: Codable, Equatable, Sendable {
    public var bot: String
    public var on: Bool

    public init(bot: String, on: Bool) {
        self.bot = bot
        self.on = on
    }
}

private struct PaymentCardsBody: Codable, Sendable { var cards: [PaymentCardLabel] }
private struct PaymentRequestsReply: Decodable, Sendable { var requests: [PaymentRequest]; var bots: [String] }
private struct PaymentHistoryReply: Decodable, Sendable { var entries: [PaymentHistoryEntry] }
private struct PaymentWordsBody: Codable, Sendable { var words: String; var card: String; var ask: Bool }
private struct PaymentRefusalBody: Codable, Sendable { var reason: String; var expected: String? }
private struct PaymentReportBody: Codable, Sendable { var outcome: String; var reason: String?; var showing: Bool }

/// Open payments and the helpers allowed to pay, read together on each look.
public struct PaymentRequests: Equatable, Sendable {
    public var requests: [PaymentRequest]
    public var allowed: Set<String>
}

@MainActor
extension GatewayRuntime {
    public static let paymentsPath = "/api/plugins/nollie-workflow/payments"

    /// The cards as labels, for the iPhone's list and the Mac's check of what the add-on holds.
    public func paymentCards() async throws -> [PaymentCardLabel] {
        let reply: PaymentCardsBody = try await api.get(Self.paymentsPath + "/cards")
        return reply.cards
    }

    /// Tells the add-on which cards are saved: brand, last four digits and the name on the card only.
    public func savePaymentCards(_ cards: [SavedCard]) async throws {
        let _: PaymentCardsBody = try await api.send("PUT", Self.paymentsPath + "/cards",
                                                     body: PaymentCardsBody(cards: cards.map(PaymentCardLabel.init)))
    }

    public func paymentSwitch(bot: String) async throws -> PaymentSwitch {
        try await api.get(Self.paymentsPath + "/bots", query: [URLQueryItem(name: "bot", value: bot)])
    }

    public func savePaymentSwitch(bot: String, on: Bool) async throws -> PaymentSwitch {
        try await api.send("PUT", Self.paymentsPath + "/bots", body: PaymentSwitch(bot: bot, on: on))
    }

    public func paymentRequests() async throws -> PaymentRequests {
        let reply: PaymentRequestsReply = try await api.get(Self.paymentsPath + "/requests")
        return PaymentRequests(requests: reply.requests, allowed: Set(reply.bots))
    }

    public func paymentRequest(_ id: String) async throws -> PaymentRequest {
        try await api.get(Self.paymentsPath + "/requests/" + id)
    }

    /// The Mac's words for the card, the card it will use and whether its rules ask. False when the
    /// request has moved on (409).
    public func preparePayment(_ id: String, words: String, card: String, ask: Bool) async throws -> Bool {
        do {
            let _: PaymentRequest = try await api.send("POST", Self.paymentsPath + "/requests/\(id)/prepare",
                                                       body: PaymentWordsBody(words: words, card: card, ask: ask))
            return true
        } catch HermesAPIError.http(status: 409, _) { return false }
    }

    public func refusePayment(_ id: String, reason: PaymentRefusal, expected: String? = nil) async throws {
        let _: PaymentRequest = try await api.send("POST", Self.paymentsPath + "/requests/\(id)/refuse",
                                                   body: PaymentRefusalBody(reason: reason.rawValue, expected: expected))
    }

    /// The Mac is about to type. False when the helper stopped waiting (409).
    public func startPaymentFill(_ id: String) async throws -> Bool {
        do {
            let _: PaymentRequest = try await api.send("POST", Self.paymentsPath + "/requests/\(id)/start", json: .object([:]))
            return true
        } catch HermesAPIError.http(status: 409, _) { return false }
    }

    /// How it went. `showing`: typed, but the number is still on the screen, so pictures stay paused.
    public func reportPayment(_ id: String, outcome: String, reason: PaymentFailure? = nil, showing: Bool = false) async throws {
        let _: PaymentRequest = try await api.send("POST", Self.paymentsPath + "/requests/\(id)/result",
                                                   body: PaymentReportBody(outcome: outcome, reason: reason?.rawValue,
                                                                           showing: showing))
    }

    /// The number has gone from the screen: pictures may resume after the short pause.
    public func clearPayment(_ id: String) async throws {
        let _: PaymentRequest = try await api.send("POST", Self.paymentsPath + "/requests/\(id)/clear", json: .object([:]))
    }

    public func paymentHistory(days: Int = 30) async throws -> [PaymentHistoryEntry] {
        let reply: PaymentHistoryReply = try await api.get(Self.paymentsPath + "/history",
                                                           query: [URLQueryItem(name: "days", value: String(days))])
        return reply.entries
    }
}
