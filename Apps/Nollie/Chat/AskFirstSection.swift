import SwiftUI
import NollieCore

/// The bot's own Ask first choice, read again whenever its settings are opened.
struct AskFirstSection: View {
    let profileName: String
    let label: String
    @Environment(AppModel.self) private var model
    @State private var setting = AskFirstModel()
    @State private var work: Task<Void, Never>?

    private var runtime: GatewayRuntime? { model.runtime }
    private var scope: String {
        "\(profileName)/\(runtime?.connection.id.uuidString ?? "")/\(runtime?.connection.gateway.description ?? "")/\(model.lock.isLocked)"
    }
    private var current: Bool {
        guard let runtime else { return false }
        return !model.lock.isLocked && setting.matches(bot: profileName, runtime: runtime)
    }

    var body: some View {
        VStack(spacing: 12) {
            if current, let enabled = setting.enabled {
                GlassSwitch("Ask first", isOn: Binding(get: { enabled }, set: { on in
                    guard let runtime, current else { return }
                    work = Task { await setting.requestChange(on, bot: profileName, runtime: runtime) }
                }), id: "profile.askFirst")
                .disabled(setting.busy)
            } else if setting.error == nil || !current {
                HStack {
                    Text("Ask first")
                    Spacer()
                    ProgressView()
                }
            }
            if current, let error = setting.error {
                Text(error).font(.footnote).foregroundStyle(.red)
                Button("Try again") {
                    guard let runtime else { return }
                    work = Task { await setting.load(bot: profileName, runtime: runtime) }
                }
                .disabled(setting.busy)
            }
            PageNote("Sending, buying, posting or deleting waits for your yes.")
        }
        .confirmationDialog("Turn off Ask first for \(label)?", isPresented: Binding(
            get: { current && setting.needsTurnOffConfirmation },
            set: { if !$0 { setting.cancelTurnOff() } }
        ), titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) {
                guard let runtime, current else { return }
                work = setting.confirmTurnOff(bot: profileName, runtime: runtime)
            }
            Button("Cancel", role: .cancel) { setting.cancelTurnOff() }
        } message: {
            Text("It will send, buy, post and delete without asking.")
        }
        .task(id: scope) {
            work?.cancel()
            setting.reset()
            guard let runtime, !model.lock.isLocked else { return }
            await setting.load(bot: profileName, runtime: runtime)
        }
        .onDisappear {
            work?.cancel()
            setting.reset()
        }
    }
}
