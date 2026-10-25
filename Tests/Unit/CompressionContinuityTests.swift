import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// The main chat carries on through Hermes's compression. An open chat follows the stored
/// session Hermes moves it to, and Hermes's own compression lines become one quiet row that
/// never suggests starting over.
@MainActor @Suite struct CompressionContinuityTests {
    private func openChat(stored: String? = "stored-before") throws -> ChatSession {
        try ChatFixtures.chat(stored: stored, named: "compression")
    }

    private func incoming(_ type: String, _ fields: [String: JSONValue] = [:]) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "s1", payload: .object(fields))
    }

    private func status(_ kind: String, _ text: String) -> GatewayEvent {
        incoming("status.update", ["kind": .string(kind), "text": .string(text)])
    }

    private func systemRows(_ chat: ChatSession) -> [String] {
        chat.items.compactMap { if case .system(let text, _) = $0.kind { return text } else { return nil } }
    }

    private let fullWarning = "⚠️  Session compressed 3 times — accuracy may degrade. Consider /new to start fresh."

    @Test func anOpenChatFollowsTheSessionHermesMovesItTo() throws {
        let chat = try openChat()
        chat.handle(event: incoming("session.info", ["stored_session_id": .string("stored-after"), "title": .string("Main chat")]))
        #expect(chat.storedID == "stored-after")
        #expect(chat.formerStoredIDs == ["stored-before"])

        var registry = ChatRegistry<ChatSession>()
        registry.add(chat)
        #expect(registry.byStored("stored-after") === chat)
        #expect(registry.byStored("stored-before") === chat, "links made before the move still find it")
        #expect(registry.byStored("unrelated") == nil)
    }

    @Test func theSameBlankOrMissingIDChangesNothing() throws {
        let chat = try openChat()
        chat.handle(event: incoming("session.info", ["stored_session_id": .string("stored-before")]))
        chat.handle(event: incoming("session.info", ["stored_session_id": .string("")]))
        chat.handle(event: incoming("session.info", ["title": .string("No id in this one")]))
        #expect(chat.storedID == "stored-before")
        #expect(chat.formerStoredIDs.isEmpty)
    }

    @Test func compressingMakesOneQuietRowAndNeverAdvisesAFreshStart() throws {
        let chat = try openChat()
        status("compacting", "🗜️ Compacting context — summarizing earlier conversation so I can continue...").applied(to: chat)
        status("compacting", "🗜️ Compacting context — still summarizing earlier conversation so I can continue...").applied(to: chat)
        #expect(systemRows(chat) == [CompressionNotice.summarizedRow])
        #expect(chat.statusLine == CompressionNotice.summarizingLine)

        status("lifecycle", fullWarning).applied(to: chat)
        #expect(chat.statusLine == CompressionNotice.summarizingLine, "the warning does not replace the status")

        status("compacted", "✓ Context compaction complete — continuing turn...").applied(to: chat)
        #expect(chat.statusLine != CompressionNotice.summarizingLine)
        #expect(systemRows(chat).allSatisfy { !$0.contains("/new") && !$0.contains("Compacting") })
    }

    @Test func theRowSitsAboveARepliesThatHasNotBegun() throws {
        let chat = try openChat()
        chat.handle(event: incoming("message.start"))
        status("compacting", "Compacting context").applied(to: chat)
        let index = chat.items.lastIndex { item in
            if case .system(let text, _) = item.kind { return text == CompressionNotice.summarizedRow } else { return false }
        }
        let found = try #require(index)
        #expect(found < chat.items.count - 1, "above the reply's own row")
    }

    @Test func aFinishedTurnsCompressionWarningIsNotShownAsABanner() throws {
        let chat = try openChat()
        chat.handle(event: incoming("message.complete", ["text": .string("Done."), "warning": .string(fullWarning)]))
        #expect(chat.banner == nil)
        chat.handle(event: incoming("message.complete", ["text": .string("Done."), "warning": .string("The provider is slow today.")]))
        #expect(chat.banner == "The provider is slow today.", "other warnings still show")
    }

    @Test func noticesAreSortedByWhatTheyMean() {
        #expect(CompressionNotice.read(kind: "compacting", text: "") == .summarizing)
        #expect(CompressionNotice.read(kind: "lifecycle", text: "🗜️ Compacting context — summarizing") == .summarizing)
        #expect(CompressionNotice.read(kind: "compacted", text: "✓ Context compaction complete — continuing turn...") == .finished)
        #expect(CompressionNotice.read(kind: "lifecycle", text: "Session compressed 4 times. Consider /new") == .hidden)
        #expect(CompressionNotice.read(kind: "lifecycle", text: "Thinking…") == nil)
        #expect(!CompressionNotice.summarizedRow.contains("—") && !CompressionNotice.summarizingLine.contains("—"))
    }
}

private extension GatewayEvent {
    /// Hands the event to a chat; reads better in a list of steps.
    @MainActor func applied(to chat: ChatSession) { chat.handle(event: self) }
}
