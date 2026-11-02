import SwiftUI
import NollieCore

/// The ask before a helper's words first go to an online model: who gets them, what goes, and Allow.
struct OnlineModelAskSheet: View {
    var ask: OnlineModelConsent.Ask
    var answer: (Bool) -> Void

    var body: some View {
        FittedSheet { card }
    }

    /// The companies the gateway named. Empty when it didn't say which model the helper uses.
    private var known: [ModelCompany] { ask.companies.filter { $0.id != OnlineModelConsent.unknownCompany.id } }

    /// "Anthropic", or "Anthropic and OpenAI".
    private var who: String { ListFormatter.localizedString(byJoining: known.map(\.name)) }

    var card: some View {
        VStack(spacing: 18) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 72, height: 72)
                .nollieGlass(.regular, in: Circle())
                .accessibilityHidden(true)
            Group {
                if known.isEmpty {
                    Text("Share with an online model?", comment: "Privacy: the ask before words first go to an online model the gateway didn't name")
                } else {
                    Text("Share with \(who)?", comment: "Privacy: the ask before words first go to an online model; %@ names one or more companies")
                }
            }
            .font(.title2.weight(.bold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            Group {
                if known.isEmpty {
                    Text("\(ask.bot) uses an online model. To answer, it sends:", comment: "Privacy: a helper's name; a list of what goes follows")
                } else {
                    Text("\(ask.bot) uses an online model from \(who). To answer, it sends:",
                         comment: "Privacy: a helper's name, then one or more companies; a list of what goes follows")
                }
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                item("text.bubble", String(localized: "What you write, and the files and photos you add", comment: "Privacy: what goes to an online model"))
                item("globe", String(localized: "What it reads for you, like web pages, and your calendar, reminders or contacts if you let it", comment: "Privacy: what goes to an online model"))
                item("brain", String(localized: "What it remembers about you", comment: "Privacy: what goes to an online model; a helper's memory"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if ask.demo {
                Text("This is the demo, so nothing leaves \(DeviceWords.this).", comment: "Privacy: %@ is a phrase like this iPhone")
                    .small(.footnote, .secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                Button { answer(true) } label: { Text("Allow", comment: "Privacy: lets words go to an online model's company").fullWidthLabel() }
                    .buttonStyle(.nollieGlassProminent)
                    .accessibilityIdentifier("onlineModel.allow")
                Button { answer(false) } label: { Text("Not now", comment: "Privacy: sends nothing to an online model's company") }
                    .small(.subheadline)
                    .accessibilityIdentifier("onlineModel.notNow")
            }
            .padding(.top, 4)
            footnote
        }
        .sheetColumn()
        .accessibilityIdentifier("onlineModel.ask")
    }

    private func item(_ symbol: String, _ words: String) -> some View {
        Label {
            Text(words).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }

    private var footnote: some View {
        VStack(spacing: 6) {
            Text("Nothing goes until you allow it. Each company's own privacy policy covers what it gets. You can change this in Settings \u{203A} Privacy.",
                 comment: "Privacy: under the ask before words first go to an online model")
                .small(.caption, .secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(known.filter { $0.privacyPolicy != nil }) { company in
                Link(String(localized: "\(company.name) privacy policy", comment: "Privacy: a link; %@ is a company"), destination: company.privacyPolicy!)
                    .small(.caption)
            }
            Link(String(localized: "How Nollie handles your data", comment: "Privacy: a link to Nollie's privacy policy"), destination: URL(string: "https://nollie.app/privacy")!)
                .small(.caption)
        }
    }
}

/// Shows the ask over this chat when it is the one asking. With no chat, it shows it over this window or
/// sheet when that is the newest one open and the words come from outside a chat.
struct OnlineModelAskHost: ViewModifier {
    var chat: ChatSession?
    @State private var id = UUID()
    private var consent: OnlineModelConsent { .shared }

    private func mine(_ ask: OnlineModelConsent.Ask?) -> Bool {
        guard let ask else { return false }
        if let chat { return ask.chat == ObjectIdentifier(chat) }
        return ask.host == id
    }

    private var shown: Binding<OnlineModelConsent.Ask?> {
        Binding(get: { mine(consent.pending) ? consent.pending : nil },
                set: { if $0 == nil, mine(consent.pending) { consent.answer(false) } })
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: shown) { ask in
                OnlineModelAskSheet(ask: ask) { consent.answer($0) }
                    .withAppModel()
            }
            .onAppear {
                if let chat { consent.chatAppeared(chat) } else { consent.hostAppeared(id) }
            }
            .onDisappear {
                if let chat { consent.chatWent(chat) } else { consent.hostWent(id) }
            }
    }
}

extension View {
    /// Hosts the ask before words first go to an online model: over `chat`, or with none, over this
    /// window or sheet.
    func onlineModelAsk(over chat: ChatSession? = nil) -> some View {
        modifier(OnlineModelAskHost(chat: chat))
    }
}
