import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Nollie Summaries makes a chat's title once and keeps it; a name the person typed always
/// wins; the preview keeps being refreshed.
@MainActor @Suite struct SummaryTitleRulesTests {
    private func made(_ title: String) -> ChatSummarizer.Summary {
        ChatSummarizer.Summary(title: title, summary: "what it covered", stamp: 1)
    }

    @Test func theEarlierTitleSticksAndANewChatTakesTheDraftOrTheFallback() {
        func stored(_ previous: ChatSummarizer.Summary?, _ draft: String) -> String {
            ChatSummarizer.storedTitle(previous: previous, draft: draft, fallback: "New chat")
        }
        #expect(stored(nil, "") == "New chat")
        #expect(stored(nil, "  Trip plan ") == "Trip plan")
        #expect(stored(made("Trip plan"), "Packing list") == "Trip plan")
        #expect(stored(made(" "), "Packing list") == "Packing list", "a blank earlier title does not count")
    }

    @Test func aTypedNameBeatsTheMadeTitleButNotThePreview() {
        let defaults = UserDefaults.standard
        let keys = [ChatSummarizer.titlesKey, ChatSummarizer.previewsKey]
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { defaults.set(value, forKey: key) } }
        keys.forEach { defaults.set(true, forKey: $0) }

        let summarizer = ChatSummarizer.shared
        #expect(summarizer.shown(made("Trip plan"), title: "Mine", preview: "p")?.title == "Trip plan")
        let renamed = summarizer.shown(made("Trip plan"), title: "Mine", preview: "p", renamed: true)
        #expect(renamed?.title == "Mine")
        #expect(renamed?.summary == "what it covered")
    }

    @Test func aRenameIsRememberedPerStoredChat() {
        let defaults = UserDefaults.standard
        let key = ChatSession.renamedByPersonKey
        let before = defaults.stringArray(forKey: key)
        defer { if let before { defaults.set(before, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.removeObject(forKey: key)

        #expect(!ChatSession.renamedByPerson("20261102_x"))
        for id in ["20261102_x", "20261102_x", ""] { ChatSession.markRenamedByPerson(id) }
        #expect(ChatSession.renamedByPerson("20261102_x"))
        #expect(!ChatSession.renamedByPerson("20261102_y"))
        #expect(defaults.stringArray(forKey: key)?.count == 1, "marked twice, kept once; blank ids ignored")
    }
}
