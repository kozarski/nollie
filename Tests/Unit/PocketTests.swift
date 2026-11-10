import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Everyday things from the iPhone, iPad and Watch: who is working (the chat list's bar and the
/// Watch), the Night shift note on the wrist, and moving a Board card from its sheet.
@Suite struct BoardMoveTests {
    private let task = KanbanTask(id: "t1", title: "Tidy the inbox", status: "ready")

    @Test func aCardMovesAnywhereAHandMayPutIt() {
        let targets = KanbanAsk.moveTargets(from: .ready)
        #expect(!targets.contains(.ready))
        // Only the gateway puts a card in Scheduled, Running or Review.
        #expect(targets.allSatisfy { $0.isMoveTarget })
        #expect(!targets.contains(.running) && !targets.contains(.review) && !targets.contains(.scheduled))
        #expect(targets.contains(.done) && targets.contains(.blocked) && targets.contains(.todo))
        #expect(KanbanAsk.moveTargets(from: nil).count == KanbanStatus.moveTargets.count)
    }

    @Test func doneBlockAndArchiveAskFirst() {
        #expect(KanbanAsk.gate(task, movingTo: .done)?.id == KanbanAsk.done(task).id)
        #expect(KanbanAsk.gate(task, movingTo: .blocked)?.asksForText == true)
        #expect(KanbanAsk.gate(task, movingTo: .archived)?.asksForText == false)
        for status in [KanbanStatus.todo, .triage, .ready] {
            #expect(KanbanAsk.gate(task, movingTo: status) == nil)
        }
    }
}

/// A phone linked to a Mac says what stays on the Mac before anyone taps it.
@Suite struct OnYourMacTests {
    @Test func aLinkedPhoneNeverMakesAScheduleByHand() {
        #expect(OnYourMac.makesSchedulesByHand(developerMode: true, linked: false))
        #expect(!OnYourMac.makesSchedulesByHand(developerMode: true, linked: true))
        #expect(!OnYourMac.makesSchedulesByHand(developerMode: false, linked: false))
    }

    @Test func onlyALinkedConnectionCounts() throws {
        #expect(!OnYourMac.applies(nil))
        var connection = GatewayConnection(name: "Studio", gateway: try GatewayURL.normalize("http://127.0.0.1:9119"), authMode: .sessionToken)
        #expect(!OnYourMac.applies(connection))
        connection.linkedMac = LinkedMac(macName: "Studio", pin: Data([1, 2, 3]), port: 8443, hosts: ["studio.local"], installTag: "tag", deviceID: UUID())
        #expect(OnYourMac.applies(connection))
    }

    @Test func theWordsAreShortAndPlain() {
        for words in [OnYourMac.changeThese, OnYourMac.editThis] {
            #expect(words.hasSuffix("on your Mac."))
            #expect(!words.contains("\u{2014}"))
        }
    }
}

#if os(iOS)
/// Board tasks waiting for help, made small for the wrist.
@Suite struct WatchBoardTests {
    private func blocked(_ id: String, _ title: String, by assignee: String? = nil, kind: String? = nil) -> KanbanTask {
        var task = KanbanTask(id: id, title: title, status: "blocked", assignee: assignee)
        task.blockKind = kind
        return task
    }

    private func note(_ tasks: [KanbanTask]) -> WatchWire.BoardNote? {
        let board = KanbanBoard(columns: [.init(name: "blocked", tasks: tasks),
                                          .init(name: "ready", tasks: [.init(id: "r", title: "Ready one", status: "ready")])])
        return WatchNight.board(board, name: { $0 == "career" ? "Scout" : $0.capitalized }, isPrivate: { $0 == "moss" })
    }

    @Test func onlyTasksThatNeedThePersonShow() throws {
        let note = try #require(note([blocked("a", "Renew the insurance", by: "career"),
                                      blocked("b", "Waits on another task", by: "career", kind: "dependency"),
                                      blocked("c", "Pick a date")]))
        #expect(note.tasks.map(\.title) == ["Renew the insurance", "Pick a date"])
        #expect(note.tasks.map(\.detail) == ["Scout", ""])
        #expect(note.more == 0)
    }

    @Test func aPrivateBotsTaskStaysOffTheWrist() {
        #expect(note([blocked("a", "Something private", by: "moss")]) == nil)
    }

    @Test func aLongListIsCutAndCounted() throws {
        let many = (1...5).map { blocked("t\($0)", "Task \($0)", by: "career") }
        let note = try #require(note(many))
        #expect(note.tasks.count == WatchNight.shownTasks)
        #expect(note.more == 5 - WatchNight.shownTasks)
    }

    @Test func nothingWaitingIsNoPageAndAnOlderPhoneStillReads() throws {
        #expect(note([]) == nil)
        #expect(WatchNight.board(nil, name: { $0 }, isPrivate: { _ in false }) == nil)
        var snapshot = WatchWire.Snapshot.empty(at: Date(timeIntervalSince1970: 1_800_050_000), connected: true)
        snapshot.board = WatchWire.BoardNote(tasks: [.init(title: "Pick a date", detail: "Nollie")], more: 1)
        #expect(try WatchWire.snapshot(from: WatchWire.message(snapshot)) == snapshot)
        let old = Data(#"{"version":1,"made":1800050000,"approvals":[],"helpers":[],"canStop":false,"connected":true}"#.utf8)
        #expect(try #require(WatchWire.decodeSnapshot(old)).board == nil)
    }
}
#endif

