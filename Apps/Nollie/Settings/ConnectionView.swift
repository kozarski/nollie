import SwiftUI
import NollieCore

/// Settings › Connection: whether Nollie is connected, in one large symbol and a few words, then
/// the few things people do here. Every assistant, address and saved sign-in waits behind
/// Advanced. Reached from Status without the setup rows, it shows those details straight away.
struct GatewaysView: View {
    var includesSetup = false
    @Environment(AppModel.self) private var model
    @AppStorage(OnboardingProgress.storageKey) private var onboardingRaw = ""
    @State private var place: String?
    @State private var visits = 0
    /// The assistant to sign in to again, kept from the tap so the form stays while it reconnects.
    @State private var signInAgain: GatewayConnection?
    #if os(macOS)
    @State private var pairingConnection: GatewayConnection?
    @State private var showLink = false
    #else
    @State private var showPairing = false
    #endif

    private var runtime: GatewayRuntime? { model.runtime }

    private var hero: ConnectionHero.State {
        guard model.hasConnections else { return .setUp }
        if let reach = model.linkReach {
            if reach == .away { return .unreachable(away: true) }
            if runtime?.socketState.isOpen == true {
                return .linked(macName: runtime?.connection.linkedMac?.macName, tailnet: reach == .tailnet)
            }
        }
        guard let runtime else { return .unreachable(away: false) }
        switch runtime.socketState {
        case .open: return .connected(name: runtime.connection.name)
        case .connecting, .reconnecting: return .connecting
        case .authRejected: return .signIn
        case .idle, .failed: return .unreachable(away: false)
        }
    }

    /// The sign-in the assistant turned down, when it did.
    private var rejected: GatewayConnection? {
        guard let runtime, case .authRejected = runtime.socketState else { return nil }
        return runtime.connection
    }

    private var placeKey: String {
        "\(runtime?.connection.id.uuidString ?? "")/\(runtime?.selectedProfile ?? "")/\(runtime?.socketState.isOpen == true)/\(visits)"
    }

    var body: some View {
        SettingsPage(includesSetup ? "settings.connection.page" : "settings.connection.status") {
            ConnectionHero(state: hero)
            if includesSetup {
                primaryAction
                GlassStack {
                    GlassLink("Models", symbol: "cpu", value: place, id: "settings.connection.models") {
                        ModelPreferencesView().untitledPage()
                    }
                    if model.hasConnections { setupButton }
                    phoneRow
                    if let runtime, !runtime.socketState.isOpen, rejected == nil {
                        GlassButton("Reconnect", symbol: "arrow.clockwise", id: "settings.reconnect") {
                            Task { await runtime.reconnectNow() }
                        }
                    }
                }
                AdvancedLink(id: "settings.connection.advanced") {
                    ConnectionAdvancedView().untitledPage()
                }
            } else {
                ConnectionAdvancedContent()
            }
        }
        .animation(.snappy, value: hero)
        .onAppear { visits += 1 }
        .task(id: placeKey) {
            guard includesSetup, let runtime, runtime.socketState.isOpen, !model.lock.isLocked else { place = nil; return }
            if let options = await ModelPlace.read(runtime), !Task.isCancelled {
                place = ModelPlace.word(options) ?? "Not chosen"
            }
        }
        .navigationDestination(item: $signInAgain) { GatewayFormView(existing: $0) }
        #if os(macOS)
        .sheet(item: $pairingConnection) { connection in
            MacDevicePairingView(connection: connection).sheetFrame().withAppModel()
        }
        .sheet(isPresented: $showLink) { NollieLinkSheet().withAppModel() }
        #else
        .sheet(isPresented: $showPairing) {
            PhoneDevicePairingView().sheetFrame().withAppModel()
        }
        #endif
    }

