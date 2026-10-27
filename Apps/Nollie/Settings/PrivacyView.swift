import SwiftUI
import NollieCore

/// How the lock looks right now, in a symbol, a few words and a colour.
private struct LockLook {
    let symbol: String
    let title: String
    let line: String
    let tint: Color

    init(locked: Bool, failed: Bool, biometry: String) {
        switch (locked, failed) {
        case (false, _):
            #if os(macOS)
            let whoCanOpen = String(localized: "Anyone using this Mac can open Nollie.")
            #else
            let whoCanOpen = String(localized: "Anyone holding \(DeviceWords.your) can open Nollie.")
            #endif
            self.init(symbol: "lock.open.fill", title: String(localized: "No lock"), line: whoCanOpen, tint: .blue)
        case (true, true):
            let title = PrivacyHero.lockWords(biometry, named: { String(localized: "Couldn't use \($0)", comment: "Face ID or Touch ID") },
                                              passcode: String(localized: "Couldn't use your passcode"),
                                              password: String(localized: "Couldn't use your password"))
            self.init(symbol: "exclamationmark.lock.fill", title: title,
                      line: String(localized: "Nollie opened without it last time."), tint: .orange)
        case (true, false):
            let title = PrivacyHero.lockWords(biometry, named: { String(localized: "Locked with \($0)", comment: "Face ID or Touch ID") },
                                              passcode: String(localized: "Locked with your passcode"),
                                              password: String(localized: "Locked with your password"))
            self.init(symbol: "lock.fill", title: title,
                      line: String(localized: "Nollie checks it's you when you come back."), tint: .green)
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

    /// Words about the lock: `named` with "Face ID" or "Touch ID" in it, else the passcode's
    /// words (the password's on a Mac). Whole sentences each, since languages build them differently.
    static func lockWords(_ biometry: String, named: (String) -> String,
                          passcode: @autoclosure () -> String, password: @autoclosure () -> String) -> String {
        if biometry != "Passcode" { return named(biometry) }
        return DeviceWords.isMac ? password() : passcode()
    }

    var body: some View {
        let look = LockLook(locked: locked, failed: failed, biometry: biometry)
        PageHero(symbol: look.symbol, title: .verbatim(look.title), line: .verbatim(look.line), tint: look.tint, id: "privacy.hero")
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
    private static let askChoices = [("risky", String(localized: "Risky ones", comment: "Which approvals ask again")),
                                     ("all", String(localized: "Every one", comment: "Which approvals ask again")),
                                     ("off", String(localized: "Never", comment: "Which approvals ask again"))]

    /// What a yes or no from outside the app does now, in one line.
    static func approvalsLine(_ mode: String) -> String {
        let mac = DeviceWords.isMac
        return switch mode {
        case "all":
            mac ? String(localized: "Any yes or no in a notification opens Nollie and asks once more.", comment: "Safety: what an approval does; keep exact meaning")
                : String(localized: "Any yes or no on the Lock Screen opens Nollie and asks once more.", comment: "Safety: what an approval does; keep exact meaning")
        case "off":
            mac ? String(localized: "A yes or no in a notification counts right away.", comment: "Safety: what an approval does; keep exact meaning")
                : String(localized: "A yes or no on the Lock Screen counts right away.", comment: "Safety: what an approval does; keep exact meaning")
        default:
            mac ? String(localized: "A yes or no in a notification on something risky opens Nollie and asks once more.", comment: "Safety: what an approval does; keep exact meaning")
                : String(localized: "A yes or no on the Lock Screen on something risky opens Nollie and asks once more.", comment: "Safety: what an approval does; keep exact meaning")
        }
    }

    /// Money and messages sent as you get one plain line, since the switch guards them.
    static func ownerCheckLine(_ on: Bool) -> String {
        on ? String(localized: "Nollie checks it's you before it pays, sends or posts.", comment: "Safety: what an approval does; keep exact meaning")
           : String(localized: "A yes to paying, sending or posting counts right away.", comment: "Safety: what an approval does; keep exact meaning")
    }

    /// The lock's switch: "Require Face ID", or "Require your passcode" ("your password" on a Mac).
    private static func lockTitle(_ biometry: String) -> String {
        PrivacyHero.lockWords(
            biometry,
            named: { String(localized: "Require \($0)", comment: "Safety: the app lock; the name is Face ID or Touch ID; keep exact meaning") },
            passcode: String(localized: "Require your passcode", comment: "Safety: the app lock; keep exact meaning"),
            password: String(localized: "Require your password", comment: "Safety: the app lock; keep exact meaning"))
    }

    /// The owner check's switch: "Face ID for buying and sending", "Passcode …", or "Password …" on a Mac.
    private static func ownerCheckTitle(_ biometry: String) -> String {
        PrivacyHero.lockWords(
            biometry,
            named: { String(localized: "\($0) for buying and sending", comment: "Safety: Face ID question; the name is Face ID or Touch ID; keep exact meaning") },
            passcode: String(localized: "Passcode for buying and sending", comment: "Safety: Face ID question; keep exact meaning"),
            password: String(localized: "Password for buying and sending", comment: "Safety: Face ID question; keep exact meaning"))
    }

    var body: some View {
        let biometry = model.lock.biometryName
        SettingsPage("privacy.page") {
            PrivacyHero(locked: lockOn, failed: model.lock.lastError != nil, biometry: biometry)
            GlassSwitch(.verbatim(Self.lockTitle(biometry)),
                        isOn: Binding(get: { lockOn }, set: { model.lock.isEnabled = $0 }),
                        id: "security.lock")
            VStack(spacing: 14) {
                GlassSwitch(.verbatim(Self.ownerCheckTitle(biometry)), isOn: $ownerCheck, id: "security.ownerCheck")
                    .onChange(of: ownerCheck) { LocalNotifier.registerCategories() }
                PageNote(.verbatim(Self.ownerCheckLine(ownerCheck)), id: "security.ownerCheck.line")
            }
            VStack(spacing: 14) {
                GlassChoice("Ask again for approvals", selection: $askAgain, options: Self.askChoices, id: "security.approvals")
                    .onChange(of: askAgain) { LocalNotifier.registerCategories() }
                PageNote(.verbatim(Self.approvalsLine(askAgain)), id: "security.approvals.line")
            }
            GlassLink("Permissions", symbol: "checkmark.shield",
                      value: PermissionsSummary.rowWord(PermissionsSummary.listed(), in: model.permissions),
                      id: "privacy.permissions") { PermissionsSettingsView().untitledPage() }
        }
        .task { await model.permissions.refresh() }
    }
}
