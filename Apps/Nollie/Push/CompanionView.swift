import SwiftUI
import NollieCore

/// Settings, Advanced, Companion: is the plugin on the gateway and running, plus guided setup,
/// Software Update, diagnostics and Uninstall.
struct CompanionView: View {
    @State private var uninstalling = false
    @State private var askingToUninstall = false
    @State private var setup = PushSetupModel()
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Companion")
            if let runtime = model.runtime {
                setupCard(runtime)
                gatewayCard
                deviceCard
                if setup.isCompleted(for: runtime) || setup.installedVersion != nil { removalCard }
                diagnosticsCard
            } else {
                Text("Connect a gateway first.").small(.body)
            }
        }
        .animation(.smooth, value: setup.updateOutcome == nil)
        .listSectionSpacing(28)
        .untitledPage()
        .modifier(UninstallPrompt(isPresented: $askingToUninstall, confirm: removeCompanion))
        .modifier(CompanionLifecycle(setup: setup))
    }

    private func removeCompanion() {
        guard let runtime = model.runtime else { return }
        Task {
            uninstalling = true
            await setup.uninstall(runtime: runtime, model: model)
            uninstalling = false
        }
    }

    // MARK: Cards

    private func setupCard(_ runtime: GatewayRuntime) -> some View {
        let configured = setup.isCompleted(for: runtime)
        return FormCard(note: configured ? "Configure goes through the setup again: address, sign-in, install, test."
                                         : "Guided setup: permission, address, sign-in, install, start and a test.") {
            NavigationLink {
                PushSetupView(setup: setup)
            } label: {
                Label(configured ? "Configure" : "Configure the companion", systemImage: "wand.and.stars")
            }
            NavigationLink {
                SoftwareUpdateView()
            } label: {
                UpdateLinkLabel(pending: setup.updateAvailable)
            }
        }
    }

    private var gatewayCard: some View {
        FormCard("Companion on the gateway",
                 note: "A small plugin on your gateway. It sends replies as notifications and brings approval cards to \(DeviceWords.your) as soon as a bot needs a yes.") {
            if setup.companionCheckedAt == nil {
                SpinnerLabel("Checking…").foregroundStyle(.secondary)
            } else {
                CompanionStatusChecks(setup: setup)
            }
        }
    }

    private var deviceCard: some View {
        let push = model.push
        var facts: [(title: String, value: String)] = [
            ("Notifications", PushSetupView.statusText(push.authorization)),
        ]
        if PushRelay.isConfigured {
            facts.append(("Push relay", Self.when("registered", push.relayRegisteredAt, otherwise: "not registered")))
        }
        facts.append(("Device file on gateway", Self.when("published", push.registeredAt, otherwise: "not published")))
        return FormCard(DeviceWords.This) {
            ForEach(facts, id: \.title) { fact in
                LabeledContent(fact.title, value: fact.value)
            }
        }
    }

    private static func when(_ verb: String, _ date: Date?, otherwise: String) -> String {
        guard let date else { return otherwise }
        return verb + " " + date.formatted(date: .omitted, time: .shortened)
    }

    private var removalCard: some View {
        FormCard(note: "Stops the service and removes the plugin and its files from the gateway, and \(DeviceWords.this) forgets the setup. Installing again starts fresh.") {
            Button(role: .destructive) {
                askingToUninstall = true
            } label: {
                if uninstalling {
                    SpinnerLabel("Uninstalling…")
                } else {
                    Label("Uninstall companion", systemImage: "trash")
                }
            }
            .disabled(uninstalling)
        }
    }

    private var diagnosticsCard: some View {
        FormCard(note: "The last notification, the push log and the last push the companion sent.") {
            NavigationLink {
                CompanionDiagnosticsView(setup: setup)
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
        }
    }
}

/// "Software Update", with a badge when the gateway's companion is behind this build.
private struct UpdateLinkLabel: View {
    let pending: Bool

    var body: some View {
        HStack {
            Label("Software Update", systemImage: "arrow.down.circle")
            Spacer(minLength: 8)
            if pending { CountBadge(1) }
        }
    }
}

// MARK: - Prompts and upkeep

/// The confirmation before the companion is removed.
private struct UninstallPrompt: ViewModifier {
    @Binding var isPresented: Bool
    let confirm: () -> Void

    func body(content: Content) -> some View {
        content.alert("Uninstall the companion?", isPresented: $isPresented) {
            Button("Uninstall", role: .destructive, action: confirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The plugin is switched off, its service stops and its files are deleted from the gateway. A bot runs the removal, so approve it in the chat that opens. \(DeviceWords.CompanionBrings) stop until you install it again.")
        }
    }
}

/// Reads the companion when the page opens or is pulled, and tells the app whether an update is waiting.
private struct CompanionLifecycle: ViewModifier {
    @Environment(AppModel.self) private var model
    let setup: PushSetupModel

    func body(content: Content) -> some View {
        content
            .task { await look(deeply: true) }
            .reloadable { await look(deeply: false) }
            .onChange(of: setup.companionCheckedAt) { _, _ in
                model.companionUpdateAvailable = setup.updateAvailable
            }
    }

    private func look(deeply: Bool) async {
        guard let runtime = model.runtime else { return }
        if deeply {
            await setup.prepare(runtime: runtime)
        } else {
            await setup.checkCompanion(runtime: runtime)
        }
    }
}
