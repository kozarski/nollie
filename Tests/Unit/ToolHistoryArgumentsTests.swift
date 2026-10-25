import Foundation
import Testing
import NollieCore

@Suite struct ToolHistoryArgumentsTests {
    private func tool(_ message: TranscriptMessage) throws -> ToolActivity {
        let item = try #require(TranscriptItem.fromHistory(message, index: 0))
        guard case .tool(let activity) = item.kind else {
            throw HistoryError.notATool
        }
        return activity
    }

    private enum HistoryError: Error { case notATool }

    @Test func resumedObjectArgumentsReachTheToolWithoutLosingOtherFields() throws {
        let arguments: JSONValue = .object(["command": "python3 -m pytest tests/test_export.py -q",
                                            "cwd": "~/Projects/exports", "timeout": 30,
                                            "options": .object(["file_path": "/tmp/My File.txt", "capture_after": true])])
        let wire: JSONValue = .object(["role": "tool", "name": "terminal", "text": "3 passed",
                                      "context": "python3 -m pytest…", "row_id": 5, "args": arguments])
        let message = try wire.decode(TranscriptMessage.self)
        let activity = try tool(message)
        let text = try #require(activity.argsText)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == arguments)
        #expect(activity.context == "python3 -m pytest…")
        #expect(activity.resultText == "3 passed")
    }

    @Test func textAliasesKeepExactEscapesThroughBothDecoders() throws {
        let raw = "{\n  \"command\": \"printf \\\"café\\\\path\\\"\\nprintf done\", \"timeout\": 30\n}"
        for key in ["args_text", "argsText", "args", "arguments"] {
            let wire: JSONValue = .object(["role": "tool", "name": "terminal", key: .string(raw)])
            let plain = try JSONDecoder().decode(TranscriptMessage.self, from: JSONEncoder().encode(wire))
            let converted = try wire.decode(TranscriptMessage.self)
            #expect(try tool(plain).argsText == raw)
            #expect(try tool(converted).argsText == raw)
        }
    }

    @Test func explicitArgumentTextWinsOverAnObjectProjection() throws {
        let raw = "{ \"command\": \"echo hello\", \"timeout\": 30 }"
        let wire: JSONValue = .object(["role": "tool", "name": "terminal", "args_text": .string(raw),
                                      "args": .object(["command": "short preview"])])
        #expect(try tool(wire.decode(TranscriptMessage.self)).argsText == raw)
    }

    @Test func olderAndMalformedArgumentRowsStillLoad() throws {
        for value in [JSONValue.null, .bool(false), .number(3)] {
            let row: JSONValue = .object(["role": "tool", "name": "read_file", "text": "File contents", "args": value])
            let activity = try tool(row.decode(TranscriptMessage.self))
            #expect(activity.argsText == nil)
            #expect(activity.resultText == "File contents")
        }
        let old = try JSONDecoder().decode(TranscriptMessage.self, from: Data(#"{"role":"tool","name":"terminal","context":"echo hello","text":"hello"}"#.utf8))
        #expect(try tool(old).argsText == nil)
        #expect(try tool(old).context == "echo hello")
    }

    @Test func cachedToolArgumentsSurviveSaveAndReopen() throws {
        let connection = UUID()
        let raw = #"{"command":"echo hello","cwd":"~/Projects/exports","timeout":30}"#
        let item = TranscriptItem(id: "history-args", kind: .tool(ToolActivity(id: "call", name: "terminal",
            context: "echo hello", argsText: raw, status: .done, resultText: "hello")), rowID: 5)
        defer {
            if let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                try? FileManager.default.removeItem(at: base.appending(path: "transcripts/\(connection.uuidString)"))
            }
        }
        TranscriptCache.save([item], connection: connection, storedID: "tool-arguments")
        TranscriptCache.flush()
        let history = try #require(TranscriptCache.load(connection: connection, storedID: "tool-arguments"))
        #expect(history.count == 1)
        let reloaded = try tool(#require(history.first))
        #expect(reloaded.argsText == raw)
        #expect(reloaded.resultText == "hello")
    }
}
