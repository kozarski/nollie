import NollieCore
import SwiftUI

/// What the screens say while the assistant Nollie runs on this Mac is on its way back (after an
/// update, at login): it is starting, or it couldn't be reached after the whole wait.
enum AssistantWait {
    /// The runtime's wait, except that an engine update under way is never "can't reach": that
    /// update starts the assistant itself when it is done.
    /// A setup that is no longer on this Mac is said as it is: no wait brings it back.
    @MainActor static func state(_ runtime: GatewayRuntime?) -> ManagedWait {
        guard let runtime else { return .none }
        #if os(macOS)
        if !runtime.socketState.isOpen, ManagedSetupPresence.isMissing(runtime.connection.managedInstallationID) { return .missing }
        if runtime.managedWait == .unreachable, EngineUpdate.shared.phase == .updating { return .starting }
        #endif
        return runtime.managedWait
    }

    static func line(_ wait: ManagedWait) -> String? {
        switch wait {
        case .none: nil
        case .starting: String(localized: "Starting your assistant…")
        case .unreachable: String(localized: "Can't reach your assistant.")
        case .missing: String(localized: "Your assistant isn't on this Mac any more.")
        }
    }
}

/// Under the bots while the assistant on this Mac isn't connected, in place of the connection's own
/// error: starting, can't be reached (with Try again), or not on this Mac any more (with the way back).
struct AssistantWaitNotice: View {
    let wait: ManagedWait

    var body: some View {
        if let line = AssistantWait.line(wait) {
            VStack(alignment: .leading, spacing: 10) {
                Text(line).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("assistant.waitLine")
                switch wait {
                case .missing: AssistantSetUpAgainButton()
                case .unreachable: AssistantTryAgainButton()
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Back to setup's first real step, to set up Nollie's own assistant on this Mac again.
struct AssistantSetUpAgainButton: View {
    var prominent = false
    @AppStorage(OnboardingProgress.storageKey) private var setupSaved = ""

    var body: some View {
        if prominent {
            Button(action: setUpAgain) { Text("Set up again").fullWidthLabel() }
                .buttonStyle(.nollieGlassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("assistant.setUpAgain")
        } else {
            Button(action: setUpAgain) {
                Text("Set up again").font(.body.weight(.semibold)).padding(.horizontal, 8)
            }
            .buttonStyle(.nollieGlass)
            .accessibilityIdentifier("assistant.setUpAgain")
        }
    }

    private func setUpAgain() { setupSaved = OnboardingProgress.settingUpAgain(setupSaved) }
}

/// Try again, for the assistant on this Mac once it couldn't be reached after the whole wait.
struct AssistantTryAgainButton: View {
    @Environment(AppModel.self) private var model
    @State private var trying = false

    var body: some View {
        Button {
            trying = true
            Task {
                await model.retryAssistant()
                trying = false
            }
        } label: {
            Text("Try again").font(.body.weight(.semibold)).padding(.horizontal, 8)
        }
        .buttonStyle(.nollieGlass)
        .controlSize(.large)
        .disabled(trying)
        .accessibilityIdentifier("assistant.tryAgain")
    }
}
