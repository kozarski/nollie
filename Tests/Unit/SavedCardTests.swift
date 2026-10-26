import Foundation
import LocalAuthentication
import Security
import Testing
@testable import Nollie
@testable import NollieCore

/// Saved cards and paying with them: how cards are stored and named, the fixed rules for when a payment
/// asks, the checks on the helper's screen, and (on the Mac) how a payment is worded and filled. Only
/// payment providers' published test numbers are used, and the number must never reach anything a
/// helper, a log or Papertrail can read: only "ending 4242".
@MainActor
struct SavedCardTests {
    static let visa = "4242 4242 4242 4242"
    static let visaDigits = "4242424242424242"
    static let now = Date(timeIntervalSince1970: 1_790_000_000)   // September 2026

    final class Prompts {
        var answer = true
        var reasons: [String] = []
    }

    private func store(_ backend: MemorySavedCardBackend = MemorySavedCardBackend(), prompts: Prompts = Prompts()) -> SavedCardStore {
        SavedCardStore(backend: backend) { reason in
            prompts.reasons.append(reason)
            return prompts.answer ? LAContext() : nil
        }
    }

    /// True when a text holds more of the test number than its last four digits: any run of digits,
    /// with or without spaces or dashes between them, that holds its first eight.
    static func leaks(_ text: String) -> Bool {
        let runs = text.matches(of: /[0-9](?:[ -]?[0-9])*/).map { $0.output.filter(\.isNumber) }
        return runs.contains { $0.contains(String(visaDigits.prefix(8))) }
    }

    // MARK: Card numbers

    @Test func testNumbersAreReadAndNamed() {
        #expect(CardNumber.valid(Self.visa) == Self.visaDigits)
        #expect(CardNumber.brand("4242424242424242") == .visa)
        #expect(CardNumber.brand("5555555555554444") == .mastercard)
        #expect(CardNumber.brand("2223003122003222") == .mastercard)
        #expect(CardNumber.brand("378282246310005") == .amex)
        #expect(CardNumber.brand("6011111111111117") == .discover)
        #expect(CardNumber.valid("4242 4242 4242 4241") == nil, "a wrong check digit")
        #expect(CardNumber.valid("4242-4242-4242-4242") == Self.visaDigits)
        #expect(CardNumber.valid("4242 4242 abcd 4242") == nil)
        #expect(CardNumber.valid("4242") == nil)
        #expect(CardBrand.amex.codeLength == 4 && CardBrand.visa.codeLength == 3)
    }

    @Test func expiryDatesAreReadAndRunOut() throws {
        #expect(CardExpiry("12/28")?.text == "12/28")
        #expect(CardExpiry("12/2028") == CardExpiry(month: 12, year: 2028))
        #expect(CardExpiry("1228") == CardExpiry(month: 12, year: 2028))
        #expect(CardExpiry("13/28") == nil)
        #expect(CardExpiry("soon") == nil)
        #expect(try #require(CardExpiry("08/26")).hasRunOut(at: Self.now))
        #expect(try !#require(CardExpiry("09/26")).hasRunOut(at: Self.now), "good to the end of its month")
    }

    // MARK: Storage

    @Test func aCardIsSavedAsALabelAndALockedNumber() throws {
        let backend = MemorySavedCardBackend()
        let s = store(backend)
        let card = try s.add(number: Self.visa, expiry: "12/34", holder: "  Sam   Example ", now: Self.now)
        #expect(card.label == "Visa ending 4242")
        #expect(card.holder == "Sam Example")
        #expect(s.items == [card])
        // The listing holds no number.
        let listing = String(decoding: try JSONEncoder().encode(card), as: UTF8.self)
        #expect(!Self.leaks(listing))
        let opened = try s.secret(card, context: LAContext())
        #expect(opened.number == Self.visaDigits && opened.expiry.text == "12/34")
        // Logs and dumps never show it.
        #expect(!Self.leaks(String(describing: opened)) && !Self.leaks(String(reflecting: opened)))
        var dumped = ""
        dump(opened, to: &dumped)
        #expect(!Self.leaks(dumped))
    }

