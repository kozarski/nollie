import SwiftUI
import NollieCore

/// A new schedule's first run, done as a rehearsal: what it would have done, what it looked at and what it would
/// have said, then Turn on or Keep off. A schedule Nollie can't rehearse gets a check card instead: why, and what it
/// will do. No state of its own: a tap in flight and a problem come in with the post.
struct RehearsalCard: View {
    /// Under an action Ask first holds: it asks each time, rehearsal or not.
    static let everyTime = String(localized: "Needs your yes each time", comment: "Safety: Ask first asks every time; keep exact meaning")

    let card: ConversationPost.Rehearsal
    let pending: ConversationPostAction?
    let problem: String?
    /// Entries whose Why is open, from the screen.
    var expanded: Set<String> = []
    let tap: (ConversationPostTap) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(card.check == nil ? "Rehearsal" : "New schedule")
                .font(Ink.cardTitle).foregroundStyle(Ink.text)
                .accessibilityAddTraits(.isHeader)
            PostBotLine(bot: card.bot, title: card.title.isEmpty ? String(localized: "A new schedule") : card.title,
                        detail: card.botName.isEmpty ? ProfileInfo.shownName(of: card.bot) : card.botName)
            if let check = card.check {
                CheckDetails(check: check)
            } else {
                report
            }
            answer
            if let problem {
                Text(problem).font(Ink.cardBody).foregroundStyle(Ink.warnText)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.card, in: .rect(cornerRadius: Ink.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("post.rehearsal")
    }

    @ViewBuilder private var report: some View {
        if card.outcome == .failed || card.outcome == .stopped {
            Text("The rehearsal did not finish.").font(Ink.cardBody).foregroundStyle(Ink.warnText)
        }
        Section(title: String(localized: "Would have", comment: "Heading over what a rehearsal would have done")) {
            if card.held.isEmpty {
                Text("Nothing that changes anything.").font(Ink.cardBody).foregroundStyle(Ink.cardText)
            }
            ForEach(Array(card.held.enumerated()), id: \.offset) { index, action in
                let key = NightShiftWhy.key(run: "held", index: index)
                let why = NightShiftWhy.explain(action, rehearsal: card, looked: false)
                if NightShiftWords.heldByAskFirst(action), !action.target.isEmpty {
                    // Ask first: its words carry their own verb, and turning the schedule on doesn't change it.
                    PostActionLine(verb: "", target: action.target, receipt: RehearsalCard.everyTime,
                                   label: NightShiftWords.sentence(verb: String(localized: "Would have:", comment: "Before what a rehearsal would have done"),
                                                                   target: action.target, receipt: RehearsalCard.everyTime),
                                   why: why, whyOpen: expanded.contains(key), whyID: "post.rehearsal.why.held.\(index)") {
                        tap(.why(key))
                    }
                } else {
                    let verb = NightShiftWords.verbs(action.tool, target: action.target).1
                    // Stopped outright (the Mac, the add-on's own files): it could not have run for real either.
                    let stopped = action.receipt?.kind == .blocked ? NightShiftWords.stopped(action.receipt?.detail) : nil
                    PostActionLine(verb: verb, target: action.target, receipt: stopped, warn: stopped != nil,
                                   label: NightShiftWords.sentence(verb: NightShiftWords.wouldHave(action.tool, target: action.target),
                                                                   target: action.target, receipt: stopped ?? NightShiftWords.heldForYou),
                                   why: why, whyOpen: expanded.contains(key), whyID: "post.rehearsal.why.held.\(index)") {
                        tap(.why(key))
                    }
                }
            }
        }
        if !card.looked.isEmpty {
            Section(title: String(localized: "Looked at", comment: "Heading over what a rehearsal looked at")) {
                ForEach(Array(card.looked.enumerated()), id: \.offset) { index, action in
                    let verb = NightShiftWords.verbs(action.tool, target: action.target).0
                    let key = NightShiftWhy.key(run: "looked", index: index)
                    // Under "Looked at", a look needs no verb of its own.
                    PostActionLine(verb: verb == NightShiftWords.lookedAt ? "" : verb, target: action.target, receipt: nil,
                                   label: NightShiftWords.sentence(verb: verb, target: action.target, receipt: nil),
                                   why: NightShiftWhy.explain(action, rehearsal: card, looked: true),
                                   whyOpen: expanded.contains(key), whyID: "post.rehearsal.why.looked.\(index)") {
                        tap(.why(key))
                    }
                }
            }
        }
        if !card.reply.isEmpty {
            Section(title: String(localized: "It would have said", comment: "Heading over a rehearsal's reply")) {
                Text(card.reply)
                    .font(Ink.cardBody)
                    .foregroundStyle(Ink.cardText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Capsule().fill(Ink.line).frame(width: 3) }
            }
        }
    }

    /// The buttons while the schedule waits; afterwards, what happened.
    @ViewBuilder private var answer: some View {
        switch card.state {
        case .on:
            Done(words: String(localized: "On. It runs for real from now on."))
        case .changed:
            Done(words: String(localized: "It changed since. It will rehearse again."))
        case .keptOff:
            Done(words: String(localized: "Kept off."))
            Button(pending == .turnOn ? "Turning on" : "Turn on") { tap(.turnOn) }
                .buttonStyle(OutlinePillStyle())
                .disabled(pending != nil)
                .accessibilityIdentifier("post.rehearsal.turnOn")
        case .ready, nil:
            HStack(spacing: 10) {
                Button(pending == .turnOn ? "Turning on" : "Turn on") { tap(.turnOn) }
                    .buttonStyle(InkPillStyle())
                    .accessibilityIdentifier("post.rehearsal.turnOn")
                Button(pending == .keepOff ? "Keeping off" : "Keep off") { tap(.keepOff) }
                    .buttonStyle(OutlinePillStyle())
                    .accessibilityIdentifier("post.rehearsal.keepOff")
            }
            .disabled(pending != nil)
        }
    }

    private struct Done: View {
        let words: String

        var body: some View {
            Text(words).font(Ink.cardBody.weight(.semibold)).foregroundStyle(Ink.text)
                .accessibilityIdentifier("post.rehearsal.done")
        }
    }

    private struct Section<Content: View>: View {
        let title: String
        @ViewBuilder let content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Ink.chip).foregroundStyle(Ink.text3).accessibilityAddTraits(.isHeader)
                content
            }
        }
    }
}

/// Why Nollie can't rehearse a schedule, and what it will do when it runs.
private struct CheckDetails: View {
    let check: ConversationPost.Check

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.why(check.reason)).font(Ink.cardBody).foregroundStyle(Ink.cardText)
            if !check.prompt.isEmpty {
                Text(check.prompt)
                    .font(Ink.cardBody)
                    .foregroundStyle(Ink.cardText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Capsule().fill(Ink.line).frame(width: 3) }
            }
            if let script = check.script {
                Text([script, check.hash].compactMap { $0 }.joined(separator: " · "))
                    .font(Ink.code11)
                    .foregroundStyle(Ink.codeText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.code, in: .rect(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Script \(script)")
            }
        }
    }

    static func why(_ reason: ConversationPost.Check.Reason?) -> String {
        switch reason {
        case .script: String(localized: "This runs a script before Nollie can watch.")
        case .once: String(localized: "This runs once.")
        case .repeat: String(localized: "This runs only a set number of times.")
        case .unwatched: String(localized: "Nollie can't watch this bot yet.")
        case nil: String(localized: "Nollie can't rehearse this one.")
        }
    }
}
