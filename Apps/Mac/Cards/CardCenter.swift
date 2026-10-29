import Foundation
import LocalAuthentication
import NollieCore
import Observation

/// Saved cards on this Mac: the Keychain store, the person's rules, telling the add-on which cards
/// exist (as "Visa ending 4242"), wording each payment by the rules, and filling the card once the
/// person said yes and typed the security code here. Every fill reads the card with Touch ID or the
/// Mac's password first, whichever device answered the card.
@MainActor
@Observable
final class CardCenter {
    static let shared = CardCenter()

    let store: SavedCardStore
    let rules: PaymentRuleStore
    @ObservationIgnored var filler: any CardFilling = CuaCardFill()
    @ObservationIgnored var runtime: () -> (any CardGateway)? = { AppModel.shared.runtime }
    @ObservationIgnored var isPrivate: (String) -> Bool = {
        PrivateBots.isPrivate($0, connection: AppModel.shared.runtime?.connection.id) || AskFirstModel.isPrivateBot($0)
    }
    /// Puts the pay sheet up on this Mac, or takes it down (nil).
    @ObservationIgnored var present: (PayAsk?) -> Void = { PaySheetWindow.show($0) }
    @ObservationIgnored var pollEvery: Duration = .seconds(2)
    /// After saying it is about to type, so a picture already being taken finishes first.
    @ObservationIgnored var settleBeforeTyping: Duration = .milliseconds(1500)
    /// After pressing Return, before looking for the number on the screen.
    @ObservationIgnored var settleAfterTyping: Duration = .seconds(3)
    @ObservationIgnored var watchEvery: Duration = .seconds(5)
    @ObservationIgnored var watchFor: Duration = .seconds(3600)

    /// What each card showed, by request: only this copy of Nollie holds them, and a payment that comes
    /// back approved without one is refused, never guessed.
    private(set) var plans: [String: PaymentPlan] = [:]
    /// The payment waiting for its security code on this Mac, one at a time.
    private(set) var asking: PayAsk?
    @ObservationIgnored private var waitingToAsk: [String] = []
    @ObservationIgnored private var handling: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sentCards: (connection: UUID, cards: [SavedCard])?

    init(store: SavedCardStore? = nil, rules: PaymentRuleStore? = nil) {
        self.store = store ?? Self.defaultStore()
        self.rules = rules ?? Self.defaultRules()
        self.store.onChange = { [weak self] _ in self?.sentCards = nil }
    }

    static func defaultStore() -> SavedCardStore {
        let authenticator = RememberedSignInCoordinator.defaultAuthenticator()
        let authenticate: @MainActor (String) async -> LAContext? = { reason in await authenticator.authenticate(reason: reason) }
        #if DEBUG
        if DemoMode.isOn || Keychain.memoryOnly {
            // The demo copy keeps cards in memory, and only a payment provider's published test numbers.
            let backend = MemorySavedCardBackend()
            let store = SavedCardStore(backend: backend, authenticate: authenticate)
            if ProcessInfo.processInfo.arguments.contains("-nollie-demo-cards") {
                let start = Date(timeIntervalSince1970: 1_790_000_000)
                _ = try? store.add(number: "4242 4242 4242 4242", expiry: "12/34", holder: "Sam Example", now: start)
                _ = try? store.add(number: "5555 5555 5555 4444", expiry: "08/33", holder: "Sam Example",
                                   now: start.addingTimeInterval(1))
            }
            return store
        }
        #endif
        return SavedCardStore(backend: KeychainSavedCardBackend(), authenticate: authenticate)
    }

    static func defaultRules() -> PaymentRuleStore {
        #if DEBUG
        if DemoMode.isOn || Keychain.memoryOnly { return PaymentRuleStore(backend: MemoryPaymentRuleBackend()) }
        #endif
        return PaymentRuleStore(backend: KeychainPaymentRuleBackend())
    }

