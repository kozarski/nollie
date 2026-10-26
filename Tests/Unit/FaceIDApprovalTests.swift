import Foundation
import LocalAuthentication
import Testing
import UserNotifications
@testable import Nollie
@testable import NollieCore

/// Face ID for buying and sending: which approvals check it's the owner, that a failed or cancelled
/// check sends nothing and leaves the card, that Deny never asks, and the switch in Privacy.
@MainActor @Suite struct FaceIDApprovalTests {
    private static let ruleID = "0123456789abcdef0123456789abcdef"

    private func approval(_ kind: String?, id: String = ruleID, request: String = "ap-1") -> ApprovalRequest {
        let key = kind.map { "plugin_rule:nollie-ask-first:\($0):\(id)" }
        return ApprovalRequest(requestId: request, sessionId: "s", description: "Pay £12 at the bakery",
                               choices: ["once", "deny"], patternKey: key)
    }

    /// Answers every check one way and counts how often it was asked.
    @MainActor final class FakeOwner: DeviceOwnerAuthenticating {
        let methodName = "Face ID"
        var canAuthenticate: Bool
        var passes: Bool
        var reasons: [String] = []

        init(passes: Bool, canAuthenticate: Bool = true) {
            self.passes = passes
            self.canAuthenticate = canAuthenticate
        }

        func authenticate(reason: String) async -> LAContext? {
            reasons.append(reason)
            return passes ? LAContext() : nil
        }
    }

    // MARK: Which approvals ask

    @Test func buyingSendingAndPostingAsk() {
        #expect(AskFirstAsk.needsOwner(approval("buy")))
        #expect(AskFirstAsk.needsOwner(approval("send")))
        #expect(AskFirstAsk.needsOwner(approval("post")))
    }

    @Test func deletingUnsureAndOrdinaryApprovalsDoNotAsk() {
        #expect(!AskFirstAsk.needsOwner(approval("delete")))
        #expect(!AskFirstAsk.needsOwner(approval("unsure")))
        #expect(!AskFirstAsk.needsOwner(approval(nil)))
        #expect(!AskFirstAsk.needsOwner(nil))
        let screen = ApprovalRequest(requestId: "r", sessionId: "s", patternKey: "cua:click:background")
        #expect(!AskFirstAsk.needsOwner(screen))
        let lookalike = ApprovalRequest(requestId: "r", sessionId: "s", patternKey: "buy:plugin_rule:nollie-ask-first:")
        #expect(!AskFirstAsk.needsOwner(lookalike))
    }

    @Test func aRuleWhoseWordsCannotBeReadStillAsks() {
        // A card that can't be read as Ask first falls back to the plain card, which must be covered too.
        #expect(AskFirstAsk(approval("buy", id: "not-a-real-id")) == nil)
        #expect(AskFirstAsk.needsOwner(approval("buy", id: "not-a-real-id")))
    }

    // MARK: The check

    @Test func aFailedOrCancelledCheckSendsNothing() async {
        let owner = FakeOwner(passes: false)
        #expect(await ApprovalOwnerCheck.check(approval("buy"), bot: "Scout", on: true, authenticator: owner) == false)
        #expect(owner.reasons == ["Let Scout pay for something"])
    }

    @Test func aPassedCheckLetsTheYesGo() async {
        let owner = FakeOwner(passes: true)
        #expect(await ApprovalOwnerCheck.check(approval("send"), bot: "Scout", on: true, authenticator: owner))
        #expect(owner.reasons == ["Let Scout send something"])
    }

    @Test func otherApprovalsAndTheSwitchOffNeverAsk() async {
        let owner = FakeOwner(passes: false)
        #expect(await ApprovalOwnerCheck.check(approval("delete"), bot: "Scout", on: true, authenticator: owner))
        #expect(await ApprovalOwnerCheck.check(approval(nil), bot: "Scout", on: true, authenticator: owner))
        #expect(await ApprovalOwnerCheck.check(approval("buy"), bot: "Scout", on: false, authenticator: owner))
        #expect(owner.reasons.isEmpty)
    }

    @Test func aDeviceWithNoPasscodeAnswersAsBefore() async {
        let owner = FakeOwner(passes: false, canAuthenticate: false)
        #expect(await ApprovalOwnerCheck.check(approval("post"), bot: "Scout", on: true, authenticator: owner))
        #expect(owner.reasons.isEmpty)
        #expect(!ApprovalOwnerCheck.willAsk(approval("post"), on: true, authenticator: owner))
    }

    @Test func theCardShowsTheLockOnlyWhenItWillAsk() {
        let owner = FakeOwner(passes: true)
        #expect(ApprovalOwnerCheck.willAsk(approval("buy"), on: true, authenticator: owner))
        #expect(!ApprovalOwnerCheck.willAsk(approval("buy"), on: false, authenticator: owner))
        #expect(!ApprovalOwnerCheck.willAsk(approval("delete"), on: true, authenticator: owner))
        #expect(!ApprovalOwnerCheck.willAsk(nil, on: true, authenticator: owner))
    }

