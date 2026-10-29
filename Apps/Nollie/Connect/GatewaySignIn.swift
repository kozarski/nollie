import NollieCore
import SwiftUI

extension GatewayConnection {
    /// Needs a session token, or whatever the browser or password flow stores, and this device has none of it.
    func lacksCredentials(_ secrets: GatewaySecrets) -> Bool {
        guard authMode == .sessionToken else { return secrets.bearer == nil }
        return (secrets.sessionToken ?? "").allSatisfy { $0 == " " || $0 == "\t" }
    }
}

/// Helpers for signing a saved gateway back in on this device once its session has ended.
@MainActor
enum GatewaySignIn {
    /// Of all the sign-in methods, only the browser one can finish from anywhere. The rest need typed
    /// details, which the gateway form collects. A connection waiting to be re-paired never goes to a browser.
    static func usesBrowser(_ connection: GatewayConnection) -> Bool {
        connection.authMode == .oauth && !DevicePairingRecovery.needsPairing(connection)
    }

    /// Keeps only the connections lacking usable credentials on this device.
    static func pending(_ list: [GatewayConnection], secrets: (GatewayConnection) -> GatewaySecrets) -> [GatewayConnection] {
        list.filter { $0.lacksCredentials(secrets($0)) }
    }

    /// Runs the web-based flow for a stored gateway, saves the fresh session, then reconnects, mirroring
    /// a save from the gateway form.
    static func browser(_ connection: GatewayConnection, model: AppModel, client: NativeAuthClient) async throws {
        if DevicePairingRecovery.needsPairing(connection) { throw DevicePairingRecovery.Failure.freshCodeRequired }
        let access = model.store.secrets(for: connection.id).access
        var fresh = try await client.signInWithBrowser(gateway: connection.gateway, provider: connection.authProvider, access: access)
        fresh.access = access
        try model.store.upsert(connection, secrets: fresh)
        if model.runtime?.connection.id == connection.id { await model.deactivate() }
        await model.activate(connection)
        NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
    }
}

/// How a gateway can be signed in to again on this device, best way first.
private enum SignInRoute {
    /// A new pairing code from the Mac.
    case pairAgain
    case browser
    /// Remembered here: the device check signs in, and typing it stays available.
    case remembered
    case typed

    @MainActor init(_ connection: GatewayConnection, model: AppModel) {
        if DevicePairingRecovery.needsPairing(connection) {
            self = .pairAgain
        } else if GatewaySignIn.usesBrowser(connection) {
            self = .browser
        } else if model.canSignInWithRemembered(connection) {
            self = .remembered
        } else {
            self = .typed
        }
    }
}

/// One of the buttons offered for a gateway.
private struct SignInOption: Identifiable {
    let id: String
    let title: String
    var symbol: String?
    var spinning = false
    var prominent = true
    let run: () -> Void
}

/// Opened from the Sign In banner. It goes through each gateway that needs a sign-in in turn: a
/// browser for browser sign-ins, the remembered sign-in if one exists, otherwise the gateway's form.
struct GatewaySignInSheet: View {
    /// Queue of gateways awaiting a sign-in, handled front to back.
    let connections: [GatewayConnection]

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    @State private var position = 0
    @State private var isBusy = false
    @State private var problem: String?
    @State private var client = NativeAuthClient()

    /// The two follow-up sheets.
    private enum Following { case form, pairing }
    @State private var following: Following?
    @State private var pairingDone = false

    private var current: GatewayConnection? {
        connections.indices.contains(position) ? connections[position] : nil
    }

    private var isLast: Bool { position + 1 >= connections.count }

    /// Name of the lock that protects a remembered sign-in (Face ID, Touch ID and so on).
    private var guardName: String { model.rememberedSignIn.authenticator.methodName }

