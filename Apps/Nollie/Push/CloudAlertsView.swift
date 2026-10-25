import SwiftUI
import NollieCore

/// Notifications › Advanced › Check alerts: whether alerts really arrive, a test to be sure, and
/// every check Nollie can make, in plain words, behind Details.
struct CloudAlertsView: View {
    @Environment(AppModel.self) private var model
    @State private var alerts = CloudAlertTransport.shared
    #if os(macOS)
    @State private var helper = CloudAlertHelperController.shared
    #endif
    @AppStorage("nollie.developerMode") private var developerMode = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var test = CloudAlertTest()
    @State private var details = false
    @State private var previewDiagnostic: CloudAlertPreviewDiagnostic?

    private var hero: CheckAlertsHero.State {
        CheckAlertsHero.State(enabled: alerts.isEnabled, working: alerts.isWorking, state: alerts.state,
                              sent: test.id != nil, status: test.status)
    }

    var body: some View {
        SettingsPage("cloudAlerts.page") {
            CheckAlertsHero(state: hero, issue: alerts.issue, alertState: alerts.state)
            if alerts.isEnabled {
                FactStrip(facts: facts, id: "cloudAlerts.facts")
                CloudAlertsTestRows(test: $test, alerts: alerts) {
                    refreshPreviewDiagnostic()
                    #if os(macOS)
                    helper.refresh()
                    #endif
                    Task { await alerts.refresh(checkTestVisibility: developerMode || details) }
                }
                detailsGroup
            } else {
                PageNote("Turn on Alerts when Nollie is closed first.", symbol: "bell.slash")
            }
        }
        .task { refreshPreviewDiagnostic() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshPreviewDiagnostic() } }
        .onChange(of: developerMode) { _, _ in refreshPreviewDiagnostic() }
        .onChange(of: details) { _, _ in refreshPreviewDiagnostic() }
        .onChange(of: alerts.isEnabled) { _, _ in test = CloudAlertTest() }
    }

    private var facts: [Fact] {
        [Fact(symbol: DeviceWords.symbol, word: CloudAlertWords.signedUp(alerts.registrationState)),
         Fact(symbol: "icloud.fill", word: CloudAlertWords.watching(alerts.subscriptionState)),
         Fact(symbol: "paperplane.fill", word: CloudAlertWords.testWord(sent: test.id != nil, test.status))]
    }

    /// Everything Nollie can check, worded for people.
    private var detailsGroup: some View {
        DisclosureGroup(isExpanded: $details) {
            VStack(alignment: .leading, spacing: 16) {
                CheckLine(CloudAlertWords.registration(alerts.registrationState),
                          ok: alerts.registrationState == .registered, id: "cloudAlerts.registration")
                CheckLine(CloudAlertWords.subscription(alerts.subscriptionState),
                          ok: [.valid, .legacy].contains(alerts.subscriptionState), id: "cloudAlerts.subscription")
                if let account = alerts.accountComparison {
                    CheckLine("Your iCloud code is \(account). The same code on your other device means the same iCloud.",
                              symbol: "person.2.fill", id: "cloudAlerts.accountCheck")
                }
                CheckLine("Set up doesn't mean delivered. A test shows they arrive.", symbol: "info.circle")
                if let previewDiagnostic {
                    CheckLine("Last alert preview, \(previewDiagnostic.at.formatted(date: .abbreviated, time: .shortened)): \(previewDiagnostic.outcome.message).",
                              symbol: "text.bubble", id: "cloudAlerts.previewDiagnostic")
                    CheckLine("Nollie got the details ready. It can't see how they looked on screen.", symbol: "info.circle")
                } else {
                    CheckLine("No alert preview on this \(DeviceWords.device) yet.", symbol: "text.bubble")
                }
                testLines
                CheckLine(CloudAlertWords.since(alerts.callbackDiagnostics), symbol: "bell.badge")
                ForEach(CloudAlertParseResult.allCases.filter { $0 != .accepted && alerts.callbackDiagnostics.results[$0, default: 0] > 0 }, id: \.self) { result in
                    CheckLine("\(CloudAlertWords.parse(result)): \(alerts.callbackDiagnostics.results[result, default: 0]), not for Nollie.",
                              symbol: "questionmark.circle")
                }
                if let last = alerts.callbackDiagnostics.lastAt, let result = alerts.callbackDiagnostics.lastResult {
                    CheckLine("Last one at \(last.formatted(date: .omitted, time: .shortened)): \(CloudAlertWords.parse(result)).", symbol: "clock")
                }
                CheckLine("Counts start when Nollie opens. One alert can count more than once.", symbol: "info.circle")
                #if os(macOS)
                if helper.isAvailable {
                    CheckLine("While Nollie is closed: \(helper.message)", symbol: "moon.fill")
                    if helper.isEnabled {
                        Button("Start again") {
                            Task {
                                if let runtime = model.runtime {
                                    helper.updateCanonicalSession(connectionID: runtime.connection.id,
                                        sessionID: BotsHome.shared.entry(runtime, "default").storedID)
                                }
                                await helper.retry()
                            }
                        }
                        .buttonStyle(.nollieGlass)
                        .buttonBorderShape(.capsule)
                        .disabled(alerts.isWorking || helper.isWorking)
                        .accessibilityIdentifier("cloudAlerts.background.retry")
                    }
                }
                #endif
            }
            .padding(.top, 14)
        } label: {
            Text("Details").font(.headline).foregroundStyle(Ink.text)
        }
        .accessibilityIdentifier("cloudAlerts.details")
    }

    /// The newest test Nollie can read in iCloud, from either device.
    @ViewBuilder private var testLines: some View {
        if let visible = alerts.visibleTest {
            CheckLine("Last test sent at \(visible.createdAt.formatted(date: .abbreviated, time: .shortened)), code \(visible.shortID).",
                      symbol: "paperplane", id: "cloudAlerts.visibleTest")
            CheckLine(visible.isThisDevice ? "From this \(DeviceWords.device)." : "From your other device.",
                      symbol: visible.isThisDevice ? DeviceWords.symbol : "laptopcomputer.and.iphone", id: "cloudAlerts.testSource")
        } else if alerts.visibilityCheckedAt != nil {
            CheckLine("No recent test in iCloud.", symbol: "paperplane")
        } else if alerts.visibilityIssue == nil {
            CheckLine("Check again to look for tests from either device.", symbol: "paperplane")
        }
        if let checked = alerts.visibilityCheckedAt {
            CheckLine(alerts.visibilityIsLimited
                      ? "Looked in iCloud at \(checked.formatted(date: .omitted, time: .shortened)). This is the newest of 100 tests; there are more."
                      : "Looked in iCloud at \(checked.formatted(date: .omitted, time: .shortened)).", symbol: "icloud")
            CheckLine("Seeing a test means this \(DeviceWords.device) can read it, not that an alert arrived.", symbol: "info.circle")
        }
        if alerts.visibilityIssue != nil {
            CheckLine("Couldn't look for tests. Check again.", symbol: "exclamationmark.triangle", tint: .orange)
        }
    }

    private func refreshPreviewDiagnostic() {
        guard developerMode || details, Bundle.main.bundleIdentifier?.hasSuffix(".demo") != true else { previewDiagnostic = nil; return }
        previewDiagnostic = CloudAlertPreviewDiagnostic.load()
    }
}

