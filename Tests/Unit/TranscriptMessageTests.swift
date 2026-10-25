import Foundation
import Testing
@testable import NollieCore

/// Transcript rows arrive in two shapes and are cached in a third.
@Suite struct TranscriptMessageTests {
    @Test func theSocketsHistoryRowDecodesFlat() throws {
        let row = JSONValue.object(["role": "assistant", "text": "hi", "timestamp": 1_700_000_000, "row_id": 7, "reasoning": "why"])
        let message = try row.decode(TranscriptMessage.self)
        #expect(message.role == "assistant")
        #expect(message.text == "hi")
        #expect(message.rowId == 7)
        #expect(message.reasoning == "why")
        #expect(message.timestamp == 1_700_000_000)
    }

    /// The REST route returns the stored row with content parts, `id`, an ISO timestamp and tool calls.
    @Test func aStoredRowFromRESTDecodesFromItsParts() throws {
        let row = JSONValue.object([
            "role": "assistant", "id": 42, "timestamp": "2026-09-23T06:04:11.123456",
            "content": .array([.object(["type": "text", "text": "first"]), .object(["type": "text", "text": "second"])]),
            "tool_calls": .array([.object(["id": "c1", "function": .object(["name": "terminal", "arguments": "{}"])])]),
        ])
        let message = try row.decode(TranscriptMessage.self)
        #expect(message.text == "first\nsecond")
        #expect(message.rowId == 42)
        #expect(message.name == "terminal")
        #expect(message.timestamp != nil)
        let simpleRow: JSONValue = ["id": 1, "role": "user", "content": "plain"]
        let plain = try simpleRow.decode(TranscriptMessage.self)
        #expect(plain.text == "plain")
        #expect(plain.role == "user")
        #expect(TranscriptItem.fromHistory(plain, index: 0) != nil)
    }

    @Test func theCacheEncodingRoundTrips() throws {
        var kept = TranscriptMessage(role: "tool", text: "out", timestamp: 5)
        kept.rowId = 3
        kept.name = "grep"
        kept.context = "-r foo"
        let stored = try JSONEncoder().encode([kept])
        #expect(try JSONDecoder().decode([TranscriptMessage].self, from: stored) == [kept])
    }
}
