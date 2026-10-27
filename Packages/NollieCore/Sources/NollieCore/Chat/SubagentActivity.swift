import Foundation

/// Work the bot handed to a helper. Every `subagent.*` event arrives on the parent's session
/// and carries the helper's id; this row follows one helper from the moment it is asked to
/// start until it reports back.
public struct SubagentActivity: Hashable, Sendable {
    /// Place in a batch started together, counted from 0 as the gateway counts.
    public var taskIndex: Int?
    public var taskCount: Int?
    public var id: String
    public var model: String?
    /// "running" until `subagent.complete` brings its own word (completed, failed, ...).
    public var status: String

    public init(id: String, goal: String, status: String = Self.runningWord, step: String? = .none, model: String? = .none,
                toolCount: Int? = .none, durationSeconds: Double? = .none, summary: String? = .none,
                taskIndex: Int? = .none, taskCount: Int? = .none) {
        self.id = id
        self.goal = goal
        self.status = status
        self.model = model
        self.step = step
        self.toolCount = toolCount
        self.durationSeconds = durationSeconds
        self.summary = summary
        self.taskIndex = taskIndex
        self.taskCount = taskCount
    }

    public static let runningWord = "running"

    public var goal: String
    /// What it came back with.
    public var summary: String?
    public var toolCount: Int?
    /// What it is doing now: the tool in hand, or the tail of its thinking.
    public var step: String?
    public var durationSeconds: Double?

    public var isRunning: Bool { status == Self.runningWord }
    public var failed: Bool { ["failed", "error"].contains(status) }

    /// The small line under the goal: where it is while running, how it went once back.
    public var detailLine: String? {
        var parts = isRunning ? [step ?? String(localized: "Working…", table: "Core")] : outcomeBits
        if let index = taskIndex, let count = taskCount, count > 1 {
            let place = index + 1
            parts.insert(String(localized: "\(place) of \(count)", table: "Core", comment: "A helper's place in a batch: 2 of 3"), at: 0)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var outcomeBits: [String] {
        let outcome: String
        if let secs = durationSeconds, secs > 0, secs >= 60 {
            let minutes = Int((secs / 60).rounded())
            outcome = failed ? String(localized: "Failed in \(minutes)m", table: "Core", comment: "A helper failed after this many minutes")
                : String(localized: "Done in \(minutes)m", table: "Core", comment: "A helper finished in this many minutes")
        } else if let secs = durationSeconds, secs > 0 {
            let seconds = Int(secs.rounded())
            outcome = failed ? String(localized: "Failed in \(seconds)s", table: "Core", comment: "A helper failed after this many seconds")
                : String(localized: "Done in \(seconds)s", table: "Core", comment: "A helper finished in this many seconds")
        } else {
            outcome = failed ? String(localized: "Failed", table: "Core", comment: "A helper's outcome")
                : String(localized: "Done", table: "Core", comment: "A helper's outcome")
        }
        guard let tools = toolCount, tools > 0 else { return [outcome] }
        return [outcome, String(localized: "\(tools) tool calls", table: "Core")]
    }

    private static let idKeys = ["subagent_id", "child_session_id", "delegation_id"]

    /// Row id of the helper named in a payload, when it names one.
    public static func rowID(for payload: JSONValue) -> String? {
        let named = idKeys.lazy.compactMap { payload.text($0) }.first { !$0.isEmpty }
        return named.map { "sub-" + $0 }
    }

    /// Applies a further `subagent.*` event. The first event of any kind creates the row, and each
    /// one after updates it, so tools and progress for the helper are never dropped.
    public static func applying(_ type: String, _ p: JSONValue, to current: SubagentActivity? = nil) -> SubagentActivity {
        var row = current ?? SubagentActivity(id: p.text("subagent_id") ?? p.text("child_session_id") ?? "", goal: String(localized: "Subagent", table: "Core", comment: "A helper's title before its goal is known"))
        row.absorbHeader(of: p)

        switch type {
        case "subagent.tool":
            let tool = p.text("tool_name") ?? "tool"
            let hint = flattened(p.text("tool_preview") ?? "")
            row.step = hint.isEmpty ? tool : "\(tool): \(hint.prefix(120))"
        case "subagent.thinking", "subagent.progress":
            let said = flattened(p.text("text") ?? "")
            if !said.isEmpty { row.step = String(said.suffix(160)) }
        case "subagent.complete":
            row.status = p.text("status") ?? "completed"
            row.step = nil
            row.summary = nonEmpty(p.text("summary")) ?? row.summary
            row.durationSeconds = p["duration_seconds"]?.doubleValue ?? row.durationSeconds
        default:
            break   // a spawn request or a start: the row appearing is the news
        }
        return row
    }

    /// The facts every event may carry, whichever kind it is.
    private mutating func absorbHeader(of p: JSONValue) {
        goal = Self.nonEmpty(p.text("goal")) ?? goal
        model = Self.nonEmpty(p.text("model")) ?? model
        toolCount = p["tool_count"]?.intValue ?? toolCount
        taskIndex = p["task_index"]?.intValue ?? taskIndex
        taskCount = p["task_count"]?.intValue ?? taskCount
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func flattened(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
