import SwiftUI
import NollieCore

/// A helper's "Can pay with my cards" switch, off to start. Turning it on checks it's the owner first;
/// every payment still waits for a yes by the Mac's rules. The iPhone shows the same switch: the cards
/// are the Mac's.
struct PaymentSwitchSection: View {
    let profileName: String
    @Environment(AppModel.self) private var model
    @State private var on: Bool?
    @State private var unavailable = false
    @State private var saving = false
    @State private var problem: String?

    private var runtime: GatewayRuntime? { model.runtime }
    private var scope: String {
        "\(profileName)/\(runtime?.connection.id.uuidString ?? "")/\(model.lock.isLocked)"
    }

    var body: some View {
        Group {
            if !unavailable, runtime != nil, !model.lock.isLocked, !AskFirstModel.isPrivateBot(profileName) {
                VStack(spacing: 12) {
                    GlassSwitch("Can pay with my cards", isOn: Binding(get: { on ?? false }, set: { want in
                        Task { await set(want) }
                    }), id: "profile.payments")
                    .disabled(on == nil || saving)
                    if on == true {
                        PageNote("Every payment asks you first.", symbol: "hand.raised.fill", id: "profile.payments.note")
                    }
                    if let problem {
                        PageNote(problem, symbol: "exclamationmark.triangle.fill", tint: .orange, id: "profile.payments.problem")
                    }
                }
                .id("payments")
            }
        }
        .task(id: scope) { await load() }
    }

    private func load() async {
        on = nil
        unavailable = false
        problem = nil
        guard let runtime, !model.lock.isLocked, !AskFirstModel.isPrivateBot(profileName) else { return }
        do {
            let found = try await runtime.paymentSwitch(bot: profileName)
            guard found.bot == profileName else { return }
            on = found.on
        } catch HermesAPIError.http(status: let status, _) where status == 404 || status == 403 {
            unavailable = true   // an older add-on, or a bot that may never pay
        } catch {
            guard !Task.isCancelled else { return }
            problem = "Couldn't check this. Try again."
        }
    }

    /// On checks it's the owner first (Face ID, Touch ID or the passcode). Off never asks.
    private func set(_ want: Bool) async {
        guard let runtime, on != want, !saving, !AskFirstModel.isPrivateBot(profileName) else { return }
        saving = true
        defer { saving = false }
        if want {
            let bot = runtime.profiles.first { $0.name == profileName }?.shownName ?? profileName.capitalized
            guard await RememberedSignInCoordinator.defaultAuthenticator().authenticate(reason: "Let \(bot) pay with your cards") != nil else { return }
        }
        do {
            on = try await runtime.savePaymentSwitch(bot: profileName, on: want).on
            problem = nil
        } catch {
            problem = "Couldn't change that. Try again."
        }
    }
}
