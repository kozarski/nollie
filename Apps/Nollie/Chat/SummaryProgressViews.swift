import SwiftUI
import NollieCore

/// Small sparkle next to a chat title that was written on the device.
/// Pulses while the title is being written or queued, sits still once it is done.
/// It reads the summarizer directly, so rows don't refresh when some other chat's summary starts.
struct SummarySparkle: View {
    /// Stored id of the chat.
    var key: String
    /// True when the row already shows a current summary.
    var done: Bool

    private static let pulseSpeed = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    private var busy: Bool { ChatSummarizer.shared.isWorking(key) }

    var body: some View {
        if busy || done {
            sparkle(busy: busy)
        }
    }

    private func sparkle(busy: Bool) -> some View {
        let calm = busy && reduceMotion
        return Image(systemName: "sparkles")
            .font(.caption2)
            .opacity(calm ? 0.55 : 1)
            .symbolEffect(.pulse, options: .repeating.speed(Self.pulseSpeed), isActive: !reduceMotion && busy)
            .foregroundStyle(busy ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .accessibilityLabel(busy ? "Summarizing" : "Summarized on device")
    }
}

/// What the strip over the chat list should say right now.
private enum StripNote {
    case counting(current: Int, total: Int, fraction: Double)
    case finished
    case none

    /// Which kind of note it is, ignoring the numbers, so only a change of kind animates.
    var kind: Int {
        switch self {
        case .counting: 1
        case .finished: 2
        case .none: 0
        }
    }
}

/// Floats over the bottom of the chat list while several summaries are being written, then says
/// "up to date" briefly. It is an inset over the list, not a row, so nothing moves.
/// A single chat gets no strip, its sparkle is enough.
struct SummaryProgressStrip: View {
    @State private var lingering = false

    private func note(_ s: ChatSummarizer) -> StripNote {
        let p = s.progress
        if s.enabled, p.isWorking, p.total > 1 {
            return .counting(current: p.current, total: p.total, fraction: p.fraction)
        }
        return lingering ? .finished : .none
    }

    var body: some View {
        let summarizer = ChatSummarizer.shared
        let current = note(summarizer)
        ZStack {
            switch current {
            case let .counting(now, total, fraction):
                StripPill(icon: "sparkles", tint: .accentColor) {
                    Text("Summarizing \(now) of \(total)").monospacedDigit()
                    ProgressView(value: fraction).frame(width: 44)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Summarizing \(now) of \(total)")
            case .finished:
                StripPill(icon: "checkmark.circle.fill", tint: .green) {
                    Text("Summaries up to date")
                }
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            case .none:
                EmptyView()
            }
        }
        .animation(.snappy, value: current.kind)
        .onChange(of: summarizer.finishedAt) { _, stamp in
            guard let stamp else { return }
            lingering = true
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                // A newer run may have finished in the meantime and owns the note.
                if summarizer.finishedAt == stamp { lingering = false }
            }
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("summaries.progress")
    }
}

private struct StripPill<Rest: View>: View {
    var icon: String
    var tint: Color
    @ViewBuilder var rest: Rest

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            rest
        }
        .font(.caption.weight(.medium))
        .inset(h: 12, v: 6)
        .nollieGlass(.regular, in: .capsule)
        .padding(.init(top: 4, leading: 0, bottom: 10, trailing: 0))
    }
}
