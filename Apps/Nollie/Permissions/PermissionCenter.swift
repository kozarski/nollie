import Foundation
import Observation

/// Every system permission Nollie can need, in the order a person meets them.
enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case notifications, localNetwork, camera, microphone, photos, liveActivities, accessibility, screenRecording
    /// The Mac's own Calendar, Reminders and Contacts, for the helpers the person turns them on for.
    case calendar, reminders, contacts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifications: "Notifications"
        case .localNetwork: "Local Network"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .photos: "Photos"
        case .liveActivities: "Live Activities"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .contacts: "Contacts"
        }
    }

    /// One plain line on why Nollie asks. Shown beside the Allow button, before the system prompt.
    var reason: String {
        switch self {
        case .notifications: "Know when a reply is ready or a task needs you."
        case .localNetwork:
            DeviceWords.isMac ? "Lets your iPhone find this Mac on your Wi-Fi."
                              : "Lets Nollie find your Mac on your Wi-Fi."
        case .camera: "Reads the code on your Mac, and takes photos for a chat."
        case .microphone: "Lets you talk with your bots, dictate and record voice memos."
        case .photos: "Saves a picture from a chat to your Photos."
        case .liveActivities: "Shows on the Lock Screen while a helper uses your Mac."
        case .accessibility: "Lets Nollie click and type in the apps you approve."
        case .screenRecording: "Lets Nollie see those apps, so it knows where to click."
        case .calendar: "Helpers you choose can see your calendar. Changes wait for your yes."
        case .reminders: "Helpers you choose can see your reminders. Changes wait for your yes."
        case .contacts: "Helpers you choose can find your contacts. Changes wait for your yes."
        }
    }

    var symbol: String {
        switch self {
        case .notifications: "bell.badge"
        case .localNetwork: "wifi"
        case .camera: "camera"
        case .microphone: "mic"
        case .photos: "photo"
        case .liveActivities: "lock.iphone"
        case .accessibility: "hand.point.up.left"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        }
    }

    /// Whether Nollie can show the system prompt for it. Live Activities has none: it is a switch
    /// in Settings only.
    var canAsk: Bool { self != .liveActivities }

    /// What this device lists, in order. `direct` is the Mac download, the only one that links an
    /// iPhone and lets a bot use the Mac.
    static func listed(isMac: Bool, direct: Bool) -> [PermissionKind] {
        if isMac {
            var kinds: [PermissionKind] = [.notifications]
            if direct { kinds.append(.localNetwork) }
            kinds.append(.microphone)
            if direct { kinds += [.accessibility, .screenRecording] }
            // Asked by a helper's switch in Bot settings, never in setup.
            kinds += [.calendar, .reminders, .contacts]
            return kinds
        }
        return [.notifications, .localNetwork, .camera, .microphone, .photos, .liveActivities]
    }

    /// What setup asks for, when the device has it. Accessibility and Screen Recording wait for
    /// the switch that lets a bot use the Mac, and the camera waits for the scanner.
    static let inSetup: [PermissionKind] = [.notifications, .localNetwork]
}

enum PermissionState: Equatable, Sendable {
    /// Nobody has been asked yet. Allow shows the system prompt.
    case notAsked
    case granted
    /// Asked and answered no (or switched off later). Only the system's Settings can change it.
    case denied
    /// Not possible here, such as a restriction set by the device's owner.
    case unavailable

    var isGranted: Bool { self == .granted }
}

/// How one permission is read, asked for, and found in Settings. Tests stand in with fakes.
@MainActor
struct PermissionClient {
    /// Reads the state. Never shows a prompt.
    var read: () async -> PermissionState
    /// Shows the system prompt and returns the answer.
    var request: () async -> PermissionState
    /// Opens the page in Settings where the person can change it.
    var openSettings: () -> Void
}

/// What Nollie knows about each permission, and the only way it asks: `ask` runs from a button,
/// never from a refresh. Reading is silent, so Settings and the setup step can look as often as
/// they like.
@MainActor
@Observable
final class PermissionCenter {
    private(set) var states: [PermissionKind: PermissionState] = [:]
    private(set) var asking: Set<PermissionKind> = []
    /// Set once the first read finishes, so a screen does not show Allow for a moment it is
    /// still looking.
    private(set) var hasRead = false

    @ObservationIgnored private let clients: [PermissionKind: PermissionClient]

    init(clients: [PermissionKind: PermissionClient]) {
        self.clients = clients
    }

    func state(_ kind: PermissionKind) -> PermissionState { states[kind] ?? .notAsked }

    func isAvailable(_ kind: PermissionKind) -> Bool { clients[kind] != nil }

    /// Reads every permission this device has. Shows nothing.
    func refresh() async {
        for kind in PermissionKind.allCases where clients[kind] != nil { await refresh(kind) }
        hasRead = true
    }

    func refresh(_ kind: PermissionKind) async {
        guard let client = clients[kind] else { return }
        states[kind] = await client.read()
    }

    /// Shows the system prompt for one permission, once. A permission already answered is left
    /// alone: macOS and iOS do not ask twice, and Settings is where it changes.
    @discardableResult
    func ask(_ kind: PermissionKind) async -> PermissionState {
        guard let client = clients[kind], kind.canAsk, !asking.contains(kind) else { return state(kind) }
        await refresh(kind)
        guard state(kind) == .notAsked else { return state(kind) }
        asking.insert(kind)
        defer { asking.remove(kind) }
        states[kind] = await client.request()
        return state(kind)
    }

    func openSettings(_ kind: PermissionKind) {
        clients[kind]?.openSettings()
    }

    /// How many of `kinds` still wait for a yes or a no.
    func unanswered(_ kinds: [PermissionKind]) -> Int {
        kinds.filter { clients[$0] != nil && state($0) == .notAsked }.count
    }
}
