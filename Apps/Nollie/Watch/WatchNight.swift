#if os(iOS)
import Foundation
import NollieCore

/// The Night shift card made small for the wrist: the same words Settings › Night shift uses, a few
/// runs, and nothing personal past the titles the card already shows.
enum WatchNight {
    /// Runs the note lists before "2 more".
    static let shownRuns = 3

    @MainActor
    static func note(_ card: ConversationPost.NightShift?, now: Date = Date()) -> WatchWire.NightNote? {
        guard let card else { return nil }
        let shown = card.runs.prefix(shownRuns).map {
            WatchWire.NightNote.Line(title: NightShiftWords.title(of: $0), detail: NightShiftWords.runLine($0))
        }
        let more = card.runs.count - shown.count + card.moreRuns
        let needsLook = card.counts.held > 0 || card.counts.stopped > 0 || !card.unwatched.isEmpty || !card.missed.isEmpty
        return WatchWire.NightNote(at: card.to ?? card.from ?? now, since: card.from.map { NightShiftWords.since($0, now: now) },
                                   counts: NightShiftWords.counts(card.counts), runs: Array(shown), more: max(0, more),
                                   needsLook: needsLook)
    }
}
#endif
