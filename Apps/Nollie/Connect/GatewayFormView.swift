import SwiftUI
import NollieCore

/// The form for adding or editing a gateway. Saving always needs a passing connection test, even
/// when the optional details are filled in.
struct GatewayFormView: View {
    /// The gateway being edited. Nil when adding a new one.
    var existing: GatewayConnection?
    /// Values a pairing link can fill in when adding a new gateway.
    var initialURL: String?
    var initialName: String?
    var initialSessionToken: String?
    var initialManagedInstallationID: UUID?
    var onSaved: ((GatewayConnection) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    /// How this device is named in the help text.
    static let thisDevice = DeviceWords.isMac ? "this Mac" : DeviceWords.this

    /// Where the gateway lives from this device's point of view. It decides which help and fields
    /// appear; the connection itself is just the URL, the sign-in method and any Access headers.
    enum ConnectionKind: String, CaseIterable, Identifiable {
        case local, tailscale, cloudflare, other

        var id: String { rawValue }

        private struct Facts {
            let title: String
            let symbol: String
            let example: String
            let help: String
        }

        private var facts: Facts {
            let secure = "https://hermes.example.com"
            switch self {
            case .local:
                return Facts(
                    title: "Local network", symbol: "wifi", example: "http://192.168.1.20:9119",
                    help: "Same Wi\u{2011}Fi as the gateway machine. Use its LAN address and the port hermes serve prints (9119 by default). Plain http is fine here; it only works at home.")
            case .tailscale:
                return Facts(
                    title: "Tailscale", symbol: "point.3.connected.trianglepath.dotted",
                    example: "http://studio.tail1234.ts.net:9119",
                    help: "Use your tailnet to reach the gateway from anywhere. Put Tailscale on \(GatewayFormView.thisDevice) and on the gateway machine, then enter that machine's MagicDNS name or 100.x address. Nothing is opened to the internet, so plain http is fine.")
            case .cloudflare:
                return Facts(
                    title: "Cloudflare Access", symbol: "cloud", example: secure,
                    help: "A public hostname behind Cloudflare Access (a Cloudflare Tunnel on the gateway machine). Enter the service token below: the app cannot use a browser login for Access. Always https.")
            case .other:
                return Facts(
                    title: "Other", symbol: "globe", example: secure,
                    help: "Any https address that gets to the dashboard, such as a reverse proxy, a VPS or your own VPN. Add Access headers only when Cloudflare is in front.")
            }
        }

        var title: String { facts.title }
        var symbol: String { facts.symbol }
        var placeholder: String { facts.example }
        var help: String { facts.help }

        /// Proposes a better connection type for the address, or nil if the current choice is fine or
        /// nothing is better. Under Local or Tailscale, a public address belongs with Other. Under Other,
        /// an address on a private network or a tailnet belongs with its own type.
        static func suggested(for url: GatewayURL, chosen: ConnectionKind) -> ConnectionKind? {
            let onTailnet = url.isTailscaleHost
            let atHome = url.isPrivateHost || onTailnet
            let natural: ConnectionKind = onTailnet ? .tailscale : (url.isPrivateHost ? .local : .other)
            switch chosen {
            case .local where atHome, .tailscale where onTailnet, .cloudflare: return nil
            case .other: return atHome ? natural : nil
            default: return natural
            }
        }
    }

    /// Focus order. Return advances, and the URL field hands off to the secret. Previously, with
    /// the URL keyboard still open, tapping the token field kept typing into the URL.
    private enum Field: Hashable {
        case name
        case url
        case prefix
        case token
        case username
        case password
    }
    @FocusState private var focus: Field?

    // What is typed or chosen.
    @State private var kind = ConnectionKind.local
    @State private var authMode = AuthMode.sessionToken
    @State private var name: String = ""
    @State private var urlText: String = ""
    @State private var pathPrefix: String = ""
    @State private var sessionToken: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var providerName: String = ""
    @State private var accessID: String = ""
    @State private var accessSecret: String = ""
    @State private var providers = [AuthProvider]()
    /// A link's token belongs to the address it came with; if that changes, the token goes.
    @State private var tokenBelongsTo: String?

    // The connection test and sign-in progress.
    @State private var steps = [ConnectionTestStep]()
    @State private var isTesting = false
    @State private var isSigningIn = false
    @State private var testPassed = false
    @State private var testedVersion: String?
    @State private var errorMessage: String?
    @State private var browserSecrets: GatewaySecrets?
    @State private var authClient = NativeAuthClient()

    // State for the "keep me signed in" switch: its position, its position when the form opened
    // (on to off means forget), whether the device has a passcode to protect it, and the name used.
    @State private var remember = false
    @State private var rememberedAtOpen = false
    @State private var canRemember = true
    @State private var guardName = "Passcode"

    // MARK: Derived

    /// With no scheme typed: plain http for home networks and tailnets (no certificate exists
    /// there), https for everything else. Whatever scheme the person typed always wins.
    private var defaultScheme: String { (kind == .local || kind == .tailscale) ? "http" : "https" }

    private func parsedURL() -> Result<GatewayURL, Error> {
        Result { try GatewayURL.normalize(urlText, pathPrefix: pathPrefix, defaultScheme: defaultScheme) }
    }

    private var normalizedURL: GatewayURL? { try? parsedURL().get() }

    private var urlError: String? {
        guard !urlText.isEmpty, case .failure(let error) = parsedURL() else { return nil }
        return error.localizedDescription
    }

    private var access: CloudflareAccess {
        let id = accessID.trimmingCharacters(in: .whitespaces)
        let secret = accessSecret.trimmingCharacters(in: .whitespaces)
        return CloudflareAccess(clientId: id, clientSecret: secret)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// The field Return goes to from the URL: the one for this sign-in method's secret.
    private var firstSecretField: Field? {
        switch authMode {
        case .sessionToken: .token
        case .password: .username
        case .oauth: nil
        }
    }

    /// Whether there is enough filled in to try the connection.
    private var canTest: Bool {
        let haveSecret: Bool
        switch authMode {
        case .sessionToken: haveSecret = sessionToken.isEmpty == false
        case .password: haveSecret = [username, password].allSatisfy { !$0.isEmpty }
        case .oauth: haveSecret = browserSecrets != nil
        }
        return haveSecret && normalizedURL != nil && access.isPartiallyConfigured == false
    }

    private var showsAccessSection: Bool {
        kind == .cloudflare || kind == .other || access.isPartiallyConfigured || !accessID.isEmpty
    }

    /// Why Save is off, shown under the test button; nil when saving is possible.
    private var saveBlocker: String? {
        let named = !trimmedName.isEmpty
        let urlOK = normalizedURL != nil
        return Self.saveBlocker(named: named, urlOK: urlOK, canTest: canTest, testPassed: testPassed)
    }

    static func saveBlocker(named: Bool, urlOK: Bool, canTest: Bool, testPassed: Bool) -> String? {
        if named && testPassed { return nil }
        // What stands in the way of a passing test comes first, then the name.
        var missing: [String] = []
        if !urlOK {
            missing.append("enter the gateway's address")
        } else if !canTest {
            missing.append("fill in the sign-in")
        } else if !testPassed {
            missing.append("run Test Connection until it passes")
        }
        if !named { missing.append("give the gateway a name") }
        return "To save: " + missing.joined(separator: ", and ") + "."
    }

    /// The line below the switch: what it does, or what it needs first.
    private var rememberFootnote: String {
        if remember { return RememberedSignInCopy.kept(guardName) }
        let plain = "Your password is swapped for a session and never kept."
        return canRemember ? plain : plain + " " + RememberedSignInCopy.needsPasscode
    }

    // MARK: Body

    var body: some View {
        Form {
            kindSection
            addressSection
            troubleshootingSection
            signInSection
            if showsAccessSection { accessSection }
            testSection
        }
        .formStyle(.grouped)
        .inlineTitle(existing == nil ? "Connect manually" : "Edit connection")
        .toolbar { bar }
        #if os(macOS)
        .buttonStyle(SettingsRowButtonStyle())
        #endif
        .onChange(of: urlText) { addressChanged() }
        .onChange(of: pathPrefix) { addressChanged() }
        .onChange(of: kind) { resetTest() }
        .onChange(of: authMode) {
            resetTest()
            Task { await loadProviders() }
        }
        .onChange(of: sessionToken) { resetTest() }
        .onChange(of: accessID) { resetTest() }
        .onChange(of: accessSecret) { resetTest() }
        .task {
            canRemember = model.rememberedSignIn.authenticator.canAuthenticate
            guardName = model.rememberedSignIn.authenticator.methodName
            fillFromExisting()
            await loadProviders()
        }
    }

    @ToolbarContentBuilder private var bar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: dismiss.callAsFunction)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save", action: save)
                .testID("gateway.save")
                .disabled(trimmedName.isEmpty || !testPassed)
        }
    }

    // MARK: Building blocks

    /// A text field that does not fix or capitalise what is typed, with its test id and the
    /// focus order: Return goes to `next`, if there is one.
    private func plainEntry(_ title: String, text: Binding<String>, prompt: String? = nil, id: String? = nil,
                            field: Field? = nil, next: Field? = nil) -> some View {
        TextField(title, text: text, prompt: prompt.map { Text($0) })
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($focus, equals: field)
            .submitLabel(next == nil ? .done : .next)
            .onSubmit { focus = next }
            .testID(id ?? "")
    }

    /// Small grey explanatory text.
    private func aside(_ text: String) -> some View {
        Text(text).small(.footnote, .secondary)
    }

    // MARK: Sections

    private var kindSection: some View {
        Section(footer: Text(kind.help)) {
            Picker(selection: $kind) {
                ForEach(ConnectionKind.allCases) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            } label: {
                Text("Connection")
            }
            .pickerStyle(.menu)
        }
    }

    private var addressSection: some View {
        Section(header: Text("Gateway"), footer: addressNotes) {
            plainEntry("Name", text: $name, prompt: "Home", id: "gateway.name", field: .name, next: .url)
            urlField
            plainEntry("Path prefix (optional)", text: $pathPrefix, prompt: "/hermes", field: .prefix, next: firstSecretField)
        }
    }

    /// The address box: a web address, never corrected, and Return jumps to the secret.
    private var urlField: some View {
        TextField("Gateway URL", text: $urlText, prompt: Text(kind.placeholder))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .textContentType(.URL)
            .submitLabel(.next)
            .focused($focus, equals: .url)
            .onSubmit { focus = firstSecretField }
            .testID("gateway.url")
    }

    private static let addressIntro = "Use the address of your Hermes dashboard (`hermes serve`), not a chat web page or an SSH app. A path prefix behind a reverse proxy is fine."

    private var addressNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.addressIntro)
            addressVerdict
        }
    }

    /// Under the intro: what is wrong with the typed address, or what Nollie will do with it.
    @ViewBuilder private var addressVerdict: some View {
        if let urlError {
            Text(urlError).foregroundStyle(.red)
        } else if let url = normalizedURL {
            notes(for: url)
        }
    }

    @ViewBuilder private func notes(for url: GatewayURL) -> some View {
        let homeNetwork = url.isPrivateHost || url.isTailscaleHost
        Text("Will connect to \(url.description)").foregroundStyle(.secondary)
        if !urlText.contains("://") {
            let which = url.isTLS
                ? "No scheme given, so we use https. Type http:// for a plain connection."
                : "No scheme given, so we use plain http. Type https:// if your gateway has a certificate."
            Text(which).foregroundStyle(.secondary)
        }
        ForEach(warnings(for: url, homeNetwork: homeNetwork), id: \.self) { warning in
            Text(warning).foregroundStyle(.orange)
        }
        // Offer a one-tap switch to the connection type this address matches.
        if let better = ConnectionKind.suggested(for: url, chosen: kind) {
            Button(action: { kind = better }) { Text("Use \(better.title) instead") }
                .font(.footnote.weight(.semibold))
                .testID("gateway.useSuggested")
        }
        if url.isTailscaleHost {
            Text("Tailscale needs to be on for \(Self.thisDevice) to pass the test.").foregroundStyle(.secondary)
        }
    }

    private func warnings(for url: GatewayURL, homeNetwork: Bool) -> [String] {
        var found: [String] = []
        if !url.isTLS, !homeNetwork {
            found.append("Plain HTTP to a public host sends your credentials without encryption.")
        }
        if kind == .tailscale, !url.isTailscaleHost {
            found.append("That is not a Tailscale address (a *.ts.net name or 100.x.x.x).")
        }
        if kind == .local, !homeNetwork {
            found.append("That is not a local address. Pick another connection type if the gateway is somewhere else.")
        }
        if kind == .cloudflare, !url.isTLS {
            found.append("Cloudflare Access only works over https.")
        }
        return found
    }

    private var troubleshootingSection: some View {
        Section(footer: Text("Things to try if the test stalls, sign-in fails or the Companion will not install.")) {
            NavigationLink(destination: TroubleshootingView()) {
                Label("Troubleshooting", systemImage: "wrench.and.screwdriver")
            }
        }
    }

    private var signInSection: some View {
        Section(header: Text("Authentication")) {
            Picker("Method", selection: $authMode) {
                ForEach(AuthMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .testID("gateway.authMethod")

            switch authMode {
            case .sessionToken: tokenFields
            case .password: passwordFields
            case .oauth: browserFields
            }
        }
    }

    @ViewBuilder private var tokenFields: some View {
        SecureField("Session token", text: $sessionToken)
            .focused($focus, equals: .token)
            .textContentType(.password)
            .autocorrectionDisabled()
            .testID("gateway.sessionToken")
        aside("Found in your Hermes dashboard settings. Only needed when it has no sign-in.")
    }

    @ViewBuilder private var passwordFields: some View {
        providerPicker
        TextField("Username", text: $username)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: .username)
            .onSubmit { focus = .password }
            .submitLabel(.next)
            .testID("gateway.username")
        SecureField("Password", text: $password)
            .focused($focus, equals: .password)
            .textContentType(.password)
            .testID("gateway.password")
        Toggle(isOn: $remember) { Text("Keep me signed in on this device") }
            .disabled(remember == false && canRemember == false)
            .testID("gateway.rememberSignIn")
        aside(rememberFootnote).testID("gateway.rememberFootnote")
    }

    @ViewBuilder private var browserFields: some View {
        providerPicker
        let signedIn = browserSecrets != nil
        Button(action: { Task { await signInWithBrowser() } }) {
            HStack {
                Label(signedIn ? "Signed in" : "Sign in with browser",
                      systemImage: signedIn ? "checkmark.circle.fill" : "safari")
                Spacer()
                if isSigningIn { ProgressView() }
            }
        }
        .disabled(isSigningIn || normalizedURL == nil)
        aside("Opens your browser to sign in. Nollie keeps the sign-in in your Keychain.")
    }

    @ViewBuilder private var providerPicker: some View {
        if providers.isEmpty {
            plainEntry("Provider name", text: $providerName, prompt: authMode == .password ? "basic" : "nous")
        } else {
            let offered = providers.filter { authMode != .password || ($0.supportsPassword ?? false) }
            Picker("Provider", selection: $providerName) {
                ForEach(offered) { Text($0.displayName ?? $0.name).tag($0.name) }
            }
        }
    }

    private var accessSection: some View {
        let isCloudflare = kind == .cloudflare
        return Section(
            header: Text(isCloudflare ? "Cloudflare Access token" : "Cloudflare Access (optional)"),
            footer: accessNotes(isCloudflare: isCloudflare)
        ) {
            plainEntry("CF-Access-Client-Id", text: $accessID)
            SecureField("CF-Access-Client-Secret", text: $accessSecret)
        }
    }

    private func accessNotes(isCloudflare: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if isCloudflare {
                Text("From Zero Trust \u{203A} Access \u{203A} Service Auth: create a service token and allow it in the application's policy. Both values are sent on every request and on the WebSocket handshake.")
            } else {
                Text("Skip this unless Cloudflare Access sits in front of your gateway. Cookies from Safari do not reach the app.")
            }
            if access.isPartiallyConfigured {
                Text("Fill in both the Client ID and the Client Secret, or neither.").foregroundStyle(.red)
            }
        }
    }

    private var testSection: some View {
        Section(footer: testFooter) {
            Button(action: { Task { await runTest() } }) {
                HStack {
                    Label("Test connection", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    testBadge
                }
            }
            .disabled(isTesting || !canTest)
            .testID("gateway.test")

            ForEach(steps) { TestStepRow(step: $0) }
            if let errorMessage {
                Text(errorMessage).small(.footnote, .red)
            }
        }
    }

    @ViewBuilder private var testBadge: some View {
        switch (isTesting, testPassed) {
        case (true, _): ProgressView()
        case (false, true): passedMark
        case (false, false): EmptyView()
        }
    }

    private var passedMark: some View {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    }

    private var testFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checks that Nollie can reach your Hermes and sign in.")
            saveBlocker.map { reason in
                Text(reason).testID("gateway.saveBlocker").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: State changes

    private func resetTest() {
        testPassed = false
        steps = []
    }

    private func addressChanged() {
        // A token that arrived with a link belongs to that address only.
        if let tokenBelongsTo, normalizedURL?.description != tokenBelongsTo {
            sessionToken = ""
            self.tokenBelongsTo = nil
        }
        resetTest()
    }

    private func fillFromExisting() {
        guard let saved = existing else {
            fillFromLink()
            return
        }
        let secrets = model.store.secrets(for: saved.id)
        // The remembered list may have been unreadable at launch (a locked phone); read it again.
        if !model.store.remembered.isKnown { model.store.remembered.reload() }

        (name, urlText, authMode) = (saved.name, saved.gateway.description, saved.authMode)
        kind = ConnectionKind(rawValue: saved.connectionKind ?? "") ?? guessKind(of: saved)
        (providerName, sessionToken) = (saved.authProvider ?? "", secrets.sessionToken ?? "")
        (accessID, accessSecret) = (secrets.access.clientId, secrets.access.clientSecret)
        remember = model.store.remembered.contains(saved.id)
        rememberedAtOpen = remember
        browserSecrets = secrets.bearer == nil ? nil : secrets
    }

    private func guessKind(of saved: GatewayConnection) -> ConnectionKind {
        if saved.hasAccessHeaders { return .cloudflare }
        if saved.gateway.isTailscaleHost { return .tailscale }
        return saved.gateway.isPrivateHost ? .local : .other
    }

    /// A new gateway can arrive pre-filled from a pairing link.
    private func fillFromLink() {
        if name.isEmpty { name = initialName ?? "" }
        if urlText.isEmpty { urlText = initialURL ?? "" }
        guard sessionToken.isEmpty, let token = initialSessionToken, !token.isEmpty,
              let linkURL = initialURL, let gateway = try? GatewayURL.normalize(linkURL),
              normalizedURL == gateway
        else { return }
        sessionToken = token
        tokenBelongsTo = gateway.description
    }

    private func loadProviders() async {
        guard authMode != .sessionToken, let url = normalizedURL else { return }
        guard let found = try? await NativeAuthClient.providers(gateway: url, access: access), !found.isEmpty else { return }
        providers = found
        guard providerName.isEmpty || !found.contains(where: { $0.name == providerName }) else { return }

        switch authMode {
        case .password:
            // Username and password only work with a provider that takes them. Picking the first provider
            // blindly used to end with the gateway complaining about no password login, so we say it up
            // front, before the person types anything.
            if let usable = found.first(where: { $0.supportsPassword ?? false }) {
                providerName = usable.name
            } else {
                providerName = ""
                errorMessage = Self.noPasswordProviderMessage(found)
            }
        default:
            providerName = found[0].name
        }
    }

    /// Message for a gateway whose sign-in options all lack a username and password.
    static func noPasswordProviderMessage(_ providers: [AuthProvider]) -> String {
        let offered = providers.map { $0.name }.joined(separator: ", ")
        return "This gateway has no username/password sign-in (it offers: " + offered + "). " + browserAdvice + " and try again."
    }

    /// What to do when the gateway has no password sign-in to use.
    private static let browserAdvice = "Choose Sign in with browser above, or enable a password provider on the gateway (HERMES_DASHBOARD_BASIC_AUTH_USER and HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)"

    // MARK: Signing in and testing

    private func signInWithBrowser() async {
        guard let url = normalizedURL else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        errorMessage = nil
        do {
            browserSecrets = try await authClient.signInWithBrowser(
                gateway: url, provider: providerName.isEmpty ? nil : providerName, access: access)
            resetTest()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Secrets for testing and saving; signs in first if the method calls for it.
    private func gatherSecrets() async throws -> GatewaySecrets {
        var gathered: GatewaySecrets
        switch authMode {
        case .sessionToken:
            gathered = GatewaySecrets()
            gathered.sessionToken = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        case .password:
            // A saved browser sign-in is reused when no username was typed.
            if let earlier = browserSecrets, earlier.bearer != nil, username.isEmpty {
                gathered = earlier
            } else {
                gathered = try await passwordSecrets()
                browserSecrets = gathered
            }
        case .oauth:
            guard let signedIn = browserSecrets else { throw NativeAuthError.noCallback }
            gathered = signedIn
        }
        gathered.access = access
        return gathered
    }

    /// Trades the typed username and password for a session.
    private func passwordSecrets() async throws -> GatewaySecrets {
        guard let url = normalizedURL else { throw GatewayURLError.invalid }
        let provider = providerName.isEmpty ? "basic" : providerName
        let offersPassword = providers.contains { $0.supportsPassword ?? false }
        if !providers.isEmpty, !offersPassword {
            let list = Self.noPasswordProviderMessage(providers)
            throw NativeAuthError.invalidResponse(list)
        }
        do {
            return try await NativeAuthClient.signInWithPassword(
                gateway: url, provider: provider, username: username, password: password, access: access)
        } catch let failure as HermesAPIError
            where failure.localizedDescription.localizedCaseInsensitiveContains("does not support password") {
            // Rephrases the gateway's message about a provider that only works in a browser as advice.
            if !providers.isEmpty { throw NativeAuthError.invalidResponse(Self.noPasswordProviderMessage(providers)) }
            throw NativeAuthError.invalidResponse(
                "The provider \u{201C}\(provider)\u{201D} on this gateway does not take a username and password. \(Self.browserAdvice).")
        }
    }

    private func runTest() async {
        guard let url = normalizedURL else { return }
        (isTesting, testPassed, errorMessage) = (true, false, nil)
        defer { isTesting = false }
        do {
            let secrets = try await gatherSecrets()
            let provider: String? = providerName.isEmpty ? nil : providerName
            let trial = GatewayConnection(
                id: existing?.id ?? UUID(), name: name, gateway: url,
                authMode: authMode, authProvider: provider)
            let outcome = await ConnectionTester.run(connection: trial, secrets: secrets) { progress in
                Task { @MainActor in self.steps = progress }
            }
            (steps, testPassed, testedVersion) = (outcome.steps, outcome.succeeded, outcome.version)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Saving

    private func save() {
        guard let url = normalizedURL else { return }
        Task {
            do {
                let secrets = try await gatherSecrets()
                let connection = buildConnection(url: url, secrets: secrets)
                try model.store.upsert(connection, secrets: secrets)
                do {
                    try applyRememberChoice(for: connection.id, gateway: connection.gateway)
                } catch {
                    // The gateway is saved and signed in; only remembering failed. Turn the
                    // switch off so a second Save goes through without it.
                    remember = false
                    errorMessage = "The gateway is saved, but \(Self.thisDevice) could not keep your sign-in (\(error.localizedDescription)). Save again to continue without it."
                    return
                }
                if model.runtime?.connection.id == connection.id { await model.deactivate() }
                onSaved?(connection)
                dismiss()
                await model.activate(connection)
            } catch let failure as KeychainError {
                errorMessage = "Saving to the Keychain failed (\(failure.localizedDescription)). On a simulator that usually means an unsigned build."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func buildConnection(url: GatewayURL, secrets: GatewaySecrets) -> GatewayConnection {
        var connection = existing ?? GatewayConnection(name: name, gateway: url, authMode: authMode)
        connection.name = trimmedName
        connection.gateway = url
        connection.authMode = authMode
        connection.authProvider = providerName.isEmpty ? nil : providerName
        connection.lastVersion = testedVersion
        connection.connectionKind = kind.rawValue

        if let old = existing {
            let identityChanged = old.gateway != url || old.authMode != authMode
                || old.authProvider != connection.authProvider
                || old.hasAccessHeaders != secrets.access.isConfigured
            if identityChanged { connection.gatewayIdentity = nil }
        }

        #if os(macOS) && NOLLIE_DIRECT
        // A gateway set up by the Mac runtime keeps its link only if it is still that gateway.
        if existing == nil, let installation = initialManagedInstallationID,
           let linkURL = initialURL, let prepared = try? GatewayURL.normalize(linkURL), prepared == url,
           ManagedRuntimeClient.isAllowedEndpoint(url.base), authMode == .sessionToken,
           let linkToken = initialSessionToken, secrets.sessionToken == linkToken,
           !access.isConfigured, !access.isPartiallyConfigured {
            connection.managedInstallationID = installation
        } else if let old = existing, old.gateway != url || old.authMode != authMode {
            connection.managedInstallationID = nil
        }
        #endif
        return connection
    }

    /// Saves, clears or keeps the remembered sign-in according to the switch and what changed
    /// (rules live in `RememberedSignInCoordinator.formChange`).
    private func applyRememberChoice(for id: UUID, gateway: GatewayURL) throws {
        let change = RememberedSignInCoordinator.formChange(
            authMode: authMode,
            switchOn: remember,
            wasOn: rememberedAtOpen,
            typed: !username.isEmpty && !password.isEmpty,
            moved: existing.map { $0.gateway != gateway } ?? false)

        if change == .remember {
            let provider = providerName.isEmpty ? "basic" : providerName
            let saved = RememberedSignIn(provider: provider, username: username, password: password, gateway: gateway)
            try model.store.remembered.remember(saved, for: id)
        } else if change == .forget {
            model.store.remembered.forget(id)
        }
        // A manual sign-in re-enables the automatic one.
        model.rememberedSignIn.didSignIn(id)
    }
}

/// One line of the connection test: how it is going, what it is, and what it found.
private struct TestStepRow: View {
    var step: ConnectionTestStep

    /// Optional message under the title for this step, and whether it should read as a problem.
    private var finding: (words: String, bad: Bool)? {
        switch step.status {
        case .passed(let note): (note, false)
        case .failed(let note): (note, true)
        default: nil
        }
    }

    /// The symbol and shade for a step that is not running.
    private var glyph: (symbol: String, shade: AnyShapeStyle) {
        switch step.status {
        case .passed: ("checkmark.circle.fill", AnyShapeStyle(.green))
        case .failed: ("xmark.circle.fill", AnyShapeStyle(.red))
        default: ("circle", AnyShapeStyle(.tertiary))
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if step.status == .running {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: glyph.symbol).foregroundStyle(glyph.shade)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.subheadline)
                if let finding {
                    Text(finding.words)
                        .small(.footnote, finding.bad ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
