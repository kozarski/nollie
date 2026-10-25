import SwiftUI
import NollieCore

/// A symbol, a title and a line under it, in a colour: how a tab or a state says where it stands.
struct CardStance {
    var symbol: String
    var title: String
    var line: String?
    var tint: Color
}

/// Where a bot thinks, as the Model tab's title says it.
enum CardThinks: Equatable {
    case mac, plan(String), key(String?), unset

    static var macWords: String {
        #if os(macOS)
        "On this Mac"
        #else
        "On your Mac"
        #endif
    }

    var stance: CardStance {
        switch self {
        case .mac: CardStance(symbol: "desktopcomputer", title: Self.macWords, line: "Private and free.", tint: .green)
        case .plan(let name): CardStance(symbol: "person.crop.circle.badge.checkmark", title: name, line: "Uses the plan you pay for.", tint: .blue)
        case .key(let name): CardStance(symbol: "key.fill", title: "Uses an API key", line: name, tint: .indigo)
        case .unset: CardStance(symbol: "questionmark.circle", title: "Pick how it thinks", line: nil, tint: .orange)
        }
    }

    var isPlan: Bool {
        if case .plan = self { true } else { false }
    }
}

/// What a bot may touch now, as the Computer tab's title says it.
enum CardComputer {
    case usingMac, canUseMac, ownComputer(gettingReady: Bool), handsOff, checking, unknown

    var stance: CardStance {
        switch self {
        case .usingMac:
            CardStance(symbol: "cursorarrow.rays", title: "Using your Mac", line: "Turn the switch off to stop it.", tint: .orange)
        case .canUseMac:
            CardStance(symbol: "cursorarrow.rays", title: "Can use your Mac", line: "Asks in the chat first, never on schedules.", tint: .green)
        case .ownComputer(let gettingReady):
            CardStance(symbol: "macwindow", title: "Has its own computer",
                       line: gettingReady ? "Getting it ready." : "Your files stay out of reach.", tint: .green)
        case .handsOff:
            CardStance(symbol: "hand.raised.fill", title: "Hands off your Mac", line: "It can't click or type in your apps.", tint: .blue)
        case .checking:
            CardStance(symbol: "ellipsis.circle", title: "Checking", line: nil, tint: Ink.text2)
        case .unknown:
            CardStance(symbol: "wifi.exclamationmark", title: "Couldn't check", line: "Your Mac didn't answer this time.", tint: .orange)
        }
    }
}

/// A tab's short title: its symbol, a few words, and one line at most.
struct CardHeadline: View {
    var symbol: String
    var tint: Color
    var title: String
    var titleTint: Color = Ink.text
    var line: String? = nil
    /// The title's identifier; the line's is the same with `.lead` in place of `.hero`.
    var id: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            centred(title, font: .title2.weight(.bold), tone: titleTint)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(id)
            if let line {
                centred(line, font: .body, tone: Ink.text2)
                    .accessibilityIdentifier(id.replacingOccurrences(of: ".hero", with: ".lead"))
            }
        }
        .spread(.center)
        .accessibilityElement(children: .contain)
    }

    private func centred(_ words: String, font: Font, tone: Color) -> some View {
        Text(words)
            .quiet(font, tone)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A plain choice on a glass capsule: its symbol (a tick once chosen), its name, and the model it
/// uses or a word about it.
struct CardChoiceLabel: View {
    var title: String
    var symbol: String
    var tint: Color
    var value: String?
    var menu: Bool

    var body: some View {
        HStack(spacing: 14) {
            Glyph(symbol, .body.weight(.semibold), tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(title)
                .quiet(.headline, Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let value { Text(value).quiet(.body, Ink.text2).lineLimit(1) }
            if menu {
                Glyph("chevron.up.chevron.down", .footnote.weight(.semibold), Ink.text3)
                    .accessibilityHidden(true)
            }
        }
        .inset(h: 22, v: 14)
        .frame(minHeight: 54)
        .contentShape(Capsule())
        .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
        .accessibilityElement(children: .combine)
    }
}

/// One fact on an Advanced page: what it is, then the words, selectable.
struct CardFact: Identifiable {
    var title: String
    var value: String
    var monospaced = false
    var id: String { title }
}

struct CardFacts: View {
    var facts: [CardFact]

    var body: some View {
        VStack(spacing: 20) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 4) {
                    Text(fact.title).quiet(.headline, Ink.text)
                    Text(fact.value)
                        .quiet(fact.monospaced ? .body.monospaced() : .body, Ink.text2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .spread()
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// "Saved description." in green, or what went wrong in orange.
struct CardNote: View {
    var words: String
    var id: String? = nil

    var body: some View {
        let saved = words.hasPrefix("Saved")
        PageNote(words, symbol: saved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                 tint: saved ? .green : .orange, id: id)
    }
}
