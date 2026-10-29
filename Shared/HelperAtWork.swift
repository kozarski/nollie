import Foundation
#if os(iOS)
import ActivityKit
#endif

/// Where a helper is working: this Mac, or a computer of its own.
enum HelperWorkPlace: String, Codable, Hashable, Sendable {
    case mac, ownComputer
}

#if os(iOS)
/// The Live Activity on the Lock Screen and in the Dynamic Island while a helper is using a
/// computer, with one Stop button. The app starts it (ActivityKit allows that only from the
/// foreground) and keeps it while it can see the work; the Controls extension draws it.
struct HelperAtWorkAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            /// The app last saw the helper at work at `lastSeen`.
            case working
            /// Stop was pressed and the app is sending it.
            case stopping
            /// The Mac took the Stop.
            case stopped
            /// Stop could not reach the Mac; the work may still be going.
            case notReached
        }
        var phase: Phase = .working
        /// When the app first saw this piece of work.
        var startedAt: Date
        /// When the app last saw it still going. Past the activity's stale date, the Lock Screen
        /// says when that was instead of claiming it is live.
        var lastSeen: Date
        /// False once the app lost the link to the Mac: shown as last seen at once.
        var reachable: Bool = true
    }

    /// The helper's profile name, which the app matches its chats by.
    var profile: String
    /// Its name as people see it.
    var name: String
    /// The character still in `CharacterAvatars.xcassets` (`character-<look>-avatar`).
    var avatar: String
    var place: HelperWorkPlace
}
#endif

/// How long the Lock Screen believes the app's last report. iOS suspends the app shortly after it
/// leaves the screen and Nollie has no server pushing updates, so beyond this window the activity
/// shows when the helper was last seen instead of claiming it is still live.
enum HelperAtWorkTiming {
    static let staleAfter: TimeInterval = 120
    /// While in the foreground, the app tells the activity it is still current this often.
    static let refreshEvery: TimeInterval = 60
    /// How long a finished Stop stays on the Lock Screen, ticked, before it goes.
    static let stoppedLingers: TimeInterval = 4

    /// Two minutes after the app last saw the work. With the link gone there is none: the state
    /// already says so, and a stale date in the past would keep the activity from showing at all.
    static func staleDate(lastSeen: Date, reachable: Bool) -> Date? {
        reachable ? lastSeen.addingTimeInterval(staleAfter) : nil
    }
}

/// What the Live Activity and its setting say. Shared so tests can hold them to the copy rules.
enum HelperAtWorkWords {
    static func title(name: String, place: HelperWorkPlace) -> String {
        switch place {
        case .mac: String(localized: "\(name) is using your Mac")
        case .ownComputer: String(localized: "\(name) is using its computer")
        }
    }
    /// The title once Stop is pressed, then once the Mac has taken it.
    static func stoppingTitle(name: String) -> String { String(localized: "Stopping \(name)", comment: "Safety: Stop was pressed for this helper") }
    static func stoppedTitle(name: String) -> String { String(localized: "\(name) stopped", comment: "Safety: the Mac took the Stop") }
    static let stop = String(localized: "Stop", comment: "Safety: stops the helper's work on the Mac")
    static let stopping = String(localized: "Telling your Mac", comment: "Safety: a Stop on its way to the Mac")
    static let stopped = String(localized: "The job has ended", comment: "Safety: the Mac took the Stop")
    static let notReached = String(localized: "Stop didn't reach your Mac", comment: "Safety: the work may still be going")
    /// Before the time since the helper was last seen ("Last seen 2 min ago").
    static let lastSeen = String(localized: "Last seen")
    static let setting = String(localized: "Show Stop on the Lock Screen while a helper is working")
    static let settingFooter = String(localized: "Stop ends the job on your Mac, stops replies and pauses schedules. Your iPhone asks to be unlocked first.",
                                      comment: "Safety: what Stop does")
}

/// The iCloud alert for a helper that started using the Mac, and its Stop button. The Mac sends
/// it; the iPhone shows it with Stop, which asks for Face ID or the passcode on a locked phone.
enum ComputerStartedWords {
    static func body(botName: String) -> String { String(localized: "\(botName) started using your Mac.") }
    static let category = "NOLLIE_COMPUTER"
    static let stopAction = "NOLLIE_STOP_MAC"
    static let stop = String(localized: "Stop", comment: "Safety: notification button; stops the bot using the Mac")
}

/// Settings › Siri & Shortcuts › Show Stop on the Lock Screen while a helper is working: on unless
/// turned off.
enum HelperAtWorkSetting {
    static let key = "stop.lockScreenActivity"
    static let defaultOn = true
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultOn }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
