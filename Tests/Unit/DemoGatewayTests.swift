import Foundation
import Testing
@testable import NollieCore

/// Everything a demo person sees comes from `DemoGateway`, so these tests talk to it the way the app
/// does: the REST routes, and the socket with its JSON-RPC calls, events and questions.

/// What a socket to the demo gateway has heard so far, and a way to wait for more.
private final class DGTInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [JSONValue] = []
    private var reader: Task<Void, Never>?
    private var nextID = 0
    let channel: DemoChannel
    let gateway: DemoGateway

    init(_ gateway: DemoGateway) async {
        self.gateway = gateway
        channel = DemoChannel()
        await gateway.attach(channel)
        reader = Task { [channel, weak self] in
            for await event in channel.incoming {
                guard case .text(let text) = event, let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { continue }
                self?.lock.withLock { self?.frames.append(frame) }
            }
        }
    }

    deinit { reader?.cancel() }

    var heard: [JSONValue] { lock.withLock { frames } }

    func events(_ type: String) -> [JSONValue] {
        heard.filter { $0["method"]?.stringValue == "event" && $0["params"]?["type"]?.stringValue == type }
    }

    /// Makes a call and returns what it answered, or throws what it refused with.
    func call(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        await gateway.receive(RPCFrames.request(id: id, method: method, params: params), from: channel)
        _ = await waitFor { heard.contains { $0["id"]?.intValue == id && $0["method"] == nil } }
        let answer = try #require(heard.first { $0["id"]?.intValue == id && $0["method"] == nil })
        if let failure = answer["error"] { throw RPCError(code: failure["code"]?.intValue ?? 0, message: failure["message"]?.stringValue ?? "") }
        return answer["result"] ?? .null
    }

    /// Answers a question the gateway put to the app.
    func answer(_ id: String, choice: String) async {
        await gateway.receive(RPCFrames.response(id: id, result: ["choice": .string(choice)]), from: channel)
    }

    /// Waits until `what` holds. The gateway's pacing runs on `InstantClock`, so no reply takes real time and this
    /// gives up only after a minute, which ends a broken test, never a slow computer's working one.
    func waitFor(_ what: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(60))
        while clock.now < end {
            if what() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return what()
    }
}

