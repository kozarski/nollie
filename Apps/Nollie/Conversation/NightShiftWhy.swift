import SwiftUI
import NollieCore

/// The answer to "Why?" on one action of the night shift or a rehearsal: who did it and for what, then the fixed
/// rule that let it happen or what stopped it, and for a stop or a hold what the person can do. Only what the add-on
/// recorded: a receipt from before 1.1 has no rule's words, and an action with no receipt says so.
enum NightShiftWhy {
    static let notKept = "Nollie didn't keep the reason for this one."

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
            lines.append("It ran, but it didn't work.")
        }
        return lines.joined(separator: " ")
    }

    /// The same for a rehearsal's report: what it would have done, or what it looked at.
    static func explain(_ action: ConversationPost.Action, rehearsal card: ConversationPost.Rehearsal, looked: Bool,
                        moment: (Date) -> String = moment) -> String {
        let run = ConversationPost.Run(id: "rehearsal", kind: "rehearsal", bot: card.bot, botName: card.botName,
                                       title: card.title, outcome: .rehearsal)
        guard looked else { return explain(action, in: run, moment: moment) }
        var text = explain(action, in: run, moment: moment)
        text += " A rehearsal lets a schedule look things up, never change anything."
        return text
    }

    /// "Scout did this during your schedule “Morning prices”."
    static func who(_ run: ConversationPost.Run, tried: Bool) -> String {
        let bot = run.botName.isEmpty ? ProfileInfo.shownName(of: run.bot) : run.botName
        let did = tried ? "tried this" : "did this"
        let title = run.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = title.isEmpty ? nil : "\u{201C}\(title)\u{201D}"
        if run.kind == "rehearsal" || run.outcome == .rehearsal {
            return named.map { "\(bot) \(did) in the rehearsal of \($0)." } ?? "\(bot) \(did) in a rehearsal."
        }
        switch run.kind {
        case "board": return named.map { "\(bot) \(did) for the Board task \($0)." } ?? "\(bot) \(did) for a Board task."
        case "helper": return "A helper \(did) while \(bot) ran a schedule."
        default: return named.map { "\(bot) \(did) during your schedule \($0)." } ?? "\(bot) \(did) during one of your schedules."
        }
    }

    /// The fixed rule, and for a stop or a hold, what the person can do.
    static func rule(_ receipt: ConversationPost.Receipt, in run: ConversationPost.Run,
                     moment: (Date) -> String = moment) -> [String] {
        let bot = run.botName.isEmpty ? ProfileInfo.shownName(of: run.bot) : run.botName
        let rule = receipt.rule.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch receipt.kind {
        case .tool:
            let work = run.kind == "board" ? "task" : "schedule"
            return ["It's one of the tools this \(work) can use, and it doesn't need your yes."]
        case .safe:
            return ["The safety check found nothing risky in the command, so it didn't need your yes."]
        case .allowlist:
            if let entry = receipt.detail { return ["It matches \u{201C}\(entry)\u{201D} on your allowed list, so it runs without asking."] }
            return ["It's on your allowed list, so it runs without asking."]
        case .always:
            let what = receipt.detail.map { " for \u{201C}\($0)\u{201D}" } ?? " for this"
            if let at = receipt.grantedAt { return ["You chose Always\(what) on \(moment(at)), so it runs without asking."] }
            return ["You chose Always\(what) earlier, so it runs without asking. Nollie didn't see when."]
        case .held:
            if receipt.detail == "ask_first" {
                return [askFirst(receipt.ask), "Ask \(bot) in a chat if you still want it."]
            }
            return ["This was a rehearsal, so Nollie wrote it down instead of doing it.",
                    "It runs for real once you turn the schedule on."]
        case .blocked:
            return stopped(receipt.detail, rule: rule, bot: bot)
        case .unknown:
            return ["It was allowed, but Nollie couldn't tell which rule let it through."]
        }
    }

    /// Ask first's hold: what needs a yes, and why nobody gave one.
    static func askFirst(_ ask: String?) -> String {
        let tail = "always waits for your yes, and nobody could answer then, so it wasn't done."
        switch ask {
        case "send": return "Sending " + tail
        case "buy": return "Buying " + tail
        case "post": return "Posting " + tail
        case "delete": return "Deleting " + tail
        case "unsure": return "Nollie couldn't tell what this would do, so it waited for your yes. Nobody could answer then, so it wasn't done."
        default: return "Anything that sends, buys, posts or deletes " + tail
        }
    }

    static func stopped(_ detail: String?, rule: String?, bot: String) -> [String] {
        switch detail ?? "" {
        case "mac":
            return ["Schedules and Board tasks never use your Mac's screen or apps, so it was stopped.",
                    "Ask \(bot) in a chat if you want it done."]
        case "risky":
            let what = rule.map { " (\($0))" } ?? ""
            return ["The command looked risky\(what), and nobody was there to say yes, so it was stopped.",
                    "Ask \(bot) in a chat if you want it done."]
        case "deny_rule":
            if let rule { return ["It matches \u{201C}\(rule)\u{201D}, one of your rules that says no, so it was stopped."] }
            return ["One of your rules says no to this, so it was stopped."]
        case "hardline":
            let what = rule.map { " (\($0))" } ?? ""
            return ["This is never allowed, even when you're there\(what), so it was stopped."]
        case "plugin":
            return ["Work nobody watches never changes Nollie's own files, so it was stopped."]
        default:
            return ["The safety check stopped it, and didn't say which rule."]
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
