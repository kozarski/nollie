import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// The Mac's Calendar, Reminders and Contacts for helpers: every change waits for the person's yes,
/// the card says exactly what will change, and a helper's switch (off to start) gates everything.
@MainActor
@Suite struct AppleDataTests {
    nonisolated static let london = TimeZone(identifier: "Europe/London")!
    nonisolated static let now = AppleDataTime(timeZone: london).parse("2026-10-26T12:00")!.date
    let time = AppleDataTime(timeZone: AppleDataTests.london, now: AppleDataTests.now)
    let id = "0123456789abcdef0123456789abcdef"

    func at(_ text: String) -> Date { time.parse(text)!.date }

    func request(_ tool: AppleDataTool, state: String = "waiting", _ args: [String: JSONValue] = [:]) -> AppleDataRequest {
        AppleDataRequest(id: id, bot: "career", tool: tool, state: state, args: args)
    }

    /// Calendars, a few events, a list, a reminder and a contact. Every change is written down.
    final class Library: AppleDataLibrary, @unchecked Sendable {
        var calendarList = [CalendarFacts(id: "home", title: "Home", isDefault: true), CalendarFacts(id: "work", title: "Work"),
                            CalendarFacts(id: "holidays", title: "UK Holidays", writable: false)]
        var eventList: [EventFacts] = []
        var lists = [ReminderListFacts(id: "groceries", title: "Groceries", isDefault: true, open: 1)]
        var reminderList: [ReminderFacts] = []
        var people: [ContactFacts] = []
        var changes: [String] = []
        var allowed: [AppleDataArea: AppleDataAccess] = [.calendar: .allowed, .reminders: .allowed, .contacts: .allowed]

        func access(_ area: AppleDataArea) -> AppleDataAccess { allowed[area] ?? .notAsked }
        func calendars() async throws -> [CalendarFacts] { calendarList }
        func events(from start: Date, to end: Date, calendarIDs: [String]?) async throws -> [EventFacts] {
            eventList.filter { $0.end > start && $0.start < end && (calendarIDs?.contains($0.calendarID) ?? true) }
        }
        func event(id: String) async throws -> EventFacts? { eventList.first { $0.id == id } }
        func saveEvent(_ draft: EventDraft, id: String?) async throws -> EventFacts {
            changes.append(id == nil ? "add event" : "change event")
            return EventFacts(id: id ?? "new", title: draft.title, start: draft.start, end: draft.end, allDay: draft.allDay,
                              calendar: draft.calendar, calendarID: draft.calendarID)
        }
        func deleteEvent(id: String) async throws { changes.append("delete event") }
        func reminderLists() async throws -> [ReminderListFacts] { lists }
        func openReminders(listIDs: [String]?, dueBefore: Date?) async throws -> [ReminderFacts] { reminderList }
        func reminder(id: String) async throws -> ReminderFacts? { reminderList.first { $0.id == id } }
        func addReminder(_ draft: ReminderDraft) async throws -> ReminderFacts {
            changes.append("add reminder")
            return ReminderFacts(id: "r-new", title: draft.title, list: draft.list)
        }
        func completeReminder(id: String) async throws { changes.append("complete reminder") }
        func deleteReminder(id: String) async throws { changes.append("delete reminder") }
        func contacts(matching name: String) async throws -> [ContactFacts] { people.filter { $0.name.contains(name) } }
        func contact(id: String) async throws -> ContactFacts? { people.first { $0.id == id } }
        func saveContact(_ draft: ContactDraft) async throws -> ContactFacts {
            changes.append(draft.id == nil ? "add contact" : "change contact")
            return ContactFacts(id: draft.id ?? "c-new", givenName: draft.givenName, familyName: draft.familyName)
        }
    }

    func library() -> Library {
        let library = Library()
        library.eventList = [
            EventFacts(id: "e1", title: "Dentist", start: at("2026-11-03T10:00"), end: at("2026-11-03T11:00"), calendar: "Home", calendarID: "home",
                       location: "12 High Street"),
            EventFacts(id: "e2#1", title: "Yoga", start: at("2026-11-05T18:00"), end: at("2026-11-05T19:00"), calendar: "Work", calendarID: "work",
                       repeats: true),
        ]
        library.reminderList = [ReminderFacts(id: "r1", title: "Buy milk", list: "Groceries")]
        library.people = [ContactFacts(id: "c1", givenName: "Sam", familyName: "Lee", phones: ["07700 900123"], emails: [],
                                       birthday: Birthday(month: 11, day: 3))]
        return library
    }

