import SwiftUI

/// What the system lets Nollie do, for the Settings page and the row that leads to it.
@MainActor
enum PermissionsSummary {
    /// The permissions this device lists that are not on, counting only ones with an answer to
    /// give (a permission this edition does not have is not listed).
    static func off(_ kinds: [PermissionKind], in center: PermissionCenter) -> [PermissionKind] {
        kinds.filter { center.isAvailable($0) && center.state($0) != .granted && center.state($0) != .unavailable }
    }

    /// A quiet word for the row in Privacy: nothing when all is on or not read yet.
    static func rowWord(_ kinds: [PermissionKind], in center: PermissionCenter) -> String? {
        guard center.hasRead else { return nil }
        let count = off(kinds, in: center).count
        return count == 0 ? nil : String(localized: "\(count) off", comment: "How many permissions are not on")
    }

    static func listed() -> [PermissionKind] {
        #if os(macOS)
        PermissionKind.listed(isMac: true, direct: NativeSetupPlan.directAvailable)
        #else
        PermissionKind.listed(isMac: false, direct: false)
        #endif
    }
}

/// Settings › Privacy › Permissions: each thing Nollie can ask the system for, whether it is on,
/// and, where it is off, the way to the system's Settings.
struct PermissionsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let center = model.permissions
        let kinds = PermissionsSummary.listed().filter(center.isAvailable)
        let off = PermissionsSummary.off(kinds, in: center)
        let denied = off.contains { center.state($0) == .denied }
        SettingsPage("permissions.page") {
            PageHero(symbol: off.isEmpty ? "checkmark.shield.fill" : "hand.raised.fill",
                     title: .verbatim(!center.hasRead ? String(localized: "Permissions")
                         : off.isEmpty ? String(localized: "All on", comment: "Every permission is on")
                         : String(localized: "\(off.count) off", comment: "How many permissions are not on")),
                     line: .verbatim(line(waiting: off.count, denied: denied)),
                     tint: off.isEmpty && center.hasRead ? .green : Ink.text, id: "permissions.hero")
            PermissionRows(center: center, kinds: kinds)
            PageNote("Nollie asks for each one only when it needs it, and says why first.", id: "permissions.note")
        }
    }

    private func line(waiting: Int, denied: Bool) -> String {
        if waiting == 0 { return String(localized: "Nollie has what it needs.") }
        return denied ? String(localized: "Open Settings to turn one on.") : String(localized: "Allow any of these when you want it.")
    }
}
