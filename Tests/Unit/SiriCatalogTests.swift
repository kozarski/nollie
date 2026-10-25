import AppIntents
import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// What Siri can name, what it says back, and how the switches start out.
@Suite struct SiriCatalogTests {
    /// Puts a defaults key back as it was.
    private func restoring(_ keys: [String], _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        body()
    }

    @Test func theCatalogKeepsBotsAndRecentChatTitlesNothingMore() {
        restoring([SiriCatalog.botsKey, SiriCatalog.chatsKey]) {
            let named = ProfileInfo(name: "default", displayName: "Main"), plain = ProfileInfo(name: "career")
            SiriCatalog.rememberBots([named, plain])
            let remembered = SiriCatalog.bots()
            #expect(remembered.map { [$0.id, $0.label] } == [["default", "Main"], ["career", "career"]])

            let sessions = (0..<60).map { n -> StoredSession in
                StoredSession(id: "c\(n)", title: "Talk \(n)", preview: "private words \(n)", profile: n.isMultiple(of: 2) ? "career" : nil)
            }
            SiriCatalog.rememberChats(sessions)
            let chats = SiriCatalog.chats()
            let keptCount = chats.count
            #expect(keptCount == SiriCatalog.chatLimit)
            #expect(chats.prefix(2).map { "\($0.title)/\($0.bot ?? "-")" } == ["Talk 0/career", "Talk 1/-"])
            // Previews never reach the catalog.
            let stored = UserDefaults.standard.array(forKey: SiriCatalog.chatsKey) as? [[String]] ?? []
            #expect(!stored.joined().contains { $0.contains("private") })
        }
    }

    @Test func theSwitchesStartAsAgreed() {
        restoring([SiriCatalog.spotlightKey, SiriCatalog.approvalsKey]) {
            UserDefaults.standard.removeObject(forKey: SiriCatalog.spotlightKey)
            UserDefaults.standard.removeObject(forKey: SiriCatalog.approvalsKey)
            #expect(SiriCatalog.spotlightOn == !DeviceWords.isMac)
            #expect(!SiriCatalog.answersApprovals)
        }
    }

    @Test func theStatusLineSaysWhatRunsAndWhatWaits() {
        typealias Running = [(bot: String, title: String)]
        func status(_ running: Running, waiting: Int, bot: String?) -> String { SiriWords.status(running: running, waiting: waiting, bot: bot) }
        let two: Running = [(bot: "career", title: "Tax notes"), (bot: "default", title: "Ideas")]

        #expect(status([], waiting: 0, bot: nil) == "No bot is running anything.")
        let quiet = status([], waiting: 1, bot: "Main")
        #expect(quiet.hasPrefix("Main is not running anything") && quiet.contains("one approval"))
        let single: Running = [(bot: "career", title: "Tax notes")]
        #expect(status(single, waiting: 0, bot: nil) == "career is working on Tax notes.")
        #expect(status(two, waiting: 2, bot: nil) == "2 chats are running: career on Tax notes, default on Ideas. You have 2 approvals to look at.")
        // Asking about one bot counts only its chats.
        #expect(status(two, waiting: 0, bot: "Default") == "default is working on Ideas.")
    }

    @Test func theApprovalQuestionNamesTheBotAndTheCommand() {
        let request = ApprovalRequest(requestId: "a1", sessionId: "s1", command: "rm -rf dist/", description: "Remove the build")
        #expect(SiriWords.approvalQuestion(bot: "career", request: request, answer: .approve) == "career wants to run: rm -rf dist/. Approve it?")
        #expect(SiriWords.approvalQuestion(bot: "career", request: request, answer: .deny) == "career wants to run: rm -rf dist/. Deny it?")

        func ask(_ request: ApprovalRequest, _ answer: ApprovalAnswer = .approve) -> String {
            SiriWords.approvalQuestion(bot: "career", request: request, answer: answer)
        }
        #expect(ask(ApprovalRequest(requestId: "a2", sessionId: "s1", command: String(repeating: "y", count: 200))).count < 170)
        #expect(ask(ApprovalRequest(requestId: "a3", sessionId: "s1")) == "career wants to run: a command. Approve it?")
    }

    @Test func stopAndControlWordsAreShortWithNoDashes() {
        let lines = [MacStopWords.stopped, MacStopWords.notLinked, MacStopWords.unreachable, MacStopWords.notSent,
                     AskNollieWords.control, AskNollieWords.controlDescription]
        for line in lines {
            #expect(!line.contains("\u{2014}"), "no em-dash in \(line)")
            #expect(line.count < 120)
        }
        // The control sits under a small button: a short name and a one-line description.
        #expect(AskNollieWords.control == "Ask Nollie")
        #expect(AskNollieWords.controlDescription.count < 40)
    }

    #if os(iOS)
    /// The Lock Screen Stop must ask for an unlock, leave the screen alone and run in the app,
    /// which holds the link to the Mac.
    @Test func stopNeedsAnUnlockAndRunsInTheApp() {
        #expect(StopMacIntent.authenticationPolicy == .requiresAuthentication)
        #expect(StopMacIntent.openAppWhenRun == false)
        #expect((StopMacIntent() as Any) is any LiveActivityIntent)
    }

    /// Ask Nollie only opens the app at the main chat; it asks for nothing iOS would not ask
    /// for to open any app.
    @Test func askNollieOpensTheMainChat() {
        #expect((AskNollieIntent() as Any) is any OpenIntent)
        #expect(AskNollieIntent().target == .mainChat)
        #expect(AskNollieIntent.authenticationPolicy == .alwaysAllowed)
    }
    #endif
}
