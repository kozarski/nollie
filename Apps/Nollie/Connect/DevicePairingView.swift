import CoreImage.CIFilterBuiltins
import SwiftUI
import NollieCore

/// Demo pictures never contain an invitation, contact a server or open the camera.
private enum DevicePairingPreview {
    static var isEnabled: Bool {
        #if DEBUG
        DemoMode.isOn
        #else
        false
        #endif
    }

    static var phoneConfirmation: Bool {
        #if DEBUG
        isEnabled && !ProcessInfo.processInfo.arguments.contains("-nollie-demo-pairing-scanner") && !linkConfirmation
        #else
        false
        #endif
    }

    /// The Nollie Link question, "Link to <Mac>?", with nothing to link to.
    static var linkConfirmation: Bool {
        #if DEBUG
        isEnabled && ProcessInfo.processInfo.arguments.contains("-nollie-demo-link")
        #else
        false
        #endif
    }

    /// `-nollie-demo-pairing-scanner` shows the real scanner view, which asks nothing until Allow.
    static var showsScanner: Bool {
        #if DEBUG
        isEnabled && ProcessInfo.processInfo.arguments.contains("-nollie-demo-pairing-scanner")
        #else
        false
        #endif
    }

    static var setupReview: Bool {
        #if DEBUG
        isEnabled && ProcessInfo.processInfo.arguments.contains("-nollie-demo-pairing-setup")
        #else
        false
        #endif
    }
}

