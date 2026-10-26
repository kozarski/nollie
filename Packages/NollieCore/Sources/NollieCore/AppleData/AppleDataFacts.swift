import Foundation

// What Nollie on the Mac knows about the person's calendars, reminders and contacts, as plain values,
// and the one door to the apps (`AppleDataLibrary`): EventKit and Contacts on the Mac, a fake in tests.

public struct CalendarFacts: Equatable, Sendable {
    public var id: String
    public var title: String
    /// The calendar new events go to unless the person says otherwise.
    public var isDefault: Bool
    public var writable: Bool

    public init(id: String, title: String, isDefault: Bool = false, writable: Bool = true) {
        self.id = id; self.title = title; self.isDefault = isDefault; self.writable = writable
    }
}

public struct EventFacts: Equatable, Sendable {
    /// The Mac's own id, with the time for one occurrence of a repeating event.
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var calendar: String
    public var calendarID: String
    public var location: String?
    public var notes: String?
    public var repeats: Bool

    public init(id: String, title: String, start: Date, end: Date, allDay: Bool = false, calendar: String,
                calendarID: String = "", location: String? = nil, notes: String? = nil, repeats: Bool = false) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.allDay = allDay
        self.calendar = calendar; self.calendarID = calendarID; self.location = location; self.notes = notes
        self.repeats = repeats
    }
}

/// An event as it will be saved: everything the card shows, and nothing it doesn't.
public struct EventDraft: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var calendar: String
    public var calendarID: String
    public var location: String?
    public var notes: String?

    public init(title: String, start: Date, end: Date, allDay: Bool, calendar: String, calendarID: String,
                location: String? = nil, notes: String? = nil) {
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.calendar = calendar
        self.calendarID = calendarID; self.location = location; self.notes = notes
    }

    public init(_ event: EventFacts) {
        self.init(title: event.title, start: event.start, end: event.end, allDay: event.allDay, calendar: event.calendar,
                  calendarID: event.calendarID, location: event.location, notes: event.notes)
    }
}

public struct ReminderListFacts: Equatable, Sendable {
    public var id: String
    public var title: String
    public var isDefault: Bool
    public var open: Int

    public init(id: String, title: String, isDefault: Bool = false, open: Int = 0) {
        self.id = id; self.title = title; self.isDefault = isDefault; self.open = open
    }
}

public struct ReminderFacts: Equatable, Sendable {
    public var id: String
    public var title: String
    public var list: String
    public var due: Date?
    /// False for a reminder due on a day, with no time.
    public var dueHasTime: Bool
    public var notes: String?

    public init(id: String, title: String, list: String, due: Date? = nil, dueHasTime: Bool = true, notes: String? = nil) {
        self.id = id; self.title = title; self.list = list; self.due = due; self.dueHasTime = dueHasTime; self.notes = notes
    }
}

public struct ReminderDraft: Equatable, Sendable {
    public var title: String
    public var list: String
    public var listID: String
    public var due: Date?
    public var dueHasTime: Bool
    public var notes: String?

    public init(title: String, list: String, listID: String, due: Date? = nil, dueHasTime: Bool = true, notes: String? = nil) {
        self.title = title; self.list = list; self.listID = listID; self.due = due; self.dueHasTime = dueHasTime; self.notes = notes
    }
}

/// A birthday as the Contacts app keeps it: a day and month, and a year when known.
public struct Birthday: Equatable, Sendable {
    public var year: Int?
    public var month: Int
    public var day: Int

    public init(year: Int? = nil, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }
}

public struct ContactFacts: Equatable, Sendable {
    public var id: String
    public var givenName: String
    public var familyName: String
    public var phones: [String]
    public var emails: [String]
    public var birthday: Birthday?

    public init(id: String, givenName: String, familyName: String = "", phones: [String] = [], emails: [String] = [],
                birthday: Birthday? = nil) {
        self.id = id; self.givenName = givenName; self.familyName = familyName; self.phones = phones
        self.emails = emails; self.birthday = birthday
    }

    public var name: String { [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// A contact as it will be saved. For a change, `id` is the contact's and phones and emails are added
/// to what is there; nothing is taken away.
public struct ContactDraft: Equatable, Sendable {
    public var id: String?
    public var givenName: String
    public var familyName: String
    public var addPhones: [String]
    public var addEmails: [String]
    public var birthday: Birthday?

    public init(id: String? = nil, givenName: String, familyName: String = "", addPhones: [String] = [],
                addEmails: [String] = [], birthday: Birthday? = nil) {
        self.id = id; self.givenName = givenName; self.familyName = familyName; self.addPhones = addPhones
        self.addEmails = addEmails; self.birthday = birthday
    }

    public var name: String { [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// Exactly one change, worded on the card and made only after the person's yes. A change to something
/// that exists carries how it looked when the card was worded, so it is made only if that still holds.
public enum AppleDataPlan: Equatable, Sendable {
    case addEvent(EventDraft)
    case changeEvent(before: EventFacts, after: EventDraft)
    case deleteEvent(EventFacts)
    case addReminder(ReminderDraft)
    case completeReminder(ReminderFacts)
    case deleteReminder(ReminderFacts)
    case addContact(ContactDraft)
    case changeContact(before: ContactFacts, after: ContactDraft)

    public var area: AppleDataArea {
        switch self {
        case .addEvent, .changeEvent, .deleteEvent: .calendar
        case .addReminder, .completeReminder, .deleteReminder: .reminders
        case .addContact, .changeContact: .contacts
        }
    }
}

/// Why something wasn't done, in a sentence the helper can pass on.
public struct AppleDataRefusal: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// The person's calendars, reminders and contacts. Reads never ask macOS for anything; the system
/// prompt only ever comes from the switch in Bot settings.
public protocol AppleDataLibrary: Sendable {
    func access(_ area: AppleDataArea) -> AppleDataAccess

    func calendars() async throws -> [CalendarFacts]
    func events(from start: Date, to end: Date, calendarIDs: [String]?) async throws -> [EventFacts]
    func event(id: String) async throws -> EventFacts?
    /// Adds the draft, or changes the event `id` to it (that occurrence only, for a repeating one).
    func saveEvent(_ draft: EventDraft, id: String?) async throws -> EventFacts
    func deleteEvent(id: String) async throws

    func reminderLists() async throws -> [ReminderListFacts]
    func openReminders(listIDs: [String]?, dueBefore: Date?) async throws -> [ReminderFacts]
    func reminder(id: String) async throws -> ReminderFacts?
    func addReminder(_ draft: ReminderDraft) async throws -> ReminderFacts
    func completeReminder(id: String) async throws
    func deleteReminder(id: String) async throws

    func contacts(matching name: String) async throws -> [ContactFacts]
    func contact(id: String) async throws -> ContactFacts?
    func saveContact(_ draft: ContactDraft) async throws -> ContactFacts
}
