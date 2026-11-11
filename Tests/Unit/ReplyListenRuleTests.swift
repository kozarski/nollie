import Testing
@testable import Nollie

/// Where a reply's play button goes: every finished reply can be heard, and the thread stays quiet.
struct ReplyListenRuleTests {
    @Test func theLastReplyOfARunAlwaysShowsItsButton() {
        for onMac in [false, true] {
            #expect(ReplyListenRule.placed(lastOfRun: true, onMac: onMac))
        }
        #expect(ReplyListenRule.shown(lastOfRun: true, hovering: false, speaking: false))
    }

    @Test func anOlderReplyShowsItsButtonOnTheMacOnlyWhilePointedAtOrSpeaking() {
        #expect(ReplyListenRule.placed(lastOfRun: false, onMac: true))
        #expect(!ReplyListenRule.shown(lastOfRun: false, hovering: false, speaking: false))
        #expect(ReplyListenRule.shown(lastOfRun: false, hovering: true, speaking: false))
        // While it is being read the stop button stays, wherever the pointer goes.
        #expect(ReplyListenRule.shown(lastOfRun: false, hovering: false, speaking: true))
    }

    @Test func anOlderReplyOnTheIPhoneUsesItsMenuInstead() {
        #expect(!ReplyListenRule.placed(lastOfRun: false, onMac: false))
    }

    @Test func theMenuOffersListenOrStop() {
        #expect(BubbleAction.listen.title == "Listen")
        #expect(BubbleAction.listen.symbol == "play.fill")
        #expect(BubbleAction.stopListening.title == "Stop Reading")
        #expect(BubbleAction.stopListening.symbol == "stop.fill")
    }
}
