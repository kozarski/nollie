import Foundation
import Testing
@testable import Nollie

/// A bot with no main chat yet gets one, not two: setup's Start chatting, the window opening its first
/// chat and a second click can all ask at once.
@MainActor
@Suite struct MainChatLookupsTests {
    @Test func asksThatOverlapShareOneLookup() async {
        let lookups = MainChatLookups()
        var started = 0
        let find: @MainActor () async -> MainChatAnswer = {
            started += 1
            let mine = started
            try? await Task.sleep(for: .milliseconds(80))
            return .session("chat\(mine)")
        }
        async let first = lookups.answer("mac|default", find: find)
        async let second = lookups.answer("mac|default", find: find)
        async let other = lookups.answer("mac|scout", find: find)
        let answers = await [first, second, other]
        #expect(started == 2, "One lookup for the bot asked twice, one for the other bot")
        #expect(answers[0] == answers[1], "Both asks open the same chat")
        #expect(answers[2] != answers[0])
    }

    @Test func aLaterAskLooksAgain() async {
        let lookups = MainChatLookups()
        var started = 0
        let find: @MainActor () async -> MainChatAnswer = { started += 1; return .unreachable }
        _ = await lookups.answer("mac|default", find: find)
        _ = await lookups.answer("mac|default", find: find)
        #expect(started == 2, "A lookup that finished is not remembered: the connection may be back")
    }
}
