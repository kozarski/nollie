import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// The Lock Screen's "Scout is using your Mac" with Stop: when the app counts a helper as at work,
/// where, how long it trusts what it saw, and what it says.
@MainActor
@Suite struct HelperAtWorkTests {
    private func tool(_ name: String, action: String? = nil, status: ToolActivity.Status = .running,
                      at time: TimeInterval = 0) -> TranscriptItem {
        var item = TranscriptItem(id: UUID().uuidString,
                                  kind: .tool(ToolActivity(id: UUID().uuidString, name: name,
                                                           argsText: action.map { "{\"action\":\"\($0)\"}" }, status: status)))
        item.timestamp = Date(timeIntervalSinceReferenceDate: time)
        return item
    }

    private var prompt: TranscriptItem { TranscriptItem(id: UUID().uuidString, kind: .user(text: "Work", attachments: [])) }

    @Test func theMacAndItsOwnComputerAreToldApart() {
        #expect(BotComputerActivity.workPlace(in: [prompt, tool("computer_use", action: "click")], isRunning: true)?.place == .mac)
        #expect(BotComputerActivity.workPlace(in: [prompt, tool("mcp__nollie_mac__mac_start", status: .done)], isRunning: true)?.place == .mac)
        #expect(BotComputerActivity.workPlace(in: [prompt, tool("mcp__cua__space_bash")], isRunning: true)?.place == .ownComputer)
        #expect(BotComputerActivity.workPlace(in: [prompt, tool("web_search")], isRunning: true) == nil)
    }

    /// Between two calls the helper is still at it: the activity must not flicker off.
    @Test func aTurnThatUsedAComputerCountsUntilItEnds() {
        let items = [prompt, tool("computer_use", action: "click", status: .done, at: 10), tool("web_search", at: 20)]
        let work = BotComputerActivity.workPlace(in: items, isRunning: true)
        #expect(work?.place == .mac)
        #expect(work?.since == Date(timeIntervalSinceReferenceDate: 10))
        #expect(BotComputerActivity.workPlace(in: items, isRunning: false) == nil)
    }

    @Test func onlyThisTurnCounts() {
        let earlier = tool("computer_use", action: "click", status: .done)
        #expect(BotComputerActivity.workPlace(in: [prompt, earlier, prompt, tool("web_search")], isRunning: true) == nil)
        let answer = TranscriptItem(id: "answer", kind: .assistant(text: "Done", reasoning: nil, streaming: false),
                                    stats: TurnStats(outputTokens: 2, seconds: 1, exact: true))
        #expect(BotComputerActivity.workPlace(in: [prompt, earlier, answer, tool("web_search")], isRunning: true) == nil)
    }

    @Test func discoveryAndFailedCallsAreNotWork() {
        for call in [tool("computer_use", action: "list_apps"), tool("mcp__cua__list_spaces"),
                     tool("computer_use", action: "click", status: .failed)] {
            #expect(BotComputerActivity.workPlace(in: [prompt, call], isRunning: true) == nil)
        }
    }

    /// Nollie Computer's task is over once the helper says it is done; a new one counts from its
    /// own start.
    @Test func macDoneEndsTheMacTask() {
        let items = [prompt, tool("mcp__nollie_mac__mac_start", status: .done, at: 1),
                     tool("mcp__nollie_mac__mac_click", status: .done, at: 2),
                     tool("mcp__nollie_mac__mac_done", status: .done, at: 3), tool("web_search", at: 4)]
        #expect(BotComputerActivity.workPlace(in: items, isRunning: true) == nil)
        let again = items + [tool("mcp__nollie_mac__mac_start", status: .done, at: 5)]
        #expect(BotComputerActivity.workPlace(in: again, isRunning: true)?.place == .mac)
        #expect(BotComputerActivity.workPlace(in: again, isRunning: true)?.since == Date(timeIntervalSinceReferenceDate: 5))
    }

    /// While `mac_start` runs, the person at the Mac has not said yes: nothing is using it yet.
    /// A refused call means the task is over (stopped on the Mac, or timed out).
    @Test func macWorkCountsOnlyWhileTheTaskIsOpen() {
        #expect(BotComputerActivity.workPlace(in: [prompt, tool("mcp__nollie_mac__mac_start")], isRunning: true) == nil)
        let refused = TranscriptItem(id: UUID().uuidString,
                                     kind: .tool(ToolActivity(id: UUID().uuidString, name: "mcp__nollie_mac__mac_click", status: .done,
                                                              resultText: #"{"isError": true, "content": [{"type": "text", "text": "The task has ended."}]}"#)))
        let items = [prompt, tool("mcp__nollie_mac__mac_start", status: .done, at: 1), refused]
        #expect(BotComputerActivity.workPlace(in: items, isRunning: true) == nil)
    }

    /// The timer counts from when this place's work began, not the turn's other computer.
    @Test func theTimeBelongsToThePlaceShown() {
        let items = [prompt, tool("mcp__cua__space_bash", status: .done, at: 1), tool("computer_use", action: "click", at: 11)]
        let work = BotComputerActivity.workPlace(in: items, isRunning: true)
        #expect(work?.place == .mac)
        #expect(work?.since == Date(timeIntervalSinceReferenceDate: 11))
    }

    /// Without a server, the Lock Screen trusts what the app saw for two minutes, and not at all
    /// once the link to the Mac is gone.
    @Test func staleDatesAreHonest() {
        let seen = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(HelperAtWorkTiming.staleDate(lastSeen: seen, reachable: true) == seen.addingTimeInterval(120))
        #expect(HelperAtWorkTiming.staleDate(lastSeen: seen, reachable: false) == nil)
        #expect(HelperAtWorkTiming.refreshEvery < HelperAtWorkTiming.staleAfter)
    }

    @Test func wordsArePlainAndShort() {
        #expect(HelperAtWorkWords.title(name: "Scout", place: .mac) == "Scout is using your Mac")
        #expect(HelperAtWorkWords.title(name: "Scout", place: .ownComputer) == "Scout is using its computer")
        for line in [HelperAtWorkWords.stop, HelperAtWorkWords.stopping, HelperAtWorkWords.stopped, HelperAtWorkWords.notReached,
                     HelperAtWorkWords.lastSeen, HelperAtWorkWords.setting, HelperAtWorkWords.settingFooter,
                     HelperAtWorkWords.title(name: "Scout", place: .mac)] {
            #expect(!line.contains("\u{2014}"))
            #expect(line.count < 120)
        }
    }

    @Test func theLockScreenStopIsOnUnlessTurnedOff() {
        let d = UserDefaults.standard
        let had = d.object(forKey: HelperAtWorkSetting.key)
        defer { if let had { d.set(had, forKey: HelperAtWorkSetting.key) } else { d.removeObject(forKey: HelperAtWorkSetting.key) } }
        d.removeObject(forKey: HelperAtWorkSetting.key)
        #expect(HelperAtWorkSetting.isOn)
        HelperAtWorkSetting.isOn = false
        #expect(!HelperAtWorkSetting.isOn)
    }
}
