import SwiftUI
import NollieCore

/// A helper the bot started. Shows its goal, what it is doing while it runs, and, once it is
/// back, with its report folded below, like the output of a tool card.
struct SubagentRow: View {
    var activity: SubagentActivity

    @State private var open = false

    private var report: String? {
        guard let text = activity.summary, !text.isEmpty else { return nil }
        return text
    }

    private var badge: (name: String, tint: Color) {
        if activity.failed { return ("person.2.slash", .red) }
        return activity.isRunning ? ("person.2.circle", .accentColor) : ("person.2.circle.fill", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if open, let report { opened(report) }
        }
        .font(.footnote)
        .padding(10)
        .nollieGlass(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(perform: toggleReport)
        // This detail line follows the helper's reports and has no animation of its own. Give it one and
        // the card resizes alone while the rows near it snap, and when the line gets shorter the card
        // paints over the following row until it settles.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Subagent: \(activity.goal). \(activity.detailLine ?? "")")
    }

    private func toggleReport() {
        guard report != nil else { return }
        withAnimation(.snappy) { open.toggle() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            // The slashed glyph is wider; a fixed width keeps the text aligned in every state.
            Glyph(badge.name, .body, badge.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.goal).lineLimit(3)
                detailText
            }
            Spacer(minLength: 4)
            trailing
        }
    }

    @ViewBuilder private var detailText: some View {
        if let line = activity.detailLine {
            Text(line).quiet().lineLimit(2).contentTransition(.opacity)
        }
    }

    @ViewBuilder private var trailing: some View {
        if activity.isRunning {
            ProgressView().controlSize(.small)
        } else if report != nil {
            Glyph(open ? "chevron.up" : "chevron.down", .caption2.weight(.bold), .secondary)
        }
    }

    private func opened(_ report: String) -> some View {
        Text(report)
            .font(.caption)
            .textSelection(.enabled)
            .spread()
            .transition(.move(edge: .top).combined(with: .opacity))
            .padding(.top, 2)
    }
}
