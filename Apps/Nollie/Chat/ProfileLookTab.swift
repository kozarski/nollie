import SwiftUI
import NollieCore

/// Look: the bot's face, then its colour, and a way back to the default.
struct ProfileLookTab: View {
    var state: ProfileCardState
    /// Saved colours live in settings; reading it here redraws the ticked swatch when one is saved.
    @AppStorage(BotColors.storageKey) private var savedColours = ""
    @AppStorage(BotAvatarStore.storageKey) private var savedLooks = ""

    var body: some View {
        CardHeadline(symbol: "paintpalette.fill", tint: state.tint, title: "How \(state.label) looks", id: "profile.look.hero")
        CharacterLookPicker(profile: state.name, choice: Binding(get: { state.avatar }, set: state.chooseLook))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bot.editor.look.section")
        Swatches(state: state, current: current)
        GlassButton("Reset to default", symbol: "arrow.counterclockwise", id: "bot.editor.reset", action: state.resetLook)
    }

    private var current: String {
        _ = savedColours
        _ = savedLooks
        return BotColors.hex(for: state.name).uppercased()
    }
}

/// The colours to pick from, and the system's picker for any other.
private struct Swatches: View {
    @Bindable var state: ProfileCardState
    var current: String

    private static let offered: [(hex: String, name: String)] = {
        let extras = [("#FFFFFF", String(localized: "White", comment: "A colour")), ("#8E8E93", String(localized: "Grey", comment: "A colour")),
                      ("#A2845E", String(localized: "Brown", comment: "A colour"))]
        let named: [String: String] = [
            "#7C5CFF": String(localized: "Violet", comment: "A colour"), "#0A84FF": String(localized: "Blue", comment: "A colour"),
            "#30D158": String(localized: "Green", comment: "A colour"), "#FF9F0A": String(localized: "Orange", comment: "A colour"),
            "#FF375F": String(localized: "Pink", comment: "A colour"), "#64D2FF": String(localized: "Cyan", comment: "A colour"),
            "#BF5AF2": String(localized: "Purple", comment: "A colour"), "#FFD60A": String(localized: "Yellow", comment: "A colour"),
            "#FF6B35": String(localized: "Tangerine", comment: "A colour"), "#5AC8FA": String(localized: "Sky blue", comment: "A colour"),
        ]
        var seen = Set<String>()
        return (BotColors.palette.map { ($0, named[$0.uppercased()] ?? String(localized: "Colour \($0)", comment: "A colour by its hex code")) } + extras)
            .filter { seen.insert($0.0.uppercased()).inserted }
    }()

    private static let columns = [GridItem](repeating: .init(.flexible(), spacing: 10), count: 7)

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: 12) {
            ForEach(Self.offered, id: \.hex) { swatch in
                let ticked = current == swatch.hex.uppercased()
                PlainButton { state.chooseColour(swatch.hex) } label: {
                    Circle()
                        .fill(Color(hex: swatch.hex) ?? .gray)
                        .frame(square: 30)
                        // A thin outline keeps the white swatch visible against a white page.
                        .overlay(Circle().stroke(.primary.opacity(0.18), lineWidth: 1))
                        .padding(4)
                        .overlay(Circle().strokeBorder(.primary.opacity(ticked ? 0.6 : 0), lineWidth: 2))
                }
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(ticked ? .isSelected : [])
            }
            ColorPicker("Another colour", selection: $state.tint, supportsOpacity: false)
                .labelsHidden()
                .frame(square: 38)
                .onChange(of: state.tint) { _, picked in
                    if picked.hexString.uppercased() != current { state.chooseColour(picked.hexString) }
                }
        }
    }
}
