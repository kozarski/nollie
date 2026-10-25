import SwiftUI
import UserNotifications
import NollieCore

/// What the Companion sheet says and which button does what, for one situation. Plain data and a
/// couple of plain functions, so the sheet itself only has to draw it.
struct CompanionScript: Equatable {
    /// What the main button does.
    enum Action { case install, askForPermission }

    var message: String
    var buttonTitle: String
    var skipTitle: String
    var footnote: String
    var action: Action

    private static let pitch = "Get replies and questions when Nollie is closed. Set up the companion once to keep in touch while you're away."

    /// With no Companion on the gateway we offer to set it up. If it is there already (installed from
    /// a different device), this device just needs notification permission.
    init(companionFound: Bool, authorization: UNAuthorizationStatus) {
        guard companionFound else {
            self = CompanionScript(
                message: Self.pitch, buttonTitle: "Set up notifications", skipTitle: "Later",
                footnote: "No rush. Settings will remind you.", action: .install)
            return
        }
        let place = DeviceWords.isMac ? "this Mac" : DeviceWords.this
        let (message, button): (String, String)
        switch authorization {
        case .denied:
            message = "Notifications are off on \(place). Turn them on in Settings to get replies and questions while you're away."
            button = "Open " + (DeviceWords.isMac ? "System Settings" : "Settings")
        case .authorized, .provisional, .ephemeral:
            message = "Notifications are allowed on \(place). You can change this any time in Settings."
            button = "Continue"
        default:
            message = "Allow notifications on \(place) so Nollie can let you know when a reply is ready or it needs your help."
            button = "Allow notifications"
        }
        self = CompanionScript(
            message: message, buttonTitle: button, skipTitle: "Not now",
            footnote: "Settings \u{203A} Notifications can turn it on later.", action: .askForPermission)
    }

    private init(message: String, buttonTitle: String, skipTitle: String, footnote: String, action: Action) {
        (self.message, self.buttonTitle, self.skipTitle, self.footnote, self.action) =
            (message, buttonTitle, skipTitle, footnote, action)
    }

    /// Where the system keeps this app's notification switch.
    static var systemNotificationSettings: URL? {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        #else
        URL(string: UIApplication.openNotificationSettingsURLString)
        #endif
    }
}

/// Appears one time, straight after the first gateway connects. Without a Companion the choice is
/// "set up now or later". If the gateway already runs one (installed from another device), we
/// only ask to allow notifications here, and the device then registers on its own.
struct CompanionPromptSheet: View {
    /// Version of the Companion found on the gateway, if it has one.
    var found: String?
    var authorization: UNAuthorizationStatus
    var install: () -> Void
    var allow: () -> Void
    var later: () -> Void

    @Environment(\.openURL) private var openURL

    private var script: CompanionScript {
        CompanionScript(companionFound: found != nil, authorization: authorization)
    }

    var body: some View {
        FittedSheet { card }
    }

    var card: some View {
        let script = script
        return VStack(spacing: 18) {
            CharacterView(look: .main, state: .listening, size: 96)
            Text("Stay in the loop").font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text(script.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            choices(script).padding(.top, 6)
            Text(script.footnote).small(.caption, .tertiary)
        }
        .sheetColumn()
    }

    private func choices(_ script: CompanionScript) -> some View {
        VStack(spacing: 10) {
            Button { press(script.action) } label: { Text(script.buttonTitle).fullWidthLabel() }
                .buttonStyle(.nollieGlassProminent)
            Button(script.skipTitle, action: later).small(.subheadline)
        }
    }

    private func press(_ action: CompanionScript.Action) {
        switch action {
        case .install:
            install()
        case .askForPermission where authorization == .denied:
            if let page = CompanionScript.systemNotificationSettings { openURL(page) }
            later()
        case .askForPermission:
            allow()
        }
    }

    /// Version string of the gateway's Companion, nil when absent. Reads the manifest, same as the
    /// Status page does.
    @MainActor static func installedVersion(on runtime: GatewayRuntime) async -> String? {
        let check = PushSetupModel()
        await check.checkCompanion(runtime: runtime)
        return check.installedVersion
    }
}
