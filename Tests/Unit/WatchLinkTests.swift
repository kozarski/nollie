#if os(iOS)
import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Nollie on Apple Watch: what the phone and the Watch say to each other, which approvals the
/// wrist may say yes to, and the words it shows.
@Suite struct WatchWireTests {
    private let answer = WatchWire.Answer(cardID: "card-1", requestID: "req-1", chatID: "chat-1", profile: "career",
                                          connectionID: UUID().uuidString, choice: .once)

    @Test func everyRequestSurvivesTheTrip() throws {
        let requests: [WatchWire.Request] = [.refresh, .answer(answer), .stop,
                                             .notificationDeny(["session_id": "chat-1", "request_id": "req-1"])]
        for request in requests {
            #expect(try WatchWire.request(from: WatchWire.message(request)) == request)
        }
    }

    @Test func aReplyCarriesItsPicture() throws {
        let made = Date(timeIntervalSince1970: 1_800_000_000)
        let helper = WatchWire.Helper(profile: "career", name: "Scout", avatar: "character-kick-avatar", place: .mac, since: made)
        let snapshot = WatchWire.Snapshot(made: made, approvals: [], helpers: [helper], canStop: true, connected: true)
        let reply = WatchWire.Reply(done: true, line: MacStopWords.stopped, snapshot: snapshot)
        #expect(try WatchWire.reply(from: WatchWire.message(reply)) == reply)
        #expect(try WatchWire.snapshot(from: WatchWire.message(snapshot)) == snapshot)
        #expect(WatchWire.decodeSnapshot(try #require(WatchWire.encode(snapshot))) == snapshot)
    }

    @Test func anotherVersionOrNoiseIsNotRead() throws {
        var snapshot = WatchWire.Snapshot.empty(at: Date(timeIntervalSince1970: 1_800_000_000))
        snapshot.version = WatchWire.version + 1
        #expect(throws: WatchWire.Problem.otherVersion(WatchWire.version + 1)) { try WatchWire.snapshot(from: WatchWire.message(snapshot)) }
        #expect(WatchWire.decodeSnapshot(try #require(WatchWire.encode(snapshot))) == nil)
        #expect(throws: WatchWire.Problem.missing) { try WatchWire.request(from: ["other": Data()]) }
        #expect(throws: WatchWire.Problem.unreadable) { try WatchWire.request(from: [WatchWire.key: Data("{}".utf8)]) }

        let future = Data(#"{"version":99,"body":{"stop":{}}}"#.utf8)
        #expect(throws: WatchWire.Problem.otherVersion(99)) { try WatchWire.request(from: [WatchWire.key: future]) }
    }

    @Test func onlyAChangedPictureIsNew() {
        let earlier = WatchWire.Snapshot.empty(at: Date(timeIntervalSince1970: 1), connected: true)
        var later = earlier
        later.made = Date(timeIntervalSince1970: 100)
        #expect(later.sameAs(earlier))
        later.canStop = true
        #expect(!later.sameAs(earlier))
        #expect(!later.sameAs(nil))
    }

    @Test func aNotificationGivesItsTextDetailsOnly() {
        let info: [AnyHashable: Any] = ["hermes": ["session_id": "chat-1", "request_id": "req-1", "message_row_id": 7]]
        #expect(WatchWire.notificationDetails(info) == ["session_id": "chat-1", "request_id": "req-1"])
        #expect(WatchWire.notificationDetails(["hermes": ["request_id": "req-1"]]) == nil)
        #expect(WatchWire.notificationDetails([:]) == nil)
    }

    @Test func theWatchKeepsThePhonesNotificationNames() {
        #expect(WatchNotificationNames.approvalCategory == LocalNotifier.approvalCategory)
        #expect(WatchNotificationNames.approveOnceAction == LocalNotifier.approveOnceAction)
        #expect(WatchNotificationNames.denyAction == LocalNotifier.denyAction)
        #expect(WatchNotificationNames.computerCategory == ComputerStartedWords.category)
        #expect(WatchNotificationNames.stopAction == ComputerStartedWords.stopAction)
    }

    @Test func theWordsAreShortAndPlain() {
        let words = [WatchWords.allowOnce, WatchWords.deny, WatchWords.allowAgain, WatchWords.approveOnPhone, WatchWords.stop,
                     WatchWords.working, WatchWords.allQuiet, WatchWords.nobodyWorking, WatchWords.openPhone,
                     WatchWords.phoneAway, WatchWords.allowed, WatchWords.denied, WatchWords.gone, WatchWords.flagged,
                     WatchWords.count(1), WatchWords.count(2), WatchWords.doing(.mac), WatchWords.doing(.ownComputer)]
        for line in words {
            #expect(!line.contains("\u{2014}"), "\(line)")
            #expect(line.count <= 34, "\(line)")
        }
        #expect(WatchWords.count(1) == "1 helper working")
        #expect(WatchWords.count(2) == "2 helpers working")
        #expect(WatchWords.count(0) == WatchWords.nobodyWorking)
    }
}

/// Which approvals the Watch may allow, worded as the chat's card words them.
@MainActor
@Suite struct WatchCardTests {
    private let id = "0123456789abcdef0123456789abcdef"

