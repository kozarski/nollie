import SwiftUI
import UserNotifications
import NollieCore

/// Settings › Notifications: whether you'll hear back, a way to allow it when needed, a few
/// switches on glass, and the rest behind Advanced.
struct NotificationsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @AppStorage("hapticsEnabled") private var haptics = true
    @AppStorage(NotificationPreviewPolicy.preferenceKey) private var showMessagePreviews = NotificationPreviewPolicy.defaultShowPreviews
    @AppStorage(AppLock.enabledKey) private var appLockEnabled = false
    @State private var previewSaveFailed = false
    @State private var alerts = CloudAlertTransport.shared
    #if os(macOS)
    @State private var helper = CloudAlertHelperController.shared
    #endif

    private var hero: NotificationsHero.State {
        #if os(macOS)
        let closed: Bool? = helper.isAvailable ? helper.isEnabled && [.enabled, .starting].contains(helper.state) : nil
        let helperLine = helper.isEnabled ? CloudAlertWords.helper(helper.state) : nil
        #else
        let closed: Bool? = nil
        let helperLine: String? = nil
        #endif
        return NotificationsHero.State(authorization: model.push.authorization, alertsOn: alerts.isEnabled,
                                       working: alerts.isWorking, alerts: alerts.state,
                                       checksWhileClosed: closed, helperNeeds: helperLine)
    }

    private var detailsHidden: Bool { !showMessagePreviews || appLockEnabled }

    var body: some View {
        let push = model.push
        SettingsPage("notifications.page") {
            NotificationsHero(state: hero, issue: alerts.issue)
            if push.authorization == .notDetermined {
                Button { Task { _ = await push.requestAuthorization() } } label: {
                    Text("Allow").fullWidthLabel()
                }
                .buttonStyle(.nollieGlassProminent).buttonBorderShape(.capsule).controlSize(.large)
                .testID("notifications.allow")
            } else if push.authorization == .denied || alerts.state == .notificationsDenied {
                Button { openURL(NotificationSettingsLink.url) } label: {
                    Text(DeviceWords.isMac ? "Open System Settings" : "Open Settings")
                        .fullWidthLabel()
                }
                .buttonStyle(.nollieGlassProminent).buttonBorderShape(.capsule).controlSize(.large)
                .testID("notifications.openSettings")
            }
            FactStrip(facts: [Fact(symbol: "bubble.left.fill", word: "Replies"),
                              Fact(symbol: "hand.raised.fill", word: "Needs you"),
                              Fact(symbol: detailsHidden ? "eye.slash.fill" : "eye.fill",
                                   word: detailsHidden ? "Details hidden" : "Details shown")],
                      id: "notifications.facts")
            GlassStack {
                CloudAlertsSwitch()
                #if os(macOS)
                CloudAlertsHelperSwitch()
                #endif
                previewsSwitch
                if appLockEnabled {
                    PageNote("App Lock keeps details hidden.", symbol: "lock.fill")
                }
                if previewSaveFailed {
                    PageNote("Couldn't save that. Try again.", symbol: "exclamationmark.circle", tint: .orange)
                }
                #if os(iOS)
                GlassSwitch("Haptics", isOn: $haptics, id: "notifications.haptics")
                #endif
            }
            AdvancedLink(id: "notifications.advanced") { NotificationsAdvancedView().untitledPage() }
        }
        .animation(.snappy, value: hero)
        .cloudAlertsUpkeep()
        .task { await push.refreshAuthorization() }
    }

    /// "Hide notification details": saved for the app and mirrored to where alerts are drawn.
    private var previewsSwitch: some View {
        GlassSwitch("Hide notification details", isOn: Binding(
            get: { !showMessagePreviews },
            set: { hidden in
                NotificationPreviewPreferences.setHidesDetails(hidden)
                showMessagePreviews = !hidden
                previewSaveFailed = !NotificationPreviewPreferences.mirror()
            }
        ), id: "notifications.previews")
        .onChange(of: showMessagePreviews) { _, _ in
            previewSaveFailed = !NotificationPreviewPreferences.mirror()
        }
    }
}

