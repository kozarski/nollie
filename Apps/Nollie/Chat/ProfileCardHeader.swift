import SwiftUI
import NollieCore

/// The face, large and centred, the name, and today's answer from the bot's Papertrail (else its
/// description). VoiceOver reads them as one header.
struct ProfileCardHeader: View {
    var state: ProfileCardState
    var today: PapertrailToday?
    var botState: CharacterState
    var floating: Bool

    private var line: String { today?.headline ?? state.savedBlurb }

    var body: some View {
        VStack(spacing: 14) {
            BotAvatar(profile: state.name, size: 132, state: botState)
                .padding(.top, floating ? 48 : 12)
            VStack(spacing: 8) {
                Text(state.label).font(.largeTitle.weight(.bold)).foregroundStyle(Ink.text)
                if let today {
                    Label(today.headline, systemImage: today.symbol)
                        .quiet(.headline, today.tint)
                        .accessibilityIdentifier("profile.today")
                } else if !state.savedBlurb.isEmpty {
                    Text(state.savedBlurb).quiet(.body, Ink.text2)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 560)
            .inset(h: 24)
        }
        .spread(.center)
        .animation(.snappy, value: today)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.isEmpty ? state.label : "\(state.label). \(line)")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("profile.header")
    }
}

#if os(iOS)
/// A round Close button on the left and, when opened from a chat, a round more menu on the right,
/// floating above the header. Both sit on a strip of system material that fades in once rows have
/// scrolled beneath, so content never shows through the circles.
struct ProfileCardControls: View {
    var scrolled: CGFloat
    var canRename: Bool
    var close: () -> Void
    var rename: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var solid

    var body: some View {
        HStack {
            PlainButton(action: close) { disc("xmark") }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("profile.close")
            Spacer()
            if canRename {
                Menu {
                    Button(action: rename) { Label("Rename chat", systemImage: "pencil") }
                } label: { disc("ellipsis") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("profile.more")
            }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16))
        .background(alignment: .top) { band }
    }

    /// A frosted strip behind the buttons. Invisible until the card has scrolled 20 points, then
    /// it fades in over the next 60.
    private var band: some View {
        let solidThenClear = Gradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.6),
            .init(color: .clear, location: 1),
        ])
        let strength = max(0, min(1, (scrolled - 20) / 60))
        return Rectangle()
            .fill(.regularMaterial)
            .frame(height: 84)
            .mask(LinearGradient(gradient: solidThenClear, startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea()
            .opacity(strength)
            .allowsHitTesting(false)
    }

    /// A glass circle 40 points wide; with Reduce Transparency on, it is solid.
    @ViewBuilder private func disc(_ symbol: String) -> some View {
        let face = Glyph(symbol, .body.weight(.semibold), .primary).frame(square: 40).contentShape(.circle)
        if solid {
            face.background {
                Circle().fill(Color(.secondarySystemGroupedBackground)).overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 1))
            }
        } else {
            face.nollieGlass(.regular.interactive(), in: .circle)
        }
    }
}
#endif
