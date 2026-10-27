import SwiftUI
import UserNotifications
import NollieCore

/// Health of a single piece of Nollie. Green means fine, orange wants a look, red means broken, and
/// grey covers off, not set up and unknown. An optional piece that was never set up stays grey so it
/// cannot drag the page down. Raw values run from best to worst, so the worst one sorts highest.
enum StatusLight: Int, Comparable {
    case off, good, warn, bad

    var color: Color {
        switch self { case .good: .green; case .warn: .orange; case .bad: .red; case .off: Ink.text2 }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One part on Status: its light, a word for its row, a short line for the top of the page when it
/// is the worst, and the full sentence under Details.
struct StatusPart: Identifiable {
    enum Fix { case connection, signIn, companion, notifications }
    var id: String
    var title: String
    var symbol: String
    var light: StatusLight
    var word: String
    var line: String
    var detail: String
    var fix: Fix
    /// What isn't set up yet, when this part is optional and simply off: named under "All good".
    var notSetUp: Extra? = nil

    /// Something optional that the top of the page names when it isn't set up.
    enum Extra: Hashable { case companion, approvalCards, alerts }
}

/// What Status says, worked out once for Status and for the top of Advanced: the connection, the
/// sign-in, the Companion, approval requests and notifications, and the worst of them.
struct StatusReport {
    var parts: [StatusPart]
    var connected: Bool
    /// The Companion's first check hasn't come back yet.
    var checking: Bool

    @MainActor init(model: AppModel, setup: PushSetupModel) {
        let push = model.push
        guard let rt = model.runtime else {
            connected = false
            checking = false
            parts = [
                StatusPart(id: "connection", title: String(localized: "Connection", comment: "A Status row"), symbol: "network", light: .off,
                           word: String(localized: "None", comment: "A Status row's state word"), line: "",
                           detail: model.activationError ?? String(localized: "No gateway connected"), fix: .connection),
                StatusPart(id: "companion", title: String(localized: "Companion", comment: "A Status row"), symbol: "puzzlepiece.fill", light: .off,
                           word: String(localized: "Off", comment: "A Status row's state word"), line: "",
                           detail: String(localized: "Connect a gateway first"), fix: .companion),
                Self.notifications(push),
            ]
            return
        }
        connected = true
        checking = setup.companionCheckedAt == nil && setup.companionCheckError == nil
        parts = [Self.connection(rt), Self.signIn(rt), Self.companion(setup, checking: checking), Self.approvals(rt), Self.notifications(push)]
    }

    /// The first of the worst parts, when something needs a look.
    var worst: StatusPart? {
        guard let light = parts.map(\.light).max(), light >= .warn else { return nil }
        return parts.first { $0.light == light }
    }

    struct Hero { var symbol: String; var title: String; var line: String?; var tint: Color }

    /// The worst light wins, in the same words on Status and on Advanced. Red only when something
    /// is broken; optional parts that aren't set up only change the line under "All good".
    var hero: Hero {
        guard connected else {
            return Hero(symbol: "bolt.horizontal.circle", title: String(localized: "Not connected"),
                        line: String(localized: "Connect to see how things are."), tint: Ink.text2)
        }
        if let worst, worst.light == .bad {
            return Hero(symbol: "xmark.octagon.fill", title: String(localized: "Something is off"), line: worst.line, tint: .red)
        }
        if let worst {
            return Hero(symbol: "exclamationmark.triangle.fill", title: String(localized: "Needs a look"), line: worst.line, tint: .orange)
        }
        if checking { return Hero(symbol: "ellipsis.circle", title: String(localized: "Checking"), line: nil, tint: Ink.text2) }
        return Hero(symbol: "checkmark.seal.fill", title: String(localized: "All good"), line: notSetUpLine ?? String(localized: "Everything is working."), tint: .green)
    }

    /// The optional parts not set up yet, in one line: "Alerts aren't set up yet."
    var notSetUpLine: String? {
        let extras = Set(parts.compactMap(\.notSetUp))
        return switch (extras.contains(.companion), extras.contains(.approvalCards), extras.contains(.alerts)) {
        case (false, false, false): nil
        case (true, false, false): String(localized: "The Companion isn't set up yet.")
        case (false, true, false): String(localized: "Approval cards aren't set up yet.")
        case (false, false, true): String(localized: "Alerts aren't set up yet.")
        case (true, true, false): String(localized: "The Companion and approval cards aren't set up yet.")
        case (true, false, true): String(localized: "The Companion and alerts aren't set up yet.")
        case (false, true, true): String(localized: "Approval cards and alerts aren't set up yet.")
        case (true, true, true): String(localized: "The Companion, approval cards and alerts aren't set up yet.")
        }
    }

    // MARK: Connection

    @MainActor private static func connection(_ rt: GatewayRuntime) -> StatusPart {
        let s = rt.socketState
        let name = rt.connection.name
        let light: StatusLight
        let word: String
        let line: String
        let detail: String
        switch s {
        case .open:
            (light, word, line, detail) = (.good, String(localized: "Connected", comment: "A Status row's state word"), "", String(localized: "Connected to \(name)"))
        case .connecting:
            (light, word, line, detail) = (.warn, String(localized: "Connecting", comment: "A Status row's state word"), String(localized: "Connecting to \(name)."),
                                           String(localized: "Connecting to \(name)…"))
        case .reconnecting(let n, _):
            (light, word, line, detail) = (.warn, String(localized: "Trying again", comment: "A Status row's state word"), String(localized: "Connecting to \(name)."),
                                           String(localized: "The link dropped, so Nollie is retrying (attempt \(n))"))
        case .failed(let why):
            (light, word, line, detail) = (.bad, String(localized: "Can't reach", comment: "A Status row's state word"), String(localized: "Nollie can't reach \(name)."),
                                           String(localized: "Cannot reach \(name): \(why)"))
        case .authRejected:
            (light, word, line, detail) = (.bad, String(localized: "Refused", comment: "A Status row's state word"), String(localized: "\(name) turned down the sign-in."),
                                           String(localized: "\(name) refused the sign-in"))
        case .idle:
            (light, word, line, detail) = (.warn, String(localized: "Not yet", comment: "A Status row's state word"), String(localized: "Not connected yet."),
                                           String(localized: "Not connected yet"))
        }
        return StatusPart(id: "connection", title: String(localized: "Connection", comment: "A Status row"), symbol: "network", light: light, word: word, line: line,
                          detail: detail, fix: .connection)
    }

    @MainActor private static func signIn(_ rt: GatewayRuntime) -> StatusPart {
        let s = rt.socketState
        if case .authRejected(let why) = s {
            return StatusPart(id: "signin", title: String(localized: "Sign-in", comment: "A Status row"), symbol: "person.badge.key.fill",
                              light: .bad, word: String(localized: "Sign in again", comment: "A Status row's state word"), line: String(localized: "Sign in again."),
                              detail: why.isEmpty ? String(localized: "The gateway ended this session. Please sign in once more.") : why,
                              fix: .signIn)
        }
        let detail = switch rt.connection.authMode {
        case .sessionToken: String(localized: "Signed in with a session token from the gateway")
        case .password: String(localized: "Signed in with a name and password")
        case .oauth: String(localized: "Signed in with the browser")
        }
        return StatusPart(id: "signin", title: String(localized: "Sign-in", comment: "A Status row"), symbol: "person.badge.key.fill",
                          light: s.isOpen ? .good : .warn,
                          word: s.isOpen ? String(localized: "Signed in", comment: "A Status row's state word") : String(localized: "Waiting", comment: "A Status row's state word"),
                          line: String(localized: "Not signed in yet."), detail: detail, fix: .signIn)
    }

    // MARK: Gateway side

    @MainActor private static func companion(_ setup: PushSetupModel, checking: Bool) -> StatusPart {
        func part(_ light: StatusLight, _ word: String, _ line: String, _ detail: String) -> StatusPart {
            StatusPart(id: "companion", title: String(localized: "Companion", comment: "A Status row"), symbol: "puzzlepiece.fill",
                       light: light, word: word, line: line,
                       detail: detail, fix: .companion)
        }
        if checking { return part(.off, String(localized: "Checking", comment: "A Status row's state word"), "", String(localized: "Checking the Companion on the gateway…")) }
        if let e = setup.companionCheckError {
            return part(.warn, String(localized: "Couldn't check", comment: "A Status row's state word"), String(localized: "Couldn't check the Companion."),
                        String(localized: "Could not check: \(e)"))
        }
        // The Companion is optional: not installed is not set up, never broken.
        guard let v = setup.installedVersion else {
            var p = part(.off, String(localized: "Not set up", comment: "A Status row's state word"), "",
                         String(localized: "Not installed. Settings › Advanced › Companion installs it in one \(DeviceWords.tap)."))
            p.notSetUp = .companion
            return p
        }
        if setup.companionHealthy { return part(.good, String(localized: "Running", comment: "A Status row's state word"), "", String(localized: "Running, version \(v)")) }
        // Just installed or updated: one restart and it runs. A look, not broken.
        if setup.needsRestart {
            return part(.warn, String(localized: "Needs a restart", comment: "A Status row's state word"), String(localized: "The Companion needs a restart."),
                        String(localized: "Version \(v) is installed, but the gateway has not been restarted to load it"))
        }
        if setup.heartbeat == nil {
            return part(.bad, String(localized: "Not running", comment: "A Status row's state word"), String(localized: "The Companion isn't running."),
                        String(localized: "Version \(v) is installed, yet it has not checked in. Restart the gateway."))
        }
        if setup.runningOlderCode || !setup.installedScriptMatches {
            return part(.warn, String(localized: "Update ready", comment: "A Status row's state word"), String(localized: "The Companion has an update."),
                        String(localized: "Running an older version than this build ships. Update it from Settings › Advanced › Companion."))
        }
        return part(.bad, String(localized: "Stopped", comment: "A Status row's state word"), String(localized: "The Companion has stopped reporting."),
                    String(localized: "Installed (\(v)) but its last report is old or it lost its connection. Is the gateway running?"))
    }

    /// Approval cards are idle, not broken, until the gateway offers them: grey, never red.
    @MainActor private static func approvals(_ rt: GatewayRuntime) -> StatusPart {
        let offered = !rt.serverRequestsAdvertised.isEmpty
        let received = rt.serverRequestsReceived
        let detail = !offered
            ? String(localized: "This connection has not been cleared to receive approval cards. Reconnect, or update Hermes on the gateway.")
            : received == 0 ? String(localized: "Cards are allowed here, and none have arrived on this connection so far")
            : String(localized: "\(received) arrived on this connection", comment: "How many approval cards arrived")
        let word = !offered
            ? (rt.socketState.isOpen ? String(localized: "Not set up", comment: "A Status row's state word") : String(localized: "Waiting", comment: "A Status row's state word"))
            : received == 0 ? String(localized: "Ready", comment: "A Status row's state word")
            : String(localized: "\(received) received", comment: "How many approval cards arrived")
        var part = StatusPart(id: "approvals", title: String(localized: "Approvals", comment: "A Status row"), symbol: "checkmark.shield.fill",
                              light: offered ? .good : .off, word: word, line: "", detail: detail, fix: .companion)
        if !offered, rt.socketState.isOpen { part.notSetUp = .approvalCards }
        return part
    }

    // MARK: Device side

    @MainActor private static func notifications(_ push: PushRegistrar) -> StatusPart {
        func part(_ light: StatusLight, _ word: String, _ line: String, _ detail: String) -> StatusPart {
            StatusPart(id: "notifications", title: String(localized: "Notifications", comment: "A Status row"), symbol: "bell.fill",
                       light: light, word: word, line: line,
                       detail: detail, fix: .notifications)
        }
        func notSetUp(_ detail: String) -> StatusPart {
            var p = part(.off, String(localized: "Not set up", comment: "A Status row's state word"), "", detail)
            p.notSetUp = .alerts
            return p
        }
        if !push.notificationsEnabled {
            return part(.off, String(localized: "Off", comment: "A Status row's state word"), "", String(localized: "Turned off in Settings › Notifications › Advanced"))
        }
        switch push.authorization {
        // Turned down on this device: the person's choice, worth a look but never red.
        case .denied:
            return part(.warn, String(localized: "Not allowed", comment: "A Status row's state word"), String(localized: "Notifications aren't allowed."),
                        String(localized: "Not allowed in \(DeviceWords.settings)"))
        case .notDetermined: return notSetUp(String(localized: "Not asked yet"))
        default: break
        }
        if let e = push.relayError ?? push.lastError {
            return part(.warn, String(localized: "Problem", comment: "A Status row's state word"), String(localized: "Notifications hit a problem."), e)
        }
        guard push.registeredAt != nil else {
            return notSetUp(String(localized: "Allowed, though \(DeviceWords.this) has not signed up with the gateway yet"))
        }
        return part(.good, String(localized: "On", comment: "A Status row's state word"), "",
                    PushRelay.isConfigured ? String(localized: "Allowed, and signed up with both the gateway and the relay")
                                           : String(localized: "Allowed, and signed up with the gateway"))
    }
}

/// Lives under Settings > Advanced > Status. Lists each piece of Nollie by health with the worst on top;
/// tapping a row goes to the page that repairs it. Full sentences and versions are kept in Details.
struct StatusView: View {
    @Environment(AppModel.self) private var model
    @State private var setup = PushSetupModel()

    var body: some View {
        let report = StatusReport(model: model, setup: setup)
        let hero = report.hero
        SettingsPage("status.page") {
            PageHero(symbol: hero.symbol, title: .verbatim(hero.title), line: .verbatim(hero.line), tint: hero.tint, id: "status.hero")
            GlassStack {
                ForEach(report.parts) { part in
                    NavigationLink { fix(part.fix).untitledPage() } label: { StatusRowLabel(part: part) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("status.row.\(part.id)")
                }
            }
            StatusDetails(parts: report.parts, versions: versions)
        }
        .untitledPage()
        .task { await check() }
        .reloadable { await check() }
    }

    private func check() async {
        if let rt = model.runtime { await setup.checkCompanion(runtime: rt) }
        await model.push.refreshAuthorization()
    }

    @ViewBuilder private func fix(_ fix: StatusPart.Fix) -> some View {
        switch fix {
        case .connection: GatewaysView()
        case .signIn:
            if let rt = model.runtime { GatewayFormView(existing: rt.connection) } else { GatewaysView() }
        case .companion: CompanionView()
        case .notifications: NotificationsView()
        }
    }

    private var versions: [(String, String)] {
        let app = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))"
        var list = [("Nollie", app), (String(localized: "Companion this build ships"), PushSetupModel.bundledPluginVersion)]
        if let v = setup.installedVersion { list.append((String(localized: "Companion on the gateway"), v)) }
        return list
    }
}

/// A part's row: its symbol in its light's colour, its name, and a word for how it is.
private struct StatusRowLabel: View {
    var part: StatusPart

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: part.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(part.light.color)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(part.title).font(.headline).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(part.word)
                .font(.body)
                .foregroundStyle(part.light >= .warn ? part.light.color : Ink.text2)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Ink.text3)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .frame(minHeight: 54)
        .contentShape(Capsule())
        .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(part.title): \(part.word)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Details, folded away: each part's whole sentence, then the versions.
private struct StatusDetails: View {
    var parts: [StatusPart]
    var versions: [(String, String)]
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Button { withAnimation(reduceMotion ? nil : .snappy) { open.toggle() } } label: {
                HStack(spacing: 14) {
                    Image(systemName: "info.circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Ink.text2)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    Text("Details").font(.headline).foregroundStyle(Ink.text)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Ink.text3)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
                .frame(minHeight: 54)
                .contentShape(Capsule())
                .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Shown" : "Hidden")
            .accessibilityIdentifier("status.details")
            if open {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(parts) { part in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(part.title).font(.headline).foregroundStyle(Ink.text)
                            Text(part.detail).font(.body).foregroundStyle(Ink.text2)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Versions").font(.headline).foregroundStyle(Ink.text)
                        ForEach(versions, id: \.0) { name, value in
                            Text("\(name): \(value)").font(.body).foregroundStyle(Ink.text2)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
                .accessibilityIdentifier("status.details.list")
            }
        }
    }
}
