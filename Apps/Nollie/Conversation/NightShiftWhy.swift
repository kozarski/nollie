import SwiftUI
import NollieCore

/// The answer to "Why?" on one action of the night shift or a rehearsal: who did it and for what, then the fixed
/// rule that let it happen or what stopped it, and for a stop or a hold what the person can do. Only what the add-on
/// recorded: a receipt from before 1.1 has no rule's words, and an action with no receipt says so.
enum NightShiftWhy {
    static let notKept = String(localized: "Nollie didn't keep the reason for this one.")

    /// The screen's key for an entry whose Why is open: one per run and action, or per rehearsal list and action.
    static func key(run: String, index: Int) -> String { "why:\(run)#\(index)" }

    /// When the person chose Always: "17 Oct at 14:02", in their own date and clock style.
    static func moment(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// Why one action of a run happened, or didn't, in two or three short sentences.
    static func explain(_ action: ConversationPost.Action, in run: ConversationPost.Run,
                        moment: (Date) -> String = moment) -> String {
        let receipt = action.receipt
        let stopped = action.status == .blocked || receipt?.kind == .held || receipt?.kind == .blocked
        var lines = [who(run, tried: stopped)]
        guard let receipt else { return (lines + [notKept]).joined(separator: " ") }
        lines += rule(receipt, in: run, moment: moment)
        if action.status == .failed, receipt.kind != .blocked, receipt.kind != .held {
            lines.append(String(localized: "It ran, but it didn't work."))
        }
        return lines.joined(separator: " ")
    }

    /// The same for a rehearsal's report: what it would have done, or what it looked at.
    static func explain(_ action: ConversationPost.Action, rehearsal card: ConversationPost.Rehearsal, looked: Bool,
                        moment: (Date) -> String = moment) -> String {
        let run = ConversationPost.Run(id: "rehearsal", kind: "rehearsal", bot: card.bot, botName: card.botName,
                                       title: card.title, outcome: .rehearsal)
        guard looked else { return explain(action, in: run, moment: moment) }
        return [explain(action, in: run, moment: moment),
                String(localized: "A rehearsal lets a schedule look things up, never change anything.")].joined(separator: " ")
    }

    /// "Scout did this during your schedule “Morning prices”."
    static func who(_ run: ConversationPost.Run, tried: Bool) -> String {
        let bot = run.botName.isEmpty ? ProfileInfo.shownName(of: run.bot) : run.botName
        let title = run.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = title.isEmpty ? nil : title
        if run.kind == "rehearsal" || run.outcome == .rehearsal {
            switch (named, tried) {
            case (let named?, false): return String(localized: "\(bot) did this in the rehearsal of \u{201C}\(named)\u{201D}.")
            case (let named?, true): return String(localized: "\(bot) tried this in the rehearsal of \u{201C}\(named)\u{201D}.")
            case (nil, false): return String(localized: "\(bot) did this in a rehearsal.")
            case (nil, true): return String(localized: "\(bot) tried this in a rehearsal.")
            }
        }
        switch run.kind {
        case "board":
            switch (named, tried) {
            case (let named?, false): return String(localized: "\(bot) did this for the Board task \u{201C}\(named)\u{201D}.")
            case (let named?, true): return String(localized: "\(bot) tried this for the Board task \u{201C}\(named)\u{201D}.")
            case (nil, false): return String(localized: "\(bot) did this for a Board task.")
            case (nil, true): return String(localized: "\(bot) tried this for a Board task.")
            }
        case "helper":
            return tried ? String(localized: "A helper tried this while \(bot) ran a schedule.")
                         : String(localized: "A helper did this while \(bot) ran a schedule.")
        default:
            switch (named, tried) {
            case (let named?, false): return String(localized: "\(bot) did this during your schedule \u{201C}\(named)\u{201D}.")
            case (let named?, true): return String(localized: "\(bot) tried this during your schedule \u{201C}\(named)\u{201D}.")
            case (nil, false): return String(localized: "\(bot) did this during one of your schedules.")
            case (nil, true): return String(localized: "\(bot) tried this during one of your schedules.")
            }
        }
    }

    /// The fixed rule, and for a stop or a hold, what the person can do.
    static func rule(_ receipt: ConversationPost.Receipt, in run: ConversationPost.Run,
                     moment: (Date) -> String = moment) -> [String] {
        let bot = run.botName.isEmpty ? ProfileInfo.shownName(of: run.bot) : run.botName
        let rule = receipt.rule.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch receipt.kind {
        case .tool:
            return [run.kind == "board"
                    ? String(localized: "It's one of the tools this task can use, and it doesn't need your yes.")
                    : String(localized: "It's one of the tools this schedule can use, and it doesn't need your yes.")]
        case .safe:
            return [String(localized: "The safety check found nothing risky in the command, so it didn't need your yes.")]
        case .allowlist:
            if let entry = receipt.detail {
                return [String(localized: "It matches \u{201C}\(entry)\u{201D} on your allowed list, so it runs without asking.")]
            }
            return [String(localized: "It's on your allowed list, so it runs without asking.")]
        case .always:
            switch (receipt.detail, receipt.grantedAt) {
            case (let what?, let at?):
                return [String(localized: "You chose Always for \u{201C}\(what)\u{201D} on \(moment(at)), so it runs without asking.")]
            case (nil, let at?):
                return [String(localized: "You chose Always for this on \(moment(at)), so it runs without asking.")]
            case (let what?, nil):
                return [String(localized: "You chose Always for \u{201C}\(what)\u{201D} earlier, so it runs without asking. Nollie didn't see when.")]
            case (nil, nil):
                return [String(localized: "You chose Always for this earlier, so it runs without asking. Nollie didn't see when.")]
            }
        case .held:
            if receipt.detail == "ask_first" {
                return [askFirst(receipt.ask), String(localized: "Ask \(bot) in a chat if you still want it.")]
            }
            return [String(localized: "This was a rehearsal, so Nollie wrote it down instead of doing it."),
                    String(localized: "It runs for real once you turn the schedule on.")]
        case .blocked:
            return stopped(receipt.detail, rule: rule, bot: bot)
        case .unknown:
            return [String(localized: "It was allowed, but Nollie couldn't tell which rule let it through.")]
        }
    }

    /// Ask first's hold: what needs a yes, and why nobody gave one.
    static func askFirst(_ ask: String?) -> String {
        switch ask {
        case "send":
            return String(localized: "Sending always waits for your yes, and nobody could answer then, so it wasn't done.",
                          comment: "Safety: Ask first held a send; keep exact meaning")
        case "buy":
            return String(localized: "Buying always waits for your yes, and nobody could answer then, so it wasn't done.",
                          comment: "Safety: Ask first held a payment; keep exact meaning")
        case "post":
            return String(localized: "Posting always waits for your yes, and nobody could answer then, so it wasn't done.",
                          comment: "Safety: Ask first held a post; keep exact meaning")
        case "delete":
            return String(localized: "Deleting always waits for your yes, and nobody could answer then, so it wasn't done.",
                          comment: "Safety: Ask first held a delete; keep exact meaning")
        case "unsure":
            return String(localized: "Nollie couldn't tell what this would do, so it waited for your yes. Nobody could answer then, so it wasn't done.",
                          comment: "Safety: Ask first held an unclear action; keep exact meaning")
        default:
            return String(localized: "Anything that sends, buys, posts or deletes always waits for your yes, and nobody could answer then, so it wasn't done.",
                          comment: "Safety: Ask first held an action; keep exact meaning")
        }
    }

    static func stopped(_ detail: String?, rule: String?, bot: String) -> [String] {
        let askInChat = String(localized: "Ask \(bot) in a chat if you want it done.")
        switch detail ?? "" {
        case "mac":
            return [String(localized: "Schedules and Board tasks never use your Mac's screen or apps, so it was stopped."), askInChat]
        case "risky":
            let first = rule.map { String(localized: "The command looked risky (\($0)), and nobody was there to say yes, so it was stopped.") }
                ?? String(localized: "The command looked risky, and nobody was there to say yes, so it was stopped.")
            return [first, askInChat]
        case "deny_rule":
            if let rule { return [String(localized: "It matches \u{201C}\(rule)\u{201D}, one of your rules that says no, so it was stopped.")] }
            return [String(localized: "One of your rules says no to this, so it was stopped.")]
        case "hardline":
            return [rule.map { String(localized: "This is never allowed, even when you're there (\($0)), so it was stopped.") }
                    ?? String(localized: "This is never allowed, even when you're there, so it was stopped.")]
        case "plugin":
            return [String(localized: "Work nobody watches never changes Nollie's own files, so it was stopped.")]
        default:
            return [String(localized: "The safety check stopped it, and didn't say which rule.")]
        }
    }
}

/// A small glass "Why?" under or beside an entry. It opens the answer in place.
struct WhyButton: View {
    let open: Bool
    var tint = Ink.text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Why?")
                .font(Ink.chip)
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Capsule())
                .nollieGlass(open ? .regular.tint(tint.opacity(0.18)).interactive() : .regular.interactive(), in: Capsule(),
                             solid: tint.opacity(open ? 0.22 : 0.12))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Why?")
        .accessibilityValue(open ? "Shown" : "Hidden")
        .accessibilityHint("Says why this happened")
    }
}

/// The answer, opened in place: a quiet bar on the leading edge and the plain words beside it.
struct WhyNote: View {
    let text: String
    var detail: String? = nil
    var colors = PostColors()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule().fill(colors.detail.opacity(0.45)).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(Ink.cardBody).foregroundStyle(colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(Ink.stamp).foregroundStyle(colors.detail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