    /// The one prominent step, when there is one: set up, or sign in again.
    @ViewBuilder private var primaryAction: some View {
        if !model.hasConnections {
            Button(action: startSetup) {
                Text("Set up Nollie").fullWidthLabel()
            }
            .buttonStyle(.nollieGlassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .testID("settings.setup")
        } else if rejected != nil {
            Button { signInAgain = rejected } label: {
                Text("Sign in again").fullWidthLabel()
            }
            .buttonStyle(.nollieGlassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .testID("settings.signInAgain")
        }
    }

    private var setupButton: some View {
        GlassButton("Review setup", symbol: "sparkles", id: "settings.setup", action: startSetup)
    }

    /// Opens setup again: at the model step with an assistant, else from the start.
    private func startSetup() {
        var progress = OnboardingProgress.parse(onboardingRaw)
        progress.completion = .inProgress
        progress.step = model.hasConnections ? .model : .home
        progress.connectionID = model.runtime?.connection.id
        onboardingRaw = progress.encoded
    }

    /// The way to the iPhone: show a code on the Mac, or scan one on the phone.
    @ViewBuilder private var phoneRow: some View {
        #if os(macOS)
        if let connection = model.runtime?.connection {
            if NollieLinkMacClient.isAvailable(for: connection) {
                GlassButton("Use Nollie on your iPhone", symbol: "iphone", id: "settings.linkPhone") { showLink = true }
            } else {
                GlassButton("Pair iPhone", symbol: "qrcode", id: "settings.pairPhone") { pairingConnection = connection }
            }
        }
        #else
        GlassButton("Scan QR code", symbol: "qrcode.viewfinder", id: "settings.scanPairing") { showPairing = true }
        #endif
    }
}

/// The top of the Connection page: whether Nollie can talk to its assistant now.
struct ConnectionHero: View {
    enum State: Equatable {
        case setUp, connected(name: String), linked(macName: String?, tailnet: Bool), connecting, signIn
        case unreachable(away: Bool)

        var symbol: String {
            switch self {
            case .setUp: "sparkles"
            case .connected: "checkmark.circle.fill"
            case .linked: "laptopcomputer.and.iphone"
            case .connecting: "arrow.triangle.2.circlepath"
            case .signIn: "person.badge.key.fill"
            case .unreachable(let away): away ? "airplane" : "wifi.exclamationmark"
            }
        }
        var title: String {
            switch self {
            case .setUp: "Let's set up Nollie"
            case .connected: "Connected"
            case .linked: "Linked to your Mac"
            case .connecting: "Connecting"
            case .signIn: "Sign in again"
            case .unreachable:
                #if os(macOS)
                "Can't connect"
                #else
                "Can't reach your Mac"
                #endif
            }
        }
        var line: String {
            switch self {
            case .setUp: "It takes a few minutes."
            case .connected(let name): "\(name) is ready."
            case .linked(let name, let tailnet):
                tailnet ? "Connected through Tailscale." : name.map { "\($0) is ready." } ?? "Everything works."
            case .connecting: "Nollie keeps trying by itself."
            case .signIn: "Your sign-in ended."
            case .unreachable(let away):
                #if os(macOS)
                "Nollie keeps trying by itself."
                #else
                away ? "You're away from home." : "Check that it's awake and online."
                #endif
            }
        }
        var tint: Color {
            switch self {
            case .setUp: .blue
            case .connected, .linked: .green
            case .connecting, .signIn: .orange
            case .unreachable(let away): away ? .orange : .red
            }
        }
    }

    var state: State

    var body: some View {
        PageHero(symbol: state.symbol, title: state.title, line: state.line, tint: state.tint, id: "settings.connection.hero")
    }
}

/// Connection › Advanced: every assistant Nollie knows, how each is reached, and saved sign-ins.
/// The top says how many there are and how the one in use is reached.
struct ConnectionAdvancedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hero = self.hero
        SettingsPage("settings.connection.advanced.page") {
            PageHero(symbol: hero.symbol, title: hero.title, line: hero.line, tint: hero.tint,
                     id: "settings.connection.advanced.hero")
            ConnectionAdvancedContent()
        }
    }

    private var hero: (symbol: String, title: String, line: String?, tint: Color) {
        let connections = model.store.connections
        guard !connections.isEmpty else {
            return ("server.rack", "No assistants yet", "Add one by address below.", Ink.text2)
        }
        let one = connections.count == 1
        let title = one ? connections[0].name : "\(connections.count) assistants"
        guard let runtime = model.runtime else {
            return ("server.rack", title, "None in use right now.", Ink.text2)
        }
        let name = runtime.connection.name
        let kind = GatewayFormView.ConnectionKind(rawValue: runtime.connection.connectionKind ?? "")
        switch runtime.socketState {
        case .open:
            let line: String
            if runtime.connection.linkedMac != nil {
                line = one ? "Linked to your Mac." : "\(name) is linked to your Mac."
            } else if let over = Self.over(kind) {
                line = one ? "Connected over \(over)." : "\(name) is connected over \(over)."
            } else {
                line = one ? "Connected." : "\(name) is connected."
            }
            return (kind?.symbol ?? "checkmark.circle.fill", title, line, .green)
        case .connecting, .reconnecting:
            return ("arrow.triangle.2.circlepath", title, one ? "Connecting." : "Connecting to \(name).", .orange)
        case .authRejected:
            return ("person.badge.key.fill", title, one ? "Sign in again." : "Sign in to \(name) again.", .orange)
        case .idle, .failed:
            return ("wifi.exclamationmark", title, one ? "Can't reach it right now." : "Can't reach \(name) right now.", .red)
        }
    }

    /// How the assistant in use is reached, as the end of "Connected over …".
    private static func over(_ kind: GatewayFormView.ConnectionKind?) -> String? {
        switch kind {
        case .local: "your local network"
        case .tailscale: "Tailscale"
        case .cloudflare: "Cloudflare Access"
        case .other: "the internet"
        case nil: nil
        }
    }
}