    var body: some View {
        FittedSheet {
            VStack(spacing: 16) {
                CharacterView(look: .main, state: isBusy ? .thinking : .listening, size: 84)
                if let current { card(for: current) }
            }
            .padding(EdgeInsets(top: 0, leading: 28, bottom: 24, trailing: 28))
            .frame(maxWidth: 440)
        }
        .interactiveDismissDisabled(isBusy)
        .sheet(isPresented: isFollowing(.form), onDismiss: moveOnIfSignedIn) {
            if let current {
                NavigationStack { GatewayFormView(existing: saved(current)) }.sheetFrame().withAppModel()
            }
        }
        #if os(iOS)
        .sheet(isPresented: isFollowing(.pairing), onDismiss: {
            guard pairingDone else { return }
            pairingDone = false
            advance()
        }) {
            if let current {
                PhoneDevicePairingView(replacing: saved(current)) { _ in pairingDone = true }
                    .sheetFrame()
                    .withAppModel()
            }
        }
        #endif
    }

    private func isFollowing(_ which: Following) -> Binding<Bool> {
        Binding(get: { following == which }, set: { if !$0 { following = nil } })
    }

    /// The saved copy of a connection, which may be newer than the one the sheet was given.
    private func saved(_ connection: GatewayConnection) -> GatewayConnection {
        model.store.connections.first { $0.id == connection.id } ?? connection
    }

    private func moveOnIfSignedIn() {
        guard let current, !current.lacksCredentials(model.store.secrets(for: current.id)) else { return }
        advance()
    }

    // MARK: What is offered

    private func card(for connection: GatewayConnection) -> some View {
        let route = SignInRoute(connection, model: model)
        return VStack(spacing: 16) {
            heading(for: connection, repairing: route == .pairAgain)
            note(explanation(route, connection), .callout)
            Text(connection.gateway.description)
                .truncationMode(.middle)
                .lineLimit(1)
                .small(.footnote, .tertiary)
                .monospaced()
            if let problem { note(problem, .footnote, tint: .red) }
            VStack(spacing: 10) {
                ForEach(options(route, connection)) { optionButton($0) }
                skipButton
            }
            note(String(localized: "You can reconnect later from Chats or Settings \u{203A} Connections."), .footnote)
        }
    }

    /// What the card is about, and which of the gateways in line this is.
    private func heading(for connection: GatewayConnection, repairing: Bool) -> some View {
        VStack(spacing: 16) {
            Text(repairing ? String(localized: "Reconnect to \(connection.name)") : String(localized: "Sign in to \(connection.name)"))
                .multilineTextAlignment(.center)
                .font(.title3.weight(.semibold))
            if connections.count > 1 {
                Text("Gateway \(position + 1) of \(connections.count)").small(.caption)
            }
        }
    }

