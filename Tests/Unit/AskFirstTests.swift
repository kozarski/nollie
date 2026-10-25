import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Ask first: the card is recognised only from the add-on's rule, and the "you're about to…" line
/// is taken out of the body only when it is exactly what the add-on writes.
@Suite struct AskFirstTests {
    private let id = "0123456789abcdef0123456789abcdef"

    private func approval(_ key: String?, _ words: String?) -> ApprovalRequest {
        ApprovalRequest(requestId: "r", sessionId: "s", command: "<mcp__gmail__send_email> (plugin approval rule)",
                        description: words, choices: ["once", "session", "always", "deny"], patternKey: key)
    }

    @Test func aSendIsReadWithItsDetails() throws {
        let words = "Send with gmail: send email\nto: sam@example.com\nsubject: Lunch on Friday\nbody: Are you free at noon?"
        let ask = try #require(AskFirstAsk(approval("plugin_rule:nollie-ask-first:send:" + id, words)))
        #expect(ask.kind == .send)
        #expect(ask.id == id)
        #expect(ask.summary == words)
        #expect(ask.check == nil)
        #expect(ask.buttonLabel == nil)
    }

    @Test func everyKindIsKnown() {
        for kind in ["send", "buy", "post", "delete", "unsure"] {
            #expect(AskFirstAsk(approval("plugin_rule:nollie-ask-first:\(kind):" + id, "Do it"))?.kind.rawValue == kind)
        }
    }

    @Test func theCheckLineComesOutOfTheBody() throws {
        let words = "Press “Send” on its computer.\nYou're about to press “Send”."
        let ask = try #require(AskFirstAsk(approval("plugin_rule:nollie-ask-first:send:" + id, words)))
        #expect(ask.summary == "Press “Send” on its computer.")
        #expect(ask.check == "You're about to press “Send”.")
        #expect(ask.buttonLabel == "Send")
    }

    @Test func olderComputerActionsReadInPlainWords() throws {
        for (words, expected) in [
            ("Press “Send” on its computer (local:nollie-career).\nClick at (640, 410).", "Press “Send” on its computer."),
            ("Press “Send” on this Mac.\nClick at (640, 410).", "Press “Send” on this Mac."),
            ("Press “Send on its computer (draft)” on its computer (work-computer).\nClick at (640, 410).",
             "Press “Send on its computer (draft)” on its computer."),
            ("Click at (640, 410) on its computer (local:nollie-career).\nNollie couldn't read a label there, so it asks first.",
             "Click on its computer.\nNollie couldn't read a label there, so it asks first."),
            ("Click at (640, 410) on the browser.", "Click on the browser."),
            ("Press cmd+Return on its computer (work-computer).\nIn most apps this sends.",
             "Press cmd+Return on its computer.\nIn most apps this sends."),
            ("Press cmd+Delete on its computer (work-computer).\nIn most apps this deletes.",
             "Press cmd+Delete on its computer.\nIn most apps this deletes.")
        ] {
            let ask = try #require(AskFirstAsk(approval("plugin_rule:nollie-ask-first:send:" + id, words)))
            #expect(ask.summary == expected)
        }
    }

    @Test func typingKeepsAllOfItsText() throws {
        let text = "Click at (640, 410).\nPress “Send” on its computer (local:nollie-career)."
        let words = "Type “\(text)” and press Return on its computer (work-computer).\nReturn can press a Send, Pay, Post or Delete button showing there."
        let ask = try #require(AskFirstAsk(approval("plugin_rule:nollie-ask-first:send:" + id, words)))
        #expect(ask.summary == "Type “\(text)” and press Return on its computer.\nReturn can press a Send, Pay, Post or Delete button showing there.")
    }

    @Test func computerCleanupLeavesCommandsAndOtherDetailsWhole() throws {
        let text = "Press “Send” on its computer (local:nollie-career).\nClick at (640, 410)."
        let command = "cat <<'END'\n" + String(repeating: text + "\n", count: 100) + "END"
        for words in ["Run this command:\n\(command)",
                      "Run this command on its computer (work-computer):\n\(command)",
                      "Send with gmail: send email\nbody: \(text)"] {
            var request = approval("plugin_rule:nollie-ask-first:send:" + id, words)
            request.command = command
            let ask = try #require(AskFirstAsk(request))
            #expect(ask.summary == words)
            #expect(request.command == command)
            #expect(request.description == words)
        }
    }

