import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// The bots as Chats' rows: the pins, the dates, what "Always" names, and the recordings a tool
/// hands back.
@Suite struct BotsHomeTests {
    private let bots = ["nollie", "career", "nowhere", "moss", "forager"].map { ProfileInfo(name: $0) }

    @MainActor @Test func pinsKeepTheirOrderAndUnpinningTheLastOneStaysUnpinned() {
        let home = BotsHome()
        #expect(home.pinned(bots, raw: "").isEmpty, "nothing pinned yet")
        #expect(home.firstPins(bots, raw: "") == "nollie,career,nowhere", "four bots or more start with three pinned")
        #expect(home.firstPins(Array(bots.prefix(3)), raw: "") == nil, "three rows need no pins")
        #expect(home.firstPins(bots, raw: "-") == nil, "unpinned on purpose")
        #expect(home.pinned(bots, raw: "nowhere,nollie,gone").map(\.name) == ["nowhere", "nollie"], "in the order pinned; a bot that went is dropped")
        var raw = "nollie"
        raw = BotsHome.toggledPin(raw, "moss")
        #expect(raw == "nollie,moss")
        raw = BotsHome.toggledPin(raw, "nollie")
        raw = BotsHome.toggledPin(raw, "moss")
        #expect(raw == "-")
        #expect(home.pinned(bots, raw: raw).isEmpty)
        #expect(BotsHome.toggledPin("a,b,c,d", "e") == "a,b,c,d", "four at most")
    }

    @MainActor @Test func launchAndKeyboardOrderFollowVisiblePinsBeforeOtherBots() {
        let home = BotsHome()
        let ordered = ["default", "career", "nowhere", "forager"].map { ProfileInfo(name: $0) }
        let visible = home.visibleOrder(ordered, raw: "forager,gone,career,forager")
        #expect(visible.map(\.name) == ["forager", "career", "default", "nowhere"])
        #expect(visible.first?.name == "forager", "launch selects the first visible pin, not a previously selected bot")
        #expect(home.visibleOrder(ordered, raw: "-").first?.name == "default")
        #expect(home.visibleOrder(ordered, raw: "gone").map(\.name) == ordered.map(\.name))
        #expect(home.visibleOrder([], raw: "forager").isEmpty)
    }

    @MainActor @Test func pinningAfterUnpinningEverythingStillAllowsFourRealPins() {
        var raw = "-"
        for name in ["a", "b", "c", "d"] { raw = BotsHome.toggledPin(raw, name) }
        #expect(raw == "a,b,c,d")
        #expect(BotsHome.toggledPin(raw, "e") == raw)
        #expect(BotsHome.toggledPin("a,a,b", "a") == "b")
    }

    @MainActor @Test func aConversationIsDatedTheWayMessagesDatesIt() {
        var cal = Calendar.current
        cal.timeZone = .current
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 10, minute: 0))!
        #expect(BotsHome.when(now.addingTimeInterval(-3600), now: now) == now.addingTimeInterval(-3600).formatted(date: .omitted, time: .shortened))
        #expect(BotsHome.when(now.addingTimeInterval(-86_400), now: now) == "Yesterday")
        let tuesday = now.addingTimeInterval(-2 * 86_400)
        #expect(BotsHome.when(tuesday, now: now) == tuesday.formatted(.dateTime.weekday(.wide)))
        let old = now.addingTimeInterval(-30 * 86_400)
        #expect(BotsHome.when(old, now: now) == old.formatted(.dateTime.day().month(.abbreviated)))
    }

    @Test func alwaysNamesWhatAScreenRuleAllows() {
        func scope(_ key: String?) -> String { ApprovalRequest(requestId: "r", sessionId: "s", patternKey: key).alwaysScope }
        #expect(scope("cua:click:background") == "every click on this Mac's screen, in the background")
        #expect(scope("cua:type:background") == "all typing on this Mac's screen, in the background")
        #expect(scope("cua:right_click:foreground") == "every right-click on this Mac's screen, in front")
        #expect(scope("rm -rf") == "commands matching “rm -rf”")
        #expect(scope(nil) == "this kind of command")
    }

    @Test func aRecordingInAToolsOutputIsFoundOnce() {
        let output = """
        {"recording": false, "last_video_path": "/Users/sam/.hermes/cache/recordings/20261015-1010/recording.mp4", "turns": 4}
        Saved MEDIA:/Users/sam/.hermes/cache/recordings/20261015-1010/recording.mp4 and ~/Movies/demo.MOV.
        Not a video: /tmp/clip.mp4.txt or /var/log/x.mp3
        """
        let clips = MediaScan.videoPaths(inToolOutput: output)
        #expect(clips.map(\.id) == ["/Users/sam/.hermes/cache/recordings/20261015-1010/recording.mp4", "~/Movies/demo.MOV"])
        #expect(MediaRef.isVideo("recording.mp4") && MediaRef.isVideo("a.M4V") && !MediaRef.isVideo("call.m4a"))
        // A reply naming the recording gets a video card, not a file card (the files list still has it).
        let reply = "Here it is.\nMEDIA:/Users/sam/.hermes/cache/recordings/x/recording.mp4"
        #expect(MediaScan.files(in: reply).filter { MediaRef.isVideo($0.name) }.map(\.name) == ["recording.mp4"])
        #expect(MediaScan.textWithoutMedia(reply) == "Here it is.")
    }
}

