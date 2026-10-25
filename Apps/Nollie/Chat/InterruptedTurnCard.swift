import SwiftUI
import NollieCore

/// Sits where a turn broke off early, instead of a bare error bubble. A single muted line with a
/// Why? button explaining the cause and what lets long jobs carry on. When the app knows it spent
/// time in the background, the explanation opens by itself.
struct InterruptedTurnCard: View {
    var turn: InterruptedTurn
    private static let wash = Color.orange.opacity(0.1)
    var cause: InterruptedTurn.Cause?
    /// Goes to the gateway's setting for keeping work running.
    var onKeepRunning: () -> Void

    @State private var expanded: Bool = false

    private var stoppedByYou: Bool { cause == .stopped }
    private var pausedForUpdate: Bool { cause == .pausedForUpdate }
    private var showsExplanation: Bool { !stoppedByYou && !pausedForUpdate && (expanded || cause == .appWasAway) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            ForEach(notes, id: \.self) { note in
                Text(note).quiet(.footnote)
            }
            if showsExplanation { keepRunningButton }
        }
        .padding(12)
        .spread()
        .background(Self.wash, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    /// The small grey lines under the title, in order.
    private var notes: [String] {
        var lines: [String] = []
        if pausedForUpdate {
            return ["Nollie was updating itself. Send a message to pick up where it left off."]
        }
        if !stoppedByYou, let doing = turn.doing {
            let stopped = doing.lowercased().hasPrefix("during")
            lines.append(stopped ? "It was stopped \(doing)." : "It was \(doing).")
        }
        if showsExplanation {
            lines.append(explanation)
            lines.append("Send a message to pick up where it left off.")
        }
        return lines
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Label(headline, systemImage: "stop.circle")
                .fontWeight(.semibold)
                .font(.subheadline)
            Spacer()
            if cause == nil { whyToggle }
        }
    }

    private var headline: String {
        if pausedForUpdate { return "Paused for an update" }
        return stoppedByYou ? "You stopped this turn" : "Stopped before it finished"
    }

    private var whyToggle: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            Text(expanded ? "Hide" : "Why?").font(.caption)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("interrupted.why")
    }

    private var keepRunningButton: some View {
        Button("Keep work running…", systemImage: "hourglass", action: onKeepRunning)
            .controlSize(.small)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("interrupted.keepRunning")
    }

    /// Why a turn can end without anyone pressing Stop.
    private var explanation: String {
        let why = cause == .appWasAway
            ? "Nollie was not connected, so the gateway ended this turn."
            : "Either Stop was pressed, or no app was connected to this chat and the gateway ended the turn."
        let drop = DeviceWords.isMac
            ? "When a Mac sleeps or loses its network, it drops the gateway connection."
            : "iOS pauses an app soon after you leave it, and that drops the gateway connection."
        let grace = "With no app on a chat, the gateway waits a short while (20 seconds unless changed) and then stops the turn."
        return [why, drop, grace].joined(separator: " ")
    }
}