    @Test func aCheckLineWithStraightQuotesStaysInTheBody() throws {
        let words = "Run this command:\necho hi\nYou're about to press \"Send\"."
        let ask = try #require(AskFirstAsk(approval("plugin_rule:nollie-ask-first:unsure:" + id, words)))
        #expect(ask.check == nil)
        #expect(ask.summary == words)
    }

    @Test func aLabelOverSixtyCharactersStaysInTheBody() throws {
        let sixty = String(repeating: "a", count: 60)
        let long = "Press it\nYou're about to press “\(sixty)b”."
        let tooLong = try #require(AskFirstAsk(approval("plugin_rule:nollie-ask-first:post:" + id, long)))
        #expect(tooLong.check == nil)
        #expect(tooLong.summary == long)
        let fits = try #require(AskFirstAsk(approval("plugin_rule:nollie-ask-first:post:" + id, "Press it\nYou're about to press “\(sixty)”.")))
        #expect(fits.buttonLabel == sixty)
        #expect(fits.summary == "Press it")
    }

    @Test func aCheckLineNotLastStaysInTheBody() throws {
        let words = "You're about to press “Send”.\nThen more"
        let ask = try #require(AskFirstAsk(approval("plugin_rule:nollie-ask-first:send:" + id, words)))
        #expect(ask.check == nil)
        #expect(ask.summary == words)
    }

    @Test func anythingElseIsNotAnAskFirstCard() {
        let good = "Send with gmail: send email"
        for (key, words) in [("plugin_rule:nollie-sign-in:" + id, good),
                             ("plugin_rule:other:send:" + id, good),
                             ("nollie-ask-first:send:" + id, good),
                             ("plugin_rule:nollie-ask-first:send:" + id.uppercased(), good),
                             ("plugin_rule:nollie-ask-first:Send:" + id, good),
                             ("plugin_rule:nollie-ask-first:spend:" + id, good),
                             ("plugin_rule:nollie-ask-first:send:" + id.dropLast(), good),
                             ("plugin_rule:nollie-ask-first:send:" + id + "0", good),
                             ("plugin_rule:nollie-ask-first:send:" + id + ":x", good),
                             ("plugin_rule:nollie-ask-first:send:../" + id.dropFirst(3), good),
                             ("plugin_rule:nollie-ask-first:" + id, good),
                             ("plugin_rule:nollie-ask-first:send:" + id, ""),
                             ("plugin_rule:nollie-ask-first:send:" + id, " \n "),
                             ("plugin_rule:nollie-ask-first:send:" + id, "You're about to press “Send”."),
                             ("plugin_rule:nollie-ask-first:send:" + id, nil),
                             (nil, good)] as [(String?, String?)] {
            #expect(AskFirstAsk(approval(key, words)) == nil, "\(String(describing: key)) \(String(describing: words))")
        }
        #expect(AskFirstAsk(nil) == nil)
    }

    @Test func anAskFirstCardIsAlwaysRisky() {
        let plain = ApprovalRequest(requestId: "r", sessionId: "s", description: "Look", toolName: "browser_click",
                                    patternKey: "plugin_rule:nollie-ask-first:unsure:" + id)
        #expect(ApprovalRisk.isRisky(plain))
    }

    @Test func theCardTitleFollowsTheKindAndUnsureStaysNeutral() throws {
        func title(_ kind: String, bot: String = "Scout") throws -> String {
            let ask = try #require(AskFirstAsk(approval("plugin_rule:nollie-ask-first:\(kind):" + id, "Run this command:\nmake deploy")))
            return AskFirstCardBody(ask: ask, botName: bot, onChoice: { _ in }).title
        }
        #expect(try title("send") == "Scout wants to send something")
        #expect(try title("buy") == "Scout wants to pay for something")
        #expect(try title("post") == "Scout wants to post something")
        #expect(try title("delete") == "Scout wants to delete something")
        // Also used for commands and scripts Nollie can't read, so it never says "press".
        #expect(try title("unsure") == "Scout wants to do something")
        #expect(try title("unsure", bot: "") == "Your bot wants to do something")
    }

