import Foundation

/// What Nollie on the Mac may do with one request, by fixed rules. A change is only ever worded while
/// it waits, and made only once it comes back approved with the plan this Mac worded: nothing a helper
/// sends can skip the person's yes.
public enum AppleDataGate {
    public enum Step: Equatable, Sendable {
        case read
        /// Word the change for the card. Nothing is changed.
        case prepare
        /// The person said yes to this exact plan.
        case apply(AppleDataPlan)
        case refuse(String)
        /// Nothing for the Mac to do yet.
        case wait
    }

    public static func step(_ request: AppleDataRequest, switchedOn: Bool, isPrivate: Bool, access: AppleDataAccess,
                            plan: AppleDataPlan?) -> Step {
        guard let tool = request.known else {
            return .refuse("Nollie on the Mac doesn't know that yet. Ask the person to update Nollie.")
        }
        let area = tool.area
        if isPrivate { return .refuse("Calendar, Reminders and Contacts aren't used by private bots.") }
        guard switchedOn else {
            return .refuse("\(area.title) is off for this helper. The person can turn it on in Bot settings, Apps.")
        }
        switch access {
        case .allowed: break
        case .notAsked:
            return .refuse("\(area.title) isn't allowed on the Mac yet. The person can turn it on in Bot settings, Apps, in Nollie on their Mac.")
        case .denied:
            return .refuse("The Mac doesn't let Nollie use \(area.title). The person can allow it in System Settings, Privacy & Security, \(area.title).")
        case .unavailable:
            return .refuse("\(area.title) can't be used on this Mac.")
        }
        switch request.state {
        case "waiting":
            return tool.isWrite ? .prepare : .read
        case "approved":
            guard tool.isWrite else { return .refuse("Nothing to change.") }
            guard let plan, plan.area == area else {
                return .refuse("Nollie on the Mac lost track of this change, so nothing was changed. Ask again.")
            }
            return .apply(plan)
        default:
            return .wait
        }
    }
}

/// Reads, words and makes changes against the person's own apps (`AppleDataLibrary`). Results carry
/// only what a helper needs: never addresses, notes on contacts, or anything else in a card.
public struct AppleDataWork: Sendable {
    public var library: any AppleDataLibrary
    public var time: AppleDataTime

    public static let maxEvents = 200
    public static let maxFound = 50
    public static let maxReminders = 200
    public static let maxContacts = 25
    /// The longest range a helper can look over at once.
    public static let maxDays = 400

    public init(library: any AppleDataLibrary, time: AppleDataTime) {
        self.library = library
        self.time = time
    }

    public typealias Answer = Result<[String: JSONValue], AppleDataRefusal>

    // MARK: Reads

    public func read(_ request: AppleDataRequest) async -> Answer {
        do {
            switch request.known {
            case .calendarEvents: return .success(try await events(request))
            case .calendarSearch: return .success(try await search(request))
            case .reminderLists: return .success(try await lists())
            case .remindersOpen: return .success(try await reminders(request))
            case .contactsSearch: return .success(try await contacts(request))
            default: return .failure(AppleDataRefusal("That isn't something Nollie reads."))
            }
        } catch let refusal as AppleDataRefusal {
            return .failure(refusal)
        } catch {
            return .failure(AppleDataRefusal("Nollie couldn't read that on the Mac."))
        }
    }

    private func range(_ request: AppleDataRequest, back: Int, ahead: Int) throws -> (Date, Date) {
        let start = try request.text("start").map { try moment($0, "start").date } ?? time.adding(days: -back, to: time.now)
        var end = try request.text("end").map { try moment($0, "end") }.map { $0.hasTime ? $0.date : time.adding(days: 1, to: $0.date) }
            ?? time.adding(days: ahead, to: max(start, time.now))
        if end <= start { throw AppleDataRefusal("The end is before the start.") }
        end = min(end, time.adding(days: Self.maxDays, to: start))
        return (start, end)
    }