    private func request(_ key: String?, _ words: String?, command: String? = nil, tool: String? = nil,
                         flagged: Bool? = nil) -> ApprovalRequest {
        ApprovalRequest(requestId: "req-1", sessionId: "s", command: command, description: words,
                        choices: ["once", "session", "always", "deny"], toolName: tool, smartDenied: flagged, patternKey: key)
    }

    private func card(_ request: ApprovalRequest, privateBot: Bool = false, asksAgain: Bool = false) -> WatchWire.Approval {
        WatchCards.approval(card: PendingCard(id: "card-1", method: "approval", params: .null), request: request,
                            chatID: "chat-1", profile: "career", connectionID: UUID(), botName: "Scout",
                            avatar: "character-kick-avatar", privateBot: privateBot, asksAgain: asksAgain)
    }

    @Test func payingSendingAndPostingWaitForThePhone() {
        for kind in ["buy", "send", "post"] {
            let ask = request("plugin_rule:nollie-ask-first:\(kind):" + id, "Do it")
            #expect(WatchCards.needsPhone(ask, privateBot: false), "\(kind)")
            #expect(card(ask).answers == .denyOnly)
            // The rule's key is enough: words that can't be read change nothing.
            #expect(WatchCards.needsPhone(request("plugin_rule:nollie-ask-first:\(kind):" + id, ""), privateBot: false))
        }
    }

    @Test func signInsTheMacAndPrivateBotsWaitForThePhone() {
        #expect(WatchCards.needsPhone(request("plugin_rule:nollie-sign-in:" + id, "Sign in to example.com"), privateBot: false))
        #expect(WatchCards.needsPhone(request("cua:click:background", nil), privateBot: false))
        #expect(WatchCards.needsPhone(request(nil, "List the files", command: "ls"), privateBot: true))
    }

    @Test func otherApprovalsCanBeAllowedFromTheWrist() {
        for key in ["plugin_rule:nollie-ask-first:delete:" + id, "plugin_rule:nollie-ask-first:calendar:" + id] {
            let ask = request(key, "Move 3 files to the Trash")
            #expect(!WatchCards.needsPhone(ask, privateBot: false), "\(key)")
            #expect(card(ask).answers == .allowOrDeny)
        }
        #expect(card(request(nil, "List the files", command: "ls")).answers == .allowOrDeny)
    }

    @Test func thePhoneChecksTheAnswerAgain() {
        let payment = request("plugin_rule:nollie-ask-first:buy:" + id, "Order coffee")
        #expect(WatchCards.verdict(.once, request: payment, privateBot: false) == .refuse(WatchWords.approveOnPhone))
        #expect(WatchCards.verdict(.deny, request: payment, privateBot: false) == .answer("deny"))
        let listing = request(nil, "List the files", command: "ls")
        #expect(WatchCards.verdict(.once, request: listing, privateBot: false) == .answer("once"))
        #expect(WatchCards.verdict(.once, request: listing, privateBot: true) == .refuse(WatchWords.approveOnPhone))
        #expect(WatchCards.verdict(.deny, request: listing, privateBot: true) == .answer("deny"))
    }

    @Test func askFirstReadsAsItsCard() throws {
        let words = "Press “Send” on its computer.\nYou're about to press “Send”."
        let raw = request("plugin_rule:nollie-ask-first:send:" + id, words)
        let ask = try #require(AskFirstAsk(raw))
        let shown = card(raw)
        #expect(shown.title == AskFirstCardBody(ask: ask, botName: "Scout", onChoice: { _ in }).title)
        #expect(shown.title == "Scout wants to send something")
        #expect(shown.body == "Press “Send” on its computer.")
        #expect(shown.check == "You're about to press “Send”.")
        #expect(shown.symbol == "paperplane.fill")
    }

    @Test func anOrdinaryApprovalReadsAsItsCard() {
        let shown = card(request(nil, "Clear the build folder", command: "rm -rf build", flagged: true), asksAgain: true)
        #expect(shown.title == "Scout needs your OK")
        #expect(shown.body == "Clear the build folder")
        #expect(shown.command == "rm -rf build")
        #expect(shown.flagged)
        #expect(shown.asksAgain)
        #expect(shown.id == "card-1" && shown.requestID == "req-1" && shown.chatID == "chat-1")
        #expect(card(request(nil, nil, tool: "write_file")).body == "Use write file.")
        #expect(card(request(nil, nil, command: "ls")).body == "Run a command.")
    }