/// The top of Check alerts: whether alerts arrive, as far as Nollie can tell.
struct CheckAlertsHero: View {
    enum State: Equatable {
        case off, waiting, needsLook, arrived, opened, onItsWay, expired, sendTest

        init(enabled: Bool, working: Bool, state: CloudAlertState, sent: Bool, status: CloudAlertTestStatus?) {
            guard enabled || working else { self = .off; return }
            if working || state == .checking || state == .registering { self = .waiting; return }
            guard state == .ready else { self = .needsLook; return }
            if status?.openedAt != nil { self = .opened; return }
            if status?.receivedAt != nil { self = .arrived; return }
            if let status, !status.stored { self = .expired; return }
            self = sent ? .onItsWay : .sendTest
        }

        var symbol: String {
            switch self {
            case .off: "bell.slash.fill"
            case .waiting: "icloud"
            case .needsLook: "exclamationmark.triangle.fill"
            case .arrived, .opened: "checkmark.seal.fill"
            case .onItsWay: "clock.fill"
            case .expired: "clock.badge.xmark"
            case .sendTest: "bell.badge"
            }
        }
        var title: String {
            switch self {
            case .off: "Alerts are off"
            case .waiting: "Waiting for Apple"
            case .needsLook: "Alerts need a look"
            case .arrived, .opened: "Alerts arrive"
            case .onItsWay: "Test on its way"
            case .expired: "Test expired"
            case .sendTest: "Send a test to be sure"
            }
        }
        var line: String? {
            switch self {
            case .off, .waiting, .needsLook: nil
            case .arrived: "Your other device got the last test."
            case .opened: "Your last test was opened."
            case .onItsWay: "Check your other device."
            case .expired: "Send another."
            case .sendTest: "Alerts are set up."
            }
        }
        var tint: Color {
            switch self {
            case .off, .waiting, .expired: Ink.text2
            case .needsLook, .onItsWay: .orange
            case .arrived, .opened: .green
            case .sendTest: .blue
            }
        }
    }

