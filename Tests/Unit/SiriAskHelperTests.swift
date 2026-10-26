import AppIntents
import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// "Ask Nollie" from Siri, Shortcuts and the Action button: which way a request goes and what is
/// said when it can't, that a card always stops the wait and is never answered, and the words.
@MainActor @Suite struct SiriAskHelperTests {
    // MARK: Routing

    private func runtime(linked: Bool) throws -> GatewayRuntime {
        var link = GatewayConnection(name: "Ask", gateway: try GatewayURL.normalize("https://192.168.1.20:8443"), authMode: .sessionToken)
        if linked {
            link.linkedMac = LinkedMac(macName: "Studio", pin: Data(), port: 8443, hosts: ["192.168.1.20"],
                                       installTag: "test", deviceID: UUID())
        }
        let runtime = GatewayRuntime(connection: link, store: ConnectionStore())
        runtime.socketEnabled = false
        return runtime
    }

    @Test func anIPhoneLinkedToAMacAsksThroughTheMac() throws {
        #expect(AskRoute.path(of: try runtime(linked: true), onMac: false) == .linkedMac(.home))
        #expect(AskRoute.path(of: try runtime(linked: false), onMac: false) == .gateway)
        // On the Mac the request goes to the Mac's own helpers, whatever the connection says.
        #expect(AskRoute.path(of: try runtime(linked: true), onMac: true) == .thisMac)
    }

    @Test func eachWaySaysPlainlyWhyItCannotAsk() {
        #expect(AskRoute.problem(path: .linkedMac(.home), open: true) == nil)
        #expect(AskRoute.problem(path: .linkedMac(.tailnet), open: true) == nil)
        #expect(AskRoute.problem(path: .gateway, open: true) == nil)
        #expect(AskRoute.problem(path: .thisMac, open: true) == nil)

        // Away from home without Tailscale: the same words as Stop, even if a stale socket looks open.
        #expect(AskRoute.problem(path: .linkedMac(.away), open: true) == MacStopWords.unreachable)
        #expect(AskRoute.problem(path: .linkedMac(.away), open: false) == "Can't reach your Mac right now. Try at home, or with Tailscale on both.")
        #expect(AskRoute.problem(path: .linkedMac(.home), open: false) == "Your Mac isn't answering. Check it's awake, then try again.")
        #expect(AskRoute.problem(path: .linkedMac(.tailnet), open: false) == AskWords.macQuiet)
        #expect(AskRoute.problem(path: .gateway, open: false) == "Nollie can't reach your helpers right now.")
        #expect(AskRoute.problem(path: .thisMac, open: false) == AskWords.thisMacQuiet)
    }

    @Test func theHelperIsTheOneNamedAndNeverAPrivateOne() {
        let crew = [ProfileInfo(name: "default", displayName: "Nollie", isDefault: true), ProfileInfo(name: "career", displayName: "Scout"),
                    ProfileInfo(name: "private", displayName: "Moss")]
        func pick(_ name: String?, privately: Set<String> = []) -> String {
            switch AskRoute.pick(name, among: crew, isPrivate: { privately.contains($0) }) {
            case .success(let found): "\(found.profile)/\(found.name)"
            case .failure(let refusal): refusal.words
            }
        }
        #expect(pick("career") == "career/Scout")
        #expect(pick("default") == "default/Nollie")
        #expect(pick("gone") == AskWords.unknownHelper)
        #expect(pick(nil) == AskWords.unknownHelper)
        #expect(pick("private") == "Moss is private. Ask in Nollie.")
        #expect(pick("career", privately: ["career"]) == "Scout is private. Ask in Nollie.")
        // Before the list has loaded, a name from Siri's catalog is trusted as it is.
        if case .success(let early) = AskRoute.pick("career", among: [], isPrivate: { _ in false }) {
            #expect(early.profile == "career")
        } else {
            Issue.record("a known name was refused before the list loaded")
        }
    }

    // MARK: Ask first

    @Test func aCardAlwaysEndsTheWaitAndNothingAnswersIt() {
        for running in [true, false] {
            for timeUp in [true, false] {
                #expect(AskWatch.next(cardsUp: true, running: running, timeUp: timeUp) == .needsYou)
            }
        }
        #expect(AskWatch.next(cardsUp: false, running: true, timeUp: false) == .wait)
        #expect(AskWatch.next(cardsUp: false, running: true, timeUp: true) == .tooLong)
        #expect(AskWatch.next(cardsUp: false, running: false, timeUp: false) == .finished)
        // The steps are the whole vocabulary: none of them answers anything.
        #expect(Set(AskWatch.Step.allCases) == [.wait, .needsYou, .finished, .tooLong])
    }

