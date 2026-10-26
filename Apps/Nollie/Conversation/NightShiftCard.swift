import SwiftUI
import NollieCore

/// What the person tapped on a post. Turn on and Keep off go to the add-on through the engine; Share and Show all
/// stay on this device, with the screen.
enum ConversationPostTap: Equatable {
    case turnOn
    case keepOff
    case share
    /// Shows all of a run's actions, or the first few again.
    case showAll(String)
}

/// A post in the thread: the morning's night shift card or a rehearsal's report. Cells are recycled and measured
/// in bare hosts, so the cards hold no state of their own: what they show comes in with the post, and what is
/// open (`expanded`) comes from the screen.
struct ConversationPostView: View {
    let post: ConversationPost
    let expanded: Set<String>
    let tap: (ConversationPostTap) -> Void

    var body: some View {
        switch post.kind {
        case .nightShift(let card):
            NightShiftCard(card: card, expanded: expanded, tap: tap)
        case .rehearsal(let card):
            RehearsalCard(card: card, pending: post.pending, problem: post.problem, tap: tap)
        }
    }
}

/// What unattended runs did overnight: each run with its first actions and the receipt for each, and a round
/// Share button in the corner.
struct NightShiftCard: View {
    let card: ConversationPost.NightShift
    let expanded: Set<String>
    let tap: (ConversationPostTap) -> Void