#if os(iOS)
@MainActor
@Suite struct CrewAtWorkTests {
    init() { PrivateBots.useForTesting(PrivateBots(names: ["private", "moss"], settled: true)) }

    @Test func eachWorkingBotShowsOnceWithItsStep() throws {
        let runtime = try ChatFixtures.runtime(named: "crew-\(UUID().uuidString)")
        runtime.profiles = [ProfileInfo(name: "career", displayName: "Scout"), ProfileInfo(name: "nowhere"),
                            ProfileInfo(name: "moss", displayName: "Moss")]
        let later = ChatSession(runtime: runtime, storedID: "chat-later", title: "Second", profile: "career")
        later.items = [TestRows.user("u2", "And this", at: 30)]
        later.isRunning = true
        let first = ChatSession(runtime: runtime, storedID: "chat-first", title: "First", profile: "career")
        first.items = [TestRows.user("u1", "Find roles", at: 10)]
        first.isRunning = true
        first.statusLine = "Running web_search"
        let quiet = ChatSession(runtime: runtime, storedID: "chat-quiet", title: "Done", profile: "nowhere")
        quiet.items = [TestRows.user("u3", "Hi", at: 0)]
        let secret = ChatSession(runtime: runtime, storedID: "chat-moss", title: "Diary", profile: "moss")
        secret.items = [TestRows.user("u4", "Go", at: 0)]
        secret.isRunning = true
        for chat in [later, first, quiet, secret] { runtime.registry.add(chat) }

        let members = CrewAtWork.members(in: runtime, now: TestRows.epoch.addingTimeInterval(60))
        // Moss stays off, the quiet bot isn't working, and Scout shows once for the chat that began first.
        #expect(members.map(\.helper.name) == ["Scout"])
        let scout = try #require(members.first)
        #expect(scout.helper.since == TestRows.epoch.addingTimeInterval(10))
        #expect(scout.chatID == "chat-first")
        #expect(scout.step == "Searching the web…")
        #expect(scout.helper.place == nil)
    }

    @Test func nobodyWorkingOrNoGatewayMeansNoBar() throws {
        #expect(CrewAtWork.members(in: nil).isEmpty)
        let runtime = try ChatFixtures.runtime(named: "crew-\(UUID().uuidString)")
        runtime.profiles = [ProfileInfo(name: "career", displayName: "Scout")]
        #expect(CrewAtWork.members(in: runtime).isEmpty)
    }

    @Test func aSuggestionRefusedOverTheLinkSaysWhereToAnswer() {
        let refused = HermesAPIError.http(status: 403, detail: "This can only be changed on your Mac.")
        #expect(CrewNoteCard.problem(refused, linked: true) == "Answer this on your Mac.")
        #expect(CrewNoteCard.problem(refused, linked: false) == "That didn't go through. Try again.")
        #expect(CrewNoteCard.problem(URLError(.timedOut), linked: true) == "That didn't go through. Try again.")
    }

    @Test func stopsOutcomeFitsTheBar() {
        #expect(CrewAtWorkBar.short(MacStopWords.stopped) == "Stopping on your Mac")
        for missed in [MacStopWords.unreachable, MacStopWords.notSent, MacStopWords.notLinked] {
            #expect(CrewAtWorkBar.short(missed) == HelperAtWorkWords.notReached)
        }
    }

