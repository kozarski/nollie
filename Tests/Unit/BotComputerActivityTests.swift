import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

@MainActor
@Suite struct BotComputerActivityTests {
    private func tool(_ name: String, action: String? = nil, status: ToolActivity.Status = .running,
                      output: String? = nil, rowID: Int? = nil) -> TranscriptItem {
        let args = action.map { "{\"action\":\"\($0)\"}" }
        return TranscriptItem(id: UUID().uuidString,
                              kind: .tool(ToolActivity(id: UUID().uuidString, name: name, argsText: args,
                                                       status: status, resultText: output)), rowID: rowID)
    }

    private var prompt: TranscriptItem { TranscriptItem(id: UUID().uuidString, kind: .user(text: "Work", attachments: [])) }

    @Test func activeComputerCallsAreDistinctFromAWorkingChat() {
        #expect(BotComputerActivity.isActive(in: [prompt, tool("computer_use", action: "click")], isRunning: true))
        #expect(BotComputerActivity.isActive(in: [prompt, tool("mcp__cua__computer_screenshot")], isRunning: true))
        #expect(BotComputerActivity.isActive(in: [prompt, tool("mcp__cua__space_bash")], isRunning: true))
        #expect(!BotComputerActivity.isActive(in: [prompt, tool("web_search")], isRunning: true))
        #expect(!BotComputerActivity.isActive(in: [prompt, tool("computer_use", action: "click")], isRunning: false))
    }

    @Test func discoveryAndFinishedCallsDoNotGlow() {
        for call in [tool("computer_use", action: "list_apps"), tool("computer_use", action: "list_windows"),
                     tool("mcp__cua__computer_list_windows"), tool("mcp__cua__space_status"),
                     tool("mcp__cua__list_spaces"), tool("mcp__cua__stream_endpoint"),
                     tool("computer_use", status: .done), tool("computer_use", status: .failed),
                     tool("computer_use", rowID: 20)] {
            #expect(!BotComputerActivity.isActive(in: [prompt, call], isRunning: true))
        }
    }

    @Test func earlierUnfinishedToolsDoNotLeakIntoANewTurn() {
        let stale = tool("computer_use", action: "click")
        #expect(!BotComputerActivity.isActive(in: [prompt, stale, prompt, tool("web_search")], isRunning: true))
        let error = TranscriptItem(id: "error", kind: .error(text: "Stopped"))
        #expect(!BotComputerActivity.isActive(in: [prompt, stale, error, tool("web_search")], isRunning: true))
        let answer = TranscriptItem(id: "answer", kind: .assistant(text: "Done", reasoning: nil, streaming: false),
                                    stats: TurnStats(outputTokens: 2, seconds: 1, exact: true))
        #expect(!BotComputerActivity.isActive(in: [prompt, stale, answer, tool("web_search")], isRunning: true))
    }

    @Test func concurrentToolsKeepTheComputerActiveUntilItsOwnCompletion() {
        let items = [prompt, tool("computer_use", action: "capture"), tool("web_search")]
        #expect(BotComputerActivity.isActive(in: items, isRunning: true))
        #expect(!BotComputerActivity.isActive(in: [prompt, tool("computer_use", status: .done), tool("web_search")], isRunning: true))
    }

    @Test func activityBelongsToTheBotAcrossItsOpenChats() throws {
        let connection = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let runtime = GatewayRuntime(connection: connection, store: ConnectionStore())
        let work = ChatSession(runtime: runtime, storedID: "work", title: nil, profile: "work")
        let home = ChatSession(runtime: runtime, storedID: "home", title: nil, profile: "home")
        runtime.registry.add(work)
        runtime.registry.add(home)
        work.items = [prompt, tool("mcp__cua__space_bash")]
        work.isRunning = true
        defer { work.isRunning = false }
        #expect(BotComputerActivity.isActive(in: work))
        #expect(BotComputerActivity.isActive(runtime: runtime, profile: "work"))
        #expect(!BotComputerActivity.isActive(runtime: runtime, profile: "home"))
        #expect(BotComputerActivity.status(runtime: runtime, profile: "work") == .usingComputer)
        #expect(BotComputerActivity.status(runtime: runtime, profile: "home") == .unknown)
        work.items = [prompt, tool("web_search")]
        #expect(BotComputerActivity.status(runtime: runtime, profile: "work") == .working)
        #expect(!BotComputerActivity.isActive(runtime: runtime, profile: "work"), "a working bot does not prove computer use")
    }

    @Test func latestActualCaptureWinsOverUnrelatedImages() {
        let earlier = tool("computer_use", status: .done, output: "{\"screenshot_path\":\"/tmp/first.png\"}")
        let latest = tool("mcp__cua__computer_screenshot", status: .done, output: "Saved to /tmp/second.png")
        let generated = tool("image_generate", status: .done, output: "Saved to /tmp/art.png")
        let shell = tool("mcp__cua__space_bash", status: .done, output: "Image: /tmp/file.png")
        let uploaded = TranscriptItem(id: "upload", kind: .user(text: "Look", attachments: [
            AttachmentPreview(id: "pic", name: "upload.png", serverPath: "/tmp/upload.png", kind: .image)
        ]))
        #expect(BotComputerActivity.latestScreen(in: [earlier, latest, generated, shell, uploaded])?.id == "/tmp/second.png")
    }

    @Test func liveDelegationMarksOnlyItsRecipientWithoutClaimingComputerUse() throws {
        let connection = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let runtime = GatewayRuntime(connection: connection, store: ConnectionStore())
        let chat = ChatSession(runtime: runtime, storedID: "delegation-fixture", title: nil, profile: "default")
        runtime.registry.add(chat)
        let delivery = TranscriptItem(id: "delivery", kind: .tool(ToolActivity(id: "delivery", name: "message_agent", argsText: #"{"target":"forager","message":"Check a price"}"#)))
        chat.items = [prompt, delivery]; chat.isRunning = true
        defer { chat.isRunning = false }
        #expect(BotComputerActivity.status(runtime: runtime, profile: "forager") == .working)
        #expect(BotPresence(runtime: runtime, profile: "forager", mainID: nil).working)
        #expect(!BotComputerActivity.isActive(runtime: runtime, profile: "forager"))
        #expect(!BotComputerActivity.hasDelegatedWork(runtime: runtime, profile: "career"))
        chat.items.append(prompt)
        #expect(!BotComputerActivity.hasDelegatedWork(runtime: runtime, profile: "forager"), "a call in an earlier turn is not current work")
    }

    @Test func structuredCapturePathsPreserveSpacesAndIgnoreFailedResults() {
        let capture = tool("computer_use", status: .done, output: "{\"meta\":{\"screenshot_path\":\"/tmp/My Screen.png\"}}")
        let failed = tool("mcp__cua__computer_screenshot", status: .failed, output: "Old /tmp/failure.png")
        let rejected = tool("computer_use", status: .done, output: "{\"ok\":false,\"screenshot_path\":\"/tmp/rejected.png\"}")
        #expect(BotComputerActivity.latestScreen(in: [capture, failed, rejected])?.id == "/tmp/My Screen.png")
        #expect(BotComputerActivity.latestScreen(in: [tool("computer_use", action: "list_apps", status: .done,
                                                        output: "/tmp/icon.png")]) == nil)
    }
}
