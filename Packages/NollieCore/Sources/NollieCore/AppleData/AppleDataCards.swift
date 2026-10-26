import Foundation

/// The words on the card for a change to the person's calendar, reminders or contacts, by fixed rules
/// from the change itself, never from what the helper says about it. The first line is the whole
/// change as a question ("Add “Dentist” on Tue 4 Nov, 10:00 to Home calendar?"); lines under it add
/// what else will be saved. The same rules give the helper its "done" sentence.
public enum AppleDataCards {
    public static func card(_ plan: AppleDataPlan, time: AppleDataTime) -> String {
        ([headline(plan, time: time) + "?"] + details(plan, time: time)).joined(separator: "\n")
    }

    /// What the helper hears once the change is made.
    public static func done(_ plan: AppleDataPlan, time: AppleDataTime) -> String {
        switch plan {
        case let .addEvent(draft):
            "Added \(quoted(draft.title)) \(on(draft.start, draft.end, allDay: draft.allDay, time: time)) to \(calendarName(draft.calendar))."
        case let .changeEvent(before, after):
            onlyMoved(before, after) ? "Moved \(quoted(before.title)) to \(time.when(after.start, time: !after.allDay))."
                : "Changed \(quoted(after.title)) \(on(after.start, after.end, allDay: after.allDay, time: time))."
        case let .deleteEvent(event):
            "Deleted \(quoted(event.title)) \(on(event.start, event.end, allDay: event.allDay, time: time)) from \(calendarName(event.calendar))."
        case let .addReminder(draft): "Added the reminder \(quoted(draft.title)) to \(plain(draft.list))."
        case let .completeReminder(reminder): "Marked \(quoted(reminder.title)) as done."
        case let .deleteReminder(reminder): "Deleted the reminder \(quoted(reminder.title)) from \(plain(reminder.list))."
        case let .addContact(draft): "Added \(plain(draft.name)) to the contacts."
        case let .changeContact(_, after): "Changed \(plain(after.name)) in the contacts."
        }
    }

    static func headline(_ plan: AppleDataPlan, time: AppleDataTime) -> String {
        switch plan {
        case let .addEvent(draft):
            return "Add \(quoted(draft.title)) \(on(draft.start, draft.end, allDay: draft.allDay, time: time)) to \(calendarName(draft.calendar))"
        case let .changeEvent(before, after):
            if onlyMoved(before, after) {
                return "Move \(quoted(before.title)) from \(time.when(before.start, time: !before.allDay)) to \(time.when(after.start, time: !after.allDay))"
            }
            return "Change \(quoted(before.title)) \(on(before.start, before.end, allDay: before.allDay, time: time)) in \(calendarName(before.calendar))"
        case let .deleteEvent(event):
            return "Delete \(quoted(event.title)) \(on(event.start, event.end, allDay: event.allDay, time: time)) from \(calendarName(event.calendar))"
        case let .addReminder(draft):
            let due = draft.due.map { ", due " + time.when($0, time: draft.dueHasTime) } ?? ""
            return "Add the reminder \(quoted(draft.title)) to \(plain(draft.list))\(due)"
        case let .completeReminder(reminder):
            return "Mark \(quoted(reminder.title)) in \(plain(reminder.list)) as done"
        case let .deleteReminder(reminder):
            return "Delete the reminder \(quoted(reminder.title)) from \(plain(reminder.list))"
        case let .addContact(draft):
            return "Add \(plain(draft.name)) to your contacts"
        case let .changeContact(before, _):
            return "Change \(plain(before.name)) in your contacts"
        }
    }