    @Test func theBarSaysWhoInAFewWords() {
        let at = TestRows.epoch
        let scout = WatchWire.Helper(profile: "career", name: "Scout", avatar: "", place: nil, since: at)
        let mason = WatchWire.Helper(profile: "nowhere", name: "Mason", avatar: "", place: .mac, since: at)
        #expect(CrewAtWork.headline([scout]) == "Scout is working")
        #expect(CrewAtWork.headline([scout, mason]) == "2 helpers working")
        for line in [CrewAtWork.headline([scout]), CrewAtWork.headline([scout, mason])] {
            #expect(!line.contains("\u{2014}"))
        }
    }
}

@MainActor
@Suite struct WatchNightTests {
    private let now = Date(timeIntervalSince1970: 1_800_050_000)

    private func run(_ id: String, _ title: String, outcome: ConversationPost.Outcome = .done) -> ConversationPost.Run {
        ConversationPost.Run(id: id, bot: "career", botName: "Scout", title: title, outcome: outcome,
                             finishedAt: now.addingTimeInterval(-3600))
    }

    @Test func theNoteIsTheCardInAFewLines() throws {
        let card = ConversationPost.NightShift(
            from: now.addingTimeInterval(-12 * 3600), to: now, counts: .init(runs: 5, actions: 9, held: 1),
            runs: [run("r1", "Morning job alerts"), run("r2", ""), run("r3", "Tidy downloads"), run("r4", "Fourth")], moreRuns: 1)
        let note = try #require(WatchNight.note(card, now: now))
        #expect(note.counts == NightShiftWords.counts(card.counts))
        #expect(note.since == NightShiftWords.since(card.from!, now: now))
        #expect(note.runs.count == WatchNight.shownRuns)
        #expect(note.runs.map(\.title) == ["Morning job alerts", "Schedule", "Tidy downloads"])
        #expect(note.runs.first?.detail.hasPrefix("Scout · Done") == true)
        // One run left off the note, and one the add-on left off the card.
        #expect(note.more == 2)
        #expect(note.needsLook)
        #expect(note.at == now)
    }

    @Test func aQuietNightIsCalmAndNoCardIsNoNote() throws {
        #expect(WatchNight.note(nil, now: now) == nil)
        let quiet = try #require(WatchNight.note(ConversationPost.NightShift(from: now.addingTimeInterval(-3600), to: now), now: now))
        #expect(quiet.counts == "Quiet night. Nothing ran.")
        #expect(quiet.runs.isEmpty && quiet.more == 0 && !quiet.needsLook)
        let stopped = WatchNight.note(ConversationPost.NightShift(to: now, counts: .init(runs: 1, actions: 1, stopped: 1)), now: now)
        #expect(stopped?.needsLook == true)
        #expect(stopped?.since == nil)
    }

    @Test func theNoteTravelsAndAnOlderPhoneStillReads() throws {
        let note = WatchWire.NightNote(at: now, since: "Since 7:02 yesterday", counts: "1 run · 2 actions",
                                       runs: [.init(title: "Alerts", detail: "Scout · Done · 6:10")], more: 0, needsLook: false)
        var snapshot = WatchWire.Snapshot.empty(at: now, connected: true)
        snapshot.night = note
        #expect(try WatchWire.snapshot(from: WatchWire.message(snapshot)) == snapshot)
        var without = snapshot
        without.night = nil
        #expect(!snapshot.sameAs(without))
        // A phone that sends no note yet: the Watch reads its picture with none.
        let old = Data(#"{"version":1,"made":1800050000,"approvals":[],"helpers":[],"canStop":false,"connected":true}"#.utf8)
        let read = try #require(WatchWire.decodeSnapshot(old))
        #expect(read.night == nil && read.connected)
    }

    @Test func theSnapshotCarriesTheNote() throws {
        let runtime = try ChatFixtures.runtime(named: "night-\(UUID().uuidString)")
        let card = ConversationPost.NightShift(from: now.addingTimeInterval(-3600), to: now, counts: .init(runs: 1, actions: 2),
                                               runs: [run("r1", "Alerts")])
        let snapshot = WatchLink.snapshot(runtime: runtime, now: now, night: card)
        #expect(snapshot.night == WatchNight.note(card, now: now))
        #expect(WatchLink.snapshot(runtime: runtime, now: now).night == nil)
    }

    @Test func theWatchWordsFollowTheCopyRules() {
        for line in [WatchWords.nightShift, WatchWords.more(2)] {
            #expect(!line.contains("\u{2014}") && line.count < 24)
        }
    }
}
#endif
