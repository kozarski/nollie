import Foundation
import NollieCore

/// A single thread entry. If the chat sat quiet for a while before it, a heading with the
/// date and time goes above it, much as Messages divides a conversation.
struct TranscriptRowModel: Identifiable, Equatable {
    var item: TranscriptItem
    var separator: String?
    /// For a folded run of tool calls: all of them in order (`item` is the first). Empty otherwise.
    var run: [TranscriptItem] = []
    /// False when another reply follows directly; the bot is drawn beside the final one only.
    var lastOfRun = true

    /// One word for the row's kind, used in its accessibility identifier.
    var kindTag: String {
        switch item.kind {
        case .assistant: return "reply"
        case .user: return "user"
        case .steer: return "steer"
        case .tool: return "tool"
        case .subagent: return "helper"
        case .system: return "note"
        case .error: return "error"
        }
    }

    var id: String { item.id }

    // MARK: Where the lazy part stops

    /// A pause longer than this puts a time heading before the next row.
    static let gap: TimeInterval = 900
    /// The minimum number of rows at the thread's end that stay out of the lazy stack, enough to fill a
    /// screen, so a thread at the bottom never shows a lazy row.
    static let tailBlock: Int = 16
    /// Cap on how many rows the list's tail holds on to ahead of the lazy stack reclaiming a few. One
    /// long turn may add dozens of tool rows, and with no slack the rows would shuffle during streaming.
    static let tailCap: Int = 6 * tailBlock

    /// Where the non-lazy rows begin if nothing pins them. Counted in whole blocks, so the line
    /// moves once per block of new rows and not on every row.
    static func tailStart(_ count: Int) -> Int {
        guard count > tailBlock else { return 0 }
        return (count - tailBlock) / tailBlock * tailBlock
    }

    /// Index of the first non-lazy row. The thread's own boundary (`tailFrom`) is kept while the
    /// end it leaves is sensible. With no boundary set, for newly loaded history, or rows that built up
    /// while the reader was further up, the boundary snaps to whole blocks.
    static func split(count: Int, tailFrom: Int?) -> Int {
        let snapped = tailStart(count)
        if let tailFrom, tailFrom <= snapped, tailCap >= count - tailFrom { return tailFrom }
        return snapped
    }

    // MARK: Building

    /// Makes rows from items. With `foldSteps`, each run of plain tool calls becomes one row.
    static func build(_ items: [TranscriptItem], now: Date = .now, foldSteps: Bool = false) -> [TranscriptRowModel] {
        var taken = Set<String>()
        var previous: Date?
        var rows: [TranscriptRowModel] = []
        for (place, original) in items.enumerated() {
            let item = uniqued(original, at: place, taken: &taken)
            let quiet = previous.map { item.timestamp.timeIntervalSince($0) > gap } ?? true
            rows.append(TranscriptRowModel(item: item, separator: quiet ? label(for: item.timestamp, now: now) : nil))
            previous = item.timestamp
        }
        markRunEnds(&rows)
        guard foldSteps else { return rows }
        return fold(rows)
    }

    /// No two rows may have the same id, since SwiftUI cannot distinguish them and might lay one out in the
    /// other's place. A gateway that repeats a tool call is one way it happens.
    private static func uniqued(_ original: TranscriptItem, at place: Int, taken: inout Set<String>) -> TranscriptItem {
        var item = original
        if !taken.insert(item.id).inserted {
            item.id += "~\(place)"
            taken.insert(item.id)
        }
        return item
    }

    /// In a run of replies (tool cards may sit between) only the last shows the bot and tail; same
    /// for a run of your own messages.
    private static func markRunEnds(_ rows: inout [TranscriptRowModel]) {
        func isTool(_ row: TranscriptRowModel) -> Bool {
            if case .tool = row.item.kind { return true }
            return false
        }
        for index in rows.indices {
            guard let next = rows[(index + 1)...].first(where: { !isTool($0) }) else { continue }
            switch (rows[index].item.kind, next.item.kind) {
            case (.assistant, .assistant), (.user, .user): rows[index].lastOfRun = false
            default: break
            }
        }
    }

    /// A plain tool call, as opposed to a message sent to another bot (which keeps its notice).
    static func isStep(_ item: TranscriptItem) -> Bool {
        guard case .tool(let activity) = item.kind else { return false }
        return activity.delivery == nil && activity.crewNote == nil
    }

    /// Gathers each run of plain tool calls into one row that holds them all, headed by the first.
    /// A reply, a note or a long pause (a time heading) between calls starts a new run.
    static func fold(_ rows: [TranscriptRowModel]) -> [TranscriptRowModel] {
        var out: [TranscriptRowModel] = []
        for row in rows {
            guard isStep(row.item) else { out.append(row); continue }
            if row.separator == nil, let end = out.indices.last, !out[end].run.isEmpty {
                out[end].run.append(row.item)
            } else {
                var head = row
                head.run = [row.item]
                out.append(head)
            }
        }
        return out
    }

    /// Words for a heading: "Today 5:34 PM", "Yesterday 5:34 PM", a weekday within the week,
    /// otherwise the date.
    static func label(for date: Date, now: Date) -> String {
        let cal: Calendar = .current
        let clock = date.formatted(date: .omitted, time: .shortened)
        func daysAgo(_ n: Int) -> Date? { cal.date(byAdding: .day, value: 0 - n, to: now) }
        if cal.isDate(date, inSameDayAs: now) { return String(localized: "Today \(clock)", comment: "A time in the chat, like Today 5:34 PM") }
        if let prior = daysAgo(1), cal.isDate(date, inSameDayAs: prior) {
            return String(localized: "Yesterday \(clock)", comment: "A time in the chat, like Yesterday 5:34 PM")
        }
        if let cutoff = daysAgo(6), date > cutoff {
            let weekday = date.formatted(.dateTime.weekday(.wide))
            return String(localized: "\(weekday) \(clock)", comment: "A weekday, then a time, like Tuesday 5:34 PM")
        }
        let day = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return String(localized: "\(day) at \(clock)", comment: "A date, then a time, like Mon, Oct 12 at 5:34 PM")
    }
}

/// A piece of text offered for selecting by range, presented as a sheet.
struct SelectTextItem: Identifiable {
    let text: String
    var id: String { text }
}
