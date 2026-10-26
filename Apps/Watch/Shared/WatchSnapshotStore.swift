#if os(watchOS)
import Foundation

/// The last picture the phone sent, kept where the Watch app and its widgets both read it. It holds
/// what the wrist already showed, nothing more: names, words of waiting approvals, who is working.
enum WatchSnapshotStore {
    static let group = "group.com.coreykozarski.nollie.watch"
    private static let key = "watch.snapshot"

    private static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    static func load() -> WatchWire.Snapshot? {
        defaults.data(forKey: key).flatMap(WatchWire.decodeSnapshot)
    }

    static func save(_ snapshot: WatchWire.Snapshot) {
        guard let data = WatchWire.encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

/// How long the Watch believes what the phone last said about helpers at work, the same window as
/// the Lock Screen's Stop. Past it the Watch says when it last heard, never that work is live.
enum WatchFreshness {
    static func isStale(_ snapshot: WatchWire.Snapshot, now: Date = Date()) -> Bool {
        now.timeIntervalSince(snapshot.made) > HelperAtWorkTiming.staleAfter
    }
}
#endif
