import SwiftUI
import NollieCore
import ServiceManagement

/// Nollie was dragged to the Trash earlier and is back: its assistant, chats and memory are still on
/// this Mac. Use it again, or remove it with the same plan as Settings › About › Remove.
struct LeftoverSetupSheet: View {
    let leftover: RemovalLeftovers
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var removing = false
    @State private var trouble: String?
    @State private var working = false

    var body: some View {
        if removing {
            RemoveNollieSheet(keepApp: true)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("Welcome back").font(.title2.weight(.semibold))
                Text("Nollie found the setup an earlier copy left on this Mac: your assistant, with its chats and memory.")
                    .fixedSize(horizontal: false, vertical: true)
                if let trouble { Text(trouble).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 10) {
                    Spacer()
                    Button("Remove it") { removing = true }
                        .accessibilityIdentifier("leftover.remove")
                    Button("Use it") { Task { await useIt() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working)
                        .accessibilityIdentifier("leftover.use")
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
            .padding(24)
            .frame(width: 460)
        }
    }

    /// Nollie Runtime left launchd when the app went away: it is registered again, and starts the
    /// setup the person had running (their earlier yes is still recorded).
    private func useIt() async {
        working = true
        defer { working = false }
        if DemoMode.isOn { dismiss(); return }
        #if NOLLIE_DIRECT
        UserDefaults.standard.set(leftover.installationID.uuidString, forKey: MacHermesSetup.selectedInstallationKey)
        let control = ManagedRuntimeServiceControl.system
        if control.status() != .notRegistered && control.status() != .notFound { try? await control.unregister() }
        do { try control.register() } catch {
            trouble = "Couldn't start Nollie Runtime again. Allow it in Login Items, then try again."
            return
        }
        if let note = leftover.note { try? FileManager.default.removeItem(at: note) }
        dismiss()
        await model.activateSavedConnection()
        #endif
    }
}
