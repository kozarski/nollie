import NollieCore
import SwiftUI

/// Settings › Cards on the Mac: after Touch ID, the saved cards as "Visa ending 4242", adding and
/// removing them, and quick pay. Numbers stay in this Mac's Keychain; the security code is never kept.
struct CardsSettingsView: View {
    @Environment(AppModel.self) private var model
    var center: CardCenter = .shared
    /// Recent payments, injected for pictures; read from the add-on otherwise.
    var fixedHistory: [PaymentHistoryEntry]? = nil
    @State private var unlocked = false
    @State private var adding = false
    @State private var removing: SavedCard?
    @State private var history: [PaymentHistoryEntry] = []
    @State private var problem: String?

    private var store: SavedCardStore { center.store }
    private var settings: PaymentSettings { center.rules.settings }

    /// Helpers pay only for an assistant on this very Mac.
    private var elsewhere: Bool {
        guard let rt = model.runtime else { return false }
        return !rt.gatewayIsOnThisMac
    }

    var body: some View {
        let shown = Array((fixedHistory ?? history).prefix(30))
        SettingsPage("cards.page") {
            CardsHero(count: unlocked ? store.items.count : nil, elsewhere: elsewhere && unlocked)
            if unlocked {
                FactStrip(facts: CardsHero.facts, id: "cards.facts")
                cards
                quickPay
                if let last = shown.first {
                    PageNote("\(Self.line(last, bot: botName(last.bot))), \(SignInsSettingsView.time(last.at))",
                             symbol: "clock", id: "cards.last")
                }
                AdvancedLink(id: "cards.advanced") {
                    CardsAdvanced(center: center, entries: shown, botName: botName).untitledPage()
                }
            } else {
                GlassButton("Show cards", symbol: "touchid", id: "cards.show") { Task { await unlock() } }
            }
            if let problem {
                PageNote(problem, symbol: "exclamationmark.triangle.fill", tint: .orange, id: "cards.problem")
            }
        }
        .animation(.snappy, value: unlocked)
        .task {
            #if DEBUG
            // Pictures open the page as if Touch ID had just passed (with `-nollie-demo-biometry yes`).
            if DemoMode.isOn {
                await unlock()
                adding = ProcessInfo.processInfo.arguments.contains("-nollie-demo-card-editor")
            }
            #endif
        }
        .sheet(isPresented: $adding) {
            CardEditor(store: store) { adding = false }.withAppModel()
        }
        .confirmationDialog(removing.map { "Remove \($0.label)?" } ?? "", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let card = removing {
                    do { try store.remove(card); problem = nil } catch { problem = error.localizedDescription }
                }
                removing = nil
            }
        } message: {
            Text("Helpers can't pay with it after this.")
        }
    }

    private var cards: some View {
        VStack(spacing: 12) {
            ForEach(store.items) { card in
                CardRow(label: card.label, holder: card.holder)
                    .contextMenu { Button("Remove…", role: .destructive) { removing = card } }
                    .testID("cards.row.\(card.last4)")
            }
            Button { adding = true } label: {
                Label("Add card", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.nollieGlassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .testID("cards.add")
        }
    }

    /// One switch, its limit once it is on, and the line that says what still asks.
    @ViewBuilder private var quickPay: some View {
        VStack(spacing: 12) {
            GlassSwitch("Skip the card on sites I've paid", isOn: Binding(
                get: { settings.quickPay },
                set: { on in change { $0.quickPay = on } }), id: "cards.quickPay")
            if settings.quickPay {
                GlassChoice("Up to", selection: Binding(
                    get: { settings.quickLimit },
                    set: { limit in change { $0.quickLimit = limit } }),
                            options: PaymentSettings.limits.map { ($0, PaymentMoney.text($0, settings.currency)) },
                            id: "cards.quickLimit")
            }
            // Money: the one place a footer earns its words.
            PageNote(settings.quickPay ? "A first payment to a site always asks. Your Mac still asks for the security code."
                                       : "Every payment asks you first.",
                     symbol: "hand.raised.fill", id: "cards.quickPay.note")
        }
    }

    private func change(_ edit: (inout PaymentSettings) -> Void) {
        do { try center.rules.update(edit); problem = nil } catch { problem = "Couldn't save that. Try again." }
    }

    private func unlock() async {
        guard await store.confirmOwner(reason: "show your cards") != nil else { return }
        store.reload()
        unlocked = true
        guard fixedHistory == nil, let rt = model.runtime, rt.gatewayIsOnThisMac else { return }
        history = (try? await rt.paymentHistory(days: 30)) ?? []
    }

    private func botName(_ profile: String) -> String {
        model.runtime?.profiles.first { $0.name == profile }?.shownName ?? profile.capitalized
    }

    /// What happened, in a few words.
    static func line(_ entry: PaymentHistoryEntry, bot: String) -> String {
        let amount = entry.total.flatMap(PaymentMoney.amount).map { PaymentMoney.text($0, entry.currency ?? "") }
        let what = amount.map { "\($0) on \(entry.site)" } ?? entry.site
        switch entry.outcome {
        case "paid": return "\(bot) paid \(what)"
        case "declined": return "You said no to \(bot), \(what)"
        case "cancelled": return "You stopped \(bot), \(what)"
        case "no_answer", "expired": return "No answer for \(bot), \(what)"
        case "refused": return "Not allowed: \(bot), \(what)"
        default: return "\(bot) couldn't pay \(what)"
        }
    }
}

/// Cards › Advanced: the currency the person pays in, and every payment in the last 30 days.
private struct CardsAdvanced: View {
    var center: CardCenter
    var entries: [PaymentHistoryEntry]
    var botName: (String) -> String

    private var currencies: [String] {
        Array(Set(["GBP", "EUR", "USD", PaymentMoney.homeCurrency(), center.rules.settings.currency])).sorted()
    }

    var body: some View {
        SettingsPage("cards.recent") {
            PageHero(symbol: "clock.arrow.circlepath", title: "Payments", line: "The last 30 days.", tint: Ink.text,
                     id: "cards.recent.hero")
            GlassChoice("Pays in", selection: Binding(
                get: { center.rules.settings.currency },
                set: { code in try? center.rules.update { $0.currency = code } }),
                        options: currencies.map { ($0, $0) }, id: "cards.currency")
            VStack(spacing: 20) {
                ForEach(Array(entries.enumerated()), id: \.offset) { i, entry in
                    let line = CardsSettingsView.line(entry, bot: botName(entry.bot))
                    let card = entry.card.map { "Card ending \($0)" }
                    let time = SignInsSettingsView.time(entry.at)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line).font(.body.weight(.medium)).foregroundStyle(Ink.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if let card { Text(card).font(.body).foregroundStyle(Ink.text2) }
                        }
                        Spacer(minLength: 8)
                        Text(time).font(.body).foregroundStyle(Ink.text2).monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([line, card ?? "", time].filter { !$0.isEmpty }.joined(separator: ", "))
                    .testID("cards.history.\(i)")
                }
            }
        }
    }
}

