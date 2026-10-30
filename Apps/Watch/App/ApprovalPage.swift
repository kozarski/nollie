import SwiftUI

/// One approval on the wrist: the bot's character small at the top, the card's own words, and the
/// answers. Allow once is the prominent glass button and Deny sits under it. When the yes needs
/// the iPhone, the page says so and offers only Deny.
struct ApprovalPage: View {
    let approval: WatchWire.Approval
    @Environment(WatchModel.self) private var model
    @State private var askingAgain = false

    private var sending: Bool { model.sending.contains(approval.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                BotFace(avatar: approval.avatar, symbol: approval.symbol, size: 34)
                    .frame(maxWidth: .infinity)
                Text(approval.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if !approval.body.isEmpty {
                    Text(approval.body)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let check = approval.check {
                    Label(check, systemImage: "hand.raised.fill")
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let command = approval.command {
                    Text(command)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Command: \(command)")
                }
                if approval.flagged {
                    Label(WatchWords.flagged, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                }
                answers
                    .padding(.top, 4)
                if let note = model.note, model.page == approval.id {
                    NoteLine(text: note)
                }
            }
            .scenePadding(.horizontal)
        }
        .confirmationDialog(WatchWords.allowAgain, isPresented: $askingAgain) {
            Button(WatchWords.allowOnce) { send(.once) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(approval.title)
        }
    }

    @ViewBuilder private var answers: some View {
        VStack(spacing: 8) {
            switch approval.answers {
            case .allowOrDeny:
                Button {
                    approval.asksAgain ? (askingAgain = true) : send(.once)
                } label: {
                    Text(WatchWords.allowOnce).font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                // Ink, as on the iPhone in dark: a white pill, so the answer reads as the main one
                // and not as a grey, switched-off button.
                .tint(.white)
                .accessibilityIdentifier("watch.approval.once")
            case .denyOnly:
                Label(WatchWords.approveOnPhone, systemImage: "iphone")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("watch.approval.onPhone")
            }
            Button {
                send(.deny)
            } label: {
                Text(WatchWords.deny).font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("watch.approval.deny")
        }
        .disabled(sending)
        .opacity(sending ? 0.5 : 1)
        .overlay { if sending { ProgressView() } }
    }

    private func send(_ choice: WatchWire.Choice) {
        Task { await model.answer(approval, choice) }
    }
}

/// The bot's character still in a circle, or a symbol where there is none (a private bot).
struct BotFace: View {
    let avatar: String
    var symbol: String = "sparkles"
    let size: CGFloat

    var body: some View {
        Group {
            if avatar.isEmpty {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .frame(width: size, height: size)
                    .glassEffect(.regular, in: Circle())
            } else {
                Image(avatar)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
        }
        .accessibilityHidden(true)
    }
}

/// How an answer or Stop went, in a few words.
struct NoteLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }
}