    func start() {
        guard loop == nil else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-nollie-demo-card-fill") { filler = DemoCardFill() }
        if DemoMode.isOn, ProcessInfo.processInfo.arguments.contains("-nollie-demo-pay-sheet") {
            // For pictures: the sheet as a helper's payment puts it up, with a test card.
            asking = PayAsk(requestID: "demo", bot: "Scout", site: "shop.example.com", amount: "£48.99",
                            cardLabel: "Visa ending 4242", codeLength: 3)
            Task { try? await Task.sleep(for: .seconds(1)); self.present(self.asking) }
            return
        }
        #endif
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: self?.pollEvery ?? .seconds(2))
            }
        }
    }

    /// The runtime this Mac pays for: a gateway on this very Mac, connected.
    private func localRuntime() -> (any CardGateway)? {
        guard let rt = runtime(), rt.gatewayIsOnThisMac else { return nil }
        return rt
    }

    func tick() async {
        guard let rt = localRuntime() else { return }
        await sendCards(to: rt)
        guard let found = try? await rt.paymentRequests() else { return }
        let open = Set(found.requests.map(\.id))
        plans = plans.filter { open.contains($0.key) }
        waitingToAsk.removeAll { !open.contains($0) }
        if let shown = asking, !open.contains(shown.requestID) { finishAsking() }
        for request in found.requests where !handling.contains(request.id) {
            switch request.state {
            case "waiting":
                handling.insert(request.id)
                await word(request, allowed: found.allowed, runtime: rt)
                handling.remove(request.id)
            case "approved":
                guard asking?.requestID != request.id, !waitingToAsk.contains(request.id) else { continue }
                if plans[request.id] == nil || !(plans[request.id]?.matches(request) ?? false) {
                    // Not worded here, or not what the card showed: never filled.
                    try? await rt.reportPayment(request.id, outcome: "failed", reason: .changed, showing: false)
                    continue
                }
                waitingToAsk.append(request.id)
            default:
                continue
            }
        }
        askNext(runtime: rt)
    }

    func sendCards(to rt: any CardGateway) async {
        store.reload()
        guard store.isKnown else { return }
        let cards = store.items
        if let sent = sentCards, sent.connection == rt.connectionID, sent.cards == cards { return }
        do {
            try await rt.savePaymentCards(cards)
            sentCards = (rt.connectionID, cards)
        } catch {
            // An add-on without payments, or Hermes restarting: try again on the next look.
        }
    }

    // MARK: Wording, by the rules

    /// What the rules say about a request, from this Mac's own record of the person's choices.
    func decide(_ request: PaymentRequest, allowed: Set<String>) -> (PaymentDecision, SavedCard?) {
        if isPrivate(request.bot) { return (.refuse(.privateBot), nil) }
        store.reload()
        let card = store.card(lastFour: request.card)
        if request.card != nil, card == nil, !store.items.isEmpty { return (.refuse(.unknownCard), nil) }
        guard let attempt = request.attempt else { return (.refuse(.badTotal), nil) }
        let decision = PaymentRules.decide(attempt, settings: rules.settings, paidSites: rules.state.paidSites,
                                           botMayPay: allowed.contains(request.bot), isPrivate: false, hasCard: card != nil)
        return (decision, card)
    }

    func word(_ request: PaymentRequest, allowed: Set<String>, runtime rt: any CardGateway) async {
        let (decision, card) = decide(request, allowed: allowed)
        switch decision {
        case .refuse(let reason):
            try? await rt.refusePayment(request.id, reason: reason, expected: reason == .currency ? rules.settings.currency : nil)
        case .ask, .quick:
            guard let card, let attempt = request.attempt else { return }
            var first = false
            if case .ask(let firstOnSite) = decision { first = firstOnSite }
            let words = PaymentWords.card(total: attempt.total, currency: attempt.currency, site: attempt.site, card: card,
                                          firstOnSite: first)
            let plan = PaymentPlan(requestID: request.id, bot: request.bot, site: attempt.site, total: attempt.total,
                                   currency: attempt.currency, cardID: card.id, cardLabel: card.label, words: words)
            plans[request.id] = plan
            if (try? await rt.preparePayment(request.id, words: words, card: card.label, ask: decision != .quick)) != true {
                plans[request.id] = nil
            }
        }
    }

    // MARK: The security code, on this Mac

    private func askNext(runtime rt: any CardGateway) {
        guard asking == nil, let next = waitingToAsk.first, let plan = plans[next],
              let card = store.items.first(where: { $0.id == plan.cardID }) else { return }
        waitingToAsk.removeFirst()
        asking = PayAsk(requestID: next, bot: rt.botName(plan.bot), site: plan.site,
                        amount: PaymentMoney.text(plan.total, plan.currency), cardLabel: card.label,
                        codeLength: card.brand.codeLength)
        present(asking)
    }

    private func finishAsking() {
        asking = nil
        present(nil)
    }

    /// Cancel on the pay sheet: nothing is filled, and the helper hears the person didn't confirm.
    func cancel() async {
        guard let shown = asking, let rt = localRuntime() else { finishAsking(); return }
        finishAsking()
        try? await rt.reportPayment(shown.requestID, outcome: "cancelled", reason: nil, showing: false)
        askNext(runtime: rt)
    }

    /// Pay on the pay sheet. Returns a sentence when it can't go on yet (the sheet stays up), or nil
    /// once the payment has been handed on (the sheet goes).
    func pay(code: String) async -> String? {
        guard let shown = asking, let rt = localRuntime() else { return nil }
        let digits = code.filter { !$0.isWhitespace }
        guard digits.count == shown.codeLength, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return String(localized: "Enter the \(shown.codeLength)-digit security code.")
        }
        guard let plan = plans[shown.requestID] else { return nil }
        guard let card = store.items.first(where: { $0.id == plan.cardID }) else {
            finishAsking()
            try? await rt.reportPayment(shown.requestID, outcome: "failed", reason: .notSavedHere, showing: false)
            return nil
        }
        let reason = String(localized: "pay \(shown.amount) to \(shown.site)",
                            comment: "Safety: payment; Touch ID reason, finishes 'Nollie is trying to …'; the amount, then the site")
        guard let context = await store.confirmOwner(reason: reason) else {
            return String(localized: "Nothing was paid. Try again when you're ready.", comment: "Safety: payment")
        }
        let secret: CardSecret
        do { secret = try store.secret(card, context: context) } catch {
            finishAsking()
            try? await rt.reportPayment(shown.requestID, outcome: "failed", reason: .touchID, showing: false)
            return nil
        }
        finishAsking()
        handling.insert(plan.requestID)
        Task {
            await self.fill(plan, secret: secret, code: digits, runtime: rt)
            self.handling.remove(plan.requestID)
            self.askNext(runtime: rt)
        }
        return nil
    }

    /// Checks again, looks for the total on the screen, types, then watches until the number is gone.
    func fill(_ plan: PaymentPlan, secret: CardSecret, code: String, runtime rt: any CardGateway) async {
        let id = plan.requestID
        guard let request = try? await rt.paymentRequest(id), request.state == "approved" else { return }
        guard plan.matches(request), !isPrivate(request.bot) else {
            try? await rt.reportPayment(id, outcome: "failed", reason: isPrivate(request.bot) ? .privateBot : .changed, showing: false)
            return
        }
        // The total the person said yes to must be on the checkout now, read here, not told by the helper.
        guard let before = await filler.screenText(request.computer) else {
            try? await rt.reportPayment(id, outcome: "failed", reason: .computerUnavailable, showing: false)
            return
        }
        guard PaymentScreen.showsTotal(before, total: plan.total) else {
            try? await rt.reportPayment(id, outcome: "failed", reason: .totalNotShown, showing: false)
            return
        }
        // Only once, and only while the helper still waits: pictures pause from here on.
        guard (try? await rt.startPaymentFill(id)) == true else { return }
        try? await Task.sleep(for: settleBeforeTyping)
        guard (try? await rt.paymentRequest(id))?.state == "filling" else { return }
        let job = CardFillJob(computer: request.computer, number: secret.number, expiry: secret.expiry.text, code: code)
        switch await filler.fill(job) {
        case .failure(let reason):
            // Cua couldn't be reached: nothing was typed. Otherwise part of the number may be on the screen.
            let typed = reason != .computerUnavailable
            try? await rt.reportPayment(id, outcome: "failed", reason: reason, showing: typed)
            if typed { await watch(id, number: secret.number, computer: request.computer, runtime: rt) }
        case .success:
            rules.remember(plan.site)
            try? await Task.sleep(for: settleAfterTyping)
            let after = await filler.screenText(request.computer)
            let showing = PaymentScreen.showsNumber(after ?? [], number: secret.number)
            try? await rt.reportPayment(id, outcome: "paid", reason: nil, showing: showing)
            if showing { await watch(id, number: secret.number, computer: request.computer, runtime: rt) }
        }
    }

    /// Pictures stay paused while more than the last four digits can be read on the screen. Looks again
    /// every few seconds, here on the Mac, and tells the add-on once the number has gone.
    private func watch(_ id: String, number: String, computer: String, runtime rt: any CardGateway) async {
        let deadline = ContinuousClock.now + watchFor
        while ContinuousClock.now < deadline {
            guard (try? await rt.paymentRequest(id))?.state == "showing" else { return }
            if let lines = await filler.screenText(computer), !PaymentScreen.showsNumber(lines, number: number) {
                try? await rt.clearPayment(id)
                return
            }
            try? await Task.sleep(for: watchEvery)
        }
    }
}

/// The pay sheet's question: which helper, how much, where, with which card.
struct PayAsk: Equatable, Identifiable {
    var requestID: String
    var bot: String
    var site: String
    var amount: String
    var cardLabel: String
    var codeLength: Int
    var id: String { requestID }
}

/// What the center needs from a gateway: a protocol so the tests can stand in for Hermes.
@MainActor
protocol CardGateway: AnyObject {
    var gatewayIsOnThisMac: Bool { get }
    var connectionID: UUID { get }
    func botName(_ profile: String) -> String
    func savePaymentCards(_ cards: [SavedCard]) async throws
    func paymentRequests() async throws -> PaymentRequests
    func paymentRequest(_ id: String) async throws -> PaymentRequest
    func preparePayment(_ id: String, words: String, card: String, ask: Bool) async throws -> Bool
    func refusePayment(_ id: String, reason: PaymentRefusal, expected: String?) async throws
    func startPaymentFill(_ id: String) async throws -> Bool
    func reportPayment(_ id: String, outcome: String, reason: PaymentFailure?, showing: Bool) async throws
    func clearPayment(_ id: String) async throws
}

extension GatewayRuntime: CardGateway {}
