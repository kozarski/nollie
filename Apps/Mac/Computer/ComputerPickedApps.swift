import Foundation

/// The apps the person picked for using this Mac (a bot's settings, Computer, Advanced, Apps).
/// Kept on this Mac only, by bundle id, and empty until the person picks one. A bot can ask only
/// for these, and Nollie checks the list again before every step, so turning an app off counts
/// from the next action. Fixed rules decide; the list can only narrow what `ComputerAppRules`
/// already allows, never widen it.
enum ComputerPickedApps {
    static let key = "nollie.computer.apps"

    static func read(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set((defaults.stringArray(forKey: key) ?? []).map { $0.lowercased() })
    }

    static func set(_ bundleID: String, picked: Bool, defaults: UserDefaults = .standard) {
        var apps = read(defaults)
        if picked { apps.insert(bundleID.lowercased()) } else { apps.remove(bundleID.lowercased()) }
        defaults.set(apps.sorted(), forKey: key)
    }

    static func notPicked(_ name: String) -> String { "\(name) isn't one of the apps you picked for this Mac." }
    static let nonePicked = "No apps are picked for using this Mac yet. The person can pick them in a bot's settings, under Computer."
    static func turnedOff(_ name: String) -> String { "\(name) was turned off for this Mac, so Nollie didn't do that." }

    /// One app the page offers: one Nollie could use (or only look at) that is on this Mac.
    struct Candidate: Equatable, Hashable, Sendable, Identifiable {
        var info: ComputerAppInfo
        var viewOnly: Bool
        var id: String { info.bundleID.lowercased() }
        var name: String { info.name }
    }

    /// Every app Nollie offers that this Mac has, by name. Each is judged by the same rules as a
    /// task (signature included), so the page never offers an app a task would refuse.
    static func candidates(find: (String) -> ComputerAppInfo?,
                           access: (ComputerAppInfo) -> ComputerAppAccess = { ComputerAppRules.access(for: $0) }) -> [Candidate] {
        let ids = ComputerAppRules.usable.union(ComputerAppRules.browserIDs)
        var found: [Candidate] = []
        for id in ids {
            guard let info = find(id) else { continue }
            switch access(info) {
            case .use: found.append(Candidate(info: info, viewOnly: false))
            case .viewOnly: found.append(Candidate(info: info, viewOnly: true))
            case .never: continue
            }
        }
        var seen = Set<String>()
        return found
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.viewOnly ? 1 : 0, $0.name.lowercased()) < ($1.viewOnly ? 1 : 0, $1.name.lowercased()) }
    }
}