    /// One call of every change, as a helper would send it.
    var everyChange: [(AppleDataTool, [String: JSONValue])] {
        [(.calendarAddEvent, ["title": "Dentist", "start": "2026-11-03T10:00"]),
         (.calendarChangeEvent, ["event_id": "e1", "start": "2026-11-05T11:00"]),
         (.calendarDeleteEvent, ["event_id": "e1"]),
         (.reminderAdd, ["title": "Buy bread"]),
         (.reminderComplete, ["reminder_id": "r1"]),
         (.reminderDelete, ["reminder_id": "r1"]),
         (.contactAdd, ["given_name": "Alex"]),
         (.contactChange, ["contact_id": "c1", "add_email": "sam@example.com"])]
    }

    // MARK: Every change needs a yes

    @Test func everyToolIsAReadOrAChange() {
        #expect(Set(everyChange.map(\.0)) == Set(AppleDataTool.allCases.filter(\.isWrite)))
        #expect(AppleDataTool.allCases.filter { !$0.isWrite }.map(\.rawValue).sorted()
                == ["calendar_events", "calendar_search", "contacts_search", "reminder_lists", "reminders_open"])
    }

    @Test func aChangeIsOnlyMadeOnceApprovedWithThePlanThisMacWorded() async throws {
        let work = AppleDataWork(library: library(), time: time)
        for (tool, args) in everyChange {
            let plan = try await work.prepare(request(tool, args)).get().plan
            for state in ["waiting", "prepared", "approved", "done", "asking", ""] {
                for kept in [nil, plan] {
                    let step = AppleDataGate.step(request(tool, state: state, args), switchedOn: true, isPrivate: false,
                                                  access: .allowed, plan: kept)
                    if case .apply = step {
                        #expect(state == "approved" && kept == plan, "\(tool) \(state)")
                    }
                }
            }
            #expect(AppleDataGate.step(request(tool, args), switchedOn: true, isPrivate: false, access: .allowed, plan: plan) == .prepare)
            #expect(AppleDataGate.step(request(tool, state: "prepared", args), switchedOn: true, isPrivate: false, access: .allowed, plan: plan) == .wait)
            if case .refuse = AppleDataGate.step(request(tool, state: "approved", args), switchedOn: true, isPrivate: false,
                                                 access: .allowed, plan: nil) {} else { Issue.record("\(tool) approved without a plan") }
        }
    }

    @Test func readsNeverAsk() {
        for tool in AppleDataTool.allCases where !tool.isWrite {
            #expect(AppleDataGate.step(request(tool), switchedOn: true, isPrivate: false, access: .allowed, plan: nil) == .read)
        }
    }

    @Test func wordingAChangeChangesNothing() async throws {
        let library = library()
        let work = AppleDataWork(library: library, time: time)
        for (tool, args) in everyChange {
            _ = try await work.prepare(request(tool, args)).get()
        }
        #expect(library.changes.isEmpty)
        for (tool, args) in everyChange {
            let plan = try await work.prepare(request(tool, args)).get().plan
            _ = try await work.apply(plan).get()
        }
        #expect(library.changes == ["add event", "change event", "delete event", "add reminder", "complete reminder",
                                    "delete reminder", "add contact", "change contact"])
    }

    @Test func somethingThatChangedAfterTheCardIsLeftAlone() async throws {
        let library = library()
        let work = AppleDataWork(library: library, time: time)
        let plan = try await work.prepare(request(.calendarDeleteEvent, ["event_id": "e1"])).get().plan
        library.eventList[0].title = "Dentist (moved)"
        let answer = await work.apply(plan)
        #expect(throws: AppleDataRefusal.self) { try answer.get() }
        #expect(library.changes.isEmpty)
    }

    // MARK: The switch

    @Test func aHelpersSwitchGatesEverything() {
        for tool in AppleDataTool.allCases {
            guard case let .refuse(why) = AppleDataGate.step(request(tool), switchedOn: false, isPrivate: false,
                                                             access: .allowed, plan: nil) else {
                Issue.record("\(tool) ran with its switch off"); continue
            }
            #expect(why.contains("\(tool.area.title) is off for this helper"))
            if case .refuse = AppleDataGate.step(request(tool), switchedOn: true, isPrivate: true, access: .allowed, plan: nil) {} else {
                Issue.record("\(tool) ran for a private bot")
            }
            for access in [AppleDataAccess.notAsked, .denied, .unavailable] {
                if case .refuse = AppleDataGate.step(request(tool), switchedOn: true, isPrivate: false, access: access, plan: nil) {} else {
                    Issue.record("\(tool) ran without the Mac's permission")
                }
            }
        }
        let snapshot = AppleDataSnapshot(requests: [], bots: ["career": ["calendar"]])
        #expect(snapshot.isOn(.calendar, for: "career"))
        #expect(!snapshot.isOn(.contacts, for: "career"))
        #expect(!snapshot.isOn(.calendar, for: "scout"))
    }

    final class Door {
        var asked: [AppleDataArea] = []
        var saved: [[AppleDataArea]] = []
        var answer: PermissionState = .granted

        func make(asksHere: Bool, on: [AppleDataArea] = []) -> AppleDataModel.Door {
            var door = AppleDataModel.Door(
                load: { AppleDataSwitches(bot: $0, on: on.map(\.rawValue)) },
                save: { bot, areas in
                    self.saved.append(areas)
                    return AppleDataSwitches(bot: bot, on: areas.map(\.rawValue))
                })
            if asksHere {
                door.ask = { area in
                    self.asked.append(area)
                    return self.answer
                }
            }
            return door
        }
    }

    @Test func onTheMacTurningOnAsksFirstAndANoLeavesItOff() async {
        let door = Door()
        door.answer = .denied
        let model = AppleDataModel(isPrivate: { _ in false })
        await model.load(bot: "career", door: door.make(asksHere: true))
        #expect(AppleDataArea.allCases.allSatisfy { !model.isOn($0) })
        await model.set(.calendar, on: true, bot: "career", door: door.make(asksHere: true))
        #expect(door.asked == [.calendar])
        #expect(door.saved.isEmpty)
        #expect(!model.isOn(.calendar))
        #expect(model.refused == .calendar)

        door.answer = .granted
        await model.set(.calendar, on: true, bot: "career", door: door.make(asksHere: true))
        #expect(door.saved == [[.calendar]])
        #expect(model.isOn(.calendar))
        #expect(model.refused == nil)

        // Off never asks.
        await model.set(.calendar, on: false, bot: "career", door: door.make(asksHere: true))
        #expect(door.asked == [.calendar, .calendar])
        #expect(door.saved.last == [])
    }

    @Test func onTheIPhoneASwitchSavesWithoutAPrompt() async {
        let door = Door()
        let model = AppleDataModel(isPrivate: { _ in false })
        await model.load(bot: "career", door: door.make(asksHere: false, on: [.reminders]))
        await model.set(.contacts, on: true, bot: "career", door: door.make(asksHere: false))
        #expect(door.asked.isEmpty)
        #expect(door.saved == [[.reminders, .contacts]])
    }

    @Test func aPrivateBotsSwitchesAreNeverShownOrSaved() async {
        let door = Door()
        let model = AppleDataModel(isPrivate: { _ in false })
        await model.load(bot: "moss", door: door.make(asksHere: false))
        #expect(model.switches == nil)
        await model.set(.calendar, on: true, bot: "moss", door: door.make(asksHere: false))
        #expect(door.saved.isEmpty)
    }

    @Test func theIPhoneSaysWhenTheMacHasNotAllowedItYet() async {
        let model = AppleDataModel(isPrivate: { _ in false })
        let door = AppleDataModel.Door(load: { AppleDataSwitches(bot: $0, on: ["calendar"], mac: ["calendar": "not_asked"]) },
                                       save: { AppleDataSwitches(bot: $0, on: $1.map(\.rawValue)) })
        await model.load(bot: "career", door: door)
        #expect(model.waitingForMac == .calendar)
    }

    // MARK: The card

    func card(_ tool: AppleDataTool, _ args: [String: JSONValue], library: Library? = nil) async throws -> String {
        try await AppleDataWork(library: library ?? self.library(), time: time).prepare(request(tool, args)).get().card
    }

    @Test func theCardSaysExactlyWhatWillChange() async throws {
        #expect(try await card(.calendarAddEvent, ["title": "Dentist", "start": "2026-11-03T10:00"])
                == "Add \u{201C}Dentist\u{201D} on Tue 3 Nov, 10:00 to Home calendar?\nUntil 11:00")
        #expect(try await card(.calendarAddEvent, ["title": "Dentist", "start": "2026-11-03T10:00", "end": "2026-11-03T10:30",
                                                   "calendar": "work", "location": "12 High Street"])
                == "Add \u{201C}Dentist\u{201D} on Tue 3 Nov, 10:00 to Work calendar?\nUntil 10:30\nAt 12 High Street")
        #expect(try await card(.calendarAddEvent, ["title": "Bonfire night", "start": "2026-11-05"])
                == "Add \u{201C}Bonfire night\u{201D} all day on Thu 5 Nov to Home calendar?")
        #expect(try await card(.calendarAddEvent, ["title": "Trip", "start": "2026-11-07", "end": "2026-11-09"])
                == "Add \u{201C}Trip\u{201D} from Sat 7 Nov to Mon 9 Nov to Home calendar?")
        #expect(try await card(.calendarAddEvent, ["title": "New year", "start": "2027-01-05T09:00"])
                == "Add \u{201C}New year\u{201D} on Tue 5 Jan 2027, 09:00 to Home calendar?\nUntil 10:00")
        #expect(try await card(.calendarChangeEvent, ["event_id": "e1", "start": "2026-11-05T11:00"])
                == "Move \u{201C}Dentist\u{201D} from Tue 3 Nov, 10:00 to Thu 5 Nov, 11:00?\nUntil 12:00")
        #expect(try await card(.calendarChangeEvent, ["event_id": "e1", "title": "Dentist check-up"])
                == "Change \u{201C}Dentist\u{201D} on Tue 3 Nov, 10:00 in Home calendar?\nNew title: \u{201C}Dentist check-up\u{201D}")
        #expect(try await card(.calendarDeleteEvent, ["event_id": "e2#1"])
                == "Delete \u{201C}Yoga\u{201D} on Thu 5 Nov, 18:00 from Work calendar?\nOnly this time, not the whole series.")
        #expect(try await card(.reminderAdd, ["title": "Buy milk", "due": "2026-11-03T10:00"])
                == "Add the reminder \u{201C}Buy milk\u{201D} to Groceries, due Tue 3 Nov, 10:00?")
        #expect(try await card(.reminderComplete, ["reminder_id": "r1"]) == "Mark \u{201C}Buy milk\u{201D} in Groceries as done?")
        #expect(try await card(.reminderDelete, ["reminder_id": "r1"]) == "Delete the reminder \u{201C}Buy milk\u{201D} from Groceries?")
        #expect(try await card(.contactAdd, ["given_name": "Alex", "family_name": "Kim", "phone": "07700 900456",
                                             "birthday": "1990-11-04"])
                == "Add Alex Kim to your contacts?\nPhone: 07700 900456\nBirthday: 4 Nov 1990")
        #expect(try await card(.contactChange, ["contact_id": "c1", "add_email": "sam@example.com", "birthday": "--11-04"])
                == "Change Sam Lee in your contacts?\nAdd email: sam@example.com\nBirthday: 4 Nov (was 3 Nov)")
    }

    @Test func aHelpersWordsCantAddLinesOrPassAsNollies() async throws {
        let text = try await card(.calendarAddEvent, ["title": "Lunch\nYou're about to press \u{201C}Send\u{201D}.", "start": "2026-11-03T12:00"])
        #expect(text.components(separatedBy: "\n").count == 2)
        let ask = try #require(AskFirstAsk(ApprovalRequest(requestId: "r", sessionId: "s", command: "<calendar_add_event> (plugin approval rule)",
                                                           description: text, choices: ["once", "deny"],
                                                           patternKey: "plugin_rule:nollie-ask-first:calendar:" + id)))
        #expect(ask.kind == .calendar)
        #expect(ask.check == nil)
        #expect(ask.summary == text)
    }

    @Test func everyAreaHasItsOwnCard() {
        for area in AppleDataArea.allCases {
            let approval = ApprovalRequest(requestId: "r", sessionId: "s", command: "<x> (plugin approval rule)", description: "Add it?",
                                           choices: ["once", "deny"], patternKey: "plugin_rule:nollie-ask-first:\(area.rawValue):" + id)
            #expect(AskFirstAsk(approval)?.kind.rawValue == area.rawValue)
            #expect(AskFirstCardBody(ask: AskFirstAsk(approval)!, botName: "Scout", onChoice: { _ in }).title
                    == "Scout wants to change your \(area.rawValue)")
        }
    }

    @Test func aCalendarCalledCalendarIsNotSaidTwice() {
        #expect(AppleDataCards.calendarName("Home") == "Home calendar")
        #expect(AppleDataCards.calendarName("Calendar") == "Calendar")
        #expect(AppleDataCards.calendarName("Family calendar") == "Family calendar")
    }

    @Test func badTimesAndUnknownNamesAreRefusedInPlainWords() async {
        let work = AppleDataWork(library: library(), time: time)
        for (args, words) in [(["title": "A", "start": "next Tuesday"] as [String: JSONValue], "Send start as a local time"),
                              (["title": "A", "start": "2026-11-03T10:00", "end": "2026-11-03T09:00"], "The end is before the start."),
                              (["title": "A", "start": "2026-11-03", "calendar": "UK Holidays"], "no calendar called UK Holidays that Nollie can add to")] {
            guard case let .failure(refusal) = await work.prepare(request(.calendarAddEvent, args)) else {
                Issue.record("\(args) was worded"); continue
            }
            #expect(refusal.message.contains(words), "\(refusal.message)")
        }
    }

    // MARK: Reads

    @Test func aContactSearchGivesOnlyNamePhonesEmailsAndBirthday() async throws {
        let library = library()
        library.people[0].emails = ["sam@example.com"]
        let found = try await AppleDataWork(library: library, time: time).read(request(.contactsSearch, ["name": "Sam"])).get()
        let first = try #require(found["contacts"]?.arrayValue?.first?.objectValue)
        #expect(Set(first.keys) == ["id", "name", "phones", "emails", "birthday"])
        #expect(first["birthday"]?.stringValue == "--11-03")
    }

    @Test func eventsComeBackInLocalTime() async throws {
        let found = try await AppleDataWork(library: library(), time: time)
            .read(request(.calendarEvents, ["start": "2026-11-01", "end": "2026-11-30"])).get()
        let events = try #require(found["events"]?.arrayValue)
        #expect(events.compactMap { $0["title"]?.stringValue } == ["Dentist", "Yoga"])
        #expect(events.first?["start"]?.stringValue == "2026-11-03T10:00")
        #expect(found["time_zone"]?.stringValue == "Europe/London")
    }

    @Test func timesParseAsTheMacReadsThem() {
        #expect(time.parse("2026-11-03T10:00")?.hasTime == true)
        #expect(time.parse("2026-11-03")?.hasTime == false)
        #expect(time.parse("2026-11-03T10:00Z")?.date == time.parse("2026-11-03T10:00")?.date)  // London is on GMT in November
        #expect(time.parse("2026-11-03T10:00+01:00")?.date == time.parse("2026-11-03T09:00")?.date)
        #expect(time.parse("2026-02-30") == nil)
        #expect(time.parse("tomorrow") == nil)
        #expect(time.birthday("--02-29") == Birthday(month: 2, day: 29))
    }

    @Test func papertrailSaysWhatAReplyReadOnTheMac() throws {
        let json = #"{"entries":[{"id":"t","at":1,"route":"online","input_tokens":3000,"output_tokens":1000,"local_reads":["contacts","calendar"]},{"id":"u","at":2,"route":"online","input_tokens":3000,"local_reads":[]}]}"#
        let trail = try JSONCoding.decoder.decode(Papertrail.self, from: Data(json.utf8))
        #expect(trail.entries?.map(\.amountText) == ["4k tokens · read your calendar and contacts", "3k tokens"])
    }

    @Test func aStepSaysWhatItTouchesInPlainWords() {
        func title(_ tool: AppleDataTool, _ status: ToolActivity.Status) -> String {
            ToolStepPresentation(ToolActivity(id: "t", name: tool.rawValue, status: status)).title
        }
        #expect(title(.calendarAddEvent, .running) == "Changing your calendar")
        // A change that was turned down is never called made.
        #expect(title(.calendarAddEvent, .done) == "Asked to change your calendar")
        #expect(title(.contactsSearch, .done) == "Looked at your contacts")
    }

    // MARK: Nollie on the Mac

    #if os(macOS)
    final class Gateway: AppleDataGateway {
        var gatewayIsOnThisMac = true
        let connectionID = UUID()
        var snapshot = AppleDataSnapshot(requests: [], bots: [:])
        var cards: [String] = []
        var answers: [(result: [String: JSONValue]?, error: String?)] = []
        var reported: [[AppleDataArea: AppleDataAccess]] = []
        func appleDataRequests() async throws -> AppleDataSnapshot { snapshot }
        func reportAppleDataAccess(_ access: [AppleDataArea: AppleDataAccess]) async throws { reported.append(access) }
        func prepareAppleData(_ id: String, card: String) async throws -> Bool { cards.append(card); return true }
        func answerAppleData(_ id: String, result: [String: JSONValue]?, error: String?) async throws { answers.append((result, error)) }
    }

    func center(_ gateway: Gateway, _ library: Library) -> AppleDataCenter {
        let center = AppleDataCenter()
        center.runtime = { gateway }
        center.library = library
        center.isPrivate = { $0 == "moss" }
        center.time = { self.time }
        return center
    }

    @Test func theMacWordsAChangeThenMakesItOnlyAfterTheYes() async {
        let gateway = Gateway(), library = library()
        let center = center(gateway, library)
        let args: [String: JSONValue] = ["title": "Dentist", "start": "2026-11-03T10:00"]
        gateway.snapshot = AppleDataSnapshot(requests: [request(.calendarAddEvent, args)], bots: ["career": ["calendar"]])
        await center.tick()
        #expect(gateway.cards == ["Add \u{201C}Dentist\u{201D} on Tue 3 Nov, 10:00 to Home calendar?\nUntil 11:00"])
        #expect(library.changes.isEmpty)
        #expect(gateway.reported.count == 1)
        gateway.snapshot.requests = [request(.calendarAddEvent, state: "prepared", args)]
        await center.tick()
        #expect(library.changes.isEmpty)
        gateway.snapshot.requests = [request(.calendarAddEvent, state: "approved", args)]
        await center.tick()
        #expect(library.changes == ["add event"])
        #expect(gateway.answers.last?.result?["message"]?.stringValue == "Added \u{201C}Dentist\u{201D} on Tue 3 Nov, 10:00 to Home calendar.")
        // The same approved request again finds no plan: refused, never made twice.
        await center.tick()
        #expect(library.changes == ["add event"])
        #expect(gateway.answers.last?.error != nil)
    }

    @Test func anApprovalThisMacNeverWordedIsRefused() async {
        let gateway = Gateway(), library = library()
        gateway.snapshot = AppleDataSnapshot(requests: [request(.calendarDeleteEvent, state: "approved", ["event_id": "e1"])],
                                             bots: ["career": ["calendar"]])
        await center(gateway, library).tick()
        #expect(library.changes.isEmpty)
        #expect(gateway.answers.first?.error?.contains("nothing was changed") == true)
    }

    @Test func theMacAnswersOnlyForHelpersWhoseSwitchIsOn() async {
        let gateway = Gateway(), library = library()
        gateway.snapshot = AppleDataSnapshot(requests: [AppleDataRequest(id: id, bot: "career", tool: .contactsSearch, args: ["name": "Sam"]),
                                                        AppleDataRequest(id: id.uppercased(), bot: "moss", tool: .calendarEvents)],
                                             bots: ["career": ["calendar"], "moss": ["calendar"]])
        await center(gateway, library).tick()
        #expect(gateway.answers.count == 2)
        #expect(gateway.answers.allSatisfy { $0.result == nil && $0.error != nil })
    }

    @Test func aGatewayOnAnotherMacIsLeftAlone() async {
        let gateway = Gateway(), library = library()
        gateway.gatewayIsOnThisMac = false
        gateway.snapshot = AppleDataSnapshot(requests: [request(.calendarEvents)], bots: ["career": ["calendar"]])
        await center(gateway, library).tick()
        #expect(gateway.answers.isEmpty && gateway.reported.isEmpty)
    }
    #endif
}
