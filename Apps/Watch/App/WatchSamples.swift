#if DEBUG
import Foundation

/// `-nollie-watch-sample approval|phone|crew|stopping|quiet|night|night-quiet`: a debug build shows made-up helpers and
/// approvals without a phone, for pictures of each screen. Nothing is sent anywhere.
enum WatchSamples {
    struct Sample {
        var snapshot: WatchWire.Snapshot
        var page: String
        var note: String? = nil
        var sendingStop = false
    }

    static var active: Bool { name != nil }

    private static var name: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-nollie-watch-sample"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func fromLaunch(now: Date = Date()) -> Sample? {
        guard let name else { return nil }
        let crew = [
            WatchWire.Helper(profile: "career", name: "Scout", avatar: "character-kick-avatar", place: .mac,
                             since: now.addingTimeInterval(-252)),
            WatchWire.Helper(profile: "nowhere", name: "Mason", avatar: "character-swell-avatar", place: nil,
                             since: now.addingTimeInterval(-60)),
        ]
        var snapshot = WatchWire.Snapshot(made: now, approvals: [], helpers: crew, canStop: true, connected: true)
        switch name {
        case "approval":
            snapshot.approvals = [archive]
            return Sample(snapshot: snapshot, page: archive.id)
        case "phone":
            snapshot.approvals = [payment]
            return Sample(snapshot: snapshot, page: payment.id)
        case "stopping":
            return Sample(snapshot: snapshot, page: WatchModel.crewPage, sendingStop: true)
        case "quiet":
            snapshot.helpers = []
            return Sample(snapshot: snapshot, page: WatchModel.crewPage)
        case "night":
            snapshot.night = night
            return Sample(snapshot: snapshot, page: WatchModel.nightPage)
        case "night-quiet":
            snapshot.night = WatchWire.NightNote(at: now, since: "Since 7:00 yesterday", counts: "Quiet night. Nothing ran.",
                                                 runs: [], more: 0, needsLook: false)
            return Sample(snapshot: snapshot, page: WatchModel.nightPage)
        default:
            return Sample(snapshot: snapshot, page: WatchModel.crewPage)
        }
    }

    private static let night = WatchWire.NightNote(
        at: Date(), since: "Since 7:02 yesterday", counts: "3 runs · 7 actions · 1 held",
        runs: [.init(title: "Morning job alerts", detail: "Scout · Done · 6:10"),
               .init(title: "Tidy the Downloads folder", detail: "Mason · Done · 2:31"),
               .init(title: "Reply to the plumber", detail: "Nollie · Stopped · 1:05")],
        more: 0, needsLook: true)

    private static let archive = WatchWire.Approval(
        id: "sample-1", requestID: "req-1", chatID: "chat-1", profile: "career", connectionID: "", botName: "Scout",
        avatar: "character-kick-avatar", symbol: "trash.fill", title: "Scout wants to delete something",
        body: "Move 14 old job alerts to the Trash in Mail.", check: nil, command: nil,
        answers: .allowOrDeny, asksAgain: false, flagged: false)

    private static let payment = WatchWire.Approval(
        id: "sample-2", requestID: "req-2", chatID: "chat-2", profile: "forager", connectionID: "", botName: "Forager",
        avatar: "character-spike-avatar", symbol: "creditcard.fill", title: "Forager wants to pay for something",
        body: "Order 2 bags of coffee beans for £18.40.", check: "You're about to press \u{201C}Place order\u{201D}.",
        command: nil, answers: .denyOnly, asksAgain: true, flagged: false)
}
#endif