    static func details(_ plan: AppleDataPlan, time: AppleDataTime) -> [String] {
        switch plan {
        case let .addEvent(draft):
            return [until(draft.start, draft.end, allDay: draft.allDay, time: time),
                    draft.location.map { "At \(plain($0))" }, draft.notes.map { "Notes: \(plain($0, limit: 200))" }].compactMap { $0 }
        case let .changeEvent(before, after):
            var lines: [String?] = []
            if onlyMoved(before, after) {
                lines.append(until(after.start, after.end, allDay: after.allDay, time: time))
            } else {
                if after.title != before.title { lines.append("New title: \(quoted(after.title))") }
                if after.start != before.start || after.end != before.end || after.allDay != before.allDay {
                    let start = time.when(after.start, time: !after.allDay)
                    lines.append("New time: \(start)" + (until(after.start, after.end, allDay: after.allDay, time: time).map { ", " + $0.lowercased() } ?? ""))
                }
                if after.location != before.location { lines.append("New place: \(plain(after.location ?? ""))") }
                if after.notes != before.notes { lines.append("New notes: \(plain(after.notes ?? "", limit: 200))") }
                if after.calendarID != before.calendarID { lines.append("Move to \(calendarName(after.calendar))") }
            }
            if before.repeats { lines.append("Only this time, not the whole series.") }
            return lines.compactMap { $0 }
        case let .deleteEvent(event):
            return event.repeats ? ["Only this time, not the whole series."] : []
        case let .addReminder(draft):
            return draft.notes.map { ["Notes: \(plain($0, limit: 200))"] } ?? []
        case .completeReminder, .deleteReminder:
            return []
        case let .addContact(draft):
            return contactLines(draft, before: nil, time: time)
        case let .changeContact(before, after):
            var lines: [String] = []
            if after.name != before.name { lines.append("Name: \(plain(after.name))") }
            return lines + contactLines(after, before: before, time: time)
        }
    }

    private static func contactLines(_ draft: ContactDraft, before: ContactFacts?, time: AppleDataTime) -> [String] {
        let label = before == nil ? ("Phone", "Email") : ("Add phone", "Add email")
        var lines = draft.addPhones.map { "\(label.0): \(plain($0))" } + draft.addEmails.map { "\(label.1): \(plain($0))" }
        if let birthday = draft.birthday, birthday != before?.birthday {
            let was = before?.birthday.map { " (was \(time.birthdayText($0)))" } ?? ""
            lines.append("Birthday: \(time.birthdayText(birthday))\(was)")
        }
        return lines
    }

    /// Only the time moves: same title, place, notes, calendar and kind of day.
    static func onlyMoved(_ before: EventFacts, _ after: EventDraft) -> Bool {
        (after.start != before.start || after.end != before.end) && after.title == before.title
            && after.location == before.location && after.notes == before.notes
            && after.calendarID == before.calendarID && after.allDay == before.allDay
    }

    /// "on Tue 4 Nov, 10:00", "all day on Fri 7 Nov", "from Fri 7 Nov to Sun 9 Nov".
    static func on(_ start: Date, _ end: Date, allDay: Bool, time: AppleDataTime) -> String {
        guard allDay else { return "on \(time.when(start))" }
        let last = lastDay(start, end, time: time)
        return time.sameDay(start, last) ? "all day on \(time.when(start, time: false))"
            : "from \(time.when(start, time: false)) to \(time.when(last, time: false))"
    }

    /// "Until 11:00", or "Until Wed 5 Nov, 02:00" when it ends on another day. Nil for a whole day.
    static func until(_ start: Date, _ end: Date, allDay: Bool, time: AppleDataTime) -> String? {
        guard !allDay, end > start else { return nil }
        return "Until " + (time.sameDay(start, end) ? time.clock(end) : time.when(end))
    }

    /// The last day an all-day event covers: its end is the moment that day finishes.
    static func lastDay(_ start: Date, _ end: Date, time: AppleDataTime) -> Date {
        let back = end.addingTimeInterval(-1)
        return back > start ? back : start
    }

    /// "Home calendar", or a name that already says calendar as it is.
    static func calendarName(_ name: String) -> String {
        let name = plain(name, limit: 60)
        return name.localizedCaseInsensitiveContains("calendar") ? name : name + " calendar"
    }

    static func quoted(_ text: String) -> String { "\u{201C}\(plain(text))\u{201D}" }

    /// One line, at most `limit` characters: what a helper wrote can't add lines or run on.
    static func plain(_ text: String, limit: Int = 80) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "\u{2026}" : line
    }
}
