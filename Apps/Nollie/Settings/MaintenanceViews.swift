import Foundation
import SwiftUI
import NollieCore

/// What the person is being asked to confirm before a maintenance command runs on the gateway.
private enum MaintenanceChoice: Identifiable {
    case update, restart

    var id: Self { self }

    var question: String {
        switch self {
        case .update: String(localized: "Update Hermes?")
        case .restart: String(localized: "Restart the gateway?")
        }
    }

    var action: String {
        switch self {
        case .update: String(localized: "Update", comment: "Button: update Hermes now")
        case .restart: String(localized: "Restart", comment: "Button: restart the gateway now")
        }
    }

    /// What the command does, in the dialog. `fromBanner` gives the banner's wording, which
    /// mentions the reconnect that follows.
    func explanation(fromBanner: Bool) -> String {
        switch self {
        case .update where fromBanner:
            String(localized: "Runs `hermes update` on the gateway machine, then starts the dashboard again, which fixes this. Give it a few minutes; the app reconnects by itself.",
                   comment: "Keep the command in backticks as it is")
        case .update:
            String(localized: "Runs `hermes update` on the gateway machine, then starts the dashboard again. That also clears a \"restart required\" notice, and takes a few minutes.",
                   comment: "Keep the command in backticks as it is")
        case .restart:
            String(localized: "Runs `hermes gateway restart` on the gateway machine. Any turn in progress stops, and the app reconnects once the gateway is back.",
                   comment: "Keep the command in backticks as it is")
        }
    }

    @MainActor func run(on runtime: GatewayRuntime) async {
        switch self {
        case .update: await runtime.maintenance.update(runtime: runtime)
        case .restart: await runtime.maintenance.restartGateway(runtime: runtime)
        }
    }
}

private extension View {
    /// Asks before running a maintenance command, with a destructive confirm button.
    func confirmsMaintenance(_ choice: Binding<MaintenanceChoice?>, on runtime: GatewayRuntime, banner: Bool = false) -> some View {
        alert(
            choice.wrappedValue?.question ?? "",
            isPresented: Binding(get: { choice.wrappedValue != nil }, set: { if !$0 { choice.wrappedValue = nil } }),
            presenting: choice.wrappedValue
        ) { pending in
            Button(pending.action, role: .destructive) { Task { await pending.run(on: runtime) } }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.explanation(fromBanner: banner))
        }
    }
}

/// Banner card shown over the chats when the dashboard reports stale code. Updating fixes it,
/// and the button sits right where the problem is visible.
struct RestartRequiredBanner: View {
    var runtime: GatewayRuntime
    var message: String
    @State private var asking: MaintenanceChoice?
    @State private var detailsOpen = false

    private var work: MaintenanceModel { runtime.maintenance }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
            controls
            if detailsOpen {
                Text(message).small(.caption2, .secondary).textSelection(.enabled)
            }
            if case .failed(let reason) = work.phase {
                Text(reason).small(.caption2, .red)
            }
        }
        .padding(14)
        .nollieGlass(.regular, in: .rect(cornerRadius: 18))
        .confirmsMaintenance($asking, on: runtime, banner: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hermes needs a restart")
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(.orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hermes needs a restart").font(.subheadline.weight(.semibold))
                Text("The dashboard is running code older than what is on disk, so some of its settings are refused until it relaunches.")
                    .fixedSize(horizontal: false, vertical: true)
                    .small(.caption, .secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: { asking = .update }) {
                Text(work.isBusy ? "Updating…" : "Update Hermes").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.nollieGlassProminent)
            .disabled(work.isBusy)
            .testID("banner.update")

            Button(action: { detailsOpen.toggle() }) {
                Text(detailsOpen ? "Hide details" : "Details").font(.subheadline)
            }
            .buttonStyle(.nollieGlass)

            Spacer(minLength: 0)
            if work.isBusy { ProgressView().controlSize(.small) }
        }
    }
}

/// Update and restart actions for Settings rows.
struct MaintenanceButtons: View {
    var runtime: GatewayRuntime
    var compact = false
    /// Show only the restart row, where the gateway just needs a bounce.
    var restartOnly = false
    @State private var asking: MaintenanceChoice?

    private var work: MaintenanceModel { runtime.maintenance }

    var body: some View {
        // Plain rows, matching the rest of Settings. Two bold glass buttons side by side squeezed
        // their labels onto two lines and hid the icon on the tinted one.
        Group {
            if !restartOnly {
                row(String(localized: "Update Hermes"), symbol: "arrow.down.circle", choice: .update)
            }
            row(String(localized: "Restart gateway"), symbol: "arrow.clockwise", choice: .restart)
            progressLine
            if !compact, !work.actionLog.isEmpty {
                Text(work.actionLog.suffix(12).joined(separator: "\n"))
                    .textSelection(.enabled)
                    .small(.caption2, .secondary)
                    .monospaced()
            }
        }
        .confirmsMaintenance($asking, on: runtime)
    }

    private func row(_ title: String, symbol: String, choice: MaintenanceChoice) -> some View {
        Button(title, systemImage: symbol) { asking = choice }
            .disabled(work.isBusy)
    }

    @ViewBuilder private var progressLine: some View {
        switch work.phase {
        case .idle:
            EmptyView()
        case .running(let label):
            Label(title: { Text(label) }, icon: { ProgressView() }).small(.footnote)
        case .finished(let text, _):
            Label(text, systemImage: "checkmark.circle").small(.footnote)
        case .failed(let text):
            Label(text, systemImage: "xmark.octagon").small(.footnote, .red)
        }
    }
}