    var state: State
    var issue: String?
    var alertState: CloudAlertState = .failed

    var body: some View {
        // Something to fix says what, in the hero's one line.
        let line = state == .needsLook ? issue.flatMap(CloudAlertWords.issue) ?? CloudAlertWords.state(alertState) : state.line
        PageHero(symbol: state.symbol, title: state.title, line: line, tint: state.tint, id: "cloudAlerts.hero")
    }
}

/// A test alert, from sending to an answer about where it got to.
struct CloudAlertTest: Equatable {
    var id: String?
    var status: CloudAlertTestStatus?
    var busy = false
}

/// Send a test, Did it arrive?, Check again: each on its own glass capsule.
struct CloudAlertsTestRows: View {
    @Binding var test: CloudAlertTest
    var alerts: CloudAlertTransport
    var checkAgain: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            GlassButton("Send a test", symbol: "paperplane.fill", value: test.busy && test.id == nil ? "Sending" : nil,
                        id: "cloudAlerts.test") { send() }
                .disabled(test.busy || alerts.isWorking || alerts.state != .ready)
                .opacity(test.busy || alerts.isWorking || alerts.state != .ready ? 0.5 : 1)
            if let id = test.id {
                PageNote(CloudAlertWords.test(test.status), symbol: "paperplane", id: "cloudAlerts.testStatus")
                GlassButton("Did it arrive?", symbol: "questionmark.circle.fill", id: "cloudAlerts.checkTest") { check(id) }
                    .disabled(test.busy || alerts.isWorking)
                    .opacity(test.busy || alerts.isWorking ? 0.5 : 1)
            }
            GlassButton("Check again", symbol: "arrow.clockwise", id: "cloudAlerts.check", action: checkAgain)
                .disabled(alerts.isWorking)
                .opacity(alerts.isWorking ? 0.5 : 1)
        }
    }

    private func send() {
        Task {
            test = CloudAlertTest(busy: true)
            let sent = await alerts.sendTest()
            if alerts.isEnabled, alerts.state == .ready { test.id = sent }
            test.busy = false
        }
    }

    private func check(_ id: String) {
        Task {
            test.busy = true
            let status = await alerts.checkTest(id)
            if alerts.isEnabled, test.id == id { test.status = status }
            test.busy = false
        }
    }
}