    @Test func aRequestCanNeverBecomeACommand() {
        #expect(AskRules.deliverable("/approve") == "approve")
        #expect(AskRules.deliverable("  //yes  please ") == "yes please")
        #expect(AskRules.deliverable("   ") == nil)
        #expect(AskRules.deliverable("/") == nil)
    }

    @Test func askingNeverOpensTheAppAndNeedsAnUnlock() {
        #expect(AskHelperIntent.openAppWhenRun == false)
        #expect(AskHelperIntent.authenticationPolicy == .requiresAuthentication)
        // The control's open-the-chat intent stays out of Shortcuts, so there is one Ask Nollie there.
        #expect(AskNollieIntent.isDiscoverable == false)
    }

    /// The real flow against the demo gateway: asking Scout to send something reaches Ask first,
    /// the ask stops there and says so, and the card is still up and unanswered afterwards.
    @Test func askFirstWaitsForThePersonAndIsNeverApproved() async throws {
        let (runtime, gateway) = try await demo()
        defer { Task { await runtime.stop(); await gateway.shutdown() } }

        let outcome = await AskHelper.ask("Please send Sam an email about Thursday", profile: "scout", name: "Scout",
                                          on: runtime, wait: .seconds(20))
        guard case .needsYou(let asked, let before) = outcome else {
            Issue.record("expected a wait for the person's yes, got \(outcome)")
            return
        }
        #expect(!before)
        #expect(asked.profile == "scout" && !asked.chatID.isEmpty)
        #expect(AskWords.spoken(outcome) == "Scout needs your yes to go on. It's waiting in Nollie.")

        let chat = try #require(runtime.chatForStored(asked.chatID))
        let card = try #require(chat.cards.first?.approval)
        #expect(card.patternKey?.hasPrefix(AskFirstAsk.rulePrefix) == true)
        // A while later nothing has answered it: the card is up and the turn is still waiting.
        try await Task.sleep(for: .seconds(2))
        #expect(chat.cards.count == 1)
        #expect(chat.isRunning)
        #expect(!chat.items.contains { item in
            if case .assistant(let text, _, _) = item.kind { return text.contains("Sent.") }
            return false
        })
    }

    /// Mason already waits on a yes when the demo opens: nothing is sent into that chat.
    @Test func aCardAlreadyUpMeansNothingIsSent() async throws {
        let (runtime, gateway) = try await demo()
        defer { Task { await runtime.stop(); await gateway.shutdown() } }

        let outcome = await AskHelper.ask("yes", profile: "mason", name: "Mason", on: runtime, wait: .seconds(5))
        guard case .needsYou(let asked, let before) = outcome else {
            Issue.record("expected the waiting card, got \(outcome)")
            return
        }
        #expect(before)
        let chat = try #require(runtime.chatForStored(asked.chatID))
        #expect(!chat.items.contains { item in
            if case .user(let text, _) = item.kind { return text == "yes" }
            return false
        })
        #expect(chat.cards.count == 1)
    }

    @Test func aPlainRequestComesBackAsTheReply() async throws {
        let (runtime, gateway) = try await demo()
        defer { Task { await runtime.stop(); await gateway.shutdown() } }

        let outcome = await AskHelper.ask("Plan my weekend", profile: "wren", name: "Wren", on: runtime, wait: .seconds(20))
        guard case .replied(let asked, let text) = outcome else {
            Issue.record("expected a reply, got \(outcome)")
            return
        }
        #expect(asked.name == "Wren")
        #expect(text.contains("Plan my weekend"))
        #expect(AskWords.spoken(outcome).contains("Plan my weekend"))
    }

    @Test func aLongTurnIsLeftRunningAndSaidSo() async throws {
        let (runtime, gateway) = try await demo()
        defer { Task { await runtime.stop(); await gateway.shutdown() } }

        let outcome = await AskHelper.ask("Plan my weekend", profile: "wren", name: "Wren", on: runtime, wait: .milliseconds(10))
        guard case .stillWorking = outcome else {
            Issue.record("expected still working, got \(outcome)")
            return
        }
        #expect(AskWords.spoken(outcome) == "Wren is still on it. The reply will be in Nollie.")
        // Asking again while that turn runs is refused rather than queued behind it.
        let again = await AskHelper.ask("And Sunday?", profile: "wren", name: "Wren", on: runtime, wait: .seconds(1))
        #expect(again == .problem(AskWords.busy("Wren")))
    }

    private func demo() async throws -> (GatewayRuntime, DemoGateway) {
        let gateway = DemoGateway()
        let connection = GatewayConnection(name: "Demo", gateway: gateway.address, authMode: .sessionToken)
        let runtime = GatewayRuntime(connection: connection, store: ConnectionStore(), backend: gateway.backend)
        await runtime.start()
        for _ in 0..<100 where !runtime.socketState.isOpen { try await Task.sleep(for: .milliseconds(50)) }
        try #require(runtime.socketState.isOpen)
        return (runtime, gateway)
    }

    // MARK: The reply

    @Test func theReplyIsTheHelpersWordsAfterTheLastMessage() {
        let items = [TestRows.user("u1", "Earlier"), TestRows.reply("a1", "Old answer"),
                     TestRows.user("u2", "What's on today?"), TestRows.tool("t1", status: .done),
                     TestRows.reply("a2", "Two meetings."), TestRows.reply("a3", "And the dentist at four.")]
        let reply = AskReply.latestTurn(in: items)
        #expect(reply.text == "Two meetings.\n\nAnd the dentist at four.")
        #expect(!reply.failed)

        let lost = AskReply.latestTurn(in: [TestRows.user("u1", "Hello"),
                                            TranscriptItem(id: "e1", kind: .error(text: "socket closed"), timestamp: TestRows.epoch)])
        #expect(lost.text.isEmpty && lost.failed)
        let quiet = AskReply.latestTurn(in: [TestRows.user("u1", "Tidy up"), TestRows.tool("t1", status: .done)])
        #expect(quiet.text.isEmpty && !quiet.failed)
    }

    // MARK: Words

    @Test func everythingSaidIsShortPlainAndHasNoDashes() {
        let asked = AskedHelper(profile: "career", name: "Scout", chatID: "c1")
        let lines = [AskWords.whatToAsk, AskWords.nothingToAsk, AskWords.notSetUp, AskWords.macAway, AskWords.macQuiet,
                     AskWords.gatewayQuiet, AskWords.thisMacQuiet, AskWords.unknownHelper, AskWords.privateHelper("Moss"),
                     AskWords.noChat("Scout"), AskWords.busy("Scout"), AskWords.notSent("Scout"),
                     AskWords.needsYou("Scout", before: true), AskWords.needsYou("Scout", before: false),
                     AskWords.stillWorking("Scout"), AskWords.doneQuietly("Scout"), AskWords.waitingLabel, AskWords.workingLabel,
                     StopControlWords.control, StopControlWords.controlDescription]
        for line in lines {
            #expect(!line.contains("\u{2014}"), "no em-dash in \(line)")
            #expect(!line.lowercased().contains("approve"), "never says approve: \(line)")
            #expect(line.count < 80, "short: \(line)")
        }
        #expect(AskWords.spoken(.replied(asked, text: "")) == "Scout has finished. The details are in Nollie.")
        #expect(AskWords.spoken(.replied(asked, text: "**Two** meetings.")) == "Two meetings.")
    }

    @Test func aLongReplyIsCutAtASentence() {
        let long = (1...40).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let spoken = AskWords.shortened(long)
        #expect(spoken.count <= AskWords.spokenLimit)
        #expect(spoken.hasSuffix("."))
        let unbroken = String(repeating: "word ", count: 200)
        #expect(AskWords.shortened(unbroken).hasSuffix("…"))
    }

    /// Settings leads with the three phrases that work with no setup.
    @Test func theSettingsPhrasesLeadWithAskStatusAndStop() {
        let shown = SiriLines.shown(approvals: false).map(\.words)
        #expect(shown.prefix(3) == ["Ask Nollie", "What is Nollie doing", "Stop Nollie"])
        #expect(!shown.contains("Answer the approval in Nollie"))
        #expect(SiriLines.shown(approvals: true).map(\.words).last == "Answer the approval in Nollie")
    }
}
