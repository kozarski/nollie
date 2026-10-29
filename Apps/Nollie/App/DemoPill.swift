import SwiftUI

/// Sits at the top while the demo is on. A tap offers the way back to the real app.
struct DemoPill: View {
    @State private var confirming = false
    @Environment(AppModel.self) private var model

    var body: some View {
        pill
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(EdgeInsets(top: 2, leading: 0, bottom: 4, trailing: 0))
            .confirmationDialog("Leave the demo?", isPresented: $confirming, titleVisibility: .visible) {
                exitButtons
            } message: {
                Text("Everything here is made up. Nothing is saved.")
            }
    }

    private var pill: some View {
        Button {
            confirming = true
        } label: {
            Label("Demo", systemImage: "sparkles")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .nollieGlass(.regular, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Demo")
        .accessibilityHint("Leave the demo")
        .accessibilityIdentifier("demo.pill")
    }

    @ViewBuilder
    private var exitButtons: some View {
        Button("Leave demo", role: .destructive) {
            Task { await model.leaveDemo() }
        }
        .accessibilityIdentifier("demo.leave")
        Button("Keep looking", role: .cancel) {}
    }
}

/// The same way out, from Settings.
struct LeaveDemoRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassStack {
            Button(action: leave) {
                GlassRowLabel(title: String(localized: "Leave demo"), symbol: "arrow.uturn.backward", chevron: false)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.leaveDemo")
        }
    }

    private func leave() {
        Task { await model.leaveDemo() }
    }
}