    @Test func aSignInAndAScreenActionReadAsTheirCards() {
        #expect(card(request("plugin_rule:nollie-sign-in:" + id, "Sign in to example.com")).title == "Scout wants to sign in to example.com")
        let screen = card(request("cua:click:background", nil))
        #expect(screen.title == "Scout wants to use your Mac")
        #expect(screen.body == ApprovalCardView.screenLine("cua:click:background"))
    }

    @Test func aPrivateBotsWordsStayOnThePhone() {
        let shown = card(request(nil, "Read my diary", command: "cat diary.txt", flagged: true), privateBot: true)
        #expect(shown.title == "A helper needs your OK")
        #expect(shown.body.isEmpty && shown.command == nil && shown.check == nil)
        #expect(shown.botName.isEmpty && shown.avatar.isEmpty && !shown.flagged)
        #expect(shown.answers == .denyOnly)
    }
}

/// The picture the phone sends: approvals in the open chats and who is working.
@MainActor
@Suite struct WatchSnapshotTests {
    init() { PrivateBots.useForTesting(PrivateBots(names: ["private", "moss"], settled: true)) }

    @Test func approvalsAndWorkingHelpersAreGathered() throws {
        let runtime = try ChatFixtures.runtime(named: "watch-\(UUID().uuidString)")
        runtime.profiles = [ProfileInfo(name: "career", displayName: "Scout"), ProfileInfo(name: "nowhere")]
        let asking = ChatSession(runtime: runtime, storedID: "chat-ask", title: "Inbox", profile: "career")
        let request = ApprovalRequest(requestId: "req-1", sessionId: "s", command: "ls", description: "List the files")
        asking.cards = [PendingCard(id: "card-1", method: "approval", params: try JSONValue.encode(request))]
        let working = ChatSession(runtime: runtime, storedID: "chat-work", title: "Build", profile: "nowhere")
        working.items = [TestRows.user("u1", "Build it", at: 0)]
        working.isRunning = true
        let quiet = ChatSession(runtime: runtime, storedID: "chat-quiet", title: "Done", profile: "career")
        for chat in [asking, working, quiet] { runtime.registry.add(chat) }

        let now = TestRows.epoch.addingTimeInterval(60)
        let snapshot = WatchLink.snapshot(runtime: runtime, now: now)
        #expect(snapshot.made == now)
        #expect(snapshot.approvals.map(\.id) == ["card-1"])
        #expect(snapshot.approvals.first?.title == "Scout needs your OK")
        #expect(snapshot.approvals.first?.chatID == "chat-ask")
        #expect(snapshot.helpers.map(\.name) == ["Nowhere"])
        #expect(snapshot.helpers.first?.place == nil)
        #expect(snapshot.helpers.first?.since == TestRows.epoch)
        // Not linked to a Mac: no Stop to offer.
        #expect(!snapshot.canStop)
    }

    @Test func aPrivateBotIsKeptOffTheWrist() throws {
        let runtime = try ChatFixtures.runtime(named: "watch-\(UUID().uuidString)")
        runtime.profiles = [ProfileInfo(name: "moss", displayName: "Moss")]
        let chat = ChatSession(runtime: runtime, storedID: "chat-moss", title: "Diary", profile: "moss")
        let request = ApprovalRequest(requestId: "req-9", sessionId: "s", command: "cat diary.txt", description: "Read the diary")
        chat.cards = [PendingCard(id: "card-9", method: "approval", params: try JSONValue.encode(request))]
        chat.items = [TestRows.user("u1", "Go", at: 0)]
        chat.isRunning = true
        runtime.registry.add(chat)

        let snapshot = WatchLink.snapshot(runtime: runtime, now: TestRows.epoch)
        #expect(snapshot.helpers.isEmpty)
        let shown = try #require(snapshot.approvals.first)
        #expect(shown.title == "A helper needs your OK")
        #expect(shown.body.isEmpty && shown.command == nil && shown.botName.isEmpty)
        #expect(shown.answers == .denyOnly)
    }

    @Test func noGatewayMeansAnEmptyPicture() {
        let snapshot = WatchLink.snapshot(runtime: nil, now: Date(timeIntervalSince1970: 5))
        #expect(snapshot.approvals.isEmpty && snapshot.helpers.isEmpty && !snapshot.canStop && !snapshot.connected)
    }
}
#endif
