import SwiftUI
import NollieCore

/// What to say to Siri, as symbol and words, in the order they show. Each works with no setup.
enum SiriLines {
    static let common: [(symbol: String, words: String)] = [
        ("bubble.left.and.text.bubble.right.fill", String(localized: "Ask Nollie", comment: "Something to say to Siri; match the Siri phrase in this language")),
        ("eye.fill", String(localized: "What is Nollie doing", comment: "Something to say to Siri; match the Siri phrase in this language")),
        ("stop.circle.fill", String(localized: "Stop Nollie", comment: "Something to say to Siri; match the Siri phrase in this language")),
        ("square.and.pencil", String(localized: "New chat in Nollie", comment: "Something to say to Siri; match the Siri phrase in this language")),
        ("bubble.left.fill", String(localized: "Open my Travel chat in Nollie", comment: "Something to say to Siri; match the Siri phrase in this language")),
    ]
    static let approval = (symbol: "checkmark.shield.fill", words: String(localized: "Answer the approval in Nollie", comment: "Something to say to Siri; match the Siri phrase in this language"))

    static func shown(approvals: Bool) -> [(symbol: String, words: String)] {
        approvals ? common + [approval] : common
    }
}

/// Settings › Siri & Shortcuts: what to say to Siri, whether chats show in Spotlight, Stop on
/// the Lock Screen (iPhone), and answering approvals by voice behind Advanced.
struct SiriSettingsView: View {
    @AppStorage(SiriCatalog.spotlightKey) private var inSpotlight = SiriCatalog.spotlightDefault
    @AppStorage(SiriCatalog.approvalsKey) private var byVoice = false
    #if os(iOS)
    @AppStorage(HelperAtWorkSetting.key) private var lockScreenStop = HelperAtWorkSetting.defaultOn
    #endif

    var body: some View {
        SettingsPage("siri.page") {
            PageHero(symbol: "waveform", title: "Ask Siri",
                     line: inSpotlight ? LocalizedStringResource("Chats show in Spotlight too.") : LocalizedStringResource("Chats stay out of Spotlight."),
                     tint: .purple, id: "siri.hero")
            switches
            #if os(iOS)
            PageNote(.verbatim(HelperAtWorkWords.settingFooter))
            #endif
            phrases
            AdvancedLink(id: "siri.advanced") { SiriAdvancedView().untitledPage() }
        }
    }

    private var switches: some View {
        GlassStack {
            GlassSwitch("Show chats in Spotlight", isOn: $inSpotlight, id: "siri.spotlight")
                .onChange(of: inSpotlight) { Task { await SiriCatalog.syncSpotlight() } }
            #if os(iOS)
            GlassSwitch(.verbatim(HelperAtWorkWords.setting), isOn: $lockScreenStop, id: "siri.stopActivity")
                .onChange(of: lockScreenStop) { HelperAtWorkActivities.shared.settingChanged() }
            #endif
        }
    }

    private var phrases: some View {
        VStack(spacing: 18) {
            PageHeading("Try saying")
            ForEach(SiriLines.shown(approvals: byVoice), id: \.words) { SiriPhrase(symbol: $0.symbol, text: $0.words) }
        }
        .accessibilityElement(children: .contain)
        .testID("siri.phrases")
    }
}

/// One thing to say, large enough to read at a glance.
private struct SiriPhrase: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.purple)
                .frame(width: 30)
                .accessibilityHidden(true)
            Text("“\(text)”")
                .font(.title3.weight(.medium))
                .foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Siri & Shortcuts › Advanced: answering approvals by voice, off unless you turn it on.
private struct SiriAdvancedView: View {
    @AppStorage(SiriCatalog.approvalsKey) private var byVoice = false

    var body: some View {
        SettingsPage("siri.advanced.page") {
            PageHero(symbol: "checkmark.shield.fill", title: byVoice ? "Siri can answer" : "Siri won't answer",
                     line: "Approvals, by voice.", tint: byVoice ? .purple : Ink.text2, id: "siri.advanced.hero")
            GlassSwitch("Answer approvals by voice", isOn: $byVoice, id: "siri.approvals")
            PageNote("Siri reads the approval to you and checks before it answers. Sign-ins still need you in Nollie.")
        }
    }
}