#if os(macOS)
struct MacDevicePairingView: View {
    var connection: GatewayConnection
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var invitation: DevicePairingInvitation?
    @State private var client: DevicePairingClient?
    @State private var requestID = UUID()
    @State private var issue: String?
    @State private var loading = true
    @State private var paired = false
    @State private var ended = false
    @State private var companionNeeded = false
    @State private var showSetupReview = false
    @State private var installer = PairingCompanionInstaller()
    @State private var installTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: paired ? "checkmark.circle.fill" : "iphone.and.arrow.forward")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(paired ? Color.green : Color.accentColor)
                        .accessibilityHidden(true)
                    Text(paired ? "Your iPhone is paired" : "Bring Nollie to your iPhone")
                        .font(.title2.bold()).multilineTextAlignment(.center)
                    if model.lock.isLocked {
                        Text("Unlock Nollie to continue.").foregroundStyle(.secondary)
                    } else if DevicePairingPreview.isEnabled {
                        Text(DevicePairingPreview.setupReview ? "Preview only. No changes will be made." : "Preview only. This code cannot connect.")
                            .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("pairing.preview")
                        if DevicePairingPreview.setupReview {
                            Text("Add the pairing companion to connect your iPhone with a one-use code.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Set up pairing") { showSetupReview = true }
                                .buttonStyle(.nollieGlassProminent).controlSize(.large)
                                .accessibilityIdentifier("pairing.setup")
                        } else {
                            PairingCodeImage(value: "Nollie pairing preview. This code cannot connect.")
                            instructions
                        }
                    } else if paired {
                        Text("Finish the connection check on your iPhone.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Done") { dismiss() }.buttonStyle(.nollieGlassProminent)
                    } else if installer.isBusy {
                        ProgressView(installationProgress)
                            .accessibilityIdentifier("pairing.setup.progress")
                    } else if loading {
                        ProgressView("Preparing a secure code…")
                    } else if let invitation, !ended {
                        PairingCodeImage(value: invitation.qrString)
                            .privacySensitive()
                        instructions
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(invitation.expiresAt.timeIntervalSince(context.date)))
                            Text(remaining > 0 ? "Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))" : "This code has expired.")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                .accessibilityIdentifier("pairing.expiry")
                        }
                    } else {
                        Text(installer.message ?? issue ?? "This code has expired. Make a new one when your iPhone is ready.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .accessibilityIdentifier("pairing.issue")
                        if companionNeeded && installer.phase != .needsActivation {
                            Button { showSetupReview = true } label: {
                                Text("Set up pairing").frame(maxWidth: .infinity).padding(.vertical, 5)
                            }
                            .buttonStyle(.nollieGlassProminent).controlSize(.large)
                            .accessibilityIdentifier("pairing.setup")
                        } else if connection.gateway.isTLS && !connection.hasAccessHeaders {
                            Button("Try again") { requestID = UUID() }
                                .buttonStyle(.nollieGlassProminent)
                                .accessibilityIdentifier("pairing.retry")
                        }
                        if let backup = installer.backupDirectory {
                            Button("Show companion backup") {
                                NSWorkspace.shared.activateFileViewerSelecting([backup])
                            }.font(.callout)
                        }
                    }
                    if !paired {
                        Text("Only scan a code from your own Mac. The code works once and expires after two minutes.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 400).padding(28).frame(maxWidth: .infinity)
            }
            .navigationTitle("Pair iPhone")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { revoke(); dismiss() }.accessibilityIdentifier("pairing.close")
                }
            }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 580)
        .sheet(isPresented: $showSetupReview) { setupReview.withAppModel() }
        .task(id: requestID) { await prepareAndWatch() }
        .onDisappear { revoke() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { revoke() }
        }
        .onChange(of: model.lock.isLocked) { _, locked in
            if locked { revoke(); requestID = UUID() }
        }
    }

    private var instructions: some View {
        VStack(spacing: 6) {
            Text("Open Nollie on your iPhone").font(.headline)
            Text("Choose Scan QR code, then point the camera here.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var installationProgress: String {
        switch installer.phase {
        case .checking: "Checking the connection…"
        case .backingUp: "Saving a verified backup…"
        case .copying: "Adding the pairing companion…"
        case .enabling: "Enabling pairing…"
        default: "Checking that pairing is ready…"
        }
    }

    private var setupReview: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Set up iPhone pairing", systemImage: "iphone.and.arrow.forward")
                .font(.title2.bold())
            Text("Nollie will add its small pairing companion to this Hermes setup.")
            VStack(alignment: .leading, spacing: 12) {
                Label("Back up any pairing files it replaces, then verify the new files.", systemImage: "externaldrive.badge.checkmark")
                Label("Enable the companion through Hermes. Your other settings stay in place.", systemImage: "checkmark.shield")
                Label("Use your existing secure address. No ports, listeners or network settings change.", systemImage: "network")
            }.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Setup checks that no tasks are running. It won't restart Hermes. The backup contains companion files, not your chats or credentials.")
                .font(.callout).foregroundStyle(.secondary)
            Button { showSetupReview = false; installCompanion() } label: {
                Text("Set up pairing").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.nollieGlassProminent).controlSize(.large)
            .disabled(model.lock.isLocked || installer.isBusy || DevicePairingPreview.isEnabled)
            .accessibilityIdentifier("pairing.setup.confirm")
            Button("Not now") { showSetupReview = false }.frame(maxWidth: .infinity)
        }.padding(28).frame(width: 460)
    }

    private func installCompanion() {
        guard !DevicePairingPreview.isEnabled, !model.lock.isLocked,
              let runtime = model.runtime, runtime.connection.id == connection.id else { return }
        installTask?.cancel()
        installTask = Task {
            await installer.install(runtime: runtime) {
                !model.lock.isLocked && model.runtime === runtime
            }
            guard !Task.isCancelled, !model.lock.isLocked, model.runtime === runtime else { return }
            if installer.phase == .ready { companionNeeded = false; requestID = UUID() }
        }
    }

    private func prepareAndWatch() async {
        guard !DevicePairingPreview.isEnabled else { loading = false; return }
        installer.clearStatus()
        loading = true; paired = false; ended = false; issue = nil; companionNeeded = false
        guard !model.lock.isLocked else {
            issue = "Unlock Nollie before making a pairing code."
            loading = false
            return
        }
        guard let runtime = model.runtime, runtime.connection.id == connection.id else {
            issue = "Connect to this assistant first, then try pairing again."
            loading = false
            return
        }
        guard connection.gateway.isTLS, !connection.hasAccessHeaders else {
            issue = connection.hasAccessHeaders
                ? "This connection has an extra sign-in gate. Connect manually on your iPhone for now."
                : "This connection is only available on this Mac or local network. Pairing needs a secure address your iPhone can reach."
            loading = false
            return
        }
        let client = DevicePairingClient(api: runtime.api)
        self.client = client
        do {
            let capability = try await client.capability()
            try Task.checkCancellation()
            guard !model.lock.isLocked, !ended else { throw CancellationError() }
            guard capability.supported else {
                companionNeeded = capability.reason == "companion_required"
                    && connection.authMode.usesBearer && connection.authProvider != DevicePairingClient.provider
                issue = companionNeeded
                    ? "Add the pairing companion to connect your iPhone with a one-use code."
                    : capability.reason == "original_sign_in_required"
                        ? "Sign in with your original Mac account before making a pairing code."
                        : "Pairing needs an existing secure address with sign-in. You can still connect manually on your iPhone."
                loading = false
                return
            }
            let created = try await client.create(displayName: connection.name)
            if Task.isCancelled || model.lock.isLocked || ended {
                Task { try? await client.cancel(created) }
                return
            }
            invitation = created; loading = false
            while !Task.isCancelled && !ended && Date() < created.expiresAt {
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                let status = try await client.status(created)
                try Task.checkCancellation()
                guard !model.lock.isLocked else { throw CancellationError() }
                switch status.state {
                case .pending: break
                case .paired: paired = true; invitation = nil; return
                case .expired, .cancelled: ended = true; invitation = nil; return
                }
            }
            ended = true; invitation = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            revoke()
            issue = "Couldn't prepare pairing. Check the connection and try again."
            loading = false
        }
    }

    private func revoke() {
        installTask?.cancel()
        showSetupReview = false
        ended = true
        loading = false
        if let invitation, let client {
            self.invitation = nil
            Task { try? await client.cancel(invitation) }
        }
    }
}
#endif

