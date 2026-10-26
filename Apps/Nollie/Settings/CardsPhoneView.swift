import NollieCore
import SwiftUI

/// The top of Cards, on both devices: how many cards are saved, or that they are locked.
struct CardsHero: View {
    /// nil while the list is locked.
    var count: Int?
    /// The assistant runs on another computer, so no helper can pay from this one.
    var elsewhere = false

    var body: some View {
        if elsewhere {
            PageHero(symbol: "desktopcomputer.trianglebadge.exclamationmark", title: "Not in use",
                     line: "Your assistant runs on another computer, so helpers can't pay from here.",
                     tint: .orange, id: "cards.hero")
        } else if let count {
            PageHero(symbol: "creditcard.fill", title: Self.title(count),
                     line: "Helpers pay only after your yes. They never see the number.",
                     tint: count == 0 ? .blue : .green, id: "cards.hero")
        } else {
            PageHero(symbol: "lock.fill", title: "Cards", line: DeviceWords.isMac ? "Touch ID shows them." : "Face ID shows them.",
                     tint: Ink.text, id: "cards.hero")
        }
    }

    /// "No cards yet", "1 card", "2 cards".
    static func title(_ count: Int) -> String {
        switch count {
        case 0: "No cards yet"
        case 1: "1 card"
        default: "\(count) cards"
        }
    }

    /// What keeps a payment safe, as a few symbols.
    static var facts: [Fact] {
        [Fact(symbol: "hand.raised.fill", word: "First buy asks"),
         Fact(symbol: "lock.fill", word: DeviceWords.isMac ? "Touch ID" : "Face ID"),
         Fact(symbol: "number", word: "Code each time")]
    }
}

/// One saved card as a glass row: "Visa ending 4242", and on the Mac's wider page the name on it.
struct CardRow: View {
    var label: String
    var holder: String

    var body: some View {
        GlassRowLabel(title: label, symbol: "creditcard.fill", value: DeviceWords.isMac && !holder.isEmpty ? holder : nil,
                      chevron: false)
            .accessibilityLabel(holder.isEmpty ? label : "\(label), \(holder)")
    }
}

/// Settings › Cards on the iPhone: the cards saved on the Mac, after Face ID. Cards are added on the Mac,
/// where helpers' computers run, and the iPhone never holds a number.
struct PhoneCardsView: View {
    @Environment(AppModel.self) private var model
    @State private var cards: [PaymentCardLabel]?
    @State private var unlocked = false
    @State private var problem: String?

    var body: some View {
        SettingsPage("cards.page") {
            CardsHero(count: unlocked ? cards?.count : nil)
            if unlocked {
                FactStrip(facts: CardsHero.facts, id: "cards.facts")
                if let cards, !cards.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(cards) { card in
                            CardRow(label: card.label, holder: card.holder).testID("cards.row.\(card.last4)")
                        }
                    }
                }
                PageNote("Add and remove cards in Nollie on your Mac. That's where helpers pay.", symbol: "desktopcomputer",
                         id: "cards.onMac")
            } else {
                GlassButton("Show cards", symbol: "faceid", id: "cards.show") { Task { await unlock() } }
            }
            if let problem {
                PageNote(problem, symbol: "exclamationmark.triangle.fill", tint: .orange, id: "cards.problem")
            }
        }
        .task {
            #if DEBUG
            // Pictures open the page as if Face ID had just passed (with `-nollie-demo-biometry yes`).
            if DemoMode.isOn { await unlock() }
            #endif
        }
    }

    private func unlock() async {
        guard await RememberedSignInCoordinator.defaultAuthenticator().authenticate(reason: "Show your cards") != nil else { return }
        guard let runtime = model.runtime else { return }
        do {
            cards = try await runtime.paymentCards()
            problem = nil
            unlocked = true
        } catch {
            problem = "Couldn't reach your Mac. Try again."
        }
    }
}
