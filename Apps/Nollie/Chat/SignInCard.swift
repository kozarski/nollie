import SwiftUI
import NollieCore

/// A helper asking to sign in to a site with a saved sign-in: who, which site, and two answers.
/// Allow once asks Touch ID on the Mac (which then types the sign-in) or Face ID on the iPhone.
/// There is no "always": every sign-in is asked for.
struct SignInCardBody: View {
    var ask: SignInAsk
    var botName: String
    /// Allow (true) or Deny (false). Returns a sentence to show when it didn't go through.
    var onAnswer: (Bool) async -> String?
    @State private var working = false
    @State private var problem: String?

    private var who: String { botName.isEmpty ? "Your bot" : botName }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(Ink.text)
                Text("\(who) wants to sign in to \(ask.site)")
                    .foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(Ink.cardTitle)
            Text(DeviceWords.isMac ? "Nollie types your saved sign-in. \(who) is never told the password, and pictures pause while it's typed."
                                   : "Your Mac types it in after Touch ID. \(who) is never told the password, and pictures pause while it's typed.")
                .font(Ink.cardBody)
                .foregroundStyle(Ink.cardText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, problem == nil ? 12 : 6)
            if let problem {
                Text(problem)
                    .font(Ink.pill)
                    .foregroundStyle(Ink.warnText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("signIn.problem")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { answers(fill: false) }
                VStack(spacing: 8) { answers(fill: true) }
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.signIn")
    }

    @ViewBuilder private func answers(fill: Bool) -> some View {
        Button(working ? "Checking…" : "Allow once") { answer(true) }
            .buttonStyle(InkPillStyle(fill: fill))
            .disabled(working)
            .accessibilityHint(DeviceWords.isMac ? "Asks for Touch ID, then types the sign-in." : "Asks for Face ID. Your Mac types the sign-in.")
            .accessibilityIdentifier("approval.once")
        Button("Deny") { answer(false) }
            .buttonStyle(OutlinePillStyle(fill: fill))
            .disabled(working)
            .accessibilityIdentifier("approval.deny")
    }

    private func answer(_ allow: Bool) {
        working = true
        problem = nil
        Task {
            let said = await onAnswer(allow)
            working = false
            problem = said
        }
    }
}

/// Answering a sign-in card, on either device. The approval itself goes back through Hermes like
/// any other; the password leaves the Mac only as keystrokes into the helper's computer.
@MainActor
enum SignInAnswer {
    static func answer(_ allow: Bool, card: PendingCard, chat: ChatSession) async -> String? {
        guard let ask = SignInAsk(card.approval) else { return nil }
        guard allow else {
            await chat.respond(card: card, result: ["choice": "deny"])
            return nil
        }
        if PrivateBots.isPrivate(chat.profileName, connection: chat.runtime.connection.id) || chat.profileName.lowercased() == "private" {
            await chat.respond(card: card, result: ["choice": "deny"])
            return "Saved sign-ins aren't used for private bots."
        }
        #if os(macOS)
        return await SignInCenter.shared.allowHere(ask, card: card, chat: chat)
        #else
        let bot = botName(chat)
        guard await RememberedSignInCoordinator.defaultAuthenticator()
            .authenticate(reason: "Let \(bot) sign in to \(ask.site)") != nil else { return nil }
        // Who answered, for the history. Only a label: the Mac still asks for Touch ID before it types.
        if (try? await chat.runtime.claimSignIn(ask.requestID, approver: "iphone")) == false {
            return "This one was already answered."
        }
        await chat.respond(card: card, result: ["choice": "once"])
        return nil
        #endif
    }

    static func botName(_ chat: ChatSession) -> String {
        let known = chat.runtime.profiles.first(where: { $0.name == chat.profileName })
        return known?.shownName ?? chat.profileName.capitalized
    }
}
