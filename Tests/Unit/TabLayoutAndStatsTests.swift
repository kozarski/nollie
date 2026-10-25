import Foundation
import SwiftUI
import Testing
@testable import Nollie
@testable import NollieCore

/// Which tabs the app shows, and what survives from older saved layouts.
@Suite struct TabLayoutTests {
    @Test func savedAdministrationTabsFallBackToChatsAndSettings() {
        let old = TabLayout.parse("dashboard,bots,files,cron,system,status,sessions,bogus")
        #expect(old.tabs == [.chats, .settings])
        for empty in [nil, ""] as [String?] { #expect(TabLayout.parse(empty) == .default) }
    }

    @Test func theBoardSurvivesMigrationAndARoundTrip() {
        let layout = TabLayout.parse("dashboard,kanban,chats,kanban,settings")
        #expect(layout.tabs == [.kanban, .chats, .settings])
        #expect(TabLayout.parse(layout.encoded) == layout)
        #expect(layout.visible(hiding: [.kanban]) == [.chats, .settings])
    }

    @Test func aTabHiddenForNowStaysSavedButIsNotShown() {
        // The Board's plugin can be off: the layout keeps the tab, nothing shows or opens on it.
        let saved = TabLayout(tabs: [.chats, .kanban, .settings]).encoded
        let layout = TabLayout.parse(saved)
        let shown = [layout.visible(), layout.visible(hiding: [.kanban])]
        #expect(shown == [[.chats, .kanban, .settings], [.chats, .settings]])
    }

    @Test func switchingEverythingOnStillGivesThreeTabs() {
        var layout = TabLayout.default
        AppModel.AppTab.allCases.forEach { layout.set($0, enabled: true) }
        #expect(layout.tabs == [.chats, .kanban, .settings])
        #expect(layout.isFull)
    }

    @Test func chatsAndSettingsCannotBeSwitchedOff() {
        var layout = TabLayout.default
        for tab in [AppModel.AppTab.chats, .settings, .kanban] { layout.set(tab, enabled: false) }
        #expect(layout.tabs == [.chats, .settings])
        layout.set(.kanban, enabled: true)
        #expect(layout.tabs == [.chats, .kanban, .settings])
    }

    @Test(arguments: ["dashboard", "home", "bots", "files", "cron", "settings", "unknown", "", nil, "chats"] as [String?])
    func anythingButTheBoardOpensOnChats(saved: String?) {
        #expect(TabLayout.launchTab(saved) == .chats)
    }

    @Test func theBoardCanBeTheLaunchTab() {
        #expect(TabLayout.launchTab("kanban") == .kanban)
    }
}

@Suite struct TurnFiguresTests {
    @Test func countsFromTheServerAreMarkedExact() {
        let stats = TurnStats.make(outputBefore: 100, outputAfter: 512, streamedCharacters: 9999, seconds: 10.3)
        #expect(stats.exact)
        #expect(stats.outputTokens == 412)
        #expect(stats.label == "412 tokens · 40 tok/s · 10.3s")
    }

    @Test func withoutACountTheFigureIsEstimatedFromTheText() {
        let stats = TurnStats.make(outputBefore: nil, outputAfter: 512, streamedCharacters: 400, seconds: 0.2)
        #expect(!stats.exact)
        #expect(stats.outputTokens == 100)
        #expect(stats.tokensPerSecond == nil)
        #expect(stats.label == "~100 tokens · 0.2s")
    }
}

@Suite struct TranscriptLookTests {
    @Test func aTimeMarkerAppearsOnlyAfterAGap() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func at(_ seconds: TimeInterval, _ id: String, _ kind: TranscriptItem.Kind) -> TranscriptItem {
            TranscriptItem(id: id, kind: kind, timestamp: start.addingTimeInterval(seconds))
        }
        let talk = [
            at(0, "a", .user(text: "hi", attachments: [])),
            at(30, "b", .assistant(text: "hello", reasoning: nil, streaming: false)),
            at(3600, "c", .user(text: "later", attachments: [])),
        ]
        let rows = TranscriptRowModel.build(talk, now: start.addingTimeInterval(4000))
        #expect(rows.map { $0.separator != nil } == [true, false, true])
        #expect(rows.last?.separator?.hasPrefix("Today") == true)
    }

    @Test func eachBotKeepsItsColourAndColoursParse() {
        let twice = ["default", "default"].map(BotColors.defaultHex(for:))
        #expect(twice[0] == twice[1])
        for name in ["scout", "mason", "ops"] {
            let hex = BotColors.defaultHex(for: name)
            #expect(BotColors.palette.contains(hex))
            #expect(Color(hex: hex) != nil)
        }
        #expect(Color(hex: "nope") == nil)
    }
}