/// The details themselves, also shown straight away when Status opens Connection.
struct ConnectionAdvancedContent: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var pendingDelete: GatewayConnection?

    var body: some View {
        VStack(spacing: 36) {
            assistants
            savedSignIns
            if let runtime = model.runtime { now(runtime) }
        }
        .sheet(isPresented: $showAdd) { NavigationStack { GatewayFormView() }.sheetFrame().withAppModel() }
        .alert(pendingDelete.map { "Remove \($0.name)?" } ?? "Remove?", isPresented: .present($pendingDelete), presenting: pendingDelete) { doomed in
            Button("Remove", role: .destructive) { Task { await model.deleteConnection(doomed.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its saved sign-in comes off this device too.")
        }
    }

    /// Your assistants: tap one to use it, edit how it is reached, or remove it.
    private var assistants: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeading("Your assistants")
            if model.store.connections.isEmpty {
                PageNote("No assistant connected.")
            }
            ForEach(model.store.connections) { c in
                VStack(alignment: .leading, spacing: 8) {
                    AssistantRow(connection: c, active: model.store.activeConnectionID == c.id,
                                 activate: { Task { await model.activate(c) } },
                                 remove: { pendingDelete = c })
                    Text(Self.details(c))
                        .font(.body)
                        .foregroundStyle(Ink.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 22)
                        .textSelection(.enabled)
                }
            }
            GlassButton("Add one by address", symbol: "plus", id: "settings.connection.add") { showAdd = true }
        }
    }

    /// One-line summary of how an assistant is reached: its address, network type, sign-in method and
    /// the Hermes version it last reported.
    static func details(_ c: GatewayConnection) -> String {
        let network = GatewayFormView.ConnectionKind(rawValue: c.connectionKind ?? "")?.title
        let viaCloudflare = c.hasAccessHeaders && c.connectionKind != "cloudflare"
        let parts: [String?] = [
            c.gateway.description, network, c.authMode.title,
            viaCloudflare ? "Cloudflare Access" : nil,
            c.lastVersion.map { "Hermes " + $0 },
        ]
        return parts.compactMap { $0 }.joined(separator: "  \u{00B7}  ")
    }

    /// Sign-ins stored on this device, one per assistant. Each can be forgotten without removing the assistant.
    @ViewBuilder private var savedSignIns: some View {
        let remembered = model.store.connections.filter { model.store.remembered.contains($0.id) }
        if !remembered.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                PageHeading("Saved sign-ins")
                ForEach(remembered) { c in
                    HStack(spacing: 14) {
                        Image(systemName: "person.badge.key")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Ink.text2)
                            .frame(width: 26)
                            .accessibilityHidden(true)
                        Text(c.name).font(.headline).foregroundStyle(Ink.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Forget", role: .destructive) { model.store.remembered.forget(c.id) }
                            .buttonStyle(.borderless)
                            .font(.headline)
                            .foregroundStyle(.red)
                            .testID("gateway.forgetSignIn")
                    }
                    .inset(h: 22, v: 14)
                    .frame(minHeight: 54)
                    .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
                }
                PageNote("Kept only on this device, never in iCloud. Forget one to type it next time.")
            }
        }
    }

    /// The connection in use now: reconnect, and sign in again when it was turned down.
    private func now(_ runtime: GatewayRuntime) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeading("Right now")
            ConnectionLine(text: runtime.socketState.label)
            GlassButton("Reconnect", symbol: "arrow.clockwise", id: "settings.connection.reconnect") {
                Task { await runtime.reconnectNow() }
            }
            if case .authRejected(let why) = runtime.socketState {
                ConnectionLine(text: "What it said: \(why)", tint: .red)
                GlassLink("Sign in again", symbol: "person.badge.key", id: "settings.connection.signIn") {
                    GatewayFormView(existing: runtime.connection)
                }
            }
        }
    }
}

/// One assistant on a glass capsule: tap to use it, the pencil to edit, the bin to remove.
private struct AssistantRow: View {
    var connection: GatewayConnection
    var active: Bool
    var activate: () -> Void
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: activate) {
                HStack(spacing: 14) {
                    Image(systemName: active ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(active ? Color.accentColor : Ink.text3)
                        .accessibilityHidden(true)
                    Text(connection.name).font(.headline).foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(active ? .isSelected : [])
            NavigationLink(destination: GatewayFormView(existing: connection)) {
                squareGlyph("pencil", tint: Ink.text2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(connection.name)")
            Button(role: .destructive, action: remove) {
                squareGlyph("trash", tint: .red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(connection.name)")
        }
        .padding(.leading, 22).padding(.trailing, 14).padding(.vertical, 12)
        .frame(minHeight: 54)
        .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
        .contextMenu { Button("Remove", systemImage: "trash", role: .destructive, action: remove) }
    }

    /// A 32-point tap target around a bold symbol.
    private func squareGlyph(_ name: String, tint: some ShapeStyle) -> some View {
        Image(systemName: name)
            .font(.body.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .contentShape(.rect)
    }
}

/// A plain line on the Advanced page, in body text.
private struct ConnectionLine: View {
    var text: String
    var tint: Color = Ink.text2
    var body: some View {
        Text(text).font(.body).foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
