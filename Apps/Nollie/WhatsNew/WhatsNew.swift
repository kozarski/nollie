import Foundation

/// What changed in one version, said the way Nollie would say it to a friend: a line of welcome, then each
/// change with one plain sentence, where to find it, and more for anyone who wants the detail.
struct WhatsNewNote: Identifiable, Equatable {
    var version: String
    var lead: String
    var items: [Item]
    var id: String { version }

    struct Item: Identifiable, Equatable {
        var id: String
        var symbol: String
        var title: String
        /// One sentence: what is different now.
        var line: String
        /// Where it lives, as a short path: "Apple Watch · below your crew".
        var place: String? = nil
        /// The longer telling, behind More.
        var more: String? = nil
        /// Shown only on the Mac (something the iPhone has no part in).
        var macOnly = false
    }
}

/// When the note shows. Someone who just installed Nollie has nothing that is "new" to them, so only a
/// person who already had Nollie set up sees it, once, the first time a newer version opens.
enum WhatsNew {
    /// The last version whose note this person has seen (or, for a new install, the version they started on).
    static let seenKey = "nollie.whatsNew.seen"
    /// Notes shown at once when someone skipped a few versions.
    static let most = 3

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// True when `a` is a later version than `b`: "1.10" is after "1.9", and "1.3.1" after "1.3".
    static func isLater(_ a: String, than b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0, r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// What to remember at launch when nothing is remembered yet: a new install starts on this version, and
    /// someone who already had Nollie set up came from before the notes began.
    static func firstRecord(hadSetup: Bool, current: String) -> String { hadSetup ? "0" : current }

    /// The notes to show, newest first: those after what was seen, up to this version.
    static func pending(seen: String?, current: String, notes: [WhatsNewNote]) -> [WhatsNewNote] {
        guard let seen else { return [] }
        let due = notes.filter { isLater($0.version, than: seen) && !isLater($0.version, than: current) }
        return Array(due.sorted { isLater($0.version, than: $1.version) }.prefix(most))
    }

    /// The note for one version, for reading again from Settings › About.
    static func note(for version: String, in notes: [WhatsNewNote]) -> WhatsNewNote? {
        notes.first { $0.version == version } ?? notes.sorted { isLater($0.version, than: $1.version) }.first
    }

    /// Called once at launch, before any setup screen can add a connection.
    static func launch(hadSetup: Bool, defaults: UserDefaults = .standard, current: String = currentVersion) {
        guard defaults.string(forKey: seenKey) == nil else { return }
        defaults.set(firstRecord(hadSetup: hadSetup, current: current), forKey: seenKey)
    }

    static func markSeen(defaults: UserDefaults = .standard, current: String = currentVersion) {
        defaults.set(current, forKey: seenKey)
    }
}

extension WhatsNewNote.Item {
    /// Whether this device has any part in the change.
    var showsHere: Bool {
        #if os(macOS)
        true
        #else
        !macOnly
        #endif
    }
}
