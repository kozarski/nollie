import Foundation
import NollieCore

#if os(macOS)
extension PermissionClient {
    // MARK: Calendar, Reminders and Contacts (Mac)

    /// The Mac's own Calendar, Reminders or Contacts, for helpers. Read without asking; asked only
    /// from a helper's switch in Bot settings, or Allow in Settings › Privacy › Permissions.
    static func appleData(_ kind: PermissionKind) -> PermissionClient {
        let area: AppleDataArea = switch kind {
        case .reminders: .reminders
        case .contacts: .contacts
        default: .calendar
        }
        let pane = switch area {
        case .calendar: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .contacts: "Privacy_Contacts"
        }
        return PermissionClient(
            read: { map(AppleLibrary().access(area)) },
            request: { map(await AppleLibrary.request(area)) },
            openSettings: { openPane("com.apple.preference.security?" + pane) })
    }

    static func map(_ access: AppleDataAccess) -> PermissionState {
        switch access {
        case .allowed: .granted
        case .denied: .denied
        case .notAsked: .notAsked
        case .unavailable: .unavailable
        }
    }
}
#endif

extension PermissionKind {
    /// The kind behind one of a helper's Mac switches.
    init(_ area: AppleDataArea) {
        switch area {
        case .calendar: self = .calendar
        case .reminders: self = .reminders
        case .contacts: self = .contacts
        }
    }
}