    /// Actions a run shows before Show all.
    static let firstActions = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                NightShiftHeading(window: card.from.map { NightShiftWords.since($0) })
                Spacer(minLength: 0)
                Button { tap(.share) } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NightShiftInk.text)
                        .frame(width: 40, height: 40)
                        .background(NightShiftInk.control, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share a picture of this card")
                .accessibilityIdentifier("post.nightShift.share")
            }
            Text(NightShiftWords.counts(card.counts)).font(Ink.cardBody).foregroundStyle(NightShiftInk.text)
            if let asleep = SleepNote.line(for: card) {
                Text(asleep).font(Ink.cardBody).foregroundStyle(NightShiftInk.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("post.nightShift.sleep")
            }
            if !card.unwatched.isEmpty {
                Text(NightShiftWords.unwatched(card.unwatched)).font(Ink.cardBody).foregroundStyle(NightShiftInk.warning)
            }
            ForEach(card.runs) { run in
                NightShiftRunView(run: run, open: expanded.contains(run.id)) { tap(.showAll(run.id)) }
            }
            ForEach(card.missed, id: \.self) { missed in
                PostBotLine(bot: missed.bot, title: missed.title.isEmpty ? "Schedule" : missed.title,
                            detail: NightShiftWords.missedLine(missed), colors: .night)
                    .accessibilityIdentifier("post.nightShift.missed.\(missed.jobId)")
            }
            if card.moreRuns > 0 {
                Text(NightShiftWords.moreRuns(card.moreRuns)).font(Ink.stamp).foregroundStyle(NightShiftInk.detail)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            NightShiftSky().clipShape(.rect(cornerRadius: Ink.cardRadius, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("post.nightShift")
    }
}

/// One run on the card: the bot's face, the run's title, outcome and time, then its actions.
private struct NightShiftRunView: View {
    let run: ConversationPost.Run
    let open: Bool
    let showAll: () -> Void

    var body: some View {
        let shown = open ? run.actions : Array(run.actions.prefix(NightShiftCard.firstActions))
        VStack(alignment: .leading, spacing: 10) {
            PostBotLine(bot: run.bot, title: NightShiftWords.title(of: run), detail: NightShiftWords.runLine(run), colors: .night)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, action in
                PostActionLine(verb: NightShiftWords.verb(action), target: action.target,
                               receipt: NightShiftWords.receipt(action, in: run), warn: action.status == .blocked, colors: .night)
                    .padding(.leading, PostBotLine.indent)
            }
            if open, run.more > 0 {
                Text("\(run.more) more not listed").font(Ink.stamp).foregroundStyle(NightShiftInk.detail)
                    .padding(.leading, PostBotLine.indent)
            }
            if run.actions.count > NightShiftCard.firstActions {
                Button(action: showAll) {
                    Text(open ? "Show fewer" : "Show all")
                        .font(Ink.chip)
                        .foregroundStyle(NightShiftInk.text)
                        .padding(.horizontal, 10)
                        .background {
                            Capsule().fill(NightShiftInk.control).padding(.vertical, -4)
                        }
                }
                .buttonStyle(.plain)
                .padding(.leading, PostBotLine.indent)
                .accessibilityLabel(open ? "Show fewer of \(NightShiftWords.title(of: run))" : "Show all of \(NightShiftWords.title(of: run))")
                .accessibilityIdentifier("post.nightShift.showAll.\(run.id)")
            }
        }
    }
}

/// Rehearsals keep the usual ink; the night shift opts into its sky colours.
struct PostColors {
    var text = Ink.text
    var detail = Ink.text3
    var code = Ink.codeText
    var warning = Ink.warnText

    static let night = PostColors(text: NightShiftInk.text, detail: NightShiftInk.detail,
                                  code: NightShiftInk.detail, warning: NightShiftInk.warning)
}

/// A bot's face beside a title and a quiet line under it.
struct PostBotLine: View {
    let bot: String
    let title: String
    let detail: String
    var colors = PostColors()

    static let face: CGFloat = 30
    /// Lines under it start at its words.
    static let indent: CGFloat = face + 10

    var body: some View {
        HStack(spacing: 10) {
            BotAvatar(profile: bot, size: Self.face)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Ink.cardBody.weight(.semibold)).foregroundStyle(colors.text)
                Text(detail).font(Ink.stamp).foregroundStyle(colors.detail)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One action: its verb, what it acted on in code type, and the receipt words under it. VoiceOver reads it as one
/// sentence.
struct PostActionLine: View {
    let verb: String
    let target: String
    let receipt: String?
    var warn = false
    /// What VoiceOver reads, when the verb alone would not say it.
    var label: String? = nil
    var colors = PostColors()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if target.isEmpty {
                Text(verb).font(Ink.cardBody).foregroundStyle(colors.text)
            } else if verb.isEmpty {
                Text(target).font(Ink.code11).foregroundStyle(colors.code)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(Text(verb).foregroundStyle(colors.text)) \(Text(target).font(Ink.code11).foregroundStyle(colors.code))")
                    .font(Ink.cardBody)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let receipt {
                Text(receipt).font(Ink.stamp).foregroundStyle(warn ? colors.warning : colors.detail)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? NightShiftWords.sentence(verb: verb, target: target, receipt: receipt))
    }
}

/// The cards' words, shared with the picture made to share.
enum NightShiftWords {
    /// "Since 7:02 yesterday".
    static func since(_ from: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = from.formatted(.dateTime.hour().minute())
        if calendar.isDate(from, inSameDayAs: now) { return "Since \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(from, inSameDayAs: yesterday) {
            return "Since \(time) yesterday"
        }
        return "Since \(from.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    /// "2 runs · 5 actions · 1 stopped", or the quiet night's line.
    static func counts(_ counts: ConversationPost.Counts) -> String {
        guard counts.runs > 0 else { return "Quiet night. Nothing ran." }
        var parts = [plural(counts.runs, "run"), plural(counts.actions, "action")]
        if counts.held > 0 { parts.append("\(counts.held) held") }
        if counts.stopped > 0 { parts.append("\(counts.stopped) stopped") }
        if counts.unrecorded > 0 { parts.append("\(counts.unrecorded) not recorded") }
        return parts.joined(separator: " · ")
    }

    static func unwatched(_ bots: [String]) -> String { "Not watched: " + bots.joined(separator: ", ") }

    /// Runs the add-on left off a busy night's card.
    static func moreRuns(_ count: Int) -> String { "\(plural(count, "more run")) not listed" }

    static func title(of run: ConversationPost.Run) -> String {
        if !run.title.isEmpty { return run.title }
        switch run.kind {
        case "board": return "Board task"
        case "helper": return "Helper"
        case "rehearsal": return "Rehearsal"
        default: return "Schedule"
        }
    }

    /// "Nollie · Done · 3:10 AM", and for a run that waited for the Mac, when it was due: "· Due 2:00 AM".
    static func runLine(_ run: ConversationPost.Run) -> String {
        var parts = [run.botName.isEmpty ? ProfileInfo.shownName(of: run.bot) : run.botName]
        if let outcome = run.outcome { parts.append(outcomeWords(outcome)) }
        if let at = run.finishedAt ?? run.startedAt { parts.append(at.formatted(.dateTime.hour().minute())) }
        if run.late, let due = run.dueAt { parts.append("Due \(due.formatted(.dateTime.hour().minute()))") }
        return parts.joined(separator: " · ")
    }

    /// A schedule that never ran for some of its times: "Scout · Didn't run 3 times · 2:00 AM to 4:00 AM".
    static func missedLine(_ missed: ConversationPost.Missed) -> String {
        var parts = [missed.botName.isEmpty ? ProfileInfo.shownName(of: missed.bot) : missed.botName,
                     missed.count == 1 ? "Didn't run" : "Didn't run \(missed.count) times"]
        let time = { (date: Date) in date.formatted(.dateTime.hour().minute()) }
        switch (missed.firstDue, missed.lastDue) {
        case let (first?, last?) where missed.count > 1 && last > first: parts.append("\(time(first)) to \(time(last))")
        case let (first?, _): parts.append("Due \(time(first))")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    static func outcomeWords(_ outcome: ConversationPost.Outcome) -> String {
        switch outcome {
        case .done: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .skipped: "Skipped"
        case .rehearsal: "Rehearsal"
        }
    }

    /// The tool's short verb: what was done ("Ran"), or for a stopped call what was tried ("Tried to run"). None for
    /// an Ask first hold: its target already starts with its own verb ("Send with gmail: send email").
    static func verb(_ action: ConversationPost.Action) -> String {
        if heldByAskFirst(action), !action.target.isEmpty { return "" }
        let (done, notDone) = verbs(action.tool, target: action.target)
        return action.status == .blocked ? "Tried to " + notDone.lowercased() : done
    }

    /// A tool's verb as done and as not done ("Ran", "Run"), to go before `target` when there is one. A verb that
    /// already names what it acted on joins its target with "for" ("Used the screen for click").
    static func verbs(_ tool: String, target: String = "") -> (String, String) {
        let (done, notDone) = plainVerbs(tool)
        guard !target.isEmpty, done == "Used the screen" else { return (done, notDone) }
        return (done + " for", notDone + " for")
    }

    private static func plainVerbs(_ tool: String) -> (String, String) {
        if tool.hasPrefix("mcp__cua_recorder__") || tool.hasPrefix("mcp__nollie_mac__") { return ("Used the screen", "Use the screen") }
        switch tool {
        case "terminal", "shell", "bash", "execute_code", "process": return ("Ran", "Run")
        case "write_file", "patch": return ("Wrote", "Write")
        case "web_search", "search_files", "session_search", "search": return ("Searched", "Search")
        case "read_file", "web_extract", "vision_analyze", "browser_snapshot", "browser_get_images", "browser_console",
             "skill_view", "skills_list":
            return ("Looked at", "Look at")
        case "send_message": return ("Sent", "Send")
        case "computer_use": return ("Used the screen", "Use the screen")
        case "todo": return ("Noted", "Note")
        case "cronjob", "cronjob_manage": return ("Scheduled", "Schedule")
        case "delegate_task": return ("Handed off", "Hand off")
        case "memory": return ("Remembered", "Remember")
        default:
            if tool.hasPrefix("browser_") { return ("Browsed", "Browse") }
            let name = tool.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "_", with: " ")
            return ("Used \(name)", "Use \(name)")
        }
    }

    /// Why an action was allowed, or what stopped it, in the card's words. A failed action says so after it.
    static func receipt(_ action: ConversationPost.Action, in run: ConversationPost.Run) -> String {
        let words: String
        switch action.receipt?.kind {
        case .tool: words = run.kind == "board" ? "Part of this task's tools" : "Part of this schedule's tools"
        case .safe: words = "Not a risky command"
        case .allowlist: words = "On your allow list"
        case .always:
            if let at = action.receipt?.grantedAt {
                words = "You chose Always for this on \(at.formatted(.dateTime.month(.abbreviated).day()))"
            } else {
                words = "You chose Always for this"
            }
        case .held: words = action.receipt?.detail == "ask_first" ? "Held: needs your yes" : "Held for you"
        case .blocked: words = stopped(action.receipt?.detail)
        case .unknown: words = "Allowed. Reason not recorded"
        case nil: words = action.status == .blocked ? "Stopped" : "Allowed. Reason not recorded"
        }
        guard action.status == .failed, action.receipt?.kind != .blocked else { return words }
        return words + " · It failed"
    }

    /// Held by Ask first: it waits for a yes every time, and its target is the plain words a card would use.
    static func heldByAskFirst(_ action: ConversationPost.Action) -> Bool {
        action.receipt?.kind == .held && action.receipt?.detail == "ask_first"
    }

    static func stopped(_ detail: String?) -> String {
        switch detail ?? "" {
        case "mac": "Stopped: schedules never use your Mac's screen"
        case "risky": "Stopped: a risky command needs your OK"
        case "deny_rule": "Stopped: one of your rules says no"
        case "hardline": "Stopped: this is never allowed"
        case "plugin": "Stopped: schedules never change Nollie's own files"
        default: "Stopped"
        }
    }

    /// One sentence for VoiceOver: "Ran df -h. Not a risky command."
    static func sentence(verb: String, target: String, receipt: String?) -> String {
        let action = target.isEmpty ? verb : verb.isEmpty ? target : "\(verb) \(target)"
        guard let receipt else { return action + "." }
        return "\(action). \(receipt)."
    }

    private static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }
}