/// The top of Notifications: whether you'll hear back, from what this device allows and whether
/// iCloud alerts are on.
struct NotificationsHero: View {
    enum State: Equatable {
        case canTell, off, whileOpen, settingUp, hearBack(closed: Bool), signInToICloud, newICloud, needsLook(String?)

        /// - Parameters:
        ///   - checksWhileClosed: the Mac's background check is running; nil where there is none.
        ///   - helperNeeds: what the Mac's background check needs, if anything.
        init(authorization: UNAuthorizationStatus, alertsOn: Bool, working: Bool, alerts: CloudAlertState,
             checksWhileClosed: Bool? = nil, helperNeeds: String? = nil) {
            switch authorization {
            case .notDetermined: self = .canTell; return
            case .denied: self = .off; return
            default: break
            }
            if alerts == .notificationsDenied { self = .off; return }
            if alerts == .accountChanged { self = .newICloud; return }
            guard alertsOn || working else { self = .whileOpen; return }
            if working || alerts == .checking || alerts == .registering { self = .settingUp; return }
            switch alerts {
            case .iCloudUnavailable: self = .signInToICloud
            case .failed: self = .needsLook(nil)
            default:
                if let helperNeeds { self = .needsLook(helperNeeds) }
                else { self = .hearBack(closed: checksWhileClosed ?? true) }
            }
        }

        var symbol: String {
            switch self {
            case .canTell: "bell.badge"
            case .off: "bell.slash.fill"
            case .whileOpen: "bell.fill"
            case .settingUp: "icloud"
            case .hearBack: "bell.badge.fill"
            case .signInToICloud: "exclamationmark.icloud.fill"
            case .newICloud: "icloud.slash"
            case .needsLook: "exclamationmark.triangle.fill"
            }
        }
        var title: String {
            switch self {
            case .canTell: String(localized: "Nollie can tell you")
            case .off: String(localized: "Alerts are off")
            case .whileOpen: String(localized: "Alerts while Nollie is open")
            case .settingUp: String(localized: "Setting up alerts")
            case .hearBack: String(localized: "You'll hear back")
            case .signInToICloud: String(localized: "Sign in to iCloud")
            case .newICloud: String(localized: "New iCloud account")
            case .needsLook: String(localized: "Alerts need a look")
            }
        }
        var line: String? {
            switch self {
            case .canTell: String(localized: "Allow alerts to hear back.")
            case .off: String(localized: "Turn them on in \(DeviceWords.settings).")
            case .whileOpen: String(localized: "Turn on alerts for when it's closed.")
            case .settingUp: nil
            case .hearBack(let closed):
                closed ? String(localized: "Even when Nollie is closed.") : String(localized: "While Nollie is open.")
            case .signInToICloud: String(localized: "Alerts travel through your iCloud.")
            case .newICloud: String(localized: "Turn alerts on again.")
            case .needsLook(let line): line
            }
        }
        var tint: Color {
            switch self {
            case .canTell, .whileOpen: .blue
            case .off: .red
            case .settingUp: Ink.text2
            case .hearBack: .green
            case .signInToICloud, .newICloud, .needsLook: .orange
            }
        }
    }

    var state: State
    /// iCloud alerts' own issue, the line when something needs a look and nothing else says why.
    var issue: String? = nil

    var body: some View {
        PageHero(symbol: state.symbol, title: .verbatim(state.title), line: .verbatim(line), tint: state.tint, id: "notifications.hero")
    }

    private var line: String? {
        guard case .needsLook(nil) = state else { return state.line }
        return issue.flatMap(CloudAlertWords.issue) ?? String(localized: "Turn alerts off and on again.")
    }
}

