#if os(macOS)
import AppKit
import SwiftUI
import NollieCore

/// Nollie Link on the Mac: Nollie Runtime's pairing code and linked devices, over its signed XPC.
@MainActor
enum NollieLinkMacClient {
    /// Only the Direct edition's own assistant has a door for a phone.
    static func isAvailable(for connection: GatewayConnection?) -> Bool {
        #if NOLLIE_DIRECT
        connection?.managedInstallationID != nil
        #else
        false
        #endif
    }

    static func offer() async throws -> NollieLinkIPCResponse { try await send(.linkOffer) }
    static func status() async throws -> NollieLinkIPCResponse { try await send(.linkStatus) }
    static func cancel() async { _ = try? await send(.linkCancel) }
    static func remove(_ id: UUID) async throws -> NollieLinkIPCResponse { try await send(.linkRemove(id)) }
    /// Sharing a helper at home: the people, a code for someone, or the owner's answer to an ask.
    static func family(_ request: NollieLinkIPCFamilyRequest) async throws -> NollieLinkIPCResponse {
        try await send(.linkFamily((try? JSONEncoder().encode(request)) ?? Data("{}".utf8)))
    }
    /// Away from home: reads it, or turns it on or off, or saves a typed-in name ("" clears it).
    static func away(on: Bool? = nil, host: String? = nil) async throws -> NollieLinkIPCAway {
        let request = (try? JSONEncoder().encode(NollieLinkIPCAwayRequest(on: on, host: host))) ?? Data("{}".utf8)
        let response = try await send(.linkAway(request))
        if response.error == .invalidRequest { throw NollieLinkIPCError.invalidRequest }
        guard let away = response.away else { throw ManagedRuntimeFailure.invalidResponse }
        return away
    }

    /// Away through iCloud: hands the helper this Mac's away public key, for linked phones to swap.
    static func giveAwayKey(_ key: Data) async throws {
        let request = try JSONEncoder().encode(NollieLinkIPCAwayRequest(sealKey: AwayBase64URL.encode(key)))
        let response = try await send(.linkAway(request))
        if response.error != nil { throw ManagedRuntimeFailure.invalidResponse }
    }

    private static func send(_ operation: ManagedRuntimeOperation) async throws -> NollieLinkIPCResponse {
        guard NativeSetupPlan.directAvailable, !DemoMode.isOn else { throw ManagedRuntimeFailure.unavailable }
        let response = try NollieLinkIPCResponse.decode(try await ManagedRuntimeRequest.send(operation).data)
        if response.error == .unavailable { throw ManagedRuntimeFailure.unavailable }
        return response
    }
}

