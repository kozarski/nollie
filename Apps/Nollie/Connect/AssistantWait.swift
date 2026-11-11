import NollieCore
import SwiftUI

/// What the screens say while the assistant Nollie runs on this Mac is on its way back (after an
/// update, at login): it is starting, or it couldn't be reached after the whole wait.
enum AssistantWait {
    /// The runtime's wait, except that an engine update under way is never "can't reach": that
    /// update starts the assistant itself when it is done.
    @MainActor static func state(_ runtime: GatewayRuntime?) -> ManagedWait {
        guard let runtime else { return .none }
        #if os(macOS)
        if runtime.managedWait == .unreachable, EngineUpdate.shared.phase == .updating { return .starting }
        #endif
        return runtime.managedWait
    }

    static func line(_ wait: ManagedWait) -> String? {
        switch wait {
        case .none: nil
        case .starting: String(localized: "Starting your assistant…")
        case .unreachable: String(localized: "Can't reach your assistant.")
        }
    }
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
