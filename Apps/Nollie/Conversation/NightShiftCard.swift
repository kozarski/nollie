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
    /// Opens or closes the answer to "Why?" on one entry (`NightShiftWhy.key`).
    case why(String)
}

/// A post in the thread: the morning's night shift card or a rehearsal's report. Cells are recycled and measured
/// in bare hosts, so the cards hold no state of their own: what they show comes in with the post, and what is
/// open (`expanded`: runs shown whole, and entries whose Why is open) comes from the screen.
struct ConversationPostView: View {
    let post: ConversationPost
    let expanded: Set<String>
    let tap: (ConversationPostTap) -> Void

    var body: some View {
        switch post.kind {
        case .nightShift(let card):
            NightShiftCard(card: card, expanded: expanded, tap: tap)
        case .rehearsal(let card):
            RehearsalCard(card: card, pending: post.pending, problem: post.problem, expanded: expanded, tap: tap)
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
                NightShiftRunView(run: run, open: expanded.contains(run.id), expanded: expanded, tap: tap)
            }
            ForEach(card.missed, id: \.self) { missed in
                PostBotLine(bot: missed.bot, title: missed.title.isEmpty ? NightShiftWords.untitledSchedule : missed.title,
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
    /// Entries whose Why is open, among others.
    let expanded: Set<String>
    let tap: (ConversationPostTap) -> Void

    var body: some View {
        let shown = open ? run.actions : Array(run.actions.prefix(NightShiftCard.firstActions))
        VStack(alignment: .leading, spacing: 10) {
            PostBotLine(bot: run.bot, title: NightShiftWords.title(of: run), detail: NightShiftWords.runLine(run), colors: .night)
            ForEach(Array(shown.enumerated()), id: \.offset) { index, action in
                let key = NightShiftWhy.key(run: run.id, index: index)
                PostActionLine(verb: NightShiftWords.verb(action), target: action.target,
                               receipt: NightShiftWords.receipt(action, in: run), warn: action.status == .blocked, colors: .night,
                               why: NightShiftWhy.explain(action, in: run), whyOpen: expanded.contains(key),
                               whyID: "post.nightShift.why.\(run.id).\(index)") { tap(.why(key)) }
                    .padding(.leading, PostBotLine.indent)
            }
            if open, run.more > 0 {
                Text("\(run.more) more not listed").font(Ink.stamp).foregroundStyle(NightShiftInk.detail)
                    .padding(.leading, PostBotLine.indent)
            }
            if run.actions.count > NightShiftCard.firstActions {
                Button { tap(.showAll(run.id)) } label: {
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
    /// The sky is dark in light mode too, so the glass on it is drawn dark.
    var scheme: ColorScheme? = nil

    static let night = PostColors(text: NightShiftInk.text, detail: NightShiftInk.detail,
                                  code: NightShiftInk.detail, warning: NightShiftInk.warning, scheme: .dark)
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
/// sentence. With `why`, a small glass Why? sits beside it and opens the answer under it.
struct PostActionLine: View {
    let verb: String
    let target: String
    let receipt: String?
    var warn = false
    /// What VoiceOver reads, when the verb alone would not say it.
    var label: String? = nil
    var colors = PostColors()
    var why: String? = nil
    var whyOpen = false
    var whyID: String? = nil
    var whyTap: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let why, let whyTap {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    line.frame(maxWidth: .infinity, alignment: .leading)
                    WhyButton(open: whyOpen, tint: colors.text, action: whyTap)
                        .modifier(SchemeIfSet(scheme: colors.scheme))
                        .accessibilityIdentifier(whyID ?? "post.why")
                }
                if whyOpen {
                    WhyNote(text: why, colors: colors)
                        .accessibilityIdentifier((whyID ?? "post.why") + ".text")
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: whyOpen)
        } else {
            line
        }
    }

    private var line: some View {
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

/// Draws a view in a fixed light or dark, when the colours under it need one.
private struct SchemeIfSet: ViewModifier {
    let scheme: ColorScheme?

    func body(content: Content) -> some View {
        if let scheme { content.environment(\.colorScheme, scheme) } else { content }
    }
}

/// The cards' words, shared with the picture made to share.
enum NightShiftWords {
    /// "Since 7:02 yesterday".
    static func since(_ from: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = from.formatted(.dateTime.hour().minute())
        if calendar.isDate(from, inSameDayAs: now) { return String(localized: "Since \(time)", comment: "%@ is a time today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(from, inSameDayAs: yesterday) {
            return String(localized: "Since \(time) yesterday", comment: "%@ is a time")
        }
        return String(localized: "Since \(from.formatted(.dateTime.weekday(.abbreviated).hour().minute()))",
                      comment: "%@ is a day and a time")
    }

    /// "2 runs · 5 actions · 1 stopped", or the quiet night's line.
    static func counts(_ counts: ConversationPost.Counts) -> String {
        guard counts.runs > 0 else { return String(localized: "Quiet night. Nothing ran.") }
        var parts = [String(localized: "\(counts.runs) runs", comment: "Night shift: how many schedules ran"),
                     String(localized: "\(counts.actions) actions", comment: "Night shift: how many things the runs did")]
        if counts.held > 0 { parts.append(String(localized: "\(counts.held) held", comment: "Night shift: actions held for your yes")) }
        if counts.stopped > 0 { parts.append(String(localized: "\(counts.stopped) stopped", comment: "Night shift: actions that were stopped")) }
        if counts.unrecorded > 0 {
            parts.append(String(localized: "\(counts.unrecorded) not recorded", comment: "Night shift: actions with no receipt"))
        }
        return parts.joined(separator: " · ")
    }

    static func unwatched(_ bots: [String]) -> String {
        String(localized: "Not watched: \(bots.joined(separator: ", "))", comment: "%@ is a list of bot names")
    }

    /// Runs the add-on left off a busy night's card.
    static func moreRuns(_ count: Int) -> String { String(localized: "\(count) more runs not listed") }

    /// A run or a missed schedule with no title of its own.
    static let untitledSchedule = String(localized: "Schedule", comment: "Noun: a scheduled job with no name")

    static func title(of run: ConversationPost.Run) -> String {
        if !run.title.isEmpty { return run.title }
        switch run.kind {
        case "board": return String(localized: "Board task")
        case "helper": return String(localized: "Helper", comment: "Noun: a helper bot")
        case "rehearsal": return String(localized: "Rehearsal", comment: "Noun: a schedule's practice run")
        default: return untitledSchedule
        }
    }

    /// "Nollie · Done · 3:10 AM", and for a run that waited for the Mac, when it was due: "· Due 2:00 AM".
    static func runLine(_ run: ConversationPost.Run) -> String {
        var parts = [run.botName.isEmpty ? ProfileInfo.shownName(of: run.bot) : run.botName]
        if let outcome = run.outcome { parts.append(outcomeWords(outcome)) }
        if let at = run.finishedAt ?? run.startedAt { parts.append(at.formatted(.dateTime.hour().minute())) }
        if run.late, let due = run.dueAt {
            parts.append(String(localized: "Due \(due.formatted(.dateTime.hour().minute()))", comment: "%@ is a time"))
        }
        return parts.joined(separator: " · ")
    }

    /// A schedule that never ran for some of its times: "Scout · Didn't run 3 times · 2:00 AM to 4:00 AM".
    static func missedLine(_ missed: ConversationPost.Missed) -> String {
        var parts = [missed.botName.isEmpty ? ProfileInfo.shownName(of: missed.bot) : missed.botName,
                     String(localized: "Didn't run \(missed.count) times")]
        let time = { (date: Date) in date.formatted(.dateTime.hour().minute()) }
        switch (missed.firstDue, missed.lastDue) {
        case let (first?, last?) where missed.count > 1 && last > first:
            parts.append(String(localized: "\(time(first)) to \(time(last))", comment: "A range of two times"))
        case let (first?, _): parts.append(String(localized: "Due \(time(first))", comment: "%@ is a time"))
        default: break
        }
        return parts.joined(separator: " · ")
    }

    static func outcomeWords(_ outcome: ConversationPost.Outcome) -> String {
        switch outcome {
        case .done: String(localized: "Done", comment: "How a run ended")
        case .failed: String(localized: "Failed", comment: "How a run ended")
        case .stopped: String(localized: "Stopped", comment: "How a run ended")
        case .skipped: String(localized: "Skipped", comment: "How a run ended")
        case .rehearsal: String(localized: "Rehearsal", comment: "Noun: a schedule's practice run")
        }
    }

    /// The tool's short verb: what was done ("Ran"), or for a stopped call what was tried ("Tried to run"). None for
    /// an Ask first hold: its target already starts with its own verb ("Send with gmail: send email").
    static func verb(_ action: ConversationPost.Action) -> String {
        if heldByAskFirst(action), !action.target.isEmpty { return "" }
        let words = toolWords(action.tool, target: action.target)
        return action.status == .blocked ? words.tried : words.done
    }

    /// A tool's verb as done and as not done ("Ran", "Run"), to go before `target` when there is one. A verb that
    /// already names what it acted on joins its target with "for" ("Used the screen for click").
    static func verbs(_ tool: String, target: String = "") -> (String, String) {
        let words = toolWords(tool, target: target)
        return (words.done, words.notDone)
    }

    /// For VoiceOver on a rehearsal: "Would have: run".
    static func wouldHave(_ tool: String, target: String = "") -> String {
        toolWords(tool, target: target).wouldHave
    }

    /// What a look is called; under "Looked at" in a rehearsal it needs no verb of its own.
    static let lookedAt = String(localized: "Looked at", comment: "Past tense verb before what was looked at")

    /// A tool's verb in each form the cards use: done ("Ran"), not done ("Run"), tried ("Tried to run") and, for a
    /// rehearsal, would have ("Would have: run"). Each is a whole phrase, since languages build these differently.
    struct ToolWords: Equatable {
        var done: String
        var notDone: String
        var tried: String
        var wouldHave: String
    }

    static func toolWords(_ tool: String, target: String = "") -> ToolWords {
        let screen = tool.hasPrefix("mcp__cua_recorder__") || tool.hasPrefix("mcp__nollie_mac__") || tool == "computer_use"
        if screen {
            if target.isEmpty {
                return ToolWords(done: String(localized: "Used the screen"), notDone: String(localized: "Use the screen"),
                                 tried: String(localized: "Tried to use the screen"),
                                 wouldHave: String(localized: "Would have: use the screen"))
            }
            return ToolWords(done: String(localized: "Used the screen for", comment: "Before what was done on the screen, like click"),
                             notDone: String(localized: "Use the screen for", comment: "Before what is done on the screen, like click"),
                             tried: String(localized: "Tried to use the screen for", comment: "Before what was tried on the screen, like click"),
                             wouldHave: String(localized: "Would have: use the screen for", comment: "Before what would have been done on the screen"))
        }
        switch tool {
        case "terminal", "shell", "bash", "execute_code", "process":
            return ToolWords(done: String(localized: "Ran", comment: "Past tense verb before a command"),
                             notDone: String(localized: "Run", comment: "Verb before a command"),
                             tried: String(localized: "Tried to run", comment: "Before a command"),
                             wouldHave: String(localized: "Would have: run", comment: "Before a command"))
        case "write_file", "patch":
            return ToolWords(done: String(localized: "Wrote", comment: "Past tense verb before a file name"),
                             notDone: String(localized: "Write", comment: "Verb before a file name"),
                             tried: String(localized: "Tried to write", comment: "Before a file name"),
                             wouldHave: String(localized: "Would have: write", comment: "Before a file name"))
        case "web_search", "search_files", "session_search", "search":
            return ToolWords(done: String(localized: "Searched", comment: "Past tense verb before what was searched for"),
                             notDone: String(localized: "Search", comment: "Verb before what to search for"),
                             tried: String(localized: "Tried to search", comment: "Before what was searched for"),
                             wouldHave: String(localized: "Would have: search", comment: "Before what would have been searched for"))
        case "read_file", "web_extract", "vision_analyze", "browser_snapshot", "browser_get_images", "browser_console",
             "skill_view", "skills_list":
            return ToolWords(done: lookedAt,
                             notDone: String(localized: "Look at", comment: "Verb before what to look at"),
                             tried: String(localized: "Tried to look at", comment: "Before what was looked at"),
                             wouldHave: String(localized: "Would have: look at", comment: "Before what would have been looked at"))
        case "send_message":
            return ToolWords(done: String(localized: "Sent", comment: "Past tense verb before what was sent"),
                             notDone: String(localized: "Send", comment: "Verb before what to send"),
                             tried: String(localized: "Tried to send", comment: "Safety: before what was not sent"),
                             wouldHave: String(localized: "Would have: send", comment: "Safety: before what was not sent"))
        case "todo":
            return ToolWords(done: String(localized: "Noted", comment: "Past tense verb before a to-do"),
                             notDone: String(localized: "Note", comment: "Verb before a to-do"),
                             tried: String(localized: "Tried to note", comment: "Before a to-do"),
                             wouldHave: String(localized: "Would have: note", comment: "Before a to-do"))
        case "cronjob", "cronjob_manage":
            return ToolWords(done: String(localized: "Scheduled", comment: "Past tense verb before a schedule's name"),
                             // Its own key: the noun "Schedule" is translated apart from the verb.
                             notDone: String(localized: "Schedule (verb)", defaultValue: "Schedule",
                                             comment: "Verb before a schedule's name, set up a schedule"),
                             tried: String(localized: "Tried to schedule", comment: "Before a schedule's name"),
                             wouldHave: String(localized: "Would have: schedule", comment: "Before a schedule's name"))
        case "delegate_task":
            return ToolWords(done: String(localized: "Handed off", comment: "Past tense verb before a task given to another bot"),
                             notDone: String(localized: "Hand off", comment: "Verb before a task to give to another bot"),
                             tried: String(localized: "Tried to hand off", comment: "Before a task given to another bot"),
                             wouldHave: String(localized: "Would have: hand off", comment: "Before a task given to another bot"))
        case "memory":
            return ToolWords(done: String(localized: "Remembered", comment: "Past tense verb before what was remembered"),
                             notDone: String(localized: "Remember", comment: "Verb before what to remember"),
                             tried: String(localized: "Tried to remember", comment: "Before what was remembered"),
                             wouldHave: String(localized: "Would have: remember", comment: "Before what would have been remembered"))
        default:
            if tool.hasPrefix("browser_") {
                return ToolWords(done: String(localized: "Browsed", comment: "Past tense verb before a web page"),
                                 notDone: String(localized: "Browse", comment: "Verb before a web page"),
                                 tried: String(localized: "Tried to browse", comment: "Before a web page"),
                                 wouldHave: String(localized: "Would have: browse", comment: "Before a web page"))
            }
            let name = tool.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "_", with: " ")
            return ToolWords(done: String(localized: "Used \(name)", comment: "%@ is a tool's name"),
                             notDone: String(localized: "Use \(name)", comment: "%@ is a tool's name"),
                             tried: String(localized: "Tried to use \(name.lowercased())", comment: "%@ is a tool's name"),
                             wouldHave: String(localized: "Would have: use \(name.lowercased())", comment: "%@ is a tool's name"))
        }
    }

    /// Why an action was allowed, or what stopped it, in the card's words. A failed action says so after it.
    static func receipt(_ action: ConversationPost.Action, in run: ConversationPost.Run) -> String {
        let words: String
        switch action.receipt?.kind {
        case .tool:
            words = run.kind == "board" ? String(localized: "Part of this task's tools") : String(localized: "Part of this schedule's tools")
        case .safe: words = String(localized: "Not a risky command")
        case .allowlist: words = String(localized: "On your allow list")
        case .always:
            if let at = action.receipt?.grantedAt {
                words = String(localized: "You chose Always for this on \(at.formatted(.dateTime.month(.abbreviated).day()))",
                               comment: "%@ is a date")
            } else {
                words = String(localized: "You chose Always for this")
            }
        case .held:
            words = action.receipt?.detail == "ask_first"
                ? String(localized: "Held: needs your yes", comment: "Safety: Ask first held this; keep exact meaning")
                : heldForYou
        case .blocked: words = stopped(action.receipt?.detail)
        case .unknown: words = String(localized: "Allowed. Reason not recorded")
        case nil:
            words = action.status == .blocked ? String(localized: "Stopped", comment: "An action that was stopped")
                                              : String(localized: "Allowed. Reason not recorded")
        }
        guard action.status == .failed, action.receipt?.kind != .blocked else { return words }
        return [words, String(localized: "It failed", comment: "An action that ran but did not work")].joined(separator: " · ")
    }

    /// An action held back until the person says yes.
    static let heldForYou = String(localized: "Held for you", comment: "Safety: an action waiting for your yes")

    /// Held by Ask first: it waits for a yes every time, and its target is the plain words a card would use.
    static func heldByAskFirst(_ action: ConversationPost.Action) -> Bool {
        action.receipt?.kind == .held && action.receipt?.detail == "ask_first"
    }

    static func stopped(_ detail: String?) -> String {
        switch detail ?? "" {
        case "mac": String(localized: "Stopped: schedules never use your Mac's screen")
        case "risky": String(localized: "Stopped: a risky command needs your OK")
        case "deny_rule": String(localized: "Stopped: one of your rules says no")
        case "hardline": String(localized: "Stopped: this is never allowed")
        case "plugin": String(localized: "Stopped: schedules never change Nollie's own files")
        default: String(localized: "Stopped", comment: "An action that was stopped")
        }
    }

    /// One sentence for VoiceOver: "Ran df -h. Not a risky command."
    static func sentence(verb: String, target: String, receipt: String?) -> String {
        let action = target.isEmpty ? verb
            : verb.isEmpty ? target
            : String(localized: "\(verb) \(target)", comment: "A verb, then what it acted on, like Ran df -h")
        guard let receipt else { return String(localized: "\(action).", comment: "One action as a sentence") }
        return String(localized: "\(action). \(receipt).", comment: "One action, then why it was allowed or stopped")
    }
}