    /// Siri may deny an Ask first hold but never allow it, and never reads the gateway's rule words.
    @Test func siriDeniesButNeverApprovesAnAskFirstHold() throws {
        let held = approval("plugin_rule:nollie-ask-first:send:" + id,
                            "Send with gmail: send email\nto: sam@example.com\nYou're about to press “Send”.")
        #expect(SiriWords.approveRefusal(held) == "This one needs a look first. Open Nollie to answer it.")
        // A hold the card can't read is still never approved by voice.
        #expect(SiriWords.approveRefusal(approval("plugin_rule:nollie-ask-first:send:" + id, "")) != nil)
        let signIn = approval("plugin_rule:nollie-sign-in:" + id, "Sign in to example.com")
        #expect(SiriWords.approveRefusal(signIn) == "Sign-ins need Face ID or Touch ID. Open Nollie to allow it.")
        #expect(SiriWords.approveRefusal(ApprovalRequest(requestId: "r", sessionId: "s", command: "rm -rf build/")) == nil)

        let question = SiriWords.approvalQuestion(bot: "Scout", request: held, answer: .deny)
        #expect(question == "Scout asks: Send with gmail: send email. Deny it?")
        let other = ApprovalRequest(requestId: "r", sessionId: "s", command: "<some_tool> (plugin approval rule)",
                                    description: "Run this command:\nmake deploy", patternKey: "plugin_rule:other:" + id)
        #expect(SiriWords.approvalQuestion(bot: "Scout", request: other, answer: .deny) == "Scout asks: Run this command. Deny it?")
        let bare = ApprovalRequest(requestId: "r", sessionId: "s", command: "<some_tool> (plugin approval rule)", patternKey: "plugin_rule:x")
        #expect(SiriWords.approvalQuestion(bot: "Scout", request: bare, answer: .deny) == "Scout asks: something. Deny it?")
        for request in [held, other, bare, signIn] {
            #expect(!SiriWords.approvalQuestion(bot: "Scout", request: request, answer: .approve).contains("plugin approval rule"))
        }
    }

    /// After a notification's Approve once, the alert reads the action and the check, never the command.
    @Test func theConfirmationReadsTheActionNotTheCommand() throws {
        let held = approval("plugin_rule:nollie-ask-first:send:" + id,
                            "Press “Send” on its computer (local:nollie-career).\nClick at (640, 410).\nYou're about to press “Send”.")
        #expect(ConversationView.confirmWords(held)
                == "Press “Send” on its computer.\n\nYou're about to press “Send”.")
        let noCheck = approval("plugin_rule:nollie-ask-first:delete:" + id, "Run this command:\nrm -rf build")
        #expect(ConversationView.confirmWords(noCheck) == "Run this command:\nrm -rf build")
        let signIn = approval("plugin_rule:nollie-sign-in:" + id, "Sign in to example.com")
        #expect(ConversationView.confirmWords(signIn) == "Sign in to example.com")
        let plain = ApprovalRequest(requestId: "r", sessionId: "s", command: "rm -rf build/", description: "Clean the build folder")
        #expect(ConversationView.confirmWords(plain) == "Clean the build folder\n\nrm -rf build/")
    }

    #if os(macOS)
    /// The menu bar offers Deny and Answer in Nollie for these, never a one-click Approve once.
    @MainActor @Test func theMenuBarSendsAskFirstAndSignInsToTheApp() {
        #expect(TurnBoard.answersInApp(approval("plugin_rule:nollie-ask-first:send:" + id, "Send with gmail: send email")))
        #expect(TurnBoard.answersInApp(approval("plugin_rule:nollie-ask-first:send:" + id, "")))
        #expect(TurnBoard.answersInApp(approval("plugin_rule:nollie-sign-in:" + id, "Sign in to example.com")))
        #expect(!TurnBoard.answersInApp(ApprovalRequest(requestId: "r", sessionId: "s", command: "rm -rf build/")))
        #expect(!TurnBoard.answersInApp(approval("dangerous:rm", "Clean up")))
    }
    #endif

    /// System control answers screen actions by itself; never an Ask first hold, even with the switch on.
    @MainActor @Test func systemControlNeverAnswersAnAskFirstCard() {
        let held = approval("plugin_rule:nollie-ask-first:send:" + id, "Press “Send”\nYou're about to press “Send”.")
        #expect(!SystemControl.isScreen(held))
        #expect(SystemControl.autoAnswer(held, controlOn: true) == nil)
        #expect(SystemControl.shared.autoAnswer(held, profile: "career") == nil)
    }
}