/// One plain line in Details: a symbol and a sentence, never small grey type.
private struct CheckLine: View {
    var text: String
    var symbol: String
    var tint: Color
    var id: String?

    init(_ text: String, symbol: String = "circle", tint: Color = Ink.text2, id: String? = nil) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.id = id
    }

    /// A check that is either fine or not yet.
    init(_ text: String, ok: Bool, id: String) {
        self.init(text, symbol: ok ? "checkmark.circle.fill" : "circle.dashed", tint: ok ? .green : .orange, id: id)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 24).accessibilityHidden(true)
            Text(text).font(.body).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .modifier(CheckLineIdentifier(id: id))
    }
}

private struct CheckLineIdentifier: ViewModifier {
    var id: String?
    func body(content: Content) -> some View {
        if let id { content.accessibilityIdentifier(id) } else { content }
    }
}

/// The page's one switch for iCloud alerts, and what it is doing when there is something to say.
struct CloudAlertsSwitch: View {
    @State private var alerts = CloudAlertTransport.shared
    #if os(macOS)
    @State private var helper = CloudAlertHelperController.shared
    #endif

    private var changingSettings: Bool {
        #if os(macOS)
        alerts.isWorking || helper.isWorking
        #else
        alerts.isWorking
        #endif
    }

    var body: some View {
        VStack(spacing: 12) {
            GlassSwitch("Alerts when Nollie is closed", isOn: Binding(get: { alerts.isEnabled }, set: { enabled in
                Task {
                    if enabled { await alerts.enable() }
                    else {
                        #if os(macOS)
                        if helper.isAvailable { await helper.disable() }
                        #endif
                        await alerts.disable()
                    }
                }
            }), id: "cloudAlerts.enabled")
            .disabled(changingSettings)
            if alerts.isWorking {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(CloudAlertWords.working(alerts.state)).font(.body).foregroundStyle(Ink.text2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("cloudAlerts.status")
            } else if let issue = alerts.issue.flatMap(CloudAlertWords.issue) {
                PageNote(issue, symbol: "exclamationmark.circle", tint: .orange, id: "cloudAlerts.issue")
            }
        }
    }
}

#if os(macOS)
/// "Keep checking while Nollie is closed": the Mac's background check, with a line and a way
/// forward only when it needs something.
struct CloudAlertsHelperSwitch: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var alerts = CloudAlertTransport.shared
    @State private var helper = CloudAlertHelperController.shared

    private var changingSettings: Bool { alerts.isWorking || helper.isWorking }

    var body: some View {
        if helper.isAvailable, alerts.isEnabled || helper.isEnabled {
            VStack(spacing: 12) {
                GlassSwitch("Keep checking while Nollie is closed", isOn: Binding(get: { helper.isEnabled }, set: { enabled in
                    Task {
                        if enabled, alerts.isEnabled, let runtime = model.runtime {
                            await helper.enable(connectionID: runtime.connection.id, profiles: ["default"],
                                                canonicalSessionID: BotsHome.shared.entry(runtime, "default").storedID)
                        } else if !enabled { await helper.disable() }
                    }
                }), id: "cloudAlerts.background.enabled")
                .disabled(changingSettings || (!helper.isEnabled && (!alerts.isEnabled || model.runtime == nil)))
                if !helper.isEnabled, model.runtime == nil {
                    PageNote("Set up Nollie first.")
                }
                if helper.isEnabled, let line = CloudAlertWords.helper(helper.state) {
                    PageNote(line, symbol: "exclamationmark.circle", tint: .orange, id: "cloudAlerts.background.status")
                    if helper.state == .needsApproval {
                        Button("Open Login Items") {
                            openURL(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                        .buttonStyle(.nollieGlassProminent).buttonBorderShape(.capsule).controlSize(.large)
                        .accessibilityIdentifier("cloudAlerts.background.loginItems")
                    } else if [.stopped, .retrying, .signInRequired, .needsMainChat, .failed].contains(helper.state) {
                        Button("Try again") { retry() }
                            .buttonStyle(.nollieGlassProminent).buttonBorderShape(.capsule).controlSize(.large)
                            .disabled(changingSettings)
                            .accessibilityIdentifier("cloudAlerts.background.retry")
                    }
                }
            }
        }
    }

    private func retry() {
        Task {
            if let runtime = model.runtime {
                helper.updateCanonicalSession(connectionID: runtime.connection.id,
                    sessionID: BotsHome.shared.entry(runtime, "default").storedID)
            }
            await helper.retry()
        }
    }
}
#endif

/// Keeps iCloud alerts current while a page that shows them is open: on arrival, when Nollie
/// comes back to the front, and (on the Mac) the background check's health every few seconds.
private struct CloudAlertsUpkeep: ViewModifier {
    @State private var alerts = CloudAlertTransport.shared
    #if os(macOS)
    @State private var helper = CloudAlertHelperController.shared
    #endif
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task { await alerts.refresh() }
            #if os(macOS)
            .task(id: scenePhase) {
                if scenePhase == .active { await helper.monitorStatus() }
            }
            #endif
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await alerts.refresh() } }
            }
            .onChange(of: alerts.isEnabled) { _, enabled in
                #if os(macOS)
                if !enabled, helper.isEnabled { Task { await helper.disable() } }
                #endif
            }
    }
}

