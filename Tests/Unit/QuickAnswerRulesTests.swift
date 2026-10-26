import Foundation
import Testing
@testable import NollieCore

/// Quick answers on this device: which requests the small model may answer, which go to the
/// helper on the Mac, when the iPhone offers it, and what a reply may never claim.
@Suite struct QuickAnswerRulesTests {
    private typealias Rules = QuickAnswerRules

    @Test func everydayQuestionsAndDraftingStayOnThisDevice() {
        let here = [
            "What's the capital of Peru?",
            "Explain compound interest simply",
            "Ideas for a rainy Sunday with kids",
            "Reword this so it sounds warmer: I can't come to the party, sorry",
            "Write a text to Mum saying I'll be late",
            "Draft an email to my landlord about the broken boiler",
            "Help me reply to this: thanks for the invite, are you free Friday?",
            "How do I say no to extra work politely?",
            "Can you proofread this paragraph for me",
            "Translate 'where is the station' into Spanish",
            "Nollie, what should I cook tonight with eggs and spinach?",
            "",
        ]
        for text in here {
            #expect(Rules.route(text) == .answerHere, "\(text)")
        }
    }

    @Test func actionsGoToTheHelper() {
        let acts = [
            "Send Sam a message saying I'm on my way",
            "Text Mum that I'm late",
            "Can you email my boss the report",
            "Please book a table for two at eight",
            "Buy more coffee pods",
            "Order a taxi",
            "Remind me to call the dentist tomorrow",
            "Set an alarm for 7",
            "Add the school play to my calendar",
            "Delete the old photos",
            "Hey Nollie, call Dad",
            "Write a reply to Sam and send it",
            "Draft a post and then post it",
        ]
        for text in acts {
            #expect(Rules.route(text) == .helper(.action), "\(text)")
        }
    }

    @Test func yourOwnThingsAndFreshFactsGoToTheHelper() {
        #expect(Rules.route("What's on my calendar tomorrow?") == .helper(.yourStuff))
        #expect(Rules.route("Check my email") == .helper(.yourStuff))
        #expect(Rules.route("Do I have any meetings today") == .helper(.yourStuff))
        #expect(Rules.route("Summarise my inbox") == .helper(.yourStuff))
        #expect(Rules.route("Find the PDF on my Mac") == .helper(.yourStuff))
        #expect(Rules.route("What's the weather like tomorrow?") == .helper(.lookUp))
        #expect(Rules.route("Latest news about the election") == .helper(.lookUp))
        #expect(Rules.route("Look up train times to Leeds") == .helper(.lookUp))
        #expect(Rules.route("Is the chemist open now") == .helper(.lookUp))
    }

    @Test func aReplyThatClaimsToHaveActedIsCaught() {
        let claims = [
            "Done! I've sent the message to Sam.",
            "I have booked a table for two at 8pm.",
            "I'll add that to your calendar now.",
            "Your reminder has been scheduled.",
            "I’ve checked your inbox and there are three new emails.",
            "I emailed your boss.",
        ]
        for reply in claims {
            #expect(Rules.claimsAction(reply), "\(reply)")
        }
        let honest = [
            "Here's a warmer version: \"I'm so sorry I can't make it, I hope it's a lovely evening.\"",
            "Lima is the capital of Peru.",
            "You could send something like this: \"Running ten minutes late, see you soon.\"",
            "I can't send messages from here, but here's a draft you can copy.",
        ]
        for reply in honest {
            #expect(!Rules.claimsAction(reply), "\(reply)")
        }
    }

    @Test func theIPhoneOffersQuickAnswersOnlyOnceTheMacHasStayedOutOfReach() {
        #expect(!Rules.offersWhileAway(nil, outOfReachFor: 60))
        #expect(!Rules.offersWhileAway(.open, outOfReachFor: 60))
        #expect(!Rules.offersWhileAway(.authRejected("expired"), outOfReachFor: 60))
        #expect(Rules.offersWhileAway(.failed("no route"), outOfReachFor: 0))
        #expect(!Rules.offersWhileAway(.connecting, outOfReachFor: 2))
        #expect(Rules.offersWhileAway(.connecting, outOfReachFor: Rules.awayGrace))
        #expect(!Rules.offersWhileAway(.reconnecting(attempt: 1, delay: 1), outOfReachFor: 1))
        #expect(Rules.offersWhileAway(.reconnecting(attempt: 4, delay: 8), outOfReachFor: 30))
        #expect(Rules.offersWhileAway(.idle, outOfReachFor: 10))
    }

    @Test func memoryKeepsTheLatestExchangesThatFit() {
        let all = (1...10).map { Rules.Exchange(question: "question \($0)", answer: String(repeating: "a", count: 100)) }
        let kept = Rules.window(all, budget: 400)
        #expect(kept.map(\.question) == ["question 8", "question 9", "question 10"])
        #expect(Rules.window(all, budget: 0).isEmpty)
        let long = Rules.window([Rules.Exchange(question: String(repeating: "q", count: 2_000), answer: String(repeating: "a", count: 5_000))], budget: 9_000)
        #expect(long.first?.question.count == 600)
        #expect(long.first?.answer.count == 900)
    }

    @Test func memoryBudgetLeavesRoomForTheAnswer() {
        #expect(Rules.memoryBudget(contextTokens: 4_096) == 7_488)
        #expect(Rules.memoryBudget(contextTokens: 8_192) == 9_000)
        #expect(Rules.memoryBudget(contextTokens: 1_000) == 0)
    }

    @Test func helperLinesNameTheRightPlaceAndNeverPromiseTooMuch() {
        for reason in [Rules.Reason.action, .yourStuff, .lookUp] {
            #expect(Rules.helperLine(reason, place: .macAway).contains("Nollie on your Mac"))
            #expect(Rules.helperLine(reason, place: .macSetup).contains("Once setup is done"))
            #expect(Rules.helperLine(reason, place: .phoneSetup).contains("set up on your Mac"))
            for place in Rules.Place.allCases {
                let line = Rules.helperLine(reason, place: place)
                #expect(!line.contains("—"))
                #expect(!line.lowercased().contains(" only "))
            }
        }
        #expect(Rules.Place.macAway.handsOff)
        #expect(!Rules.Place.macSetup.handsOff)
        #expect(!Rules.Place.phoneSetup.handsOff)
    }
}
