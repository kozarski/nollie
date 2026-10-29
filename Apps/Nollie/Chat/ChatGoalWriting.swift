import FoundationModels
import SwiftUI
import NollieCore

// Reading a chat for its goal line: what is collected, how the on-device model is asked, and how
// its reply is trimmed down.

extension ChatGoals {
    private static func isFromPerson(_ item: TranscriptItem) -> Bool {
        if case .user = item.kind { return true }
        return false
    }

    /// Everything since the person's latest message (or the whole chat if they have not written yet).
    private static func currentTurn(_ items: [TranscriptItem]) -> [TranscriptItem] {
        guard let latest = items.lastIndex(where: isFromPerson) else { return items }
        return Array(items[latest...])
    }

    /// Names the running turn by the id of the person's latest message.
    static func turnKey(_ items: [TranscriptItem]) -> String {
        guard let latest = items.last(where: isFromPerson) else { return "start" }
        return latest.id
    }

    /// Tool calls and helper hand-offs in the current turn.
    static func stepCount(_ items: [TranscriptItem]) -> Int {
        var total = 0
        for item in currentTurn(items) {
            switch item.kind {
            case .tool, .subagent: total += 1
            default: break
            }
        }
        return total
    }

    /// What has been gathered so far from one turn, item by item.
    private struct Digest {
        var prompt = ""
        var steps: [String] = []
        var lastReply: String?

        mutating func take(_ kind: TranscriptItem.Kind) {
            switch kind {
            case .user(let text, let attachments):
                let onlyFiles = text.isEmpty && !attachments.isEmpty
                prompt = onlyFiles ? "(sent \(ChatGoals.fileWords(attachments.count)))" : text
            case .steer(let text, _):
                // Steering mid-turn can change what the turn is about.
                guard !text.isEmpty else { return }
                prompt += "\nThen the user added: \(text)"
            case .tool(let act):
                steps.append(ChatGoals.describe(act))
            case .subagent(let helper):
                steps.append("handed a helper this: \(helper.goal.prefix(120))")
            case .assistant(let text, _, _):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lastReply = String(trimmed.suffix(320)) }
            case .system, .error:
                break
            }
        }
    }

    /// Collects what the model reads. Lengths are capped so a long turn stays cheap to read.
    static func input(_ items: [TranscriptItem], earlier: String?) -> Input {
        var digest = Digest()
        currentTurn(items).forEach { digest.take($0.kind) }
        return Input(prompt: String(digest.prompt.prefix(800)),
                     steps: Array(digest.steps.suffix(8)),
                     said: digest.lastReply,
                     earlier: earlier)
    }

    nonisolated fileprivate static func describe(_ act: ToolActivity) -> String {
        let extra = (act.context ?? act.summary ?? "").replacingOccurrences(of: "\n", with: " ")
        guard !extra.isEmpty else { return act.displayName }
        return "\(act.displayName): \(extra.prefix(120))"
    }

    // Goes to the model, so it stays in English.
    nonisolated fileprivate static func fileWords(_ count: Int) -> String {
        count == 1 ? "a file" : "\(count) files"
    }

    // MARK: Asking the model

    @Generable
    struct Line {
        @Guide(description: "A short phrase, three to seven words, naming what the assistant is trying to get done right now. Begin with a verb ending in -ing. Name the task and not the tool. Leave off the period and any quotes.")
        var goal: String
    }

    nonisolated private static let brief = """
        You write a status line for an AI assistant that is busy on something for its user. \
        Say what it is trying to achieve, in plain words that read at a glance. \
        Leave out tool and command names, do not speak to the user, \
        and never say it is working or thinking.
        """

    /// Puts the collected facts into the prompt, one paragraph per kind of fact.
    nonisolated private static func question(for input: Input) -> String {
        var paragraphs: [String] = []
        paragraphs.append("The user asked: " + (input.prompt.isEmpty ? "(nothing typed)" : input.prompt))
        if !input.steps.isEmpty {
            let list = input.steps.map { "- \($0)" }.joined(separator: "\n")
            paragraphs.append("What the assistant has done so far, earliest first:\n" + list)
        }
        if let said = input.said {
            paragraphs.append("The assistant last wrote: \(said)")
        }
        if let earlier = input.earlier {
            paragraphs.append("The status line until now: \(earlier)\nKeep it if it still fits. Change it if the work has moved on.")
        }
        return paragraphs.joined(separator: "\n\n")
    }

    nonisolated static func onDevice(_ input: Input) async -> String? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: brief)
        // If it declines, times out or is busy, the chat simply shows its current step.
        let reply = try? await session.respond(to: question(for: input), generating: Line.self)
        return reply?.content.goal
    }

    // MARK: Tidying

    nonisolated private static let wrappers = CharacterSet(charactersIn: "\"'“”‘’`*")
    nonisolated private static let trailing: Set<Character> = [".", "…", "!", ":", ";", ","]
    nonisolated private static let longest = 64

    /// Fits the model's reply onto one line: first line only, no quotes or trailing punctuation,
    /// a capital letter, and cut at a word if too long.
    nonisolated static func clean(_ raw: String) -> String? {
        guard let firstLine = raw.split(whereSeparator: \.isNewline).first else { return nil }
        var line = String(firstLine)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: wrappers)
        while let end = line.last, trailing.contains(end) { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        guard line.count >= 3 else { return nil }
        if line.count > longest { line = cutAtWord(line) }
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    nonisolated private static func cutAtWord(_ line: String) -> String {
        let head = line.prefix(longest)
        guard let space = head.lastIndex(of: " ") else { return head + "…" }
        return String(head[..<space]) + "…"
    }
}

/// The line under a busy chat. It shows the written goal if there is one, or else the current step
/// ("Running terminal…" for instance).
struct ChatGoalLine: View {
    var storedID: String
    var step: String?
    var font: Font = .subheadline

    var body: some View {
        let goal = ChatGoals.shared.goal(for: storedID)
        let shown = goal ?? step ?? ""
        if !shown.isEmpty {
            HStack(spacing: 4) {
                if goal != nil { Glyph("sparkles", .caption2).accessibilityHidden(true) }
                Text(shown).lineLimit(1)
            }
            .quiet(font, .tint)
            .contentTransition(.opacity)
            .animation(.snappy, value: shown)
            .accessibilityLabel(goal.map { String(localized: "Working on: \($0)") } ?? shown)
        }
    }
}
