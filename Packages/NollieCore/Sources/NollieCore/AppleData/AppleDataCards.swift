import Foundation

/// The words on the card for a change to the person's calendar, reminders or contacts, by fixed rules
/// from the change itself, never from what the helper says about it. The first line is the whole
/// change as a question ("Add “Dentist” on Tue 4 Nov, 10:00 to Home calendar?"); lines under it add
/// what else will be saved. The same rules give the helper its "done" sentence.
public enum AppleDataCards {
    /// The card the person reads before saying yes, in their own language.
    public static func card(_ plan: AppleDataPlan, time: AppleDataTime) -> String {
        let question = String(localized: "\(headline(plan, time: time))?", table: "Core",
                              comment: "Safety: a change to the person's calendar, reminders or contacts, asked as a question")
        return ([question] + details(plan, time: time)).joined(separator: "\n")
    }

    /// What the helper hears once the change is made. Goes to the model, so it stays in English.
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

    /// The card's first line, without its question mark. Each change is one whole sentence: the title, when and
    /// which calendar or list fill its places.
    static func headline(_ plan: AppleDataPlan, time: AppleDataTime) -> String {
        switch plan {
        case let .addEvent(draft):
            let title = shownQuoted(draft.title), when = shownOn(draft.start, draft.end, allDay: draft.allDay, time: time)
            let calendar = shownCalendarName(draft.calendar)
            return String(localized: "Add \(title) \(when) to \(calendar)", table: "Core", comment: "Safety: adding a calendar event; keep exact meaning")
        case let .changeEvent(before, after):
            let title = shownQuoted(before.title)
            if onlyMoved(before, after) {
                let from = time.when(before.start, time: !before.allDay), to = time.when(after.start, time: !after.allDay)
                return String(localized: "Move \(title) from \(from) to \(to)", table: "Core", comment: "Safety: moving a calendar event; keep exact meaning")
            }
            let when = shownOn(before.start, before.end, allDay: before.allDay, time: time), calendar = shownCalendarName(before.calendar)
            return String(localized: "Change \(title) \(when) in \(calendar)", table: "Core", comment: "Safety: changing a calendar event; keep exact meaning")
        case let .deleteEvent(event):
            let title = shownQuoted(event.title), when = shownOn(event.start, event.end, allDay: event.allDay, time: time)
            let calendar = shownCalendarName(event.calendar)
            return String(localized: "Delete \(title) \(when) from \(calendar)", table: "Core", comment: "Safety: deleting a calendar event; keep exact meaning")
        case let .addReminder(draft):
            let title = shownQuoted(draft.title), list = plain(draft.list)
            if let due = draft.due.map({ time.when($0, time: draft.dueHasTime) }) {
                return String(localized: "Add the reminder \(title) to \(list), due \(due)", table: "Core",
                              comment: "Safety: adding a reminder with a due date; keep exact meaning")
            }
            return String(localized: "Add the reminder \(title) to \(list)", table: "Core", comment: "Safety: adding a reminder; keep exact meaning")
        case let .completeReminder(reminder):
            let title = shownQuoted(reminder.title), list = plain(reminder.list)
            return String(localized: "Mark \(title) in \(list) as done", table: "Core", comment: "Safety: completing a reminder; keep exact meaning")
        case let .deleteReminder(reminder):
            let title = shownQuoted(reminder.title), list = plain(reminder.list)
            return String(localized: "Delete the reminder \(title) from \(list)", table: "Core", comment: "Safety: deleting a reminder; keep exact meaning")
        case let .addContact(draft):
            let name = plain(draft.name)
            return String(localized: "Add \(name) to your contacts", table: "Core", comment: "Safety: adding a contact; keep exact meaning")
        case let .changeContact(before, _):
            let name = plain(before.name)
            return String(localized: "Change \(name) in your contacts", table: "Core", comment: "Safety: changing a contact; keep exact meaning")
        }
    }

    static func details(_ plan: AppleDataPlan, time: AppleDataTime) -> [String] {
        let onlyThisTime = String(localized: "Only this time, not the whole series.", table: "Core",
                                  comment: "Safety: a change to one time of a repeating event; keep exact meaning")
        switch plan {
        case let .addEvent(draft):
            return [until(draft.start, draft.end, allDay: draft.allDay, time: time),
                    draft.location.map { String(localized: "At \(plain($0))", table: "Core", comment: "An event's place") },
                    draft.notes.map { String(localized: "Notes: \(plain($0, limit: 200))", table: "Core") }].compactMap { $0 }
        case let .changeEvent(before, after):
            var lines: [String?] = []
            if onlyMoved(before, after) {
                lines.append(until(after.start, after.end, allDay: after.allDay, time: time))
            } else {
                if after.title != before.title {
                    let title = shownQuoted(after.title)
                    lines.append(String(localized: "New title: \(title)", table: "Core"))
                }
                if after.start != before.start || after.end != before.end || after.allDay != before.allDay {
                    let start = time.when(after.start, time: !after.allDay)
                    if let end = untilTime(after.start, after.end, allDay: after.allDay, time: time) {
                        lines.append(String(localized: "New time: \(start), until \(end)", table: "Core", comment: "An event's new start and end"))
                    } else {
                        lines.append(String(localized: "New time: \(start)", table: "Core", comment: "An event's new start"))
                    }
                }
                if after.location != before.location {
                    let place = plain(after.location ?? "")
                    lines.append(String(localized: "New place: \(place)", table: "Core"))
                }
                if after.notes != before.notes {
                    let notes = plain(after.notes ?? "", limit: 200)
                    lines.append(String(localized: "New notes: \(notes)", table: "Core"))
                }
                if after.calendarID != before.calendarID {
                    let calendar = shownCalendarName(after.calendar)
                    lines.append(String(localized: "Move to \(calendar)", table: "Core", comment: "Move an event to another calendar"))
                }
            }
            if before.repeats { lines.append(onlyThisTime) }
            return lines.compactMap { $0 }
        case let .deleteEvent(event):
            return event.repeats ? [onlyThisTime] : []
        case let .addReminder(draft):
            return draft.notes.map { [String(localized: "Notes: \(plain($0, limit: 200))", table: "Core")] } ?? []
        case .completeReminder, .deleteReminder:
            return []
        case let .addContact(draft):
            return contactLines(draft, before: nil, time: time)
        case let .changeContact(before, after):
            var lines: [String] = []
            if after.name != before.name {
                let name = plain(after.name)
                lines.append(String(localized: "Name: \(name)", table: "Core", comment: "A contact's name"))
            }
            return lines + contactLines(after, before: before, time: time)
        }
    }