/// Adding one card: the number, expiry and name, saved after Touch ID. The security code is not asked
/// here: it is typed each time a helper pays, and never kept.
struct CardEditor: View {
    var store: SavedCardStore
    var done: () -> Void
    @State private var number = ""
    @State private var expiry = ""
    @State private var holder = ""
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add card").font(.title2.weight(.semibold))
            Form {
                TextField("Card number", text: $number, prompt: Text("1234 5678 9012 3456"))
                    .textContentType(.creditCardNumber)
                    .font(.body.monospacedDigit())
                    .testID("cards.number")
                TextField("Expiry", text: $expiry, prompt: Text("MM/YY"))
                    .textContentType(.creditCardExpiration)
                    .font(.body.monospacedDigit())
                    .testID("cards.expiry")
                TextField("Name on card", text: $holder, prompt: Text("As printed"))
                    .textContentType(.creditCardName)
                    .testID("cards.holder")
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Label("The security code is asked each time you pay, and never kept.", systemImage: "number")
                .font(.callout)
                .foregroundStyle(Ink.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Ink.warnText).testID("cards.editor.problem")
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: done).buttonStyle(OutlinePillStyle(fill: false))
                Button(action: save) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "lock.fill").imageScale(.small).accessibilityHidden(true)
                        Text("Save")
                    }
                }
                .buttonStyle(InkPillStyle(fill: false))
                .keyboardShortcut(.defaultAction)
                .disabled(saving || number.isEmpty || expiry.isEmpty || holder.isEmpty)
                .accessibilityHint("Asks for Touch ID, then saves the card on this Mac.")
                .testID("cards.save")
            }
        }
        .padding(24)
        .frame(width: 440)
        .onDisappear { number = ""; expiry = ""; holder = "" }
        #if DEBUG
        .onAppear {
            // Pictures show a payment provider's published test card, never a real one.
            if DemoMode.isOn { number = "4242 4242 4242 4242"; expiry = "12/34"; holder = "Sam Example" }
        }
        #endif
    }

    private func save() {
        // Check what can be checked before asking for Touch ID.
        guard CardNumber.valid(number) != nil else { problem = SavedCardError.badNumber.errorDescription; return }
        guard CardExpiry(expiry) != nil else { problem = SavedCardError.badExpiry.errorDescription; return }
        saving = true
        Task {
            defer { saving = false }
            guard await store.confirmOwner(reason: "save this card") != nil else { return }
            do {
                try store.add(number: number, expiry: expiry, holder: holder)
                done()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