/// "Use Nollie on your iPhone": a code that refreshes while shown and goes away when the sheet
/// closes, Nollie locks, the screen locks, or Nollie moves to the background. The devices that are
/// already linked sit underneath, each with a Remove button.
struct NollieLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var code: String?
    @State private var expiresAt: Date?
    @State private var linkedName: String?
    @State private var devices: [NollieLinkIPCDevice] = []
    @State private var issue: String?
    @State private var hidden = false
    @State private var screenLocked = false
    @State private var loading = true
    @State private var requestID = UUID()
    @State private var pendingRemoval: NollieLinkIPCDevice?
    @State private var removing: UUID?

    private var preview: Bool {
        #if DEBUG
        DemoMode.isOn
        #else
        false
        #endif
    }
    private static func screenLock(named name: String) -> NotificationCenter.Publisher {
        DistributedNotificationCenter.default().publisher(for: Notification.Name(name))
    }

    private var mayShow: Bool { !model.lock.isLocked && !hidden && !screenLocked && scenePhase == .active }

    var body: some View {
        NavigationStack {
            ScrollView {
                NollieLinkPanel(linkedName: linkedName, state: codeState, devices: devices, removing: removing,
                                canRemove: !model.lock.isLocked && !preview, issue: issue,
                                retry: { requestID = UUID() }, remove: { pendingRemoval = $0 })
                .frame(maxWidth: 420).padding(28).frame(maxWidth: .infinity)
            }
            .background(Ink.canvas.ignoresSafeArea())
            .untitledPage()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(linkedName == nil ? "Close" : "Done") { dismiss() }.testID("link.close")
                }
            }
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 600)
        .task(id: requestID) { await showAndWatch() }
        .onDisappear { withdraw() }
        .onChange(of: mayShow) { _, show in
            if show { requestID = UUID() } else { withdraw() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in hidden = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in hidden = false }
        .onReceive(Self.screenLock(named: "com.apple.screenIsLocked")) { _ in screenLocked = true }
        .onReceive(Self.screenLock(named: "com.apple.screenIsUnlocked")) { _ in screenLocked = false }
        .confirmationDialog(removalTitle, isPresented: .present($pendingRemoval)) {
            Button("Remove", role: .destructive) {
                if let doomed = pendingRemoval { remove(doomed) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It disconnects now, and needs a new code to connect again.")
        }
    }

    private var removalTitle: String {
        guard let device = pendingRemoval else { return "" }
        return "Remove \(device.name)?"
    }

    private var codeState: NollieLinkPanel.CodeState {
        if linkedName != nil { return .linked }
        if model.lock.isLocked { return .locked }
        if !mayShow { return .hidden }
        if let code { return .code(code) }
        if loading { return .loading }
        return .issue(issue ?? "Couldn't make a code. Try again.")
    }

    // MARK: Work

    private func showAndWatch() async {
        code = nil
        guard mayShow else { return }
        if preview { showPreview(); return }
        loading = true
        issue = nil
        do {
            while !Task.isCancelled, mayShow, linkedName == nil {
                let response = try await NollieLinkMacClient.offer()
                try Task.checkCancellation()
                guard mayShow, let offer = response.offer else {
                    if response.offer == nil { throw ManagedRuntimeFailure.invalidResponse }
                    return
                }
                guard let pin = NollieLinkOffer.decodeBase64URL(offer.pin), let secret = NollieLinkOffer.decodeBase64URL(offer.secret) else {
                    throw ManagedRuntimeFailure.invalidResponse
                }
                let made = try NollieLinkOffer(macName: offer.macName, pin: pin, port: offer.port, hosts: offer.hosts,
                                               installTag: offer.tag, secret: secret, expiresAt: offer.expiresAt)
                code = made.urlString
                expiresAt = offer.expiresAt
                devices = response.devices
                loading = false
                // A new code shortly before this one runs out, until a phone uses it.
                while !Task.isCancelled, mayShow, offer.expiresAt.timeIntervalSinceNow > 15 {
                    try await Task.sleep(for: .milliseconds(1500))
                    let status = try await NollieLinkMacClient.status()
                    try Task.checkCancellation()
                    devices = status.devices
                    if let name = status.claimedBy {
                        linkedName = name
                        code = nil
                        return
                    }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            code = nil
            loading = false
            issue = "Couldn't make a code. Check that Nollie's background service is on, then try again."
        }
    }

    private func withdraw() {
        code = nil
        expiresAt = nil
        guard !preview else { return }
        Task { await NollieLinkMacClient.cancel() }
    }

    private func remove(_ device: NollieLinkIPCDevice) {
        pendingRemoval = nil
        guard !preview, !model.lock.isLocked else { return }
        removing = device.id
        Task {
            defer { removing = nil }
            if let response = try? await NollieLinkMacClient.remove(device.id) {
                devices = response.devices
            } else {
                issue = "Couldn't remove \(device.name). Try again."
            }
        }
    }

    private func showPreview() {
        // Demo pictures: an inert code and an example device. Nothing is linked or contacted.
        code = "Nollie Link preview. This code cannot connect."
        loading = false
        devices = [NollieLinkIPCDevice(id: UUID(), name: "Corey's iPhone", linkedAt: Date().addingTimeInterval(-86_400),
                                       lastActive: Date().addingTimeInterval(-300))]
    }
}

/// What the sheet shows, apart from where it comes from: also drawn by the design snapshots.
/// What is true first, then the code itself, then the iPhones already linked. Times and the
/// background service's wording wait behind Advanced.
struct NollieLinkPanel: View {
    enum CodeState: Equatable { case linked, locked, hidden, loading, code(String), issue(String) }
    var linkedName: String?
    var state: CodeState
    var devices: [NollieLinkIPCDevice]
    var removing: UUID?
    var canRemove = true
    /// The last thing that went wrong, word for word, for Advanced.
    var issue: String? = nil
    var now = Date()
    var retry: () -> Void = {}
    var remove: (NollieLinkIPCDevice) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 32) {
            NollieLinkHero(state: hero)
                .testID(heroID)
            codeArea
            if !devices.isEmpty { deviceList }
            AdvancedLink(id: "link.advanced") {
                NollieLinkAdvanced(devices: devices, issue: issue ?? Self.issueText(state), now: now)
            }
        }
    }

    private var hero: NollieLinkHero.State {
        if let linkedName { return .linked(linkedName) }
        switch state {
        case .linked: return .linked("your iPhone")
        case .locked: return .locked
        case .hidden: return .hidden
        case .loading, .code: return .ready
        case .issue: return .issue
        }
    }

    /// The hidden and issue states keep the identifiers their notes had.
    private var heroID: String {
        switch state {
        case .hidden: "link.hidden"
        case .issue: "link.issue"
        default: "link.top"
        }
    }

    private static func issueText(_ state: CodeState) -> String? {
        if case .issue(let text) = state { return text }
        return nil
    }

    @ViewBuilder private var codeArea: some View {
        switch state {
        case .linked, .locked, .hidden:
            EmptyView()
        case .code(let code):
            VStack(spacing: 18) {
                PairingCodeImage(value: code).privacySensitive()
                Text("Open Nollie on your iPhone and scan this code")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Ink.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .testID("link.instruction")
            }
        case .loading:
            ProgressView("Making a code").frame(height: 280)
        case .issue:
            Button(action: retry) { Text("Try again").fullWidthLabel() }
                .pageAction()
                .testID("link.retry")
        }
    }

    /// The iPhones already linked, one capsule each, with Remove.
    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeading(devices.count == 1 ? "Linked iPhone" : "Linked iPhones")
            ForEach(devices) { device in
                LinkedDeviceRow(device: device, busy: removing == device.id, allowed: canRemove) { remove(device) }
            }
        }
        .accessibilityElement(children: .contain)
        .testID("link.devices")
    }

    static func activity(_ device: NollieLinkIPCDevice, now: Date = Date()) -> String {
        guard let last = device.lastActive else { return "Not used yet" }
        if now.timeIntervalSince(last) < 60 { return "Active now" }
        let ago = RelativeDateTimeFormatter()
        ago.unitsStyle = .full
        return "Last active " + ago.localizedString(for: last, relativeTo: now)
    }
}