    @Test func theReasonNamesTheBotAndWhat() {
        #expect(ApprovalOwnerCheck.reason(approval("post"), bot: "Nollie") == "Let Nollie post something")
        #expect(ApprovalOwnerCheck.reason(approval("buy", id: "unreadable"), bot: "Nollie") == "Let Nollie pay for something")
    }

    // MARK: Answering a card

    private func waitingCard(_ kind: String?, chatName: String) async throws -> (ChatSession, Task<JSONValue?, Never>) {
        let runtime = try ChatFixtures.runtime(named: chatName)
        runtime.socketEnabled = false
        let chat = ChatSession(runtime: runtime, storedID: "stored-\(chatName)", title: nil)
        chat.runtimeID = "live-\(chatName)"
        runtime.registry.add(chat)
        var params: [String: JSONValue] = ["session_id": .string(chat.runtimeID), "request_id": .string("ap-\(chatName)"),
                                           "description": "Pay £12 at the bakery"]
        if let kind { params["pattern_key"] = .string("plugin_rule:nollie-ask-first:\(kind):\(Self.ruleID)") }
        let request = ServerRequest(id: "rq-\(chatName)", method: "approval", params: .object(params))
        let waiter = Task { await chat.answer(serverRequest: request) }
        var turns = 0
        while chat.cards.isEmpty && turns < 1000 { await Task.yield(); turns += 1 }
        try #require(chat.cards.count == 1)
        return (chat, waiter)
    }

    @Test func aRefusedCheckLeavesTheCardWaiting() async throws {
        let (chat, waiter) = try await waitingCard("buy", chatName: "refused")
        let owner = FakeOwner(passes: false)
        chat.runtime.approvalOwnerCheck = { approval, bot in
            await ApprovalOwnerCheck.check(approval, bot: bot, on: true, authenticator: owner)
        }
        let card = try #require(chat.cards.first)

        let sent = await chat.respond(card: card, result: ["choice": "once"])
        #expect(!sent)
        #expect(owner.reasons.count == 1)
        #expect(chat.cards.map(\.id) == [card.id], "the card stays for another try")

        // Deny still goes, without asking.
        #expect(await chat.respond(card: card, result: ["choice": "deny"]))
        #expect(owner.reasons.count == 1, "Deny never asks")
        #expect(await waiter.value?.text("choice") == "deny")
        #expect(chat.cards.isEmpty)
    }

    @Test func aPassedCheckAnswersTheCard() async throws {
        let (chat, waiter) = try await waitingCard("send", chatName: "passed")
        chat.runtime.approvalOwnerCheck = { approval, _ in AskFirstAsk.needsOwner(approval) }
        let card = try #require(chat.cards.first)
        #expect(await chat.respond(card: card, result: ["choice": "once"]))
        #expect(await waiter.value?.text("choice") == "once")
        #expect(chat.cards.isEmpty)
    }

    @Test func aCardAnsweredElsewhereDuringTheCheckIsLeftAlone() async throws {
        let (chat, waiter) = try await waitingCard("buy", chatName: "elsewhere")
        let card = try #require(chat.cards.first)
        chat.runtime.approvalOwnerCheck = { _, _ in
            chat.settleElsewhere(card)
            return true
        }
        #expect(await chat.respond(card: card, result: ["choice": "once"]) == false)
        waiter.cancel()
    }

    // MARK: The switch

    @Test func theSwitchIsOnUntilTurnedOff() throws {
        let defaults = try #require(UserDefaults(suiteName: "faceid-switch-\(UUID().uuidString)"))
        #expect(ApprovalOwnerCheck.isOn(defaults), "new installs and upgrades start on")
        defaults.set(false, forKey: ApprovalOwnerCheck.key)
        #expect(!ApprovalOwnerCheck.isOn(defaults))
        defaults.set(true, forKey: ApprovalOwnerCheck.key)
        #expect(ApprovalOwnerCheck.isOn(defaults))
    }

    @Test func approveFromANotificationOpensNollieWhileTheSwitchIsOn() {
        let on = LocalNotifier.approveOptions(confirm: false, ownerCheck: true)
        #expect(on.contains(.foreground) && on.contains(.authenticationRequired))
        let off = LocalNotifier.approveOptions(confirm: false, ownerCheck: false)
        #expect(!off.contains(.foreground) && off.contains(.authenticationRequired))
        #expect(LocalNotifier.approveOptions(confirm: true, ownerCheck: false).contains(.foreground))
    }

    @Test func siriNeverApprovesBuyingOrSending() {
        for kind in ["buy", "send", "post"] {
            #expect(SiriWords.approveRefusal(approval(kind)) != nil)
        }
    }
}
