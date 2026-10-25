import SwiftUI
import NollieCore

struct PushInvitationSection: View {
    @Environment(AppModel.self) private var model
    @State private var invitation = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section {
            if model.push.relayRegisteredAt != nil {
                Label("Notifications connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                SecureField("Beta invitation", text: $invitation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("push.invitation")
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Text("Connect notifications")
                        if busy { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(busy || !PushRelay.isValidInvitation(invitation.trimmingCharacters(in: .whitespacesAndNewlines)))
                .accessibilityIdentifier("push.enroll")
                if let message = error ?? model.push.relayError {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Beta notifications")
        } footer: {
            Text("Use the invitation from your beta organizer. No Apple account or signing key needed.")
        }
    }

    private func connect() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try PushRelay.saveInvitation(invitation)
            invitation = ""
            guard await model.push.requestAuthorization() else { return }
            await model.push.registerWithRelay()
            if let runtime = model.runtime { await model.push.syncRegistration(runtime: runtime) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
