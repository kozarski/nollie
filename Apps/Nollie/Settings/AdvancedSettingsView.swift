import SwiftUI
import NollieCore

/// Settings › Advanced: how things are at the top (the worst Status light), then the Hermes
/// dashboard for everything about the gateway itself (models, tools, keys, sessions), the
/// Companion, and what to look at when something is wrong.
struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var setup = PushSetupModel()
    #if DEBUG
    @AppStorage(ChatDestination.newChatViewKey) private var newChatView = false
    #endif

    var body: some View {
        let hero = StatusReport(model: model, setup: setup).hero
        SettingsPage("advanced.page") {
            PageHero(symbol: hero.symbol, title: .verbatim(hero.title), line: .verbatim(hero.line), tint: hero.tint, id: "advanced.hero")
            GlassStack {
                if let rt = model.runtime {
                    if rt.connection.linkedMac != nil {
                        // Nollie Link carries the app's own routes only, not the dashboard's pages.
                        GlassRowLabel(title: String(localized: "Open the Hermes dashboard on your Mac"), symbol: "safari", chevron: false)
                            .accessibilityIdentifier("advanced.dashboard")
                    } else {
                        Link(destination: rt.connection.gateway.base) { DashboardRowLabel() }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("advanced.dashboard")
                    }
                    GlassLink("Companion", symbol: "puzzlepiece.fill", badge: model.companionUpdateAvailable ? 1 : 0,
                              id: "advanced.row.companion") { CompanionView().untitledPage() }
                }
                GlassLink("Status", symbol: "waveform.path.ecg", id: "advanced.row.status") { StatusView().untitledPage() }
                GlassLink("Troubleshooting", symbol: "wrench.and.screwdriver", id: "advanced.row.troubleshooting") {
                    TroubleshootingView().untitledPage()
                }
            }
            if model.runtime == nil {
                PageNote("Connect first to open the Hermes dashboard.")
            }
            #if DEBUG
            VStack(spacing: 14) {
                GlassSwitch("New chat view", isOn: $newChatView, id: "advanced.newChatView")
                PageNote("Opens chats on the new conversation screen. Debug builds only.")
            }
            #endif
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let rt = model.runtime { await setup.checkCompanion(runtime: rt) }
            await model.push.refreshAuthorization()
        }
    }
}

/// The dashboard's row: like the other glass rows, with an arrow for a page that opens in the browser.
private struct DashboardRowLabel: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "safari")
                .font(.body.weight(.semibold))
                .foregroundStyle(Ink.text2)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text("Open Hermes dashboard").font(.headline).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(Ink.text3)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .frame(minHeight: 54)
        .contentShape(Capsule())
        .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
        .accessibilityElement(children: .combine)
    }
}