/// Notifications › Advanced: checking alerts, what this device allows, the finer switches, and
/// (with Developer Mode) the Companion's own alerts. The top says what this device allows.
struct NotificationsAdvancedView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("nollie.developerMode") private var developerMode: Bool = false
    @AppStorage("hapticsEnabled") private var haptics: Bool = true
    @AppStorage(TypingHaptics.key) private var typingHaptics: Bool = false
    @AppStorage(PushRegistrar.enabledKey) private var notificationsOn: Bool = true
    @AppStorage(PushRegistrar.muteDesktopOriginKey) private var muteDesktopOrigin: Bool = false

    /// Sends the current alert settings to the gateway.
    private func syncRegistration() async {
        guard let runtime = model.runtime else { return }
        await model.push.syncRegistration(runtime: runtime)
    }

    /// The Companion alerts switch: turning it on asks for permission and registers with the
    /// relay; turning it off takes the registration away.
    private func companionAlerts(_ on: Bool) async {
        let push = model.push
        if on { _ = await push.requestAuthorization() }
        guard let runtime = model.runtime else { return }
        if on {
            await push.registerWithRelay()
            await push.syncRegistration(runtime: runtime)
        } else {
            await push.removeRegistration(runtime: runtime)
        }
    }

    var body: some View {
        let push = model.push
        SettingsPage("notifications.advanced.page") {
            let hero = Self.hero(push.authorization)
            PageHero(symbol: hero.symbol, title: .verbatim(hero.title), line: .verbatim(hero.line), tint: hero.tint, id: "notifications.advanced.hero")
            VStack(spacing: 12) {
                GlassLink("Check alerts", symbol: "checkmark.seal", id: "notifications.checkAlerts") {
                    CloudAlertsView().untitledPage()
                }
                GlassRowLabel(title: String(localized: "What \(DeviceWords.device) allows"), symbol: "hand.raised",
                              value: Self.allows(push.authorization), chevron: false)
                    .testID("notifications.permission")
            }
            #if os(iOS)
            GlassStack {
                GlassSwitch("Taps while typing", isOn: $typingHaptics, id: "notifications.typingHaptics")
                    .disabled(!haptics)
                if !haptics {
                    PageNote("Turn on Haptics first.")
                }
                // Only the Companion's alerts know which device drove a chat, so the switch waits
                // until the Companion is there to read it.
                if developerMode || model.companionInstalledVersion != nil {
                    GlassSwitch("Stay quiet when I'm at my Mac", isOn: $muteDesktopOrigin, id: "notifications.muteDesktopOrigin")
                        .disabled(!notificationsOn)
                        .onChange(of: muteDesktopOrigin) { Task { await syncRegistration() } }
                }
            }
            #endif
            if developerMode {
                VStack(spacing: 12) {
                    PageHeading("Developer Mode")
                    GlassSwitch("Alerts through the Companion", isOn: $notificationsOn, id: "notifications.companionAlerts")
                        .onChange(of: notificationsOn) { _, on in Task { await companionAlerts(on) } }
                    if PushRelay.isConfigured { PushInvitationSection() }
                    GlassLink("Companion", symbol: "puzzlepiece.extension", id: "notifications.companion") { CompanionView() }
                        .disabled(model.runtime == nil)
                        .opacity(model.runtime == nil ? 0.5 : 1)
                }
            }
        }
        .animation(.snappy, value: push.authorization)
        .task { await push.refreshAuthorization() }
    }

    /// The top of the page: what this device lets Nollie do with alerts.
    static func hero(_ status: UNAuthorizationStatus) -> (symbol: String, title: String, line: String?, tint: Color) {
        switch status {
        case .authorized:
            ("bell.badge.fill", String(localized: "Alerts allowed"), String(localized: "\(DeviceWords.This) shows them."), .green)
        case .provisional:
            ("bell.fill", String(localized: "Quiet alerts"), String(localized: "They wait in Notification Center."), .green)
        case .ephemeral:
            ("bell.fill", String(localized: "Alerts for now"), nil, .green)
        case .denied:
            ("bell.slash.fill", String(localized: "Alerts not allowed"), String(localized: "Turn them on in \(DeviceWords.settings)."), .red)
        default:
            ("bell", String(localized: "Not asked yet"), String(localized: "Nollie hasn't asked for alerts."), Ink.text2)
        }
    }

    /// What this device lets Nollie do with alerts, in a word or two.
    static func allows(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: String(localized: "Alerts", comment: "What the device allows: alerts")
        case .denied: String(localized: "Nothing", comment: "What the device allows: nothing")
        case .provisional: String(localized: "Quiet alerts")
        case .ephemeral: String(localized: "Alerts for now")
        default: String(localized: "Not asked yet")
        }
    }
}
