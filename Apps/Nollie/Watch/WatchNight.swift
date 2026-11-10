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

    /// Tasks the wrist lists before "2 more".
    static let shownTasks = 3

    /// The Board tasks that wait for the person, as the Board's Blocked lane has them. A private bot's task stays
    /// off the wrist, as its work does everywhere else. Nil when nothing waits or the Board hasn't been read.
    static func board(_ board: KanbanBoard?, name: (String) -> String, isPrivate: (String) -> Bool) -> WatchWire.BoardNote? {
        guard let board else { return nil }
        let waiting = KanbanPresentationGroup.blocked.tasks(in: board).filter { task in
            task.assignee.map { !isPrivate($0) } ?? true
        }
        guard !waiting.isEmpty else { return nil }
        let lines = waiting.prefix(shownTasks).map {
            WatchWire.NightNote.Line(title: $0.title, detail: $0.assignee.map(name) ?? "")
        }
        return WatchWire.BoardNote(tasks: Array(lines), more: waiting.count - lines.count)
    }

    /// Helpers the wrist's weekly note lists before "2 more".
    static let shownHelpers = 4

    /// The weekly note made small: the same counts as the phone's note, nothing more. Nil when the note isn't
    /// shown on this phone (off, or a member's).
    static func week(_ note: WeeklyNote?, shown: Bool) -> WatchWire.WeekNote? {
        guard shown, let note else { return nil }
        let lines = note.short.prefix(shownHelpers).map { WatchWire.NightNote.Line(title: $0.name, detail: $0.detail) }
        return WatchWire.WeekNote(range: WeeklyNoteDates.range(note.since, note.until), headline: note.headline,
                                  helpers: Array(lines), more: max(0, note.helpers.count - lines.count),
                                  hasNews: !note.news.isEmpty)
    }
}
#endif