    private func calendarIDs(named name: String?) async throws -> [String]? {
        guard let name else { return nil }
        let all = try await library.calendars()
        let found = all.filter { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
        guard !found.isEmpty else {
            throw AppleDataRefusal("There's no calendar called \(AppleDataCards.plain(name)). Calendars: \(all.map(\.title).joined(separator: ", ")).")
        }
        return found.map(\.id)
    }

    private func events(_ request: AppleDataRequest) async throws -> [String: JSONValue] {
        let (start, end) = try range(request, back: 0, ahead: 7)
        let found = try await library.events(from: start, to: end, calendarIDs: try await calendarIDs(named: request.text("calendar")))
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        return [
            "time_zone": .string(time.timeZone.identifier), "from": .string(time.iso(start)), "to": .string(time.iso(end)),
            "events": .array(found.prefix(Self.maxEvents).map(json)), "more": .number(Double(max(0, found.count - Self.maxEvents))),
        ]
    }

    private func search(_ request: AppleDataRequest) async throws -> [String: JSONValue] {
        let words = request.text("text") ?? ""
        let (start, end) = try range(request, back: 30, ahead: 365)
        let found = try await library.events(from: start, to: end, calendarIDs: nil).filter { event in
            [event.title, event.location ?? "", event.notes ?? ""].contains {
                $0.range(of: words, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        return ["time_zone": .string(time.timeZone.identifier), "events": .array(found.prefix(Self.maxFound).map(json)),
                "more": .number(Double(max(0, found.count - Self.maxFound)))]
    }

    private func lists() async throws -> [String: JSONValue] {
        let found = try await library.reminderLists()
        return ["lists": .array(found.map { list in
            .object(["name": .string(list.title), "open": .number(Double(list.open)), "usual": .bool(list.isDefault)])
        })]
    }

    private func reminders(_ request: AppleDataRequest) async throws -> [String: JSONValue] {
        var listIDs: [String]?
        if let name = request.text("list") {
            let all = try await library.reminderLists()
            let found = all.filter { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
            guard !found.isEmpty else {
                throw AppleDataRefusal("There's no list called \(AppleDataCards.plain(name)). Lists: \(all.map(\.title).joined(separator: ", ")).")
            }
            listIDs = found.map(\.id)
        }
        let before = try request.text("due_before").map { try moment($0, "due_before").date }
        let found = try await library.openReminders(listIDs: listIDs, dueBefore: before)
        return ["time_zone": .string(time.timeZone.identifier), "reminders": .array(found.prefix(Self.maxReminders).map(json)),
                "more": .number(Double(max(0, found.count - Self.maxReminders)))]
    }

    private func contacts(_ request: AppleDataRequest) async throws -> [String: JSONValue] {
        let name = request.text("name") ?? ""
        let found = try await library.contacts(matching: name)
        return ["contacts": .array(found.prefix(Self.maxContacts).map(json)),
                "more": .number(Double(max(0, found.count - Self.maxContacts)))]
    }

    // MARK: Wording a change (nothing is changed)

    public func prepare(_ request: AppleDataRequest) async -> Result<(card: String, plan: AppleDataPlan), AppleDataRefusal> {
        do {
            let plan = try await plan(request)
            return .success((AppleDataCards.card(plan, time: time), plan))
        } catch let refusal as AppleDataRefusal {
            return .failure(refusal)
        } catch {
            return .failure(AppleDataRefusal("Nollie couldn't look that up on the Mac."))
        }
    }

    func plan(_ request: AppleDataRequest) async throws -> AppleDataPlan {
        switch request.known {
        case .calendarAddEvent:
            guard request.text("title") != nil else { throw AppleDataRefusal("Send a title.") }
            let start = try moment(request.text("start") ?? "", "start")
            let allDay = request.flag("all_day") ?? !start.hasTime
            let begins = allDay ? time.startOfDay(start.date) : start.date
            let end = try request.text("end").map { try moment($0, "end") }
            let ends = try finish(begins, allDay: allDay, given: end, keeping: nil)
            let calendar = try await calendarFor(request.text("calendar"))
            return .addEvent(EventDraft(title: request.text("title") ?? "", start: begins, end: ends, allDay: allDay,
                                        calendar: calendar.title, calendarID: calendar.id, location: request.text("location"),
                                        notes: request.text("notes")))
        case .calendarChangeEvent:
            let before = try await existingEvent(request.text("event_id"))
            var after = EventDraft(before)
            if let title = request.text("title") { after.title = title }
            if let allDay = request.flag("all_day") { after.allDay = allDay }
            if let start = try request.text("start").map({ try moment($0, "start") }) {
                if after.allDay {
                    after.start = time.startOfDay(start.date)
                } else if start.hasTime {
                    after.start = start.date
                } else {
                    // A new day for a timed event keeps its time of day.
                    after.start = time.startOfDay(start.date).addingTimeInterval(before.start.timeIntervalSince(time.startOfDay(before.start)))
                }
            } else if after.allDay != before.allDay {
                after.start = after.allDay ? time.startOfDay(before.start) : time.adding(hours: 9, to: time.startOfDay(before.start))
            }
            let end = try request.text("end").map { try moment($0, "end") }
            after.end = try finish(after.start, allDay: after.allDay, given: end,
                                   keeping: end == nil ? before.end.timeIntervalSince(before.start) : nil)
            if let location = request.text("location") { after.location = location }
            if let notes = request.text("notes") { after.notes = notes }
            if let name = request.text("calendar") {
                let calendar = try await calendarFor(name)
                after.calendar = calendar.title
                after.calendarID = calendar.id
            }
            guard after != EventDraft(before) else { throw AppleDataRefusal("Nothing would change.") }
            return .changeEvent(before: before, after: after)
        case .calendarDeleteEvent:
            return .deleteEvent(try await existingEvent(request.text("event_id")))
        case .reminderAdd:
            guard request.text("title") != nil else { throw AppleDataRefusal("Send a title.") }
            let list = try await listFor(request.text("list"))
            let due = try request.text("due").map { try moment($0, "due") }
            return .addReminder(ReminderDraft(title: request.text("title") ?? "", list: list.title, listID: list.id,
                                              due: due?.date, dueHasTime: due?.hasTime ?? true, notes: request.text("notes")))
        case .reminderComplete:
            return .completeReminder(try await existingReminder(request.text("reminder_id")))
        case .reminderDelete:
            return .deleteReminder(try await existingReminder(request.text("reminder_id")))
        case .contactAdd:
            guard request.text("given_name") != nil else { throw AppleDataRefusal("Send a first name.") }
            return .addContact(ContactDraft(givenName: request.text("given_name") ?? "", familyName: request.text("family_name") ?? "",
                                            addPhones: request.text("phone").map { [$0] } ?? [],
                                            addEmails: request.text("email").map { [$0] } ?? [],
                                            birthday: try request.text("birthday").map(birthday)))
        case .contactChange:
            guard let id = request.text("contact_id"), let before = try await library.contact(id: id) else {
                throw AppleDataRefusal("There's no contact with that id. Look them up again with contacts_search.")
            }
            let phone = request.text("add_phone").flatMap { new in before.phones.contains(new) ? nil : new }
            let email = request.text("add_email").flatMap { new in before.emails.contains { $0.caseInsensitiveCompare(new) == .orderedSame } ? nil : new }
            let after = ContactDraft(id: before.id, givenName: request.text("given_name") ?? before.givenName,
                                     familyName: request.text("family_name") ?? before.familyName,
                                     addPhones: phone.map { [$0] } ?? [], addEmails: email.map { [$0] } ?? [],
                                     birthday: try request.text("birthday").map(birthday) ?? before.birthday)
            guard after.name != before.name || !after.addPhones.isEmpty || !after.addEmails.isEmpty || after.birthday != before.birthday
            else { throw AppleDataRefusal("Nothing would change.") }
            return .changeContact(before: before, after: after)
        default:
            throw AppleDataRefusal("That isn't a change Nollie makes.")
        }
    }

    private func moment(_ text: String, _ name: String) throws -> (date: Date, hasTime: Bool) {
        guard let found = time.parse(text) else {
            throw AppleDataRefusal("Send \(name) as a local time like 2026-11-04T10:00, or a date like 2026-11-04.")
        }
        return found
    }

    private func birthday(_ text: String) throws -> Birthday {
        guard let found = time.birthday(text) else { throw AppleDataRefusal("Send the birthday like 1990-11-04, or --11-04 without a year.") }
        return found
    }

    /// The end: as given, the same length as before, or an hour (a day for a whole day) after the start.
    private func finish(_ start: Date, allDay: Bool, given: (date: Date, hasTime: Bool)?, keeping length: TimeInterval?) throws -> Date {
        let end: Date
        if let given {
            // A whole day ends when the last day it covers ends.
            end = allDay ? time.adding(days: 1, to: time.startOfDay(given.date)) : given.date
        } else if let length, length > 0, !allDay {
            end = start.addingTimeInterval(length)
        } else {
            end = allDay ? time.adding(days: 1, to: start) : time.adding(hours: 1, to: start)
        }
        guard end > start else { throw AppleDataRefusal("The end is before the start.") }
        return end
    }

    private func calendarFor(_ name: String?) async throws -> CalendarFacts {
        let all = try await library.calendars().filter(\.writable)
        if let name {
            guard let found = all.first(where: { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                throw AppleDataRefusal("There's no calendar called \(AppleDataCards.plain(name)) that Nollie can add to. Calendars: \(all.map(\.title).joined(separator: ", ")).")
            }
            return found
        }
        guard let usual = all.first(where: \.isDefault) ?? all.first else { throw AppleDataRefusal("There's no calendar to add to on the Mac.") }
        return usual
    }

    private func listFor(_ name: String?) async throws -> ReminderListFacts {
        let all = try await library.reminderLists()
        if let name {
            guard let found = all.first(where: { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                throw AppleDataRefusal("There's no list called \(AppleDataCards.plain(name)). Lists: \(all.map(\.title).joined(separator: ", ")).")
            }
            return found
        }
        guard let usual = all.first(where: \.isDefault) ?? all.first else { throw AppleDataRefusal("There's no reminders list on the Mac.") }
        return usual
    }

    private func existingEvent(_ id: String?) async throws -> EventFacts {
        guard let id, let event = try await library.event(id: id) else {
            throw AppleDataRefusal("There's no event with that id. Look it up again with calendar_events.")
        }
        return event
    }

    private func existingReminder(_ id: String?) async throws -> ReminderFacts {
        guard let id, let reminder = try await library.reminder(id: id) else {
            throw AppleDataRefusal("There's no open reminder with that id. Look it up again with reminders_open.")
        }
        return reminder
    }

    // MARK: Making a change, after the yes

    /// Makes exactly the planned change. Something that changed since the card was worded is left alone.
    public func apply(_ plan: AppleDataPlan) async -> Answer {
        do {
            var answer: [String: JSONValue] = ["message": .string(AppleDataCards.done(plan, time: time))]
            switch plan {
            case let .addEvent(draft):
                answer["event"] = json(try await library.saveEvent(draft, id: nil))
            case let .changeEvent(before, after):
                try await unchanged(before)
                answer["event"] = json(try await library.saveEvent(after, id: before.id))
            case let .deleteEvent(event):
                try await unchanged(event)
                try await library.deleteEvent(id: event.id)
            case let .addReminder(draft):
                answer["reminder"] = json(try await library.addReminder(draft))
            case let .completeReminder(reminder):
                try await unchanged(reminder)
                try await library.completeReminder(id: reminder.id)
            case let .deleteReminder(reminder):
                try await unchanged(reminder)
                try await library.deleteReminder(id: reminder.id)
            case let .addContact(draft):
                answer["contact"] = json(try await library.saveContact(draft))
            case let .changeContact(before, after):
                guard try await library.contact(id: before.id) == before else { throw Self.moved }
                answer["contact"] = json(try await library.saveContact(after))
            }
            return .success(answer)
        } catch let refusal as AppleDataRefusal {
            return .failure(refusal)
        } catch {
            return .failure(AppleDataRefusal("The Mac didn't save that change."))
        }
    }

    static let moved = AppleDataRefusal("It changed on the Mac after the card was shown, so nothing was changed. Look again and ask again.")

    private func unchanged(_ event: EventFacts) async throws {
        guard try await library.event(id: event.id) == event else { throw Self.moved }
    }

    private func unchanged(_ reminder: ReminderFacts) async throws {
        guard try await library.reminder(id: reminder.id) == reminder else { throw Self.moved }
    }

    // MARK: What a helper sees

    func json(_ event: EventFacts) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(event.id), "title": .string(event.title), "calendar": .string(event.calendar),
            "start": .string(time.iso(event.start, time: !event.allDay)), "all_day": .bool(event.allDay),
        ]
        fields["end"] = .string(event.allDay ? time.iso(AppleDataCards.lastDay(event.start, event.end, time: time), time: false)
                                             : time.iso(event.end))
        if let location = event.location, !location.isEmpty { fields["location"] = .string(location) }
        if event.repeats { fields["repeats"] = .bool(true) }
        return .object(fields)
    }

    func json(_ reminder: ReminderFacts) -> JSONValue {
        var fields: [String: JSONValue] = ["id": .string(reminder.id), "title": .string(reminder.title), "list": .string(reminder.list)]
        if let due = reminder.due { fields["due"] = .string(time.iso(due, time: reminder.dueHasTime)) }
        if let notes = reminder.notes, !notes.isEmpty { fields["notes"] = .string(String(notes.prefix(500))) }
        return .object(fields)
    }

    /// Name, phone numbers, email addresses and birthday. Nothing else from a contact.
    func json(_ contact: ContactFacts) -> JSONValue {
        var fields: [String: JSONValue] = ["id": .string(contact.id), "name": .string(contact.name),
                                           "phones": .array(contact.phones.map(JSONValue.string)),
                                           "emails": .array(contact.emails.map(JSONValue.string))]
        if let birthday = contact.birthday { fields["birthday"] = .string(time.birthdayISO(birthday)) }
        return .object(fields)
    }
}
