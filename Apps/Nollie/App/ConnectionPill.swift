import SwiftUI
import NollieCore

/// A small glass pill with a coloured dot and the connection state, for navigation bars.
struct ConnectionPill: View {
    var state: SocketState

    private var dot: Color {
        switch state {
        case .open: .green
        case .connecting, .reconnecting: .orange
        case .authRejected, .failed: .red
        case .idle: .gray
        }
    }

    var body: some View {
        Label {
            Text(state.label).small(.caption, .secondary)
        } icon: {
            Circle().fill(dot).frame(width: 8, height: 8)
        }
        .labelStyle(DotAndWordStyle())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .nollieGlass(.regular, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection: \(state.label)")
    }
}

private struct DotAndWordStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}