/// The redesign's small rules: what a row says while a bot works, who counts as busy from the
/// gateway's record alone, names as the list shows them, and the private bot.
@Suite struct BotRowWordsTests {
    @MainActor @Test func aStepReadsInPlainWords() {
        #expect(BotActivity.humanize("Running computer_use…") == "Using your Mac…")
        #expect(BotActivity.humanize("Running mcp__cua__space_bash…") == "Using its own computer…")
        #expect(BotActivity.humanize("Running mcp__cua_recorder__start_recording…") == "Recording the screen…")
        #expect(BotActivity.humanize("Running web_search") == "Searching the web…")
        #expect(BotActivity.humanize("Running terminal…") == "Running a command…")
        #expect(BotActivity.humanize(nil) == "Typing…")
        #expect(BotActivity.humanize("Writing…") == "Typing…")
        #expect(BotActivity.humanize("Checking the board") == "Checking the board…")
        #expect(BotActivity.humanize("Running something_new…") == "Running something_new…")
    }

    @Test func aTurnIsGoingWhenTheNewestRowIsAPromptOrAStep() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func row(_ role: String, ago: Double, tools: Bool = false) -> TranscriptMessage {
            TranscriptMessage(role: role, text: "x", timestamp: now.timeIntervalSince1970 - ago, hasToolCalls: tools)
        }
        #expect(BotsHome.midTurn([row("assistant", ago: 90), row("user", ago: 20)], now: now))
        #expect(BotsHome.midTurn([row("user", ago: 40), row("tool", ago: 10)], now: now))
        #expect(BotsHome.midTurn([row("user", ago: 40), row("assistant", ago: 5, tools: true)], now: now))
        #expect(!BotsHome.midTurn([row("user", ago: 40), row("assistant", ago: 5)], now: now), "answered")
        #expect(!BotsHome.midTurn([row("user", ago: 600)], now: now), "a prompt from ten minutes ago is not work now")
        #expect(!BotsHome.midTurn([], now: now))
    }

    @Test func namesReadWithACapitalAndThePrivateBotIsKnown() {
        #expect(ProfileInfo(name: "career").shownName == "Career")
        #expect(ProfileInfo(name: "default", displayName: "Nollie").shownName == "Nollie")
        #expect(ProfileInfo(name: "moss", provider: "ollama").isPrivateBot, "a local model keeps its words on the Mac")
        #expect(!ProfileInfo(name: "career", provider: "openrouter").isPrivateBot)
    }

    @MainActor @Test func notesKeepTheirEntriesApart() {
        #expect(BotKnowsView.readable("Likes tea\n§\nLives in London") == "Likes tea\n---\nLives in London")
    }

    /// System control: one switch covers every screen action Hermes asks about, in the background
    /// and in front; a bot not read yet gets the card, never an answer by itself.
    @MainActor @Test func systemControlCoversEveryScreenAction() {
        #expect(Set(SystemControl.keys).count == SystemControl.keys.count)
        #expect(SystemControl.keys.contains("cua:launch_app:background"))
        #expect(!SystemControl.keys.contains("cua:launch_app:foreground"))
        for k in ["cua:click:background", "cua:type:foreground", "cua:key:background", "cua:bring_to_front:foreground", "cua:focus_app:background", "cua:set_value:foreground"] {
            #expect(SystemControl.keys.contains(k), "\(k) is covered")
        }
        let screen = ApprovalRequest(requestId: "r", sessionId: "s", patternKey: "cua:click:background")
        #expect(SystemControl.isScreen(screen))
        #expect(SystemControl.shared.autoAnswer(screen, profile: "not-read-yet") == nil)
        let command = ApprovalRequest(requestId: "r", sessionId: "s", command: "rm -r build", patternKey: "rm -r")
        #expect(!SystemControl.isScreen(command))
        #expect(SystemControl.shared.autoAnswer(command, profile: "not-read-yet") == nil)
        #expect(ApprovalCardView.screenStep("cua:click:foreground") == "a click, in front")
        #expect(ApprovalCardView.screenStep("cua:type:background") == "typing, in the background")
    }

    /// With System control on, a screen action is allowed for its chat only, never always, and
    /// screen rules left on the always-allowed list by an older version come off.
    @MainActor @Test func systemControlNeverAllowsTheScreenAlways() {
        let screen = ApprovalRequest(requestId: "r", sessionId: "s", patternKey: "cua:click:background")
        #expect(SystemControl.autoAnswer(screen, controlOn: true) == "session")
        #expect(SystemControl.autoAnswer(screen, controlOn: false) == nil)
        let onceOnly = ApprovalRequest(requestId: "r", sessionId: "s", choices: ["once", "deny"], patternKey: "cua:type:foreground")
        #expect(SystemControl.autoAnswer(onceOnly, controlOn: true) == nil)
        let command = ApprovalRequest(requestId: "r", sessionId: "s", command: "rm -r build", patternKey: "rm -r")
        #expect(SystemControl.autoAnswer(command, controlOn: true) == nil)
        #expect(SystemControl.withoutScreenRules(["rm -r", "cua:click:background", "cua:launch_app:background", "git push"]) == ["rm -r", "git push"])
    }
}
