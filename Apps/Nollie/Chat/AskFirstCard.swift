import SwiftUI
import NollieCore

/// Ask first holding an action for a yes: what the bot wants to do, all of it, the button it is
/// about to press when there is one, and two answers. No "always": each action is asked for.
struct AskFirstCardBody: View {
    var ask: AskFirstAsk
    var botName: String
    /// "once" or "deny".
    var onChoice: (String) -> Void

    private var who: String { botName.isEmpty ? "Your bot" : botName }

    var title: String {
        switch ask.kind {
        case .send: "\(who) wants to send something"
        case .buy: "\(who) wants to pay for something"
        case .post: "\(who) wants to post something"
        case .delete: "\(who) wants to delete something"
        case .unsure: "\(who) wants to do something"
        }
    }

    private var icon: String {
        switch ask.kind {
        case .send: "paperplane.fill"
        case .buy: "creditcard.fill"
        case .post: "megaphone.fill"
        case .delete: "trash.fill"
        case .unsure: "questionmark.circle.fill"
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
            // All of it, as it will happen. Long text scrolls inside its block rather than being cut.
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
            .frame(maxHeight: 180)
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
        Button("Allow once") { onChoice("once") }
            .buttonStyle(InkPillStyle(fill: fill))
            .accessibilityIdentifier("approval.once")
        Button("Deny") { onChoice("deny") }
            .buttonStyle(OutlinePillStyle(fill: fill))
            .accessibilityIdentifier("approval.deny")
    }
}