extension View {
    /// Keeps iCloud alerts and the Mac's background check current while this view is open.
    func cloudAlertsUpkeep() -> some View { modifier(CloudAlertsUpkeep()) }
}

/// The iCloud alerts controls on their own, for onboarding's "iCloud alerts" sheet: the switch,
/// the Mac's background check, and a test once alerts are on.
struct CloudAlertsControls: View {
    @Environment(\.openURL) private var openURL
    @State private var alerts = CloudAlertTransport.shared
    #if os(macOS)
    @State private var helper = CloudAlertHelperController.shared
    #endif
    @AppStorage("nollie.developerMode") private var developerMode = false
    @State private var test = CloudAlertTest()

    var body: some View {
        VStack(spacing: 16) {
            CloudAlertsSwitch()
            if alerts.state == .notificationsDenied {
                Button(DeviceWords.isMac ? "Open System Settings" : "Open Settings") { openURL(NotificationSettingsLink.url) }
                    .buttonStyle(.nollieGlassProminent).buttonBorderShape(.capsule).controlSize(.large)
            }
            #if os(macOS)
            CloudAlertsHelperSwitch()
            #endif
            if alerts.isEnabled {
                CloudAlertsTestRows(test: $test, alerts: alerts) {
                    #if os(macOS)
                    helper.refresh()
                    #endif
                    Task { await alerts.refresh(checkTestVisibility: developerMode) }
                }
            }
        }
        .cloudAlertsUpkeep()
        .onChange(of: alerts.isEnabled) { _, _ in test = CloudAlertTest() }
    }
}

/// Where this device's notification settings for Nollie open.
enum NotificationSettingsLink {
    static var url: URL {
        #if os(iOS)
        URL(string: UIApplication.openNotificationSettingsURLString)!
        #else
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        #endif
    }
}

/// iCloud alerts' states and messages, in the words the pages use.
enum CloudAlertWords {
    /// An issue from iCloud alerts, without the technical words. Nil for tidying that fixes
    /// itself, which needs nothing from anyone.
    static func issue(_ text: String) -> String? {
        if text.localizedCaseInsensitiveContains("cleanup") { return nil }
        if text.localizedCaseInsensitiveContains("subscription") { return "Turn alerts off and on again to fix them." }
        if text.localizedCaseInsensitiveContains("registration") { return "Signing up with Apple didn't finish. Check alerts in Advanced to try again." }
        return text
    }

