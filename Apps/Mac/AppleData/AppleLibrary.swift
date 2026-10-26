@preconcurrency import Contacts
@preconcurrency import EventKit
import Foundation
import NollieCore

/// The person's calendars and reminders (EventKit) and contacts (Contacts), read and changed by
/// Nollie itself, so macOS names Nollie when it asks. Nothing here asks: `access` only reads, and
/// `request` is called by the switch in Bot settings and nowhere else.
final class AppleLibrary: AppleDataLibrary, @unchecked Sendable {
    private let lock = NSLock()
    private var eventStore: EKEventStore?
    private var storeAccess: [AppleDataAccess] = []

    // MARK: Permissions

    func access(_ area: AppleDataArea) -> AppleDataAccess {
        switch area {
        case .calendar: Self.map(EKEventStore.authorizationStatus(for: .event))
        case .reminders: Self.map(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts: Self.map(CNContactStore.authorizationStatus(for: .contacts))
        }
    }

    /// The system prompt, from the switch only. True when it is allowed afterwards.
    static func request(_ area: AppleDataArea) async -> AppleDataAccess {
        switch area {
        case .calendar: _ = try? await EKEventStore().requestFullAccessToEvents()
        case .reminders: _ = try? await EKEventStore().requestFullAccessToReminders()
        case .contacts: _ = try? await CNContactStore().requestAccess(for: .contacts)
        }
        return AppleLibrary().access(area)
    }

    static func map(_ status: EKAuthorizationStatus) -> AppleDataAccess {
        switch status {
        case .fullAccess: .allowed
        case .notDetermined: .notAsked
        case .restricted: .unavailable
        // Add-only access can't read the calendar: Settings is where it becomes full access.
        case .denied, .writeOnly: .denied
        @unknown default: .denied
        }
    }

    static func map(_ status: CNAuthorizationStatus) -> AppleDataAccess {
        switch status {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        case .restricted: .unavailable
        default: .denied
        }
    }

    /// One store, made again when the permissions change, so a yes given since is seen.
    private func store() throws -> EKEventStore {
        try lock.withLock {
            let now = [access(.calendar), access(.reminders)]
            if let eventStore, now == storeAccess { return eventStore }
            guard now.contains(.allowed) else { throw AppleDataRefusal("Nollie isn't allowed to use this on the Mac.") }
            let made = EKEventStore()
            eventStore = made
            storeAccess = now
            return made
        }
    }

    // MARK: Calendar

    func calendars() async throws -> [CalendarFacts] {
        let store = try store()
        let usual = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event).map {
            CalendarFacts(id: $0.calendarIdentifier, title: $0.title, isDefault: $0.calendarIdentifier == usual,
                          writable: $0.allowsContentModifications)
        }
    }