    @Test func badCardsAreRefusedBeforeSaving() throws {
        let s = store()
        #expect(throws: SavedCardError.badNumber) { try s.add(number: "4242 4242 4242 4241", expiry: "12/34", holder: "Sam", now: Self.now) }
        #expect(throws: SavedCardError.badExpiry) { try s.add(number: Self.visa, expiry: "34", holder: "Sam", now: Self.now) }
        #expect(throws: SavedCardError.expired) { try s.add(number: Self.visa, expiry: "01/25", holder: "Sam", now: Self.now) }
        #expect(throws: SavedCardError.noName) { try s.add(number: Self.visa, expiry: "12/34", holder: " ", now: Self.now) }
        #expect(throws: SavedCardError.noName) { try s.add(number: Self.visa, expiry: "12/34", holder: Self.visa, now: Self.now) }
        try s.add(number: Self.visa, expiry: "12/34", holder: "Sam", now: Self.now)
        #expect(throws: SavedCardError.duplicate("Visa ending 4242")) {
            try s.add(number: Self.visa, expiry: "11/33", holder: "Sam", now: Self.now)
        }
        try s.remove(s.items[0])
        #expect(s.items.isEmpty)
    }

    @Test func keychainItemsAreThisMacOnlyAndBehindTouchIDForEveryRead() throws {
        typealias K = KeychainSavedCardBackend
        let q = K.query(id: "x")
        #expect(q[kSecAttrSynchronizable as String] as? Bool == false, "iCloud Keychain must never carry a card")
        #expect(q[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(K.accessFlags == .userPresence)
        #expect(K.protection == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly)
        #expect(![Keychain.service, KeychainSavedSignInBackend.service, KeychainSavedSignInBackend.listService,
                  KeychainPaymentRuleBackend.service].contains(K.service))
        let card = SavedCard(id: "x", brand: .visa, last4: "4242", holder: "Sam")
        let secret = try JSONEncoder().encode(CardSecret(number: Self.visaDigits, expiry: try #require(CardExpiry("12/34"))))
        let locked = try K.secretAttributes(card, secret: secret)
        #expect(locked[kSecAttrAccessControl as String] != nil)
        #expect(locked[kSecAttrService as String] as? String == K.service)
        #expect(!Self.leaks(locked[kSecAttrLabel as String] as? String ?? ""))
        let listing = try K.listingAttributes(card)
        #expect(listing[kSecAttrService as String] as? String == K.listService)
        #expect(!Self.leaks(String(decoding: listing[kSecValueData as String] as? Data ?? Data(), as: UTF8.self)))
        #expect(KeychainPaymentRuleBackend.query()[kSecAttrSynchronizable as String] as? Bool == false)
    }

    // MARK: The rules

    private func attempt(_ total: Decimal = 12, site: String = "shop.example.com", currency: String = "GBP") -> PaymentAttempt {
        PaymentAttempt(bot: "career", site: site, total: total, currency: currency)
    }

    private func decide(_ a: PaymentAttempt, quick: Bool = false, limit: Decimal = 20, paid: Set<String> = [],
                        allowed: Bool = true, isPrivate: Bool = false, hasCard: Bool = true) -> PaymentDecision {
        PaymentRules.decide(a, settings: PaymentSettings(quickPay: quick, quickLimit: limit, currency: "GBP"), paidSites: paid,
                            botMayPay: allowed, isPrivate: isPrivate, hasCard: hasCard)
    }

    @Test func theFirstPaymentOnEachSiteAlwaysAsks() {
        #expect(decide(attempt()) == .ask(firstOnSite: true))
        // Even with quick pay on and well under the limit.
        #expect(decide(attempt(1), quick: true, limit: 100) == .ask(firstOnSite: true))
        // A payment on another part of a site is a site of its own.
        #expect(decide(attempt(1, site: "pay.shop.example.com"), quick: true, paid: ["shop.example.com"]) == .ask(firstOnSite: true))
    }

    @Test func everyPaymentAsksUnlessQuickPayIsOnAndUnderTheLimit() {
        let paid: Set<String> = ["shop.example.com"]
        #expect(PaymentSettings().quickPay == false, "off to start")
        #expect(decide(attempt(5), paid: paid) == .ask(firstOnSite: false), "quick pay off: asks")
        #expect(decide(attempt(5), quick: true, paid: paid) == .quick)
        #expect(decide(attempt(20), quick: true, limit: 20, paid: paid) == .quick, "the limit itself is under it")
        #expect(decide(attempt(Decimal(string: "20.01")!), quick: true, limit: 20, paid: paid) == .ask(firstOnSite: false))
        #expect(decide(attempt(5000), quick: true, limit: 100, paid: paid) == .ask(firstOnSite: false))
    }

    @Test func aCurrencyThePersonDoesNotPayInIsRefused() {
        #expect(decide(attempt(currency: "USD")) == .refuse(.currency))
        #expect(decide(attempt(currency: "USD"), quick: true, paid: ["shop.example.com"]) == .refuse(.currency))
    }

    @Test func privateBotsSwitchedOffHelpersAndNoCardNeverPay() {
        #expect(decide(attempt(), isPrivate: true) == .refuse(.privateBot))
        #expect(decide(attempt(), quick: true, paid: ["shop.example.com"], isPrivate: true) == .refuse(.privateBot))
        #expect(decide(attempt(), allowed: false) == .refuse(.notAllowed))
        #expect(decide(attempt(), hasCard: false) == .refuse(.noCard))
        #expect(decide(attempt(0)) == .refuse(.badTotal))
        #expect(decide(attempt(200_000)) == .refuse(.badTotal))
        #expect(decide(attempt(site: "shop.example.com@evil.net")) == .refuse(.badSite))
        #expect(decide(attempt(site: "SHOP.example.com")) == .refuse(.badSite), "sites come cleaned, or not at all")
    }

    @Test func aPaymentThatChangedAfterTheCardIsNotFilled() {
        let plan = PaymentPlan(requestID: "r", bot: "career", site: "shop.example.com", total: Decimal(string: "48.99")!,
                               currency: "GBP", cardID: "c", cardLabel: "Visa ending 4242", words: "")
        let same = PaymentRequest(id: "r", bot: "career", site: "shop.example.com", total: "48.99", currency: "GBP", state: "approved")
        #expect(plan.matches(same))
        var changed = same; changed.total = "480.99"
        #expect(!plan.matches(changed))
        changed = same; changed.currency = "USD"
        #expect(!plan.matches(changed))
        changed = same; changed.site = "shop.example.net"
        #expect(!plan.matches(changed))
        changed = same; changed.bot = "work"
        #expect(!plan.matches(changed))
    }

    @Test func theCardSaysWhatWhereAndWhichCardOnly() {
        let card = SavedCard(brand: .visa, last4: "4242", holder: "Sam Example")
        let words = PaymentWords.card(total: Decimal(string: "48.99")!, currency: "GBP", site: "shop.example.com", card: card, firstOnSite: true)
        #expect(words == "Pay £48.99 to shop.example.com with Visa ending 4242.\nFirst payment to this site.\nYou type the security code on your Mac.")
        #expect(!Self.leaks(words))
        #expect(PaymentWords.card(total: 5, currency: "CHF", site: "a.example.com", card: card, firstOnSite: false)
                == "Pay 5.00 CHF to a.example.com with Visa ending 4242.\nYou type the security code on your Mac.")
    }

    @Test func amountsReadTheSameEverywhere() {
        #expect(PaymentMoney.amount("48.99") == Decimal(string: "48.99"))
        #expect(PaymentMoney.amount("48.999") == nil)
        #expect(PaymentMoney.amount("-1") == nil)
        #expect(PaymentMoney.amount("0") == nil)
        #expect(PaymentMoney.text(Decimal(string: "1048.5")!, "EUR") == "€1048.50")
    }

    @Test func theScreenMustShowTheTotal() {
        let total = Decimal(string: "48.99")!
        #expect(PaymentScreen.showsTotal(["Order summary", "Total £48.99"], total: total))
        #expect(PaymentScreen.showsTotal(["Gesamt 48,99 €"], total: total))
        #expect(PaymentScreen.showsTotal(["Total: GBP 1,048.99"], total: Decimal(string: "1048.99")!))
        #expect(PaymentScreen.showsTotal(["Total £50"], total: 50))
        #expect(!PaymentScreen.showsTotal(["Total £480.99"], total: total))
        #expect(!PaymentScreen.showsTotal(["Total £4899"], total: total))
        #expect(!PaymentScreen.showsTotal([], total: total))
    }

    @Test func picturesStayPausedWhileTheNumberShows() {
        #expect(PaymentScreen.showsNumber(["Card number", "4242 4242 4242 4242", "12 / 34"], number: Self.visaDigits))
        #expect(PaymentScreen.showsNumber(["4242 4242", "4242 4242"], number: Self.visaDigits), "split over two lines")
        #expect(!PaymentScreen.showsNumber(["Thank you", "Visa •••• 4242"], number: Self.visaDigits))
        #expect(PaymentScreen.showsNumber([], number: Self.visaDigits), "nothing read counts as still showing")
    }

    @Test func sitesPaidBeforeAreRememberedOnce() {
        var state = PaymentRuleState()
        state.remember("shop.example.com", at: Self.now)
        state.remember("shop.example.com", at: Self.now.addingTimeInterval(60))
        #expect(state.paid.count == 1 && state.paidSites == ["shop.example.com"])
        let rules = PaymentRuleStore(backend: MemoryPaymentRuleBackend())
        #expect(rules.settings.quickPay == false)
        try? rules.update { $0.quickPay = true; $0.quickLimit = 50 }
        #expect(rules.settings.quickPay && rules.settings.quickLimit == 50)
    }

    @Test func papertrailSaysWhereACardWentAndItsLastFourOnly() throws {
        let json = #"{"id": "t-1", "at": 1, "route": "online", "calls": 2, "input_tokens": 1800, "payments": [{"site": "shop.example.com", "card": "4242"}]}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let entry = try decoder.decode(Papertrail.Entry.self, from: Data(json.utf8))
        #expect(entry.amountText == "1.8k tokens · paid shop.example.com, card ending 4242")
        #expect(entry.spokenAmount.hasSuffix("paid shop.example.com, card ending 4 2 4 2"))
    }

    @Test func requestsDecodeAsTheAddOnSendsThem() throws {
        let json = """
            {"id": "0123456789abcdef0123456789abcdef", "bot": "career", "site": "shop.example.com", "total": "48.99",
             "currency": "GBP", "card": null, "computer": "local:dev", "state": "waiting", "ask": null,
             "approver": null, "created_at": 5}
            """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let request = try decoder.decode(PaymentRequest.self, from: Data(json.utf8))
        #expect(request.attempt == PaymentAttempt(bot: "career", site: "shop.example.com", total: Decimal(string: "48.99")!, currency: "GBP"))
        let label = String(decoding: try JSONEncoder().encode(PaymentCardLabel(SavedCard(id: "c", brand: .visa, last4: "4242", holder: "Sam"))),
                           as: UTF8.self)
        #expect(!label.contains("number") && !Self.leaks(label))
    }

    // MARK: On the Mac

    #if os(macOS)
    final class FakeGateway: CardGateway {
        var gatewayIsOnThisMac = true
        let connectionID = UUID()
        var requests: [PaymentRequest] = []
        var allowed: Set<String> = ["career"]
        var sentCards: [[SavedCard]] = []
        var prepared: [(id: String, words: String, card: String, ask: Bool)] = []
        var refused: [(String, PaymentRefusal, String?)] = []
        var started: [String] = []
        var reports: [(id: String, outcome: String, reason: PaymentFailure?, showing: Bool)] = []
        var cleared: [String] = []
        func botName(_ profile: String) -> String { profile == "career" ? "Scout" : profile }
        func savePaymentCards(_ cards: [SavedCard]) async throws { sentCards.append(cards) }
        func paymentRequests() async throws -> PaymentRequests { PaymentRequests(requests: requests, allowed: allowed) }
        func paymentRequest(_ id: String) async throws -> PaymentRequest {
            guard let r = requests.first(where: { $0.id == id }) else { throw HermesAPIError.http(status: 404, detail: "") }
            return r
        }
        func preparePayment(_ id: String, words: String, card: String, ask: Bool) async throws -> Bool {
            prepared.append((id, words, card, ask))
            set(id, "prepared")
            return true
        }
        func refusePayment(_ id: String, reason: PaymentRefusal, expected: String?) async throws {
            refused.append((id, reason, expected))
            set(id, "done")
        }
        func startPaymentFill(_ id: String) async throws -> Bool {
            started.append(id)
            set(id, "filling")
            return true
        }
        func reportPayment(_ id: String, outcome: String, reason: PaymentFailure?, showing: Bool) async throws {
            reports.append((id, outcome, reason, showing))
            set(id, showing ? "showing" : "done")
        }
        func clearPayment(_ id: String) async throws {
            cleared.append(id)
            set(id, "done")
        }
        func set(_ id: String, _ state: String) {
            if let i = requests.firstIndex(where: { $0.id == id }) { requests[i].state = state }
        }
        /// Everything the Mac sent that a helper, a log or Papertrail could read.
        var everythingSent: String {
            prepared.map { "\($0.words) \($0.card)" }.joined() + "\(reports)" + "\(refused)" + "\(sentCards)"
        }
    }

    final class FakeFill: CardFilling, @unchecked Sendable {
        var before: [String]? = ["Checkout", "Total £48.99"]
        var after: [[String]?] = [["Thank you", "Visa •••• 4242"]]
        var result: Result<Void, PaymentFailure> = .success(())
        var jobs: [CardFillJob] = []
        var looked = 0
        func screenText(_ computer: String) async -> [String]? {
            looked += 1
            if jobs.isEmpty { return before }
            return after.count > 1 ? after.removeFirst() : after.first ?? nil
        }
        func fill(_ job: CardFillJob) async -> Result<Void, PaymentFailure> { jobs.append(job); return result }
    }

    static let id = "0123456789abcdef0123456789abcdef"

    private func center(_ prompts: Prompts = Prompts(), fill: FakeFill = FakeFill(), gateway: FakeGateway,
                        quick: Bool = false, paid: [String] = []) throws -> (CardCenter, [PayAsk?]) {
        let s = store(prompts: prompts)
        try s.add(number: Self.visa, expiry: "12/34", holder: "Sam Example", now: Self.now)
        var state = PaymentRuleState(settings: PaymentSettings(quickPay: quick, quickLimit: 20, currency: "GBP"))
        for site in paid { state.remember(site) }
        let c = CardCenter(store: s, rules: PaymentRuleStore(backend: MemoryPaymentRuleBackend(state)))
        c.filler = fill
        c.runtime = { gateway }
        c.isPrivate = { $0 == "moss" }
        c.present = { _ in }
        c.settleBeforeTyping = .zero
        c.settleAfterTyping = .zero
        c.watchEvery = .milliseconds(10)
        return (c, [])
    }

    private func request(_ bot: String = "career", total: String = "48.99", currency: String = "GBP",
                         state: String = "waiting") -> PaymentRequest {
        PaymentRequest(id: Self.id, bot: bot, site: "shop.example.com", total: total, currency: currency, state: state)
    }

    private func until(_ done: @escaping () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func theMacWordsTheFirstPaymentOnASiteForTheCard() async throws {
        let gateway = FakeGateway()
        gateway.requests = [request()]
        let (c, _) = try center(gateway: gateway)
        await c.tick()
        let prepared = try #require(gateway.prepared.first)
        #expect(prepared.ask == true)
        #expect(prepared.card == "Visa ending 4242")
        #expect(prepared.words.hasPrefix("Pay £48.99 to shop.example.com with Visa ending 4242.\nFirst payment"))
        #expect(gateway.sentCards.last?.map(\.label) == ["Visa ending 4242"])
        #expect(!Self.leaks(gateway.everythingSent))
    }

    @Test func quickPaySparesTheCardOnlyOnASitePaidBefore() async throws {
        let gateway = FakeGateway()
        gateway.requests = [request(total: "12.00")]
        let (c, _) = try center(gateway: gateway, quick: true, paid: ["shop.example.com"])
        await c.tick()
        #expect(gateway.prepared.first?.ask == false)
        let other = FakeGateway()
        other.requests = [request(total: "12.00")]
        let (fresh, _) = try center(gateway: other, quick: true)
        await fresh.tick()
        #expect(other.prepared.first?.ask == true, "first payment there")
    }

    @Test func theMacRefusesPrivateBotsSwitchedOffHelpersAndOtherCurrencies() async throws {
        for (req, allowed, reason) in [(request("moss"), Set(["moss"]), PaymentRefusal.privateBot),
                                       (request(), Set<String>(), .notAllowed),
                                       (request(currency: "USD"), Set(["career"]), .currency)] {
            let gateway = FakeGateway()
            gateway.allowed = allowed
            gateway.requests = [req]
            let (c, _) = try center(gateway: gateway)
            await c.tick()
            #expect(gateway.prepared.isEmpty)
            #expect(gateway.refused.map(\.1) == [reason])
            if reason == .currency { #expect(gateway.refused.first?.2 == "GBP") }
        }
    }

    @Test func payingAsksTouchIDTypesTheCardAndTellsOnlyTheLastFour() async throws {
        let prompts = Prompts(), fill = FakeFill(), gateway = FakeGateway()
        gateway.requests = [request()]
        let (c, _) = try center(prompts, fill: fill, gateway: gateway)
        var shown: [PayAsk?] = []
        c.present = { shown.append($0) }
        await c.tick()
        gateway.set(Self.id, "approved")
        await c.tick()
        let ask = try #require(c.asking)
        #expect(ask.amount == "£48.99" && ask.cardLabel == "Visa ending 4242" && ask.bot == "Scout" && ask.codeLength == 3)
        #expect(shown.compactMap { $0 }.count == 1)
        #expect(await c.pay(code: "12") == "Enter the 3-digit security code.")
        #expect(fill.jobs.isEmpty)
        #expect(await c.pay(code: "123") == nil)
        await until { !gateway.reports.isEmpty }
        #expect(prompts.reasons == ["pay £48.99 to shop.example.com"])
        let job = try #require(fill.jobs.first)
        #expect(job.number == Self.visaDigits && job.expiry == "12/34" && job.code == "123")
        #expect(!Self.leaks(String(describing: job)) && !String(describing: job).contains("123"))
        #expect(gateway.started == [Self.id])
        #expect(gateway.reports.map { "\($0.outcome) \($0.showing)" } == ["paid false"])
        #expect(c.rules.state.paidSites == ["shop.example.com"])
        #expect(!Self.leaks(gateway.everythingSent))
        #expect(c.asking == nil)
    }

    @Test func noTouchIDMeansNothingIsTypedAndTheSheetStays() async throws {
        let prompts = Prompts(), fill = FakeFill(), gateway = FakeGateway()
        prompts.answer = false
        gateway.requests = [request()]
        let (c, _) = try center(prompts, fill: fill, gateway: gateway)
        await c.tick()
        gateway.set(Self.id, "approved")
        await c.tick()
        #expect(await c.pay(code: "123") != nil)
        #expect(fill.jobs.isEmpty && gateway.started.isEmpty && gateway.reports.isEmpty)
        #expect(c.asking != nil)
        await c.cancel()
        #expect(gateway.reports.map(\.outcome) == ["cancelled"])
    }

    @Test func aTotalTheScreenDoesNotShowAbortsBeforeTyping() async throws {
        let fill = FakeFill(), gateway = FakeGateway()
        fill.before = ["Checkout", "Total £480.99"]
        gateway.requests = [request()]
        let (c, _) = try center(fill: fill, gateway: gateway)
        await c.tick()
        gateway.set(Self.id, "approved")
        await c.tick()
        _ = await c.pay(code: "123")
        await until { !gateway.reports.isEmpty }
        #expect(fill.jobs.isEmpty && gateway.started.isEmpty)
        #expect(gateway.reports.first?.reason == .totalNotShown)
    }

    @Test func aTotalOrCurrencyThatChangedAfterTheCardAborts() async throws {
        let fill = FakeFill(), gateway = FakeGateway()
        gateway.requests = [request()]
        let (c, _) = try center(fill: fill, gateway: gateway)
        await c.tick()
        // Something rewrote the request after the card was worded.
        gateway.requests[0].total = "480.99"
        gateway.set(Self.id, "approved")
        await c.tick()
        #expect(c.asking == nil)
        #expect(fill.jobs.isEmpty)
        #expect(gateway.reports.map { "\($0.outcome) \($0.reason?.rawValue ?? "")" } == ["failed changed"])
    }

    @Test func aYesTheMacNeverWordedIsNeverFilled() async throws {
        let fill = FakeFill(), gateway = FakeGateway()
        gateway.requests = [request(state: "approved")]
        let (c, _) = try center(fill: fill, gateway: gateway)
        await c.tick()
        #expect(c.asking == nil && fill.jobs.isEmpty)
        #expect(gateway.reports.first?.reason == .changed)
    }

    @Test func picturesStayPausedUntilTheNumberHasGone() async throws {
        let fill = FakeFill(), gateway = FakeGateway()
        fill.after = [["Card number", "4242 4242 4242 4242"], ["4242 4242 4242 4242"], ["Thank you"]]
        gateway.requests = [request()]
        let (c, _) = try center(fill: fill, gateway: gateway)
        await c.tick()
        gateway.set(Self.id, "approved")
        await c.tick()
        _ = await c.pay(code: "123")
        await until { !gateway.cleared.isEmpty }
        #expect(gateway.reports.map { "\($0.outcome) \($0.showing)" } == ["paid true"])
        #expect(gateway.cleared == [Self.id])
    }

    @Test func theFillTypesNumberExpiryCodeThenReturn() throws {
        let job = CardFillJob(computer: "local:dev", number: Self.visaDigits, expiry: "12/34", code: "123")
        let steps = CardFillSteps.steps(for: job, sandbox: "local:dev")
        #expect(steps.map(\.0) == ["computer_type", "computer_key", "computer_type", "computer_key", "computer_type", "computer_key"])
        #expect(steps.map { ($0.1["text"] as? String) ?? ($0.1["key"] as? String) ?? "" }
                == [Self.visaDigits, "tab", "12/34", "tab", "123", "enter"])
    }
    #endif
}