#if os(iOS)
struct PhoneDevicePairingView: View {
    var onConnected: ((GatewayConnection) -> Void)? = nil
    private let replacing: GatewayConnection?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var invitation: DevicePairingInvitation?
    @State private var linkOffer: NollieLinkOffer?
    @State private var scannerID = UUID()
    @State private var issue: String?
    @State private var busy = false
    @State private var phase = ""
    @State private var task: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var pendingConnection: GatewayConnection?
    @State private var pendingSecrets: GatewaySecrets?
    @State private var savedConnection: GatewayConnection?
    @State private var showManual = false
    /// Local Network was refused when the phone first reached for the Mac.
    @State private var localNetworkOff = false

    init(initialInvitation: DevicePairingInvitation? = nil, initialLinkOffer: NollieLinkOffer? = nil,
         replacing: GatewayConnection? = nil, onConnected: ((GatewayConnection) -> Void)? = nil) {
        self.onConnected = onConnected
        self.replacing = replacing
        _invitation = State(initialValue: initialInvitation)
        _linkOffer = State(initialValue: initialLinkOffer)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if model.lock.isLocked {
                        ContentUnavailableView("Unlock Nollie to continue", systemImage: "lock")
                    } else if let savedConnection {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
                        Text(savedConnection.linkedMac?.sharedBy != nil ? "You joined"
                             : savedConnection.linkedMac != nil ? "Linked to \(savedConnection.name)" : "You're connected")
                            .font(.title2.bold()).multilineTextAlignment(.center)
                            .accessibilityIdentifier("pairing.connected")
                        Text(savedConnection.linkedMac?.sharedBy != nil ? "Your helpers are ready on this iPhone."
                             : savedConnection.linkedMac != nil ? "Nollie on this iPhone now uses your Mac's assistant."
                             : "\(savedConnection.name) is ready on this iPhone.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Continue") { dismiss() }
                            .buttonStyle(.nollieGlassProminent).controlSize(.large)
                            .accessibilityIdentifier("pairing.done")
                    } else if DevicePairingPreview.phoneConfirmation {
                        previewConfirmation
                    } else if DevicePairingPreview.linkConfirmation {
                        previewLinkConfirmation
                    } else if let linkOffer {
                        if let invite = linkOffer.invite {
                            FamilyJoinConfirmation(invite: invite)
                        } else {
                            linkConfirmation(name: linkOffer.macName)
                        }
                        localNetworkNote
                        if busy {
                            ProgressView(phase).accessibilityIdentifier("pairing.progress")
                        } else {
                            Button { link() } label: {
                                Text(pendingConnection != nil ? "Try again" : linkOffer.invite == nil ? "Link" : "Join")
                                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                            }
                            .buttonStyle(.nollieGlassProminent).controlSize(.large)
                            .accessibilityIdentifier("link.confirm")
                            Button("Scan a different code") { reset() }
                                .accessibilityIdentifier("pairing.rescan")
                        }
                    } else if let invitation {
                        confirmation(name: invitation.displayName, address: invitation.gateway.description)
                        if Self.reachesLocalNetwork(invitation.gateway) { localNetworkNote }
                        if busy {
                            ProgressView(phase).accessibilityIdentifier("pairing.progress")
                        } else {
                            Button { connect() } label: {
                                Text(pendingConnection == nil ? "Connect to this Mac" : "Retry connection")
                                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                            }
                            .buttonStyle(.nollieGlassProminent).controlSize(.large)
                            .accessibilityIdentifier("pairing.confirm")
                            Button("Scan a different code") { reset() }
                                .accessibilityIdentifier("pairing.rescan")
                        }
                    } else if DevicePairingPreview.isEnabled {
                        if DevicePairingPreview.showsScanner {
                            // The scanner before the camera is allowed: the reason, and nothing on its own.
                            PairingScanner(onCode: { _ in })
                        } else {
                            Image(systemName: "qrcode.viewfinder").font(.system(size: 100)).foregroundStyle(.secondary)
                                .frame(height: 280)
                            Text("Scanner preview. The camera is off.").foregroundStyle(.secondary)
                                .accessibilityIdentifier("pairing.preview")
                        }
                    } else if issue == nil {
                        Text(replacing.map { "Reconnect to \($0.name)" } ?? "Scan the code on your Mac").font(.title2.bold())
                        Text("On your Mac, open Nollie's Settings and show the code for your iPhone.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        PairingScanner(onCode: receive).id(scannerID)
                        Text("Camera images stay on this iPhone.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let issue {
                        Label(issue, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("pairing.issue")
                        if invitation == nil && linkOffer == nil {
                            Button("Scan again") { reset() }.buttonStyle(.nollieGlassProminent)
                        }
                    }
                    if savedConnection == nil && !busy && replacing == nil && !model.lock.isLocked {
                        Button("Connect manually") { showManual = true }
                            .buttonStyle(.nollieGlass).accessibilityIdentifier("pairing.manual")
                    }
                }
                .frame(maxWidth: 440).padding(24).frame(maxWidth: .infinity)
            }
            .navigationTitle("Connect to your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { task?.cancel(); dismiss() }
                        .accessibilityIdentifier("pairing.close")
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $showManual) {
            NavigationStack {
                GatewayFormView { connection in
                    savedConnection = connection
                    onConnected?(connection)
                }
            }
            .sheetFrame().withAppModel()
        }
        .onAppear { model.devicePairingFlowActive = true }
        .task { await model.permissions.refresh(.localNetwork) }
        .onChange(of: model.lock.isLocked) { _, locked in
            if locked {
                reset()
                issue = "Unlock Nollie, then scan a new code from your Mac."
            }
        }
        .onDisappear {
            model.devicePairingFlowActive = false
            task?.cancel(); operationID = nil; discardPending()
        }
    }

    /// Why the phone is about to ask about the local network, before it does. If it was refused,
    /// the way to turn it on.
    @ViewBuilder private var localNetworkNote: some View {
        let state = model.permissions.state(.localNetwork)
        if state == .notAsked {
            Label("Your iPhone will ask about the local network. Say Allow, so Nollie can reach your Mac.",
                  systemImage: "wifi")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("pairing.localNetworkReason")
        } else if state == .denied || localNetworkOff {
            VStack(spacing: 10) {
                Label("Local Network is off for Nollie, so it can't find your Mac.", systemImage: "wifi.slash")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { model.permissions.openSettings(.localNetwork) }
                    .buttonStyle(.nollieGlass)
                    .accessibilityIdentifier("pairing.localNetworkSettings")
            }
        }
    }

    /// A gateway on the home network, which is what the system's local network question is about.
    /// This phone itself (loopback) and the internet are not.
    static func reachesLocalNetwork(_ gateway: GatewayURL) -> Bool {
        gateway.isPrivateHost && !["localhost", "127.0.0.1", "::1"].contains(gateway.host)
    }

    /// The phone's first reach for the Mac is where the system asks about the local network, so it
    /// is asked here, with the reason on screen. False when the answer is no.
    private func localNetworkAllowed() async -> Bool {
        let answer = await model.permissions.ask(.localNetwork)
        localNetworkOff = answer == .denied
        return answer != .denied
    }

    private func confirmation(name: String, address: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Connect to \(name)?").font(.title2.bold()).multilineTextAlignment(.center)
                .accessibilityIdentifier("pairing.name")
            Text(address).font(.callout.monospaced()).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
                .accessibilityIdentifier("pairing.address")
            Text("Only connect a Mac you own.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func linkConfirmation(name: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer").font(.system(size: 48)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Link to \(name)?").font(.title2.bold()).multilineTextAlignment(.center)
                .accessibilityIdentifier("link.name")
            Text("Only link a Mac you own.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var previewLinkConfirmation: some View {
        VStack(spacing: 22) {
            Text("Preview only. Nothing will be linked.")
                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                .accessibilityIdentifier("pairing.preview")
            linkConfirmation(name: "Studio Mac")
            localNetworkNote
            Button {} label: { Text("Link").frame(maxWidth: .infinity).padding(.vertical, 5) }
                .buttonStyle(.nollieGlassProminent).controlSize(.large).disabled(true)
                .accessibilityIdentifier("link.confirm")
        }
    }

    private var previewConfirmation: some View {
        VStack(spacing: 22) {
            Text("Preview only. No connection will be made.")
                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                .accessibilityIdentifier("pairing.preview")
            confirmation(name: "Studio Mac", address: "https://studio.example.invalid")
            Button {} label: { Text("Connect to this Mac").frame(maxWidth: .infinity).padding(.vertical, 5) }
                .buttonStyle(.nollieGlassProminent).controlSize(.large).disabled(true)
                .accessibilityIdentifier("pairing.confirm")
        }
    }

    private func receive(_ value: String) {
        guard !busy, invitation == nil, linkOffer == nil, !DevicePairingPreview.isEnabled, !model.lock.isLocked else { return }
        if NollieLinkOffer.isOffer(value) {
            do throws(NollieLinkError) {
                linkOffer = try NollieLinkOffer.parse(value)
                issue = nil
            } catch {
                issue = error.localizedDescription
            }
            return
        }
        do {
            let parsed = try DevicePairingInvitation.parse(value)
            _ = try DevicePairingRecovery.connection(for: parsed, replacing: replacing)
            invitation = parsed
            issue = nil
        } catch let error as DevicePairingRecovery.Failure {
            issue = error.localizedDescription
        } catch {
            issue = "This isn't a current Nollie pairing code. Make a new code on your Mac and scan again."
        }
    }

    private func reset() {
        task?.cancel()
        operationID = nil
        discardPending()
        invitation = nil
        linkOffer = nil
        busy = false; issue = nil; scannerID = UUID()
    }

    private func discardPending() {
        if let invitation, let secrets = pendingSecrets {
            Task { try? await DevicePairingClient.discard(invitation, secrets: secrets) }
        }
        pendingSecrets = nil
        pendingConnection = nil
    }

    /// Nollie Link: find the Mac that showed the code, prove its key, spend the code once for a
    /// device credential, check Hermes answers through the Mac's door, then save and switch.
    private func link() {
        guard let offer = linkOffer, !busy, !DevicePairingPreview.isEnabled, !model.lock.isLocked else { return }
        busy = true; issue = nil
        let operation = UUID()
        operationID = operation
        task = Task {
            defer { if operationID == operation { busy = false } }
            do {
                if pendingConnection == nil {
                    guard await localNetworkAllowed() else { return }
                    try Task.checkCancellation()
                    phase = "Finding your Mac…"
                    let candidate = LinkedMac(macName: offer.macName, pin: offer.pin, port: offer.port, hosts: offer.hosts,
                                              installTag: offer.installTag, deviceID: UUID())
                    guard let host = await NollieLinkResolver().resolve(candidate, lastGood: nil) else { throw NollieLinkError.unreachable }
                    try Task.checkCancellation()
                    guard !model.lock.isLocked, operationID == operation else { throw CancellationError() }
                    phase = "Linking…"
                    let claim = try await NollieLinkClient.claim(offer, host: host, deviceName: UIDevice.current.name)
                    guard !Task.isCancelled, !model.lock.isLocked, operationID == operation else { throw CancellationError() }
                    var linked = LinkedMac(macName: claim.macName, pin: offer.pin, port: offer.port, hosts: offer.hosts,
                                           installTag: offer.installTag, deviceID: claim.deviceID)
                    // Joined as someone at home: the Mac's door gives this phone only what was shared.
                    linked.sharedBy = offer.invite?.owner
                    pendingConnection = GatewayConnection(name: claim.macName, gateway: try linked.gateway(host: host),
                                                          authMode: .sessionToken, connectionKind: "local", linkedMac: linked)
                    pendingSecrets = GatewaySecrets(sessionToken: claim.credential, linkedDevice: true)
                }
                guard var connection = pendingConnection, let secrets = pendingSecrets else { return }
                phase = "Checking the connection…"
                let outcome = await ConnectionTester.run(connection: connection, secrets: secrets) { _ in }
                try Task.checkCancellation()
                guard !model.lock.isLocked, operationID == operation else { throw CancellationError() }
                guard outcome.succeeded else {
                    issue = "Linked, but your Mac's assistant didn't answer yet. Keep Nollie open on your Mac and try again."
                    return
                }
                connection.lastVersion = outcome.version
                phase = "Saving…"
                try model.store.upsert(connection, secrets: secrets)
                pendingSecrets = nil
                pendingConnection = nil
                await model.activate(connection)
                try Task.checkCancellation()
                guard !model.lock.isLocked, operationID == operation else { throw CancellationError() }
                savedConnection = connection
                onConnected?(connection)
                NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
            } catch is CancellationError {
                return
            } catch let error as NollieLinkError {
                if operationID == operation { issue = error.localizedDescription }
            } catch {
                guard !Task.isCancelled, operationID == operation else { return }
                issue = pendingConnection == nil ? NollieLinkError.invalidResponse.localizedDescription
                    : "Couldn't save the link securely. Try again."
            }
        }
    }

    private func connect() {
        guard let invitation, !busy, !DevicePairingPreview.isEnabled, !model.lock.isLocked else { return }
        busy = true; issue = nil
        let operation = UUID()
        operationID = operation
        task = Task {
            defer { if operationID == operation { busy = false } }
            do {
                if pendingConnection == nil {
                    let connection = try DevicePairingRecovery.connection(for: invitation, replacing: replacing)
                    if Self.reachesLocalNetwork(invitation.gateway) {
                        guard await localNetworkAllowed() else { return }
                        try Task.checkCancellation()
                    }
                    phase = "Pairing with your Mac…"
                    let secrets = try await DevicePairingClient.redeem(invitation)
                    guard !Task.isCancelled, !model.lock.isLocked, operationID == operation else {
                        Task { try? await DevicePairingClient.discard(invitation, secrets: secrets) }
                        throw CancellationError()
                    }
                    pendingSecrets = secrets
                    pendingConnection = connection
                }
                guard var connection = pendingConnection, let secrets = pendingSecrets else { return }
                phase = "Checking the connection…"
                let outcome = await ConnectionTester.run(connection: connection, secrets: secrets) { _ in }
                try Task.checkCancellation()
                guard !model.lock.isLocked, operationID == operation else { throw CancellationError() }
                guard outcome.succeeded else {
                    issue = "Pairing was accepted, but the connection check didn't finish. Keep your Mac online and try again."
                    return
                }
                connection.lastVersion = outcome.version
                phase = "Saving this connection…"
                try model.store.upsert(connection, secrets: secrets)
                pendingSecrets = nil
                pendingConnection = nil
                if let current = model.runtime, current.connection.id == connection.id {
                    await current.replaceSecrets(secrets)
                } else {
                    await model.activate(connection)
                }
                try Task.checkCancellation()
                guard !model.lock.isLocked, operationID == operation else { throw CancellationError() }
                savedConnection = connection
                onConnected?(connection)
                NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
            } catch is CancellationError {
                return
            } catch let error as DevicePairingRecovery.Failure {
                if operationID == operation { issue = error.localizedDescription }
            } catch {
                guard !Task.isCancelled, operationID == operation else { return }
                issue = pendingConnection == nil
                    ? "This code may have expired or already been used. Make a new code on your Mac and scan again."
                    : "Couldn't save the connection securely. Try again."
            }
        }
    }
}
#endif

struct PairingCodeImage: View {
    var value: String

    private var image: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(width: 244, height: 244).padding(18)
                    .background(.white, in: .rect(cornerRadius: 20))
                    .accessibilityLabel("One-use pairing code. Scan with Nollie on your iPhone.")
                    .accessibilityIdentifier("pairing.code")
            } else {
                Text("The pairing code could not be drawn. Close this sheet and try again.")
            }
        }
    }
}