    func events(from start: Date, to end: Date, calendarIDs: [String]?) async throws -> [EventFacts] {
        let store = try store()
        let calendars = calendarIDs.map { ids in store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) } }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map(Self.facts)
    }

    /// `<id>#<seconds>` names one time of a repeating event; a plain id names a single event.
    static func eventID(_ event: EKEvent) -> String {
        let id = event.eventIdentifier ?? event.calendarItemIdentifier
        return event.hasRecurrenceRules ? "\(id)#\(Int((event.occurrenceDate ?? event.startDate).timeIntervalSince1970))" : id
    }

    private func find(_ id: String, in store: EKEventStore) -> EKEvent? {
        if let mark = id.lastIndex(of: "#"), let seconds = Double(id[id.index(after: mark)...]) {
            let base = String(id[..<mark])
            let when = Date(timeIntervalSince1970: seconds)
            let predicate = store.predicateForEvents(withStart: when.addingTimeInterval(-86_400 * 2),
                                                     end: when.addingTimeInterval(86_400 * 2), calendars: nil)
            return store.events(matching: predicate).first {
                $0.eventIdentifier == base && Int(($0.occurrenceDate ?? $0.startDate).timeIntervalSince1970) == Int(seconds)
            }
        }
        return store.event(withIdentifier: id)
    }

    func event(id: String) async throws -> EventFacts? {
        let store = try store()
        return find(id, in: store).map(Self.facts)
    }

    func saveEvent(_ draft: EventDraft, id: String?) async throws -> EventFacts {
        let store = try store()
        let event: EKEvent
        if let id {
            guard let found = find(id, in: store) else { throw AppleDataRefusal("That event is no longer on the Mac.") }
            event = found
        } else {
            event = EKEvent(eventStore: store)
        }
        guard let calendar = store.calendar(withIdentifier: draft.calendarID), calendar.allowsContentModifications else {
            throw AppleDataRefusal("Nollie can't add to that calendar.")
        }
        event.calendar = calendar
        event.title = draft.title
        event.isAllDay = draft.allDay
        event.startDate = draft.start
        // A whole day ends as its last day does: EventKit wants a moment inside that day.
        event.endDate = draft.allDay ? max(draft.start, draft.end.addingTimeInterval(-1)) : draft.end
        event.location = draft.location
        event.notes = draft.notes
        try store.save(event, span: .thisEvent, commit: true)
        return Self.facts(event)
    }

    func deleteEvent(id: String) async throws {
        let store = try store()
        guard let event = find(id, in: store) else { throw AppleDataRefusal("That event is no longer on the Mac.") }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    static func facts(_ event: EKEvent) -> EventFacts {
        EventFacts(id: eventID(event), title: event.title ?? "", start: event.startDate, end: event.endDate,
                   allDay: event.isAllDay, calendar: event.calendar?.title ?? "", calendarID: event.calendar?.calendarIdentifier ?? "",
                   location: event.location.flatMap { $0.isEmpty ? nil : $0 }, notes: event.notes.flatMap { $0.isEmpty ? nil : $0 },
                   repeats: event.hasRecurrenceRules)
    }

    // MARK: Reminders

    private func incomplete(_ store: EKEventStore, calendars: [EKCalendar]?, dueBefore: Date? = nil) async -> [ReminderFacts] {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: dueBefore, calendars: calendars)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: (found ?? []).map(Self.facts))
            }
        }
    }

    func reminderLists() async throws -> [ReminderListFacts] {
        let store = try store()
        let lists = store.calendars(for: .reminder)
        let open = await incomplete(store, calendars: lists)
        let usual = store.defaultCalendarForNewReminders()?.calendarIdentifier
        return lists.map { list in
            ReminderListFacts(id: list.calendarIdentifier, title: list.title, isDefault: list.calendarIdentifier == usual,
                              open: open.filter { $0.list == list.title }.count)
        }
    }

    func openReminders(listIDs: [String]?, dueBefore: Date?) async throws -> [ReminderFacts] {
        let store = try store()
        let lists = listIDs.map { ids in store.calendars(for: .reminder).filter { ids.contains($0.calendarIdentifier) } }
        return await incomplete(store, calendars: lists, dueBefore: dueBefore)
    }

    func reminder(id: String) async throws -> ReminderFacts? {
        let store = try store()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder, !reminder.isCompleted else { return nil }
        return Self.facts(reminder)
    }

    func addReminder(_ draft: ReminderDraft) async throws -> ReminderFacts {
        let store = try store()
        guard let list = store.calendar(withIdentifier: draft.listID) else { throw AppleDataRefusal("That list is no longer on the Mac.") }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = draft.title
        reminder.notes = draft.notes
        if let due = draft.due {
            var units: Set<Calendar.Component> = [.year, .month, .day]
            if draft.dueHasTime { units.formUnion([.hour, .minute]) }
            reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due)
        }
        try store.save(reminder, commit: true)
        return Self.facts(reminder)
    }

    func completeReminder(id: String) async throws {
        let store = try store()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw AppleDataRefusal("That reminder is no longer on the Mac.") }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }

    func deleteReminder(id: String) async throws {
        let store = try store()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw AppleDataRefusal("That reminder is no longer on the Mac.") }
        try store.remove(reminder, commit: true)
    }

    static func facts(_ reminder: EKReminder) -> ReminderFacts {
        let parts = reminder.dueDateComponents
        let due = parts.flatMap { ($0.calendar ?? Calendar.current).date(from: $0) }
        return ReminderFacts(id: reminder.calendarItemIdentifier, title: reminder.title ?? "", list: reminder.calendar?.title ?? "",
                             due: due, dueHasTime: parts?.hour != nil, notes: reminder.notes.flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: Contacts

    /// Only these are ever read from a contact.
    private static let keys: [CNKeyDescriptor] = [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey,
                                                   CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
                                                   CNContactBirthdayKey].map { $0 as CNKeyDescriptor }

    private func contactStore() throws -> CNContactStore {
        guard access(.contacts) == .allowed else { throw AppleDataRefusal("Nollie isn't allowed to use Contacts on the Mac.") }
        return CNContactStore()
    }

    func contacts(matching name: String) async throws -> [ContactFacts] {
        let store = try contactStore()
        return try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: Self.keys)
            .map(Self.facts)
    }

    func contact(id: String) async throws -> ContactFacts? {
        let store = try contactStore()
        return (try? store.unifiedContact(withIdentifier: id, keysToFetch: Self.keys)).map(Self.facts)
    }

    func saveContact(_ draft: ContactDraft) async throws -> ContactFacts {
        let store = try contactStore()
        let request = CNSaveRequest()
        let contact: CNMutableContact
        if let id = draft.id {
            guard let found = try? store.unifiedContact(withIdentifier: id, keysToFetch: Self.keys),
                  let copy = found.mutableCopy() as? CNMutableContact else { throw AppleDataRefusal("That contact is no longer on the Mac.") }
            contact = copy
            request.update(contact)
        } else {
            contact = CNMutableContact()
            request.add(contact, toContainerWithIdentifier: nil)
        }
        contact.givenName = draft.givenName
        contact.familyName = draft.familyName
        contact.phoneNumbers += draft.addPhones.map { CNLabeledValue(label: CNLabelOther, value: CNPhoneNumber(stringValue: $0)) }
        contact.emailAddresses += draft.addEmails.map { CNLabeledValue(label: CNLabelOther, value: $0 as NSString) }
        if let birthday = draft.birthday {
            contact.birthday = DateComponents(year: birthday.year, month: birthday.month, day: birthday.day)
        }
        try store.execute(request)
        return Self.facts(contact)
    }

    static func facts(_ contact: CNContact) -> ContactFacts {
        let birthday = contact.birthday.flatMap { parts in
            parts.month.flatMap { month in parts.day.map { Birthday(year: parts.year, month: month, day: $0) } }
        }
        return ContactFacts(id: contact.identifier, givenName: contact.givenName, familyName: contact.familyName,
                            phones: contact.phoneNumbers.map(\.value.stringValue), emails: contact.emailAddresses.map { $0.value as String },
                            birthday: birthday)
    }
}
