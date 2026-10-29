import SwiftUI
import NollieCore

/// Settings › Keep awake: whether the Mac stays awake for the crew, what it is doing now, one switch.
struct KeepAwakeView: View {
    @State private var awake = MacKeepAwake.shared

    var body: some View {
        KeepAwakePage(hero: KeepAwakeHero.State(on: awake.isOn, decision: awake.decision), laptop: awake.hasBattery,
                      isOn: Binding(get: { awake.isOn }, set: { awake.isOn = $0 }))
            .animation(.snappy, value: awake.decision)
            .task { await awake.refresh() }
    }
}

/// What the page shows, apart from where it comes from.
struct KeepAwakePage: View {
    var hero: KeepAwakeHero.State
    var laptop: Bool
    @Binding var isOn: Bool

    var body: some View {
        SettingsPage("awake.page") {
            KeepAwakeHero(state: hero)
            FactTiles(leading: FactTile(title: "Plugged in", tint: .green,
                                        facts: [Fact(symbol: "hammer.fill", word: "While helpers work"),
                                                Fact(symbol: "clock.fill", word: "Until tonight's schedules")],
                                        id: "awake.pluggedIn"),
                      trailing: FactTile(title: "On battery", tint: Ink.text2,
                                         facts: [Fact(symbol: "hammer.fill", word: "While helpers work"),
                                                 Fact(symbol: "battery.25percent", word: "Never below 20%")],
                                         id: "awake.battery"))
            VStack(spacing: 12) {
                GlassSwitch("Keep Mac awake for my crew", isOn: $isOn, id: "awake.switch")
                PageNote(laptop ? "The screen still sleeps. Keep the lid open." : "The screen still sleeps.",
                         symbol: laptop ? "laptopcomputer" : "display", id: "awake.note")
            }
        }
    }
}

/// The top of the page: what the Mac does now, in its own colour.
struct KeepAwakeHero: View {
    enum State: Equatable {
        case off, elsewhere, working, due(Date), resting, ready

        init(on: Bool, decision: KeepAwakePolicy.Decision) {
            switch (on, decision) {
            case (false, _), (_, .sleep(.off)): self = .off
            case (_, .sleep(.elsewhere)): self = .elsewhere
            case (_, .sleep(.lowBattery)): self = .resting
            case (_, .sleep(.nothingDue)): self = .ready
            case (_, .awake(.working)): self = .working
            case (_, .awake(.due(let date))): self = .due(date)
            }
        }

        var symbol: String {
            switch self {
            case .off: "moon.zzz.fill"
            case .elsewhere: "desktopcomputer.trianglebadge.exclamationmark"
            case .working, .due: "sun.max.fill"
            case .resting: "battery.25percent"
            case .ready: "checkmark.circle.fill"
            }
        }
        var title: String {
            switch self {
            case .off: String(localized: "Sleeps as usual")
            case .elsewhere: String(localized: "Your crew runs elsewhere")
            case .working, .due: String(localized: "Awake for your crew")
            case .resting: String(localized: "Saving battery")
            case .ready: String(localized: "Ready", comment: "The Mac is ready and sleeps as usual")
            }
        }
        func line(clock: SleepNote.Clock = SleepNote.clock) -> String {
            switch self {
            case .off: String(localized: "Schedules wait while it sleeps.")
            case .elsewhere: String(localized: "That computer has to stay awake.")
            case .working: String(localized: "A helper is working.")
            case .due(let date): String(localized: "Next schedule at \(clock(date)).")
            case .resting: String(localized: "Your Mac can sleep.")
            case .ready: String(localized: "Nothing due. It sleeps as usual.")
            }
        }
        var tint: Color {
            switch self {
            case .off: .indigo
            case .elsewhere, .resting: .orange
            case .working, .due: .green
            case .ready: .blue
            }
        }
    }

    var state: State

    var body: some View {
        PageHero(symbol: state.symbol, title: .verbatim(state.title), line: .verbatim(state.line()), tint: state.tint, id: "awake.hero")
    }
}