private func dgtOpen(_ gateway: DemoGateway, _ stored: String, profile: String = "default") async throws -> (inbox: DGTInbox, session: String, resumed: JSONValue) {
    let inbox = await DGTInbox(gateway)
    let resumed = try await inbox.call("session.resume", ["session_id": .string(stored), "profile": .string(profile)])
    return (inbox, try #require(resumed["session_id"]?.stringValue), resumed)
}

private func dgtREST(_ gateway: DemoGateway, _ path: String, method: String = "GET") async throws -> JSONValue {
    let answer = await gateway.rest(method, path, body: nil)
    #expect(answer.status == 200)
    return try JSONDecoder().decode(JSONValue.self, from: answer.body)
}

struct DemoGatewayTests {
    @Test func theBotsAreNollieScoutAndTwoMore() async throws {
        let gateway = DemoGateway(pace: InstantClock())
        let listed = try await dgtREST(gateway, "/api/profiles")["profiles"]?.arrayValue ?? []
        #expect(listed.compactMap { $0["display_name"]?.stringValue } == ["Nollie", "Scout", "Mason", "Wren"])
        #expect(listed.first?["is_default"]?.boolValue == true)

        // The same bots, with the chat each one opens on, as the socket lists them.
        let inbox = await DGTInbox(gateway)
        let socket = try await inbox.call("profiles.list")["profiles"]?.arrayValue ?? []
        #expect(socket.compactMap { $0["name"]?.stringValue } == ["default", "scout", "mason", "wren"])
        let chats = try await dgtREST(gateway, "/api/sessions")["sessions"]?.arrayValue ?? []
        let known = Set(chats.compactMap { $0["id"]?.stringValue })
        for bot in socket { #expect(known.contains(bot["canonical_session"]?["id"]?.stringValue ?? "")) }
    }

    @Test func aChatOpensWithItsHistoryAndTheStepsItShowed() async throws {
        let gateway = DemoGateway(pace: InstantClock())
        let (_, _, resumed) = try await dgtOpen(gateway, "demo-nollie-main")
        let messages = resumed["messages"]?.arrayValue ?? []
        #expect(messages.map { $0["role"]?.stringValue } == ["user", "tool", "assistant", "user", "assistant"])
        #expect(messages[1]["name"]?.stringValue == "web_search")
        #expect(messages[0]["text"]?.stringValue?.contains("near Bath") == true)

        // The page of messages the app reads first has the same rows.
        let page = try await dgtREST(gateway, "/api/sessions/demo-nollie-main/messages?limit=12&order=latest&profile=default")
        #expect(page["messages"]?.arrayValue?.count == messages.count)
        #expect(resumed["running"]?.boolValue == false)
    }

    @Test func aMessageGetsAReplyWithTheStepsAndThenTheWholeText() async throws {
        let gateway = DemoGateway(pace: InstantClock())
        let (inbox, session, _) = try await dgtOpen(gateway, "demo-wren-main", profile: "wren")
        let sent = try await inbox.call("prompt.submit", ["session_id": .string(session), "text": "Find me a quiet cafe near the park"])
        #expect(sent["status"]?.stringValue == "streaming")

        #expect(await inbox.waitFor { !inbox.events("message.complete").isEmpty })
        #expect(!inbox.events("message.start").isEmpty)
        let steps = inbox.events("tool.start").compactMap { $0["params"]?["payload"]?["name"]?.stringValue }
        #expect(steps == ["web_search", "web_extract"])
        let reply = inbox.events("message.complete").first?["params"]?["payload"]?["text"]?.stringValue ?? ""
        #expect(reply.contains("Find me a quiet cafe near the park"))
        // The deltas add up to the reply.
        let streamed = inbox.events("message.delta").compactMap { $0["params"]?["payload"]?["text"]?.stringValue }.joined()
        #expect(streamed == reply)

        // The chat now holds the turn, and the list shows it.
        let page = try await dgtREST(gateway, "/api/sessions/demo-wren-main/messages?limit=60&profile=wren")
        let last = page["messages"]?.arrayValue?.last
        #expect(last?["role"]?.stringValue == "assistant")
        #expect(last?["text"]?.stringValue == reply)
    }

    @Test func aMessageThatSendsSomethingWaitsForYesAndAllowOnceSendsIt() async throws {
        let gateway = DemoGateway(pace: InstantClock())
        let (inbox, session, resumed) = try await dgtOpen(gateway, "demo-mason-main", profile: "mason")
        // Mason is already waiting on the note for Sam when the chat opens.
        #expect(resumed["running"]?.boolValue == true)
        let open = try #require(resumed["open_requests"]?.arrayValue?.first)
        let ask = try #require(AskFirstAsk(open["params"].flatMap { try? $0.decode(ApprovalRequest.self) }))
        #expect(ask.kind == .send)
        #expect(ask.buttonLabel == "Send")
        #expect(ask.summary.contains("Hi Sam, I can meet at 10 on Thursday."))
        let pending = try await inbox.call("approval.pending", ["session_id": .string(session)])
        #expect(pending["approvals"]?.arrayValue?.count == 1)

        await inbox.answer(try #require(open["id"]?.stringValue), choice: "once")
        #expect(await inbox.waitFor { !inbox.events("message.complete").isEmpty })
        let reply = inbox.events("message.complete").first?["params"]?["payload"]?["text"]?.stringValue ?? ""
        #expect(reply.hasSuffix("Sent."))
        #expect(!inbox.events("tool.complete").isEmpty)

        // Nothing is waiting any more, and the note is in the chat.
        let after = try await inbox.call("approval.pending", ["session_id": .string(session)])
        #expect(after["approvals"]?.arrayValue?.isEmpty == true)
        let page = try await dgtREST(gateway, "/api/sessions/demo-mason-main/messages?limit=60&profile=mason")
        #expect(page["messages"]?.arrayValue?.last?["text"]?.stringValue?.hasSuffix("Sent.") == true)
    }

    @Test func denyLeavesTheNoteUnsentAndSettlesThroughTheApprovalCall() async throws {
        let gateway = DemoGateway(pace: InstantClock())
        let (inbox, session, resumed) = try await dgtOpen(gateway, "demo-mason-main", profile: "mason")
        let request = try #require(resumed["open_requests"]?.arrayValue?.first?["params"]?["request_id"]?.stringValue)
        let settled = try await inbox.call("approval.respond", ["session_id": .string(session), "request_id": .string(request), "choice": "deny"])
        #expect(settled["resolved"]?.intValue == 1)
        #expect(await inbox.waitFor { !inbox.events("message.complete").isEmpty })
        let reply = inbox.events("message.complete").first?["params"]?["payload"]?["text"]?.stringValue ?? ""
        #expect(reply.hasSuffix("Okay, I didn't send it."))
        #expect(inbox.events("tool.complete").isEmpty)
    }

    @Test func askingToSendInAnotherChatRaisesTheSameCard() async throws {
        let gateway = DemoGateway(pace: InstantClock())
        let (inbox, session, _) = try await dgtOpen(gateway, "demo-scout-main", profile: "scout")
        _ = try await inbox.call("prompt.submit", ["session_id": .string(session), "text": "Please send my landlord a note"])
        #expect(await inbox.waitFor { inbox.heard.contains { $0["method"]?.stringValue == "approval" } })
        let frame = try #require(inbox.heard.first { $0["method"]?.stringValue == "approval" })
        #expect(AskFirstAsk(frame["params"].flatMap { try? $0.decode(ApprovalRequest.self) }) != nil)
        await gateway.shutdown()
    }

    @Test func theBoardNightShiftAndSchedulesAreThere() async throws {
        let gateway = DemoGateway(pace: InstantClock())
        let columns = try await dgtREST(gateway, "/api/plugins/kanban/board?board=default")["columns"]?.arrayValue ?? []
        let tasks = columns.flatMap { $0["tasks"]?.arrayValue ?? [] }
        #expect(tasks.count >= 6)
        #expect(tasks.contains { $0["status"]?.stringValue == "running" })

        let posts = try await dgtREST(gateway, "/api/plugins/nollie-workflow/posts?since=1&limit=60")["posts"]?.arrayValue ?? []
        #expect(posts.first?["kind"]?.stringValue == "night_shift")
        let card = try #require(posts.first.flatMap { try? $0.decode(ConversationPostWire.self) })
        #expect(card.runs.count == 2)

        let jobs = try await dgtREST(gateway, "/api/cron/jobs")["jobs"]?.arrayValue ?? []
        #expect(jobs.count == 2)
    }

    @Test func movingACardOnTheBoardIsKeptAndABadMoveIsRefused() async throws {
        let gateway = DemoGateway(pace: InstantClock())
        let body = Data(#"{"status":"review"}"#.utf8)
        let moved = await gateway.rest("PATCH", "/api/plugins/kanban/tasks/k-2?board=default", body: body)
        #expect(moved.status == 200)
        let detail = try await dgtREST(gateway, "/api/plugins/kanban/tasks/k-2?board=default")
        #expect(detail["task"]?["status"]?.stringValue == "review")

        let refused = await gateway.rest("PATCH", "/api/plugins/kanban/tasks/k-2?board=default", body: Data(#"{"status":"running"}"#.utf8))
        #expect(refused.status == 409)
    }

    @Test func aRuntimeOnTheDemoBackendConnectsListsTheBotsAndTalks() async throws {
        let gateway = DemoGateway(pace: InstantClock())
        let connection = GatewayConnection(name: "Demo", gateway: gateway.address, authMode: .sessionToken)
        let runtime = await GatewayRuntime(connection: connection, store: ConnectionStore(), backend: gateway.backend)
        await runtime.start()
        defer { Task { await runtime.stop(); await gateway.shutdown() } }

        #expect(await runtime.profiles.map(\.name) == ["default", "scout", "mason", "wren"])
        #expect(await runtime.socketState.isOpen)

        let chat = try await runtime.openChat(storedID: "demo-wren-main", profile: "wren", waitForResume: true)
        #expect(await chat.items.count >= 2)
        let failure = await chat.send("Plan my weekend")
        #expect(failure == nil)
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(60))
        var heard = false
        while !heard, clock.now < end {
            heard = await chat.items.contains { item in
                if case .assistant(let text, _, _) = item.kind { return text.contains("Plan my weekend") }
                return false
            }
            if !heard { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(heard)
    }

    @Test func onlyTheDemoSessionCanReachTheMadeUpHost() async throws {
        let gateway = DemoGateway(pace: InstantClock())
        // The made-up host never resolves, so a plain session finds nothing there.
        #expect(gateway.host.hasSuffix(".nollie.invalid"))
        let outside = try #require(URL(string: "https://\(gateway.host)/api/status"))
        let plain = try? await URLSession(configuration: .ephemeral).data(from: outside)
        #expect(plain == nil)
        let session = try #require(gateway.backend.urlSession)
        let (data, _) = try await session.data(from: outside)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data)["gateway_running"]?.boolValue == true)
        await gateway.shutdown()
    }
}

/// Just enough of the Night shift card to count its runs.
private struct ConversationPostWire: Decodable {
    struct Run: Decodable { var id: String }
    var runs: [Run]
}
