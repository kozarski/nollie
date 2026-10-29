import SwiftUI
import NollieCore

/// Ask first holding an action for a yes: what the bot wants to do, all of it, the button it is
/// about to press when there is one, and two answers. No "always": each action is asked for.
struct AskFirstCardBody: View {
    var ask: AskFirstAsk
    var botName: String
    /// Allow once asks for Face ID first, and its pill wears a small lock.
    var locked = false
    /// "once" or "deny".
    var onChoice: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var who: String { botName.isEmpty ? String(localized: "Your bot", comment: "Stands in for a bot's name when it has none") : botName }

    var title: String {
        switch ask.kind {
        case .send: String(localized: "\(who) wants to send something", comment: "Safety: Ask first card title; a bot's name comes first")
        case .buy: String(localized: "\(who) wants to pay for something", comment: "Safety: Ask first card title; a bot's name comes first")
        case .post: String(localized: "\(who) wants to post something", comment: "Safety: Ask first card title; a bot's name comes first")
        case .delete: String(localized: "\(who) wants to delete something", comment: "Safety: Ask first card title; a bot's name comes first")
        case .unsure: String(localized: "\(who) wants to do something", comment: "Safety: Ask first card title; a bot's name comes first")
        case .calendar: String(localized: "\(who) wants to change your calendar", comment: "Safety: Ask first card title; a bot's name comes first")
        case .reminders: String(localized: "\(who) wants to change your reminders", comment: "Safety: Ask first card title; a bot's name comes first")
        case .contacts: String(localized: "\(who) wants to change your contacts", comment: "Safety: Ask first card title; a bot's name comes first")
        }
    }

    private var icon: String {
        switch ask.kind {
        case .send: "paperplane.fill"
        case .buy: "creditcard.fill"
        case .post: "megaphone.fill"
        case .delete: "trash.fill"
        case .unsure: "questionmark.circle.fill"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).foregroundStyle(Ink.text).accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("approval.askFirst.title")
                Spacer(minLength: 0)
            }
            .font(Ink.cardTitle)
            // All of it, as it will happen. Long text scrolls inside its block rather than being cut;
            // at the accessibility text sizes the block shows it all and the chat scrolls instead.
            ScrollView(.vertical) {
                Text(ask.summary)
                    .font(Ink.cardBody)
                    .foregroundStyle(Ink.cardText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .spread()
                    .accessibilityIdentifier("approval.askFirst.summary")
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: typeSize.isAccessibilitySize ? nil : 180)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
            .padding(.bottom, ask.check == nil ? 12 : 10)
            if let check = ask.check {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Ink.warnText).accessibilityHidden(true)
                    Text(check)
                        .foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(Ink.cardBody.weight(.semibold))
                .padding(.bottom, 12)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("approval.askFirst.check")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { answers(fill: false) }
                VStack(spacing: 8) { answers(fill: true) }
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.askFirst")
    }

    @ViewBuilder private func answers(fill: Bool) -> some View {
        ApproveButton(title: LocalizedStringResource("Allow once", comment: "Safety: approval answer, allows this one action only"),
                      locked: locked, fill: fill) { onChoice("once") }
        Button("Deny") { onChoice("deny") }
            .buttonStyle(OutlinePillStyle(fill: fill))
            .accessibilityIdentifier("approval.deny")
    }
}

/// The yes on an approval card. When it will ask for Face ID first, a small lock sits before its
/// words and VoiceOver says so.
struct ApproveButton: View {
    var title: String
    var locked: Bool
    var fill: Bool
    var action: () -> Void

    init(title: LocalizedStringResource, locked: Bool, fill: Bool, action: @escaping () -> Void) {
        self.init(verbatim: String(localized: title), locked: locked, fill: fill, action: action)
    }

    fileprivate init(verbatim title: String, locked: Bool, fill: Bool, action: @escaping () -> Void) {
        self.title = title
        self.locked = locked
        self.fill = fill
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if locked {
                    Image(systemName: "lock.fill")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                        .testID("approval.once.lock")
                }
                Text(title)
            }
        }
        .buttonStyle(InkPillStyle(fill: fill))
        .accessibilityLabel(title)
        .accessibilityHint(locked ? String(localized: "Checks it's you first", comment: "Safety: a yes on this card asks for Face ID or Touch ID first") : "")
        .accessibilityIdentifier("approval.once")
    }
}