    /// What to do when alerts are on but not working, if the state says.
    static func state(_ state: CloudAlertState) -> String? {
        switch state {
        case .iCloudUnavailable: "Sign in to iCloud on this \(DeviceWords.device)."
        case .notificationsDenied: "Allow Nollie's notifications in \(DeviceWords.settings)."
        case .accountChanged: "Your iCloud changed. Turn alerts on again."
        case .failed: "Turn alerts off and on again."
        case .off, .checking, .registering, .ready: nil
        }
    }

    static func working(_ state: CloudAlertState) -> String {
        state == .registering ? "Waiting for Apple" : "Checking iCloud"
    }

    /// Where a test got to.
    static func test(_ status: CloudAlertTestStatus?) -> String {
        guard let status else { return "Saved. Waiting for your other device." }
        if status.openedAt != nil { return "Opened on your other device." }
        if status.receivedAt != nil { return "Your other device got it. Look there for the alert." }
        if status.stored { return "Saved. Your other device hasn't got it yet." }
        return "This test has expired. Send another."
    }

    static func testWord(sent: Bool, _ status: CloudAlertTestStatus?) -> String {
        if status?.openedAt != nil { return "Opened" }
        if status?.receivedAt != nil { return "Arrived" }
        return sent ? "Test sent" : "No test yet"
    }

    static func signedUp(_ state: CloudAlertRegistrationState) -> String {
        switch state {
        case .registered: "Signed up"
        case .waiting: "Signing up"
        case .failed: "Not signed up"
        case .notRequested: "Not yet"
        }
    }

    static func watching(_ state: CloudAlertSubscriptionState) -> String {
        switch state {
        case .valid, .legacy: "Watching"
        case .notChecked: "Not checked"
        case .missing, .invalid: "Not watching"
        }
    }

    static func registration(_ state: CloudAlertRegistrationState) -> String {
        switch state {
        case .registered: "Signed up with Apple."
        case .waiting: "Waiting for Apple to sign up this \(DeviceWords.device)."
        case .failed: "Signing up with Apple didn't finish. Check again."
        case .notRequested: "Not signed up with Apple yet."
        }
    }

    static func subscription(_ state: CloudAlertSubscriptionState) -> String {
        switch state {
        case .valid: "iCloud is watching for alerts."
        case .legacy: "iCloud is watching for alerts, the older way."
        case .notChecked: "Not checked with iCloud yet."
        case .missing: "iCloud isn't watching. Turn alerts off and on again."
        case .invalid: "iCloud's watch needs a fix. Turn alerts off and on again."
        }
    }

    /// "Alerts since Nollie opened: 3 arrived, 1 opened."
    static func since(_ diagnostics: CloudAlertCallbackDiagnostics) -> String {
        let arrived = (diagnostics.callbacks[.remote] ?? 0) + (diagnostics.callbacks[.foreground] ?? 0)
        let opened = diagnostics.callbacks[.opened] ?? 0
        return "Alerts since Nollie opened: \(arrived) arrived, \(opened) opened."
    }

    static func parse(_ result: CloudAlertParseResult) -> String {
        switch result {
        case .accepted: "A Nollie alert"
        case .notCloudKit: "Not from iCloud"
        case .unsupportedType: "Another kind of iCloud alert"
        case .missingRecord: "Missing what it points to"
        case .containerMismatch: "From another app's iCloud"
        case .subscriptionMismatch: "From another iCloud watch"
        case .scopeMismatch: "From another part of iCloud"
        case .invalidRecord: "Pointing at something Nollie doesn't know"
        }
    }

    #if os(macOS)
    /// The Mac's background check, only when it needs something.
    static func helper(_ state: CloudAlertHelperController.State) -> String? {
        switch state {
        case .needsApproval: "Allow Nollie in Login Items."
        case .needsMainChat: "Open your main chat once to finish."
        case .signInRequired: "Sign in again, then try again."
        case .stopped: "It stopped checking."
        case .retrying: "Having trouble reaching iCloud or your bots. It keeps trying."
        case .failed: "Something went wrong."
        case .off, .starting, .enabled, .unavailable: nil
        }
    }
    #endif
}
