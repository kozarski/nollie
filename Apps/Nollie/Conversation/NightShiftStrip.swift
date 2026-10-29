import SwiftUI
import NollieCore

@MainActor
extension ChatSession {
    /// Nollie's own main chat, where the weekly note and the morning's Night shift sit at the top of the thread.
    var isNolliesMainChat: Bool {
        profileName == "default" && BotsHome.shared.entry(runtime, "default").storedID == storedID
    }
}

/// This morning's Night shift at the top of Nollie's main chat, scrolling with it: a glass capsule with the night in
/// a few words. A tap opens the whole card with a Why? beside each step (Settings › Night shift); the cross puts it
/// away until the next morning's. The card itself stays in Settings and on the Watch.
struct NightShiftStrip: View {
    var chat: ChatSession
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @State private var opened = false

    private var summary: CrewSummaryModel { model.crewSummary }

    /// The owner's own main chat only: the card is about the owner's crew.
    private var reads: Bool { chat.isNolliesMainChat && model.runtime != nil && !model.family.isMember(model) }

    var body: some View {
        Group {
            if reads, summary.nightCardShows(), let card = summary.night {
                NightShiftCapsule(card: card, open: { opened = true }, putAway: {
                    withAnimation(reduceMotion ? nil : .snappy) { summary.putNightAway() }
                })
                .frame(maxWidth: Ink.column)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .spread(.center)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: summary.nightAt)
        .task(id: "\(model.runtime?.connection.id.uuidString ?? "")/\(reads)") { await keepReading() }
        .onChange(of: phase) { _, now in
            guard now == .active, reads, let runtime = model.runtime else { return }
            Task { await summary.loadNight(runtime) }
        }
        #if DEBUG
        .task(id: summary.nightAt) {
            // For pictures: `-nollie-demo-night` opens the whole card once this morning's has been read.
            guard DemoMode.isOn, reads, summary.nightCardShows(),
                  ProcessInfo.processInfo.arguments.contains("-nollie-demo-night") else { return }
            try? await Task.sleep(for: .seconds(2))
            opened = true
        }
        #endif
        .sheetOrSidePanel(isPresented: $opened, id: "nightShift", sheet: { NightShiftSheet(summary: summary) },
                          panel: { SidePanelPage(title: String(localized: "Night shift")) { NightShiftPage(summary: summary) } })
    }

    /// Reads the card on opening, then now and then while the chat stays open, so a morning's card arrives in a
    /// window left open overnight.
    private func keepReading() async {
        guard reads else { return }
        var force = true
        while !Task.isCancelled, let runtime = model.runtime {
            await summary.loadNight(runtime, force: force)
            force = false
            try? await Task.sleep(for: .seconds(CrewSummaryModel.nightEvery))
        }
    }
}

/// The capsule: the moon, "Night shift", the night in a few words, and a cross.
struct NightShiftCapsule: View {
    var card: ConversationPost.NightShift
    var open: () -> Void
    var putAway: () -> Void

    var body: some View {
        ThreadCapsule(symbol: "moon.stars.fill", tint: card.counts.held > 0 ? .orange : .indigo, title: Text("Night shift"),
                      line: CrewSummaryWords.night(card), hint: Text("Opens the night's work"),
                      putAwayLabel: Text("Put away until tomorrow"), id: "night.card", open: open, putAway: putAway)
    }
}

/// The whole Night shift card over the chat, as Settings shows it, with Done.
struct NightShiftSheet: View {
    var summary: CrewSummaryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NightShiftPage(summary: summary)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.testID("night.done")
                    }
                }
        }
        .sheetFrame(.wide)
    }
}