/// One linked iPhone on a glass capsule, with its Remove.
private struct LinkedDeviceRow: View {
    var device: NollieLinkIPCDevice
    var busy: Bool
    var allowed: Bool
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "iphone")
                .font(.body.weight(.semibold))
                .foregroundStyle(Ink.text2)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(device.name).font(.headline).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) } else { removeButton }
        }
        .inset(h: 22, v: 14)
        .frame(minHeight: 54)
        .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
        .accessibilityElement(children: .contain)
    }

    private var removeButton: some View {
        Button("Remove", role: .destructive, action: remove)
            .buttonStyle(.borderless)
            .font(.headline)
            .foregroundStyle(allowed ? Color.red : Ink.text3)
            .disabled(!allowed)
            .accessibilityLabel("Remove \(device.name)")
            .testID("link.remove")
    }
}

/// The top of the sheet: whether an iPhone can link now, in one large symbol and a few words.
struct NollieLinkHero: View {
    enum State: Equatable {
        case ready, linked(String), locked, hidden, issue

        var symbol: String {
            switch self {
            case .ready: "iphone"
            case .linked: "checkmark.circle.fill"
            case .locked: "lock.fill"
            case .hidden: "eye.slash.fill"
            case .issue: "exclamationmark.triangle.fill"
            }
        }
        var title: String {
            switch self {
            case .ready: "Use Nollie on your iPhone"
            case .linked(let name): "Linked to \(name)"
            case .locked: "Unlock Nollie"
            case .hidden: "Code hidden"
            case .issue: "Couldn't make a code"
            }
        }
        var line: String? {
            switch self {
            case .ready: nil
            case .linked: "You can close this. Your iPhone is finishing up."
            case .locked: "Then the code shows here."
            case .hidden: "It comes back when Nollie is in front."
            case .issue: "Try again in a moment."
            }
        }
        var tint: Color {
            switch self {
            case .ready: .blue
            case .linked: .green
            case .locked: .purple
            case .hidden: Ink.text2
            case .issue: .orange
            }
        }
    }

    var state: State

    var body: some View {
        PageHero(symbol: state.symbol, title: state.title, line: state.line, tint: state.tint, id: "link.hero")
    }
}

/// Linked devices › Advanced: which iPhones are linked at the top, when each was linked and last
/// used, and what went wrong in full.
private struct NollieLinkAdvanced: View {
    var devices: [NollieLinkIPCDevice]
    var issue: String?
    var now: Date

    var body: some View {
        SettingsPage("link.advanced.page") {
            let hero = self.hero
            PageHero(symbol: hero.symbol, title: hero.title, line: hero.line, tint: hero.tint, id: "link.advanced.hero")
            if !devices.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeading("Linked iPhones")
                    ForEach(devices) { device in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name).font(.headline).foregroundStyle(Ink.text)
                            line(NollieLinkPanel.activity(device, now: now))
                            line("Linked " + device.linkedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .testID("link.advanced.devices")
            }
            if let issue {
                VStack(alignment: .leading, spacing: 8) {
                    PageHeading("What went wrong")
                    line(issue)
                }
                .testID("link.advanced.issue")
            }
            VStack(alignment: .leading, spacing: 8) {
                PageHeading("The code")
                line("Nollie's background service on this Mac makes the code. It changes by itself, and hides when you close this, lock Nollie or switch away.")
            }
        }
        .untitledPage()
    }

    /// The top of the page: which iPhones are linked, or that linking went wrong.
    private var hero: (symbol: String, title: String, line: String?, tint: Color) {
        if let first = devices.first {
            let title = devices.count == 1 ? "Linked to \(first.name)" : "\(devices.count) iPhones linked"
            return ("iphone", title, issue == nil ? nil : "The last try didn't work. It's below.", .green)
        }
        return issue == nil ? ("iphone.slash", "No iPhone linked yet", nil, Ink.text2)
                            : ("exclamationmark.triangle.fill", "Linking didn't work", "What went wrong is below.", .orange)
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.body).foregroundStyle(Ink.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