    /// Wrapped, centred explanatory text.
    private func note(_ words: String, _ size: Font, tint: Color = .secondary) -> some View {
        Text(words)
            .font(size)
            .foregroundStyle(tint)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func options(_ route: SignInRoute, _ connection: GatewayConnection) -> [SignInOption] {
        let typeIt = SignInOption(id: "signin.form", title: String(localized: "Enter Sign-In…"), prominent: route == .typed) { following = .form }
        switch route {
        case .pairAgain:
            #if os(iOS)
            return [SignInOption(id: "signin.pair", title: String(localized: "Scan a new code"), symbol: "qrcode.viewfinder") {
                pairingDone = false
                following = .pairing
            }]
            #else
            return []
            #endif
        case .browser:
            return [SignInOption(
                id: "signin.browser", title: isBusy ? String(localized: "Waiting for the browser…") : String(localized: "Sign In with Browser"),
                spinning: isBusy) { signInWithBrowser(connection) }]
        case .remembered:
            return [SignInOption(
                id: "signin.remembered", title: String(localized: "Sign In with \(RememberedSignInCopy.shownMethod(guardName))", comment: "%@ is Face ID, Touch ID, Optic ID or Passcode"), symbol: Self.symbol(for: guardName),
                spinning: isBusy) { signInWithRemembered(connection) }, typeIt]
        case .typed:
            return [typeIt]
        }
    }

    private func optionButton(_ option: SignInOption) -> some View {
        Button(action: option.run) {
            HStack(spacing: 8) {
                if option.spinning { ProgressView().controlSize(.small) }
                if let symbol = option.symbol { Label(option.title, systemImage: symbol) } else { Text(option.title) }
            }
            .fullWidthLabel()
        }
        .modifier(OptionStyle(prominent: option.prominent))
        .disabled(isBusy && option.id != "signin.pair")
        .testID(option.id)
    }

    private var skipButton: some View {
        Button(isLast ? "Later" : "Skip this one", action: advance)
            .small(.subheadline)
            .disabled(isBusy)
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif
            .testID("signin.later")
    }

    static func symbol(for guardName: String) -> String {
        switch guardName {
        case "Face ID": "faceid"
        case "Touch ID": "touchid"
        case "Optic ID": "opticid"
        default: "key.fill"
        }
    }

    private func explanation(_ route: SignInRoute, _ connection: GatewayConnection) -> String {
        switch route {
        case .pairAgain:
            #if os(iOS)
            return String(localized: "Make a new code in Nollie on your Mac, then scan it here. Your saved chats and drafts stay with this connection.")
            #else
            return String(localized: "This connection was paired on an iPhone. Pair it again there, or add a separate connection to your assistant on this Mac.")
            #endif
        case .browser:
            return String(localized: "Each device signs in for itself, so \(DeviceWords.this) does it once. Your browser opens the gateway's sign-in page, then brings you back here.",
                          comment: "%@ is this Mac, this iPhone or this iPad")
        case .remembered:
            return String(localized: "\(DeviceWords.This) keeps this gateway's sign-in safe, so \(RememberedSignInCopy.guardedBy(guardName)) can sign you back in.",
                          comment: "The first %@ is This Mac, This iPhone or This iPad; the second names the lock, such as Face ID or the passcode")
        case .typed:
            return connection.authMode == .password
                ? String(localized: "Each device signs in for itself, so \(DeviceWords.this) needs this gateway's username and password once.",
                         comment: "%@ is this Mac, this iPhone or this iPad")
                : String(localized: "Each device signs in for itself, so \(DeviceWords.this) needs this gateway's session token once.",
                         comment: "%@ is this Mac, this iPhone or this iPad")
        }
    }

    // MARK: Actions

    /// Runs a sign-in attempt with the busy state around it. A cancel is silent; any other
    /// failure is shown.
    private func attempt(_ work: @escaping () async throws -> Void) {
        isBusy = true
        problem = nil
        Task {
            defer { isBusy = false }
            do {
                try await work()
                advance()
            } catch RememberedSignInError.cancelled {
                // The check was turned down; both buttons are still there.
            } catch NativeAuthError.cancelled {
                // The browser was closed; the button is back.
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func signInWithRemembered(_ connection: GatewayConnection) {
        attempt { try await model.signInWithRemembered(connection) }
    }

    private func signInWithBrowser(_ connection: GatewayConnection) {
        attempt { try await GatewaySignIn.browser(connection, model: model, client: client) }
    }

    /// Moves to the next gateway, or closes after the last.
    private func advance() {
        problem = nil
        if isLast { dismiss() } else { withAnimation(.snappy) { position += 1 } }
    }
}

/// Prominent or plain glass for a sign-in option.
private struct OptionStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.nollieGlassProminent) } else { content.buttonStyle(.nollieGlass) }
    }
}

/// Appears in place of content when this device has no sign-in for the gateway. It names the
/// problem and carries the fixing button.
struct GatewaySignInBanner: View {
    @Environment(AppModel.self) private var model
    var connection: GatewayConnection

    private var needsPairing: Bool { DevicePairingRecovery.needsPairing(connection) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.badge.key.fill").foregroundStyle(.orange).font(.title3)
            words
            Spacer(minLength: 8)
            action
        }
        .padding(12)
        .background { RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)) }
        .accessibilityElement(children: .contain)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(needsPairing ? String(localized: "Reconnect to \(connection.name)") : String(localized: "Sign in to \(connection.name)"))
                .font(.subheadline.weight(.semibold))
            Text(needsPairing ? String(localized: "A fresh pairing code is needed.")
                 : String(localized: "\(DeviceWords.This) is not signed in to this gateway.", comment: "%@ is This Mac, This iPhone or This iPad"))
                .small()
        }
    }

    private var action: some View {
        Button(needsPairing ? "Reconnect" : "Sign In") { model.signInPrompt = [connection] }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .testID("signin.banner")
    }
}
