import SwiftUI

/// The composer: the shared glass capsule with the words and a round ink send button, which stops the bot while
/// it works and nothing is typed.
struct ConversationComposer: View {
    @Binding var draft: String
    var running = false
    let send: () -> Void
    var stop: () -> Void = {}
    @Namespace private var glass
    @FocusState private var focused: Bool

    /// The button on the right: Send, or Stop while the bot works and nothing is typed.
    private struct Round {
        var symbol: String
        var size: CGFloat
        var label: String
        var id: String
    }

    private var hasWords: Bool { !draft.allSatisfy(\.isWhitespace) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            field
            if running && !hasWords {
                button(Round(symbol: "stop.fill", size: 13, label: String(localized: "Stop", comment: "Safety: stops the bot's reply"), id: "conversation.stop"), action: stop)
            } else {
                button(Round(symbol: "arrow.up", size: 16, label: String(localized: "Send", comment: "A button that sends the typed message"), id: "conversation.send"), action: send)
                    .disabled(!hasWords)
                    .opacity(hasWords ? 1 : 0.35)
            }
        }
        .padding(Ink.composerInset)
        .composerSurface(namespace: glass)
    }

    private var field: some View {
        TextField("Message", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Ink.message)
            .foregroundStyle(Ink.text)
            .lineLimit(1...6)
            .focused($focused)
            .padding(EdgeInsets(top: Ink.composerTextInset, leading: 16, bottom: Ink.composerTextInset, trailing: 0))
            .frame(minHeight: Ink.composerHeight - 2 * Ink.composerInset)
            .onSubmit(send)
            .testID("conversation.composer")
    }

    private func button(_ round: Round, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: round.symbol)
                .font(.system(size: round.size, weight: .semibold))
                .foregroundStyle(Ink.onInk)
                .frame(square: Ink.composerButton)
                .background(Ink.ink, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(round.label)
        .testID(round.id)
    }
}
