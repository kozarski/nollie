import SwiftUI
import NollieCore

/// How the lock looks right now, in a symbol, a few words and a colour.
private struct LockLook {
    let symbol: String
    let title: String
    let line: String
    let tint: Color

    init(locked: Bool, failed: Bool, biometry: String) {
        let way = PrivacyHero.lockWord(biometry)
        switch (locked, failed) {
        case (false, _):
            #if os(macOS)
            let whoCanOpen = "Anyone using this Mac can open Nollie."
            #else
            let whoCanOpen = "Anyone holding \(DeviceWords.your) can open Nollie."
            #endif
            self.init(symbol: "lock.open.fill", title: "No lock", line: whoCanOpen, tint: .blue)
        case (true, true):
            self.init(symbol: "exclamationmark.lock.fill", title: "Couldn't use \(way)",
                      line: "Nollie opened without it last time.", tint: .orange)
        case (true, false):
            self.init(symbol: "lock.fill", title: "Locked with \(way)",
                      line: "Nollie checks it's you when you come back.", tint: .green)
        }
    }

    private init(symbol: String, title: String, line: String, tint: Color) {
        (self.symbol, self.title, self.line, self.tint) = (symbol, title, line, tint)
    }
}

/// The top of Privacy: locked or not, in its own colour.
struct PrivacyHero: View {
    var locked: Bool
    var failed: Bool
    var biometry: String

    /// "Face ID", or "your passcode" ("your password" on a Mac) when there is no Face ID or Touch ID.
    static func lockWord(_ biometry: String) -> String {
        if biometry != "Passcode" { return biometry }
        return DeviceWords.isMac ? "your password" : "your passcode"
    }

    /// The same at the start of a switch: "Face ID", "Passcode", or "Password" on a Mac.
    static func switchWord(_ biometry: String) -> String {
        if biometry != "Passcode" { return biometry }
        return DeviceWords.isMac ? "Password" : "Passcode"
    }

    var body: some View {
        let look = LockLook(locked: locked, failed: failed, biometry: biometry)
        PageHero(symbol: look.symbol, title: look.title, line: look.line, tint: look.tint, id: "privacy.hero")
    }
}

/// Settings › Privacy: whether Nollie is locked, one switch for the lock, one for Face ID before
/// buying and sending, and when an answer from outside the app asks again.
struct PrivacyView: View {
    /// Read here as well as through `model.lock`, so the page follows the switch at once.
    @AppStorage(AppLock.enabledKey) private var lockOn = false
    @AppStorage(ApprovalOwnerCheck.key) private var ownerCheck = true
    @AppStorage(ApprovalConfirm.modeKey) private var askAgain = ApprovalConfirm.mode
    @Environment(AppModel.self) private var model

    /// The ways to ask again, as stored and as shown.
    private static let askChoices = [("risky", "Risky ones"), ("all", "Every one"), ("off", "Never")]

    /// What a yes or no from outside the app does now, in one line.
    static func approvalsLine(_ mode: String) -> String {
        let place = DeviceWords.isMac ? "in a notification" : "on the Lock Screen"
        return switch mode {
        case "all": "Any yes or no \(place) opens Nollie and asks once more."
        case "off": "A yes or no \(place) counts right away."
        default: "A yes or no \(place) on something risky opens Nollie and asks once more."
        }
    }

    /// Money and messages sent as you get one plain line, since the switch guards them.
    static func ownerCheckLine(_ on: Bool) -> String {
        on ? "Nollie checks it's you before it pays, sends or posts." : "A yes to paying, sending or posting counts right away."
    }

    var body: some View {
        let biometry = model.lock.biometryName
        SettingsPage("privacy.page") {
            PrivacyHero(locked: lockOn, failed: model.lock.lastError != nil, biometry: biometry)
            GlassSwitch("Require \(PrivacyHero.lockWord(biometry))",
                        isOn: Binding(get: { lockOn }, set: { model.lock.isEnabled = $0 }),
                        id: "security.lock")
            VStack(spacing: 14) {
                GlassSwitch("\(PrivacyHero.switchWord(biometry)) for buying and sending", isOn: $ownerCheck, id: "security.ownerCheck")
                    .onChange(of: ownerCheck) { LocalNotifier.registerCategories() }
                PageNote(Self.ownerCheckLine(ownerCheck), id: "security.ownerCheck.line")
            }
            VStack(spacing: 14) {
                GlassChoice("Ask again for approvals", selection: $askAgain, options: Self.askChoices, id: "security.approvals")
                    .onChange(of: askAgain) { LocalNotifier.registerCategories() }
                PageNote(Self.approvalsLine(askAgain), id: "security.approvals.line")
            }
            GlassLink("Permissions", symbol: "checkmark.shield",
                      value: PermissionsSummary.rowWord(PermissionsSummary.listed(), in: model.permissions),
                      id: "privacy.permissions") { PermissionsSettingsView().untitledPage() }
        }
        .task { await model.permissions.refresh() }
    }
}
