import SwiftUI
import UserNotifications
import NollieCore

/// What each card of the setup shows.
extension PushSetupView {
    @ViewBuilder func stepContent(_ step: SetupStep, runtime rt: GatewayRuntime) -> some View {
        switch step {
        case .apple: appleCards(rt)
        case .address: addressCards(rt)
        case .signIn: signInCards(rt)
        case .install: installCards(rt)
        case .start: startCards(rt)
        case .overview: overviewCards(rt)
        }
    }

    private func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// Where a person who turned notifications off goes to turn them back on.
    private static var settingsLink: (title: String, address: URL) {
        #if os(iOS)
        ("Open Settings", URL(string: UIApplication.openSettingsURLString)!)
        #else
        ("Open System Settings", URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
        #endif
    }

    // MARK: 1. Apple push

    @ViewBuilder private func appleCards(_ rt: GatewayRuntime) -> some View {
        if PushRelay.isConfigured { PushInvitationSection() } else { keyCard }
        deviceCard(rt)
    }

    private func deviceCard(_ rt: GatewayRuntime) -> some View {
        let push = model.push
        let thisDevice = DeviceWords.this
        let note = PushRelay.isConfigured
            ? "Signs up with the push relay and puts \(thisDevice)'s device file on the gateway. Content is encrypted with a key only \(thisDevice) holds."
            : "Puts \(thisDevice)'s device file on the gateway."
        return FormCard(DeviceWords.This, note: note) {
            LabeledContent("Notifications", value: Self.statusText(push.authorization))
            permissionAction(push)
            if PushRelay.isConfigured {
                LabeledContent("Push relay", value: push.relayRegisteredAt.map { "registered " + clock($0) } ?? "not registered yet")
            }
            LabeledContent("Device file on gateway", value: push.registeredAt.map { "published " + clock($0) } ?? "not published yet")
            ApprovalRequestRow(runtime: rt)
            if let problem = push.relayError ?? push.lastError ?? push.registrationFailure {
                StatusNote(problem, symbol: "xmark.octagon", tone: .problem)
            }
            BusyButton(title: "Register \(thisDevice)", busyTitle: "Registering…", symbol: "arrow.up.circle", busy: setup.registering) {
                Task { await setup.registerPhone(push: push, runtime: rt) }
            }
            if let outcome = setup.registerOutcome {
                let failed = outcome.hasPrefix("Failed")
                StatusNote(outcome, symbol: failed ? "xmark.octagon" : "checkmark.circle", tone: failed ? .problem : .quiet)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var keyCard: some View {
        @Bindable var setup = setup
        return FormCard("APNs key", note: "This build has no push relay, so it needs your own APNs key: developer.apple.com, Keys, with the Apple Push Notifications service turned on. The Key ID comes from the file name, and the Team ID from this build's provisioning profile.") {
            if let name = setup.keyFileName {
                ForEach([("Key file", name), ("Key ID", setup.keyID)], id: \.0) { pair in
                    LabeledContent(pair.0, value: pair.1)
                }
            } else {
                ActionRow("Choose AuthKey_….p8", symbol: "key") { showKeyPicker = true }
            }
            TextField("Team ID", text: $setup.teamID)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        }
    }

    @ViewBuilder private func permissionAction(_ push: PushRegistrar) -> some View {
        switch push.authorization {
        case .notDetermined:
            Button("Allow notifications") { Task { _ = await push.requestAuthorization() } }
        case .denied:
            Link(Self.settingsLink.title, destination: Self.settingsLink.address)
        default:
            EmptyView()
        }
    }

    // MARK: 2. Address

    @ViewBuilder private func addressCards(_ rt: GatewayRuntime) -> some View {
        @Bindable var setup = setup
        let typed = setup.gatewayURL
        FormCard("Address", note: "The companion connects to exactly this address. A loopback address (http://127.0.0.1:9119) works if the dashboard listens there. Otherwise use \(DeviceWords.this)'s address.") {
            HStack {
                TextField("Address", text: $setup.gatewayURL, prompt: Text(verbatim: "https://hermes.example.com"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !typed.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { withAnimation(.snappy) { setup.gatewayURL = "" } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            ActionRow("Use \(DeviceWords.this)'s address", symbol: DeviceWords.symbol) {
                withAnimation(.snappy) { setup.gatewayURL = rt.connection.gateway.description }
            }
            if let inUse = setup.urlInUse, inUse != typed {
                Text("The companion uses \(inUse) right now. Installing again switches it.").note()
            }
            if !typed.isEmpty && !setup.addressValid {
                StatusNote("Enter a full address that starts with http:// or https://.", symbol: "exclamationmark.circle", tone: .warning)
            }
        }
    }

    // MARK: 3. Sign-in

    @ViewBuilder private func signInCards(_ rt: GatewayRuntime) -> some View {
        FormCard("Credentials", note: "The same account as the dashboard. It is written into the companion's config when you install.") {
            credentialRows(rt)
        }
    }

    @ViewBuilder private func credentialRows(_ rt: GatewayRuntime) -> some View {
        switch setup.credential(for: rt) {
        case .needsSignIn:
            signInPrompt
        case .ready(let provider):
            savedSignIn(provider: provider, rt: rt)
        case .sessionToken:
            Label("Signed in with this gateway's session token", systemImage: "checkmark.circle")
                .foregroundStyle(Tone.quiet.colour)
        }
    }

    @ViewBuilder private var signInPrompt: some View {
        let rejected = setup.companionSignInRejected
        ActionRow(rejected ? "Sign in again" : "Sign in for the companion", symbol: "person.badge.key") { showCompanionSignIn = true }
            .accessibilityIdentifier("setup.companion.signIn")
        Text(rejected
             ? "The gateway turned down the companion's saved sign-in. Sign in again, then install it. Your Apple key and progress stay here."
             : "The companion has a sign-in of its own, apart from \(DeviceWords.this)'s, and renews it by itself.")
            .note()
    }

    @ViewBuilder private func savedSignIn(provider: String?, rt: GatewayRuntime) -> some View {
        let connected = setup.companionHealthy
        let via = provider.map { " via \($0)" } ?? ""
        Label((connected ? "Connected" : "Sign-in saved") + via, systemImage: connected ? "checkmark.circle.fill" : "person.badge.key")
            .foregroundStyle(connected ? Tone.good.colour : Tone.quiet.colour)
        if !connected { Text("The companion confirms the sign-in once it is installed.").note() }
        ActionRow("Sign in again", symbol: "person.badge.key") { showCompanionSignIn = true }
        ActionRow("Sign out the companion", symbol: "person.slash", role: .destructive) {
            withAnimation(.snappy) { setup.signOutCompanion(runtime: rt) }
        }
    }

    // MARK: 4. Install

    @ViewBuilder private func installCards(_ rt: GatewayRuntime) -> some View {
        FormCard("Install", note: "First a checked copy of the six companion files goes into Nollie's private storage. Then those files are replaced and the plugin is switched on. Chats, profiles, schedules and Board data are not touched.") {
            if setup.alreadyServing, !setup.installedOnGateway, let version = setup.installedVersion {
                StatusNote("Already here: companion v\(version) is running and connected. Nothing to install and no restart. \(DeviceWords.This) only needs to register (step 1).",
                           symbol: "checkmark.circle.fill").foregroundStyle(Color.readableGreen)
            }
            BusyButton(title: "Back up and install", busyTitle: "Installing…", symbol: "arrow.up.doc", busy: setup.installing) {
                Task { await setup.installOnGateway(runtime: rt) }
            }
            .disabled(setup.installing || !setup.canUpload(for: rt))
            .accessibilityIdentifier("setup.companion.install")
            if setup.companionSignInRejected {
                Button("Sign in again") { showCompanionSignIn = true }.accessibilityIdentifier("setup.companion.signIn")
            }
            if !setup.installedFiles.isEmpty {
                InstalledFilesWindow(files: setup.installedFiles, finished: setup.installedOnGateway)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            if let problem = setup.error { StatusNote(problem, symbol: "xmark.octagon", tone: .problem) }
            if setup.installedOnGateway, let when = setup.installedAt {
                StatusNote("Installed at \(clock(when)). Companion v\(PushSetupModel.bundledPluginVersion), its config and the plugin are on the gateway, and the plugin is switched on.",
                           symbol: "checkmark.circle.fill")
                    .transition(.pop)
                    .foregroundStyle(Color.readableGreen)
            }
        }
        restartCard(rt)
    }

    @ViewBuilder private func restartCard(_ rt: GatewayRuntime) -> some View {
        if setup.restartCountdownEnd != nil || setup.restartPending {
            FormCard("Restart") { RestartCountdownRows(setup: setup, runtime: rt) }
        } else if !setup.installedOnGateway && !setup.alreadyServing {
            FormCard {
                StatusNote("A gateway restart finishes the install, with a 90 second countdown first. Running turns pause for a few seconds.",
                           symbol: "info.circle")
            }
        }
    }

    // MARK: 5. Start

    @ViewBuilder private func startCards(_ rt: GatewayRuntime) -> some View {
        let healthy = setup.companionHealthy
        FormCard("Companion", note: "The heartbeat is read from the gateway every few seconds.") {
            CompanionStatusRows(setup: setup, runtime: rt, showInstall: false)
        }
        FormCard(note: "Restart once so Hermes loads the plugin, and again after updates. Changes to the address or sign-in apply within seconds.") {
            StatusNote(setup.startAdvice, symbol: healthy ? "checkmark.circle.fill" : "info.circle", tone: healthy ? .good : .quiet)
                .contentTransition(.opacity)
            if setup.companionSignInRejected {
                ActionRow("Sign in again", symbol: "person.badge.key") { showCompanionSignIn = true }
                    .accessibilityIdentifier("setup.companion.signIn")
            } else {
                MaintenanceButtons(runtime: rt, compact: true, restartOnly: true)
            }
        }
    }

    // MARK: 6. Overview and test

    @ViewBuilder private func overviewCards(_ rt: GatewayRuntime) -> some View {
        FormCard("Overview") { OverviewRows(setup: setup, push: model.push, runtime: rt) }
        FormCard("Test", note: "One real notification, all the way: companion, relay, Apple, \(DeviceWords.this).") {
            TestNotificationButton(setup: setup, runtime: rt)
            if case .done(let passed, let text) = setup.testPhase {
                StatusNote(text, symbol: passed ? "checkmark.circle.fill" : "xmark.octagon", tone: passed ? .good : .problem)
                    .transition(.pop)
            }
        }
        FormCard {
            ActionRow("Start over", symbol: "arrow.counterclockwise", role: .destructive) { confirmStartOver = true }
                .font(.footnote)
        }
        .listRowBackground(Color.clear)
    }
}

// MARK: - Pieces

/// Approvals and questions come to the app as socket requests. The row reports whether the gateway
/// signed up to send them and the number received.
private struct ApprovalRequestRow: View {
    let runtime: GatewayRuntime

    private var agreed: Bool { !runtime.serverRequestsAdvertised.isEmpty }

    private var headline: String {
        agreed ? "\(runtime.serverRequestsReceived) received" : "the gateway has not agreed to these"
    }

    private var detail: String {
        if let latest = runtime.lastServerRequest { return latest }
        return agreed
            ? "none yet on this connection. Only actions the gateway's approval mode holds for a person reach \(DeviceWords.the)"
            : "try reconnecting, or update Hermes on the gateway"
    }

    var body: some View {
        LabeledContent("Approval requests") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(headline)
                Text(detail).small(.caption)
            }
            .multilineTextAlignment(.trailing)
        }
    }
}

/// The three summary lines (gateway, companion, this device), each marked with a tick or a warning.
private struct OverviewRows: View {
    let setup: PushSetupModel
    let push: PushRegistrar
    let runtime: GatewayRuntime

    private struct Line: Identifiable {
        let title: String
        let symbol: String
        let ok: Bool
        let value: String
        let detail: String
        var full: String?
        var id: String { title }
    }

    private var lines: [Line] {
        let devices = setup.heartbeat?.devices ?? 0
        let host = setup.gatewayURL.replacing("https://", with: "").replacing("http://", with: "")
        let registered = push.registeredAt != nil
        return [
            Line(title: "Gateway", symbol: "server.rack", ok: true, value: host,
                 detail: setup.credentialText(for: runtime), full: setup.gatewayURL),
            Line(title: "Companion", symbol: "puzzlepiece.extension", ok: setup.companionHealthy,
                 value: setup.installedVersion.map { "v\($0)" } ?? "not installed",
                 detail: setup.companionHealthy ? "connected · \(devices) device\(devices == 1 ? "" : "s")" : "not connected"),
            Line(title: DeviceWords.This, symbol: DeviceWords.symbol, ok: registered && push.authorization == .authorized,
                 value: registered ? "registered" : "not registered",
                 detail: "notifications " + PushSetupView.statusText(push.authorization).lowercased()),
        ]
    }

    var body: some View {
        ForEach(lines) { line in
            HStack(spacing: 12) {
                Image(systemName: line.symbol).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.title).font(.subheadline.weight(.medium))
                    Text(line.detail).small(.caption)
                }
                Spacer(minLength: 8)
                PeekableValue(text: line.value, full: line.full)
                Image(systemName: line.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(line.ok ? Color.green : Color.orange)
            }
            .inset(v: 2)
        }
    }
}

/// Sends the test notification, and while it is on its way shows how long it has been and where it is.
private struct TestNotificationButton: View {
    let setup: PushSetupModel
    let runtime: GatewayRuntime

    var body: some View {
        let waiting = setup.testPhase.isWaiting
        Button {
            Task { await setup.sendTest(runtime: runtime) }
        } label: {
            if waiting, let started = setup.testStartedAt {
                Label(title: { progress(since: started) }, icon: { ProgressView() })
            } else {
                Label("Send a test notification", systemImage: "bell.badge")
            }
        }
        .disabled(waiting || !setup.companionHealthy)
    }

    private func progress(since started: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Waiting for the notification…")
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(setup.testStage).note().contentTransition(.opacity)
        }
    }
}

private extension AnyTransition {
    /// A result settling in: a touch smaller to start, fading up.
    static var pop: AnyTransition { .scale(scale: 0.9).combined(with: .opacity) }
}
