import Foundation
import Testing
@testable import NollieCore

/// A helper the bot has dispatched: a single row tracks all of its `subagent.*` events, no matter
/// which one comes first.
@Suite struct HelperActivityTests {
    /// The payload of one helper event.
    private func payload(_ helper: String, _ more: [String: JSONValue] = [:]) -> JSONValue {
        var fields: [String: JSONValue] = ["subagent_id": .string(helper)]
        fields.merge(more) { _, new in new }
        return .object(fields)
    }

    private func apply(_ event: String, _ helper: String, _ more: [String: JSONValue] = [:], to row: SubagentActivity? = nil) -> SubagentActivity {
        SubagentActivity.applying("subagent.\(event)", payload(helper, more), to: row)
    }

    @Test func theFirstEventMakesTheRowAndLaterOnesUpdateIt() {
        var row = apply("spawn_requested", "h-1", ["goal": .string("Check the proxy"), "task_index": .number(0), "task_count": .number(2)])
        #expect(row.id == "h-1" && row.goal == "Check the proxy" && row.isRunning)
        #expect(row.detailLine == "1 of 2 · Working…")

        row = apply("start", "h-1", ["goal": .string("Check the proxy"), "model": .string("vendor/model-x")], to: row)
        #expect(row.model == "vendor/model-x" && row.taskCount == 2)

        row = apply("tool", "h-1", ["tool_name": .string("terminal"), "tool_preview": .string("cat /etc/hosts\n"), "tool_count": .number(1)], to: row)
        #expect(row.step == "terminal: cat /etc/hosts" && row.toolCount == 1)

        row = apply("progress", "h-1", ["text": .string("5 hosts listed")], to: row)
        #expect(row.detailLine == "1 of 2 · 5 hosts listed")

        row = apply("complete", "h-1", ["status": .string("completed"), "summary": .string("All fine."), "duration_seconds": .number(7.4), "tool_count": .number(3)], to: row)
        #expect(!row.isRunning && !row.failed && row.step == nil)
        #expect(row.summary == "All fine.")
        #expect(row.detailLine == "1 of 2 · Done in 7s · 3 tool calls")
    }

    @Test func aToolEventAheadOfAnyStartStillMakesARow() {
        let row = apply("tool", "h-7", ["tool_name": .string("read_file")])
        #expect([row.id, row.goal, row.step, row.detailLine] == ["h-7", "Subagent", "read_file", "read_file"])

        let keyed: [(String, JSONValue, String?)] = [
            ("its own id", payload("h-7"), "sub-h-7"),
            ("a child session id", ["child_session_id": .string("kid-2")], "sub-kid-2"),
            ("nothing to key on", ["goal": .string("nothing to key on")], nil),
        ]
        for (what, event, expected) in keyed { #expect(SubagentActivity.rowID(for: event) == expected, "\(what)") }
    }

    @Test func aFailureIsSaidAndLongRunsAreCountedInMinutes() {
        let waiting = SubagentActivity(id: "h-3", goal: "Read logs")
        let failed = apply("complete", "h-3", ["status": .string("failed"), "duration_seconds": .number(80)], to: waiting)
        #expect(failed.failed)
        #expect(failed.detailLine == "Failed in 1m")
    }
}

/// What a finished helper hands back arrives as a user message; it is shown as a note.
@Suite struct HelperReportNoteTests {
    @Test func reportsBecomeNotesNotBubbles() {
        let batchReport = "[ASYNC DELEGATION BATCH COMPLETE — d-4]\n\nTask 1 of 2: completed in 7.4s."
        let note = InjectedNote.parse(batchReport)
        #expect(note?.title == "Subagents reported back")
        #expect(note.map { $0.body.hasPrefix("[ASYNC DELEGATION BATCH COMPLETE") } == true)

        let others: [(String, String)] = [
            ("[ASYNC DELEGATION COMPLETE — h-1]\nFinished.", "Subagent reported back"),
            ("[ASYNC DELEGATION TASK FAILED — h-2]\nGave up.", "Subagent failed"),
            ("[async delegation batch complete — z] a failed test is mentioned", "Subagents reported back"),
        ]
        for (message, title) in others { #expect(InjectedNote.parse(message)?.title == title, "\(message)") }
    }

    @Test(arguments: ["Could you look at the async delegation notes?", "[ASYNC] just a label"])
    func peoplesOwnWordsAboutDelegationStayTheirs(words: String) {
        #expect(InjectedNote.parse(words) == nil)
    }
}