    private static func contactLines(_ draft: ContactDraft, before: ContactFacts?, time: AppleDataTime) -> [String] {
        let phones = draft.addPhones.map { phone in
            before == nil ? String(localized: "Phone: \(plain(phone))", table: "Core") : String(localized: "Add phone: \(plain(phone))", table: "Core")
        }
        let emails = draft.addEmails.map { email in
            before == nil ? String(localized: "Email: \(plain(email))", table: "Core") : String(localized: "Add email: \(plain(email))", table: "Core")
        }
        var lines = phones + emails
        if let birthday = draft.birthday, birthday != before?.birthday {
            let new = time.birthdayText(birthday)
            if let was = before?.birthday.map(time.birthdayText) {
                lines.append(String(localized: "Birthday: \(new) (was \(was))", table: "Core", comment: "A contact's new birthday and the one it replaces"))
            } else {
                lines.append(String(localized: "Birthday: \(new)", table: "Core"))
            }
        }
        return lines
    }

    /// Only the time moves: same title, place, notes, calendar and kind of day.
    static func onlyMoved(_ before: EventFacts, _ after: EventDraft) -> Bool {
        (after.start != before.start || after.end != before.end) && after.title == before.title
            && after.location == before.location && after.notes == before.notes
            && after.calendarID == before.calendarID && after.allDay == before.allDay
    }

    /// "on Tue 4 Nov, 10:00", "all day on Fri 7 Nov", "from Fri 7 Nov to Sun 9 Nov". For the helper's sentences.
    static func on(_ start: Date, _ end: Date, allDay: Bool, time: AppleDataTime) -> String {
        guard allDay else { return "on \(time.when(start))" }
        let last = lastDay(start, end, time: time)
        return time.sameDay(start, last) ? "all day on \(time.when(start, time: false))"
            : "from \(time.when(start, time: false)) to \(time.when(last, time: false))"
    }

    /// The same on the card.
    static func shownOn(_ start: Date, _ end: Date, allDay: Bool, time: AppleDataTime) -> String {
        guard allDay else {
            let when = time.when(start)
            return String(localized: "on \(when)", table: "Core", comment: "When an event is, as in: Add “Dentist” on Tue 4 Nov, 10:00 to Home calendar")
        }
        let last = lastDay(start, end, time: time)
        let first = time.when(start, time: false)
        if time.sameDay(start, last) {
            return String(localized: "all day on \(first)", table: "Core", comment: "When an event is, as in: Add “Holiday” all day on Fri 7 Nov to Home calendar")
        }
        let to = time.when(last, time: false)
        return String(localized: "from \(first) to \(to)", table: "Core", comment: "When an event is, as in: Add “Trip” from Fri 7 Nov to Sun 9 Nov to Home calendar")
    }

    /// "Until 11:00", or "Until Wed 5 Nov, 02:00" when it ends on another day. Nil for a whole day.
    static func until(_ start: Date, _ end: Date, allDay: Bool, time: AppleDataTime) -> String? {
        untilTime(start, end, allDay: allDay, time: time).map { String(localized: "Until \($0)", table: "Core", comment: "When an event ends") }
    }

    /// The end alone: "11:00", or "Wed 5 Nov, 02:00" on another day.
    static func untilTime(_ start: Date, _ end: Date, allDay: Bool, time: AppleDataTime) -> String? {
        guard !allDay, end > start else { return nil }
        return time.sameDay(start, end) ? time.clock(end) : time.when(end)
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

    /// The same on the card: "Home calendar".
    static func shownCalendarName(_ name: String) -> String {
        let name = plain(name, limit: 60)
        if name.localizedCaseInsensitiveContains("calendar") { return name }
        return String(localized: "\(name) calendar", table: "Core", comment: "A calendar's name, as in: Home calendar")
    }

    static func quoted(_ text: String) -> String { "\u{201C}\(plain(text))\u{201D}" }

    /// The same on the card, with the person's own quotation marks.
    static func shownQuoted(_ text: String) -> String {
        let line = plain(text)
        return String(localized: "\u{201C}\(line)\u{201D}", table: "Core", comment: "A title in quotation marks")
    }

    /// One line, at most `limit` characters: what a helper wrote can't add lines or run on.
    static func plain(_ text: String, limit: Int = 80) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "\u{2026}" : line
    }
}
