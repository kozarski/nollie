import SwiftUI
import NollieCore

/// Helpers the thread's cards share: the bot's shown name and how an approval answer goes out.
private extension ChatSession {
    var botDisplayName: String {
        let match = runtime.profiles.first { $0.name == profileName }
        return match?.shownName ?? profileName
    }

    /// Sends the choice for a waiting card, unless the person is away from home with no link.
    func answerApproval(_ card: PendingCard, with choice: String) {
        guard !AppModel.shared.awayBlocks() else { return }
        Task { await respond(card: card, result: ["choice": .string(choice)]) }
    }

    /// The approval card for a pending approval, wired to this chat. `count` is how many wait.
    func approvalCard(_ approval: ApprovalRequest, for card: PendingCard, count: Int) -> ApprovalCardView {
        ApprovalCardView(
            approval: approval, count: count, botName: botDisplayName, profile: profileName,
            onChoice: { self.answerApproval(card, with: $0) },
            onSystemControl: { SystemControl.answer($0, card: card, chat: self) },
            onSignIn: { await SignInAnswer.answer($0, card: card, chat: self) })
    }
}

private extension View {
    /// The thread's soft grey card: inner padding, a width cap on the Mac, and the ink fill.
    func inkCard() -> some View {
        self
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            #if os(macOS)
            .frame(maxWidth: 470, alignment: .leading)
            #endif
            .background(Ink.card, in: .rect(cornerRadius: Ink.cardRadius, style: .continuous))
    }
}

/// The glass card that stands in for the composer while the gateway is waiting on you.
struct PendingCardView: View {
    @Bindable var chat: ChatSession
    var card: PendingCard

    var body: some View {
        content
            .padding(16)
            .nollieGlass(.regular, in: .rect(cornerRadius: Ink.cardRadius, style: .continuous))
    }

    @ViewBuilder private var content: some View {
        if let approval = card.approval {
            chat.approvalCard(approval, for: card, count: chat.cards.count)
        } else if let question = card.clarify {
            ClarifyCardView(request: question) { reply in
                Task { await chat.respond(card: card, result: reply) }
            }
        } else if let prompt = card.valuePrompt {
            ValuePromptCardView(method: card.method, request: prompt) { value in
                let payload: JSONValue = ["value": .string(value)]
                Task { await chat.respond(card: card, result: payload) }
            }
        } else {
            Text("Unsupported request \(card.method)").font(.footnote)
        }
    }
}

/// An approval at the foot of the thread: a soft grey card with the question, what it concerns,
/// the command on one line, and the answers.
struct ThreadApprovalCard: View {
    @Bindable var chat: ChatSession
    var card: PendingCard

    private var waitingApprovals: Int { chat.cards.filter { $0.method == "approval" }.count }

    var body: some View {
        if let approval = card.approval {
            chat.approvalCard(approval, for: card, count: waitingApprovals)
                .inkCard()
                // Setting an identifier here overrides the card's own, so Ask first is renamed here.
                .accessibilityIdentifier(AskFirstAsk(approval) == nil ? "thread.approval" : "approval.askFirst")
        }
    }
}

/// Appears after a turn stopped because System control was off and Hermes refused a screen
/// action. Says so, and offers one tap to turn it on and carry on.
struct SystemControlAskCard: View {
    var botName: String
    var onTurnOn: () -> Void
    var onDismiss: () -> Void

    @State private var working: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            Text("Turn on System control and \(botName) carries on.")
                .font(Ink.cardBody)
                .foregroundStyle(Ink.cardText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, 12)
            SideBySideOrStacked { fill in buttons(fill: fill) }
        }
        .inkCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread.systemControl")
    }

    private var title: some View {
        Label {
            Text("\(botName) needs System control").lineLimit(1)
        } icon: {
            Image(systemName: "cursorarrow.rays")
        }
        .labelStyle(CardTitleLabel(alignment: .center))
        .font(Ink.cardTitle)
        .foregroundStyle(Ink.text)
    }

    @ViewBuilder private func buttons(fill: Bool) -> some View {
        Button(working ? "Turning it on…" : "Turn on and carry on") {
            working = true
            onTurnOn()
        }
        .buttonStyle(InkPillStyle(fill: fill))
        .disabled(working)
        .accessibilityIdentifier("systemControl.turnOn")
        Button("Not now", action: onDismiss)
            .buttonStyle(OutlinePillStyle(fill: fill))
            .accessibilityIdentifier("systemControl.notNow")
    }
}

/// Icon beside a title on one line, spaced the way the cards space them.
struct CardTitleLabel: LabelStyle {
    var alignment: VerticalAlignment = .firstTextBaseline

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: alignment, spacing: 8) {
            configuration.icon
            configuration.title
        }
    }
}

/// Puts the answers in a row when they fit. On a narrow phone with big text they stack instead,
/// each one filling the width.
struct SideBySideOrStacked<Answers: View>: View {
    @ViewBuilder var answers: (_ fill: Bool) -> Answers

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { answers(false) }
            VStack(spacing: 8) { answers(true) }
        }
    }
}

/// One answer on the older approval row. Allow once stands out, Deny is the destructive one.
struct ApprovalChoiceButton: View {
    var choice: String
    var title: String
    var action: () -> Void
    private var destructive: Bool { choice == "deny" }

    private var face: some View {
        Text(title).lineLimit(1).minimumScaleFactor(0.8).spread(.center)
    }

    var body: some View {
        if choice == "once" {
            Button(action: action) { face }.buttonStyle(.nollieGlassProminent)
        } else {
            Button(role: destructive ? .destructive : nil, action: action) { face }.buttonStyle(.nollieGlass)
        }
    }
}
