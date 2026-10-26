import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Each message owns the files that were staged when the person sent it. A second send while the first
/// is still uploading queues behind it, and nothing staged in the meantime is taken or lost.

/// The gateway for one chat: it records the calls, can make the first upload wait for the test, and
/// refuses files by name.
@MainActor private final class Wire {
    private(set) var calls: [(method: String, params: [String: JSONValue])] = []
    var holdNext = 0
    var parked: [CheckedContinuation<Void, Never>] = []
    var refused: Set<String> = []

    var prompts: [String] { calls.filter { $0.method == "prompt.submit" }.compactMap { $0.params["text"]?.stringValue } }
    var uploads: [String] { calls.filter { $0.method == "file.attach" }.compactMap { $0.params["name"]?.stringValue } }

    func answer(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        calls.append((method, params))
        guard method == "file.attach" else { return ["status": "ok"] }
        let name = params["name"]?.stringValue ?? ""
        if holdNext > 0 {
            holdNext -= 1
            await withCheckedContinuation { parked.append($0) }
        }
        if refused.contains(name) { throw RPCError(code: -32000, message: "file too large") }
        return ["ref_text": .string("[ref \(name)]")]
    }
}

@MainActor private func bench() throws -> (chat: ChatSession, wire: Wire) {
    let chat = try ChatFixtures.chat(stored: "stored-1")
    chat.runtimeID = "live-1"
    let wire = Wire()
    chat.gatewayStandIn = { method, params in try await wire.answer(method, params) }
    return (chat, wire)
}

@MainActor private func pump(_ ready: () -> Bool) async {
    var turns = 0
    while !ready() && turns < 1000 {
        await Task.yield()
        turns += 1
    }
}

@MainActor private func stage(_ chat: ChatSession, _ names: String...) {
    for name in names { chat.stageAttachment(data: Data(name.utf8), name: name, kind: .file) }
}

@MainActor private func finishTurn(_ chat: ChatSession) {
    chat.handle(event: ChatFixtures.event(for: chat, "message.complete", ["text": "Done.", "status": "complete"]))
}

/// What each of the person's rows in the transcript says and shows.
@MainActor private func sentRows(_ chat: ChatSession) -> [String] {
    chat.items.compactMap { item in
        guard case .user(let text, let files) = item.kind else { return nil }
        return text + " | " + files.map(\.name).joined(separator: ",")
    }
}

@MainActor @Suite struct SendingAttachmentsTests {
    @Test func twoQuickSendsEachSendTheirOwnFiles() async throws {
        let (chat, wire) = try bench()
        wire.holdNext = 1
        stage(chat, "a.txt")
        let first = Task { await chat.send("first") }
        await pump { wire.parked.count == 1 }
        #expect(chat.staged.isEmpty, "the first message holds its file from the moment it was sent")

        stage(chat, "b.txt")
        await chat.send("second")
        #expect(chat.queue.map(\.text) == ["second"], "a send during the upload waits its turn")
        #expect(chat.queue.first?.attachments.map(\.name) == ["b.txt"])
        #expect(chat.staged.isEmpty)
        #expect(wire.prompts.isEmpty)

        wire.parked.removeFirst().resume()
        await first.value
        #expect(wire.prompts == ["first\n[ref a.txt]"])
        #expect(wire.uploads == ["a.txt"], "the second message's file has not gone up yet")

        finishTurn(chat)
        await pump { wire.prompts.count == 2 }
        #expect(wire.prompts == ["first\n[ref a.txt]", "second\n[ref b.txt]"])
        #expect(wire.uploads == ["a.txt", "b.txt"])
        #expect(chat.queue.isEmpty && chat.staged.isEmpty)
        #expect(sentRows(chat) == ["first | a.txt", "second | b.txt"])
    }

    @Test func aMessageQueuedBehindARunningTurnKeepsItsFilesUntilItsTurn() async throws {
        let (chat, wire) = try bench()
        await chat.send("first")
        try #require(chat.isRunning)
        stage(chat, "c.txt")
        await chat.send("with a file")
        stage(chat, "d.txt")
        await chat.send("with another")
        #expect(chat.queue.map(\.attachments).map { $0.map(\.name) } == [["c.txt"], ["d.txt"]])
        #expect(wire.uploads.isEmpty)

        finishTurn(chat)
        await pump { wire.prompts.count == 2 }
        #expect(wire.prompts.last == "with a file\n[ref c.txt]")
        finishTurn(chat)
        await pump { wire.prompts.count == 3 }
        #expect(wire.prompts.last == "with another\n[ref d.txt]")
        #expect(wire.uploads == ["c.txt", "d.txt"])
    }

    @Test func filesStagedDuringAnUploadAreNotWiped() async throws {
        let (chat, wire) = try bench()
        wire.holdNext = 1
        stage(chat, "a.txt")
        let first = Task { await chat.send("first") }
        await pump { wire.parked.count == 1 }
        stage(chat, "later.txt")
        wire.parked.removeFirst().resume()
        await first.value
        #expect(chat.staged.map(\.name) == ["later.txt"])
        #expect(wire.prompts == ["first\n[ref a.txt]"])
    }

    @Test func aFileTheGatewayRefusedStaysStagedForAnotherTry() async throws {
        let (chat, wire) = try bench()
        wire.refused = ["big.txt"]
        stage(chat, "ok.txt", "big.txt")
        await chat.send("here you go")
        #expect(wire.prompts == ["here you go\n[ref ok.txt]"])
        #expect(chat.staged.map(\.name) == ["big.txt"])
        #expect(sentRows(chat) == ["here you go | ok.txt"])
        #expect(chat.items.contains { item in
            if case .error(let text) = item.kind { text.hasPrefix("Attachment big.txt failed") } else { false }
        })

        wire.refused = []
        finishTurn(chat)
        await chat.send("again")
        #expect(wire.prompts.last == "again\n[ref big.txt]")
        #expect(chat.staged.isEmpty)
    }

    @Test func aRefusedFileWithNoWordsSendsNothing() async throws {
        let (chat, wire) = try bench()
        wire.refused = ["big.txt"]
        stage(chat, "big.txt")
        await chat.send("")
        #expect(wire.prompts.isEmpty && !chat.isRunning)
        #expect(chat.staged.map(\.name) == ["big.txt"])
        // The chat is free again: a plain message goes straight out.
        await chat.send("hello")
        #expect(wire.prompts.last == "hello")
    }

    @Test func aMessageQueuedDuringAFailedUploadStillGoesOut() async throws {
        let (chat, wire) = try bench()
        wire.holdNext = 1
        wire.refused = ["big.txt"]
        stage(chat, "big.txt")
        let first = Task { await chat.send("") }
        await pump { wire.parked.count == 1 }
        await chat.send("while you wait")
        #expect(chat.queue.map(\.text) == ["while you wait"])
        wire.parked.removeFirst().resume()
        await first.value
        await pump { !wire.prompts.isEmpty }
        #expect(wire.prompts == ["while you wait"])
    }

    @Test func takingAQueuedMessageBackLeavesNoFileBehind() async throws {
        let (chat, _) = try bench()
        await chat.send("first")
        stage(chat, "gone.txt")
        let file = try #require(chat.staged.first?.localURL)
        await chat.send("queued")
        let queued = try #require(chat.queue.first)
        #expect(FileManager.default.fileExists(atPath: file.path))
        chat.removeQueued(queued.id)
        #expect(chat.queue.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
