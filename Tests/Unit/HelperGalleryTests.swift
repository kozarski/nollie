import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import Nollie
@testable import NollieCore

/// The ready-made helpers and the gallery that adds them.
struct ReadyMadeHelperTests {
    private let helpers = ReadyMadeHelper.gallery

    /// The crew add-on's profile name for a display name: lowercase, other characters become a dash.
    private func profileName(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            let piece: Character = (ch.isLetter || ch.isNumber) ? ch : "-"
            if piece == "-", out.last == "-" { continue }
            out.append(piece)
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    @Test func aGalleryInAFewCalmSections() {
        #expect((8...12).contains(helpers.count))
        #expect(Set(helpers.map(\.id)).count == helpers.count)
        // Every section has a few, and the gallery reads section by section.
        #expect(ReadyMadeHelper.sections == ReadyMadeHelper.Section.allCases)
        for section in ReadyMadeHelper.sections {
            #expect((2...4).contains(ReadyMadeHelper.helpers(in: section).count), "\(section.title)")
        }
        #expect(ReadyMadeHelper.sections.flatMap(ReadyMadeHelper.helpers(in:)) == helpers)
    }

    /// Ask first holds these by fixed rules whatever a helper reads. Its own words still say so
    /// out loud, in one line: sending, buying, deleting and calendar changes wait for a yes.
    @Test func everyHelperSaysWhatWaitsForAYes() {
        for helper in helpers {
            let lines = helper.instructions.lowercased().split(separator: "\n")
            let rule = lines.first { $0.contains("always wait for the person's yes") }
            #expect(rule != nil, "\(helper.name)")
            for word in ["sending", "buying", "deleting", "adding or changing anything in the calendar"] {
                #expect(rule?.contains(word) == true, "\(helper.name): \(word)")
            }
        }
        #expect(ReadyMadeHelper.asksFirst.map(\.word) == ["Sending", "Paying", "Deleting", "Calendar"])
    }

    /// A schedule is the person's own switch, after the helper is there: never in the add, never on to start.
    @Test func noHelperStartsWithASchedule() throws {
        for helper in helpers {
            let body = try #require(helper.request.objectValue)
            #expect(body["schedule"] == nil && body["cron"] == nil, "\(helper.name)")
            #expect(!helper.toolsets.contains("cronjob"), "\(helper.name)")
            guard let routine = helper.routine else { continue }
            #expect(routine.startsOn == false, "\(helper.name)")
            #expect(routine.prompt.contains("[SILENT]"))
            #expect(routine.prompt.contains("nothing is sent, booked, bought, paid, deleted or added to the calendar"))
            for text in [routine.title, routine.task] {
                #expect(!text.contains("\u{2014}"), "\(helper.name): no em dashes")
                #expect(!text.lowercased().contains("without asking"), "\(helper.name)")
            }
            #expect(routine.title.count <= 20, "\(helper.name): fits its switch")
            #expect(routine.cron.wholeMatch(of: /\d{1,2} \d{1,2} \* \* (\*|[0-6])/) != nil, "\(helper.name): \(routine.cron)")
        }
        #expect(helpers.filter { $0.routine != nil }.count >= helpers.count / 2)
    }

    @Test func aScheduleSaysWhenInThePersonsClock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let british = Locale(identifier: "en_GB")
        let school = ReadyMadeHelper.school.routine!
        #expect(school.cron == "0 18 * * 0")
        #expect(school.when(calendar: calendar, locale: british) == "Sundays, 18:00")
        let planner = ReadyMadeHelper.planner.routine!
        #expect(planner.cron == "30 7 * * *")
        // The system's own short time: "7:30" or "07:30", never "7:30 AM" for a 24-hour clock.
        let morning = planner.when(calendar: calendar, locale: british)
        #expect(morning.hasPrefix("Every day, ") && morning.hasSuffix("7:30"), "\(morning)")
        #expect(school.jobName(for: .school) == "School: Week ahead")
    }

    @Test func pagesShowAFewFactsInAWordOrTwo() {
        for helper in helpers {
            #expect((2...4).contains(helper.helpsWith.count), "\(helper.name)")
            for fact in helper.helpsWith + ReadyMadeHelper.asksFirst {
                #expect(fact.word.split(separator: " ").count <= 3, "\(helper.name): \(fact.word)")
                #expect(Self.symbolExists(fact.symbol), "\(helper.name): \(fact.symbol)")
            }
        }
    }

    private static func symbolExists(_ name: String) -> Bool {
        #if canImport(UIKit)
        UIImage(systemName: name) != nil
        #else
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #endif
    }

    @Test func namesAreOnesTheCrewAccepts() {
        let reserved: Set = ["nollie", "ollie", "moss", "private", "default", "hermes", "test"]
        for helper in helpers {
            #expect(helper.id == profileName(helper.name), "\(helper.name)")
            #expect(helper.name.wholeMatch(of: /[A-Za-z][A-Za-z0-9 '\-]{0,31}/) != nil, "\(helper.name)")
            #expect(!reserved.contains(helper.id), "\(helper.name)")
        }
    }

    @Test func looksComeFromTheSetAndLeaveNolliesOwnToNollie() {
        for helper in helpers {
            #expect(CharacterLookID.allCases.contains(helper.look))
            #expect(helper.look != .main, "\(helper.name)")
        }
        // Neighbours never share a look.
        for (one, next) in zip(helpers, helpers.dropFirst()) { #expect(one.look != next.look) }
    }

    @Test func wordsFitTheirPlaces() {
        for helper in helpers {
            #expect(helper.promise.count <= 50, "\(helper.name): the line under its name")
            #expect((1...120).contains(helper.role.count))
            #expect(helper.role.first?.isLowercase == true, "\(helper.name): reads after \"I've added …to\"")
            #expect((1...280).contains(helper.comeToMeFor.count))
            let sentences = helper.comeToMeFor.split(whereSeparator: { ".!?".contains($0) })
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            #expect(sentences.count <= 2, "\(helper.name): come to me for is one or two sentences")
            #expect((200...2_400).contains(helper.instructions.count), "\(helper.name)")
            for text in [helper.name, helper.promise, helper.role, helper.comeToMeFor, helper.instructions] + helper.helpsWith.map(\.word) {
                #expect(!text.contains("\u{2014}"), "\(helper.name): no em dashes")
                #expect(!text.localizedCaseInsensitiveContains("hermes"), "\(helper.name): no Hermes in what people read")
            }
        }
    }

    /// Ask first is enforced by fixed rules whatever a helper reads; its own instructions still
    /// never say otherwise, and each one says the yes out loud.
    @Test func instructionsNeverWeakenAskFirst() {
        let skips = [
            "don't ask", "do not ask", "no need to ask", "never ask", "stop asking", "skip asking", "skip ask first",
            "skip the yes", "skip the approval", "without needing to", "assume yes", "assume a yes", "assume the yes",
            "assume their yes", "already approved", "pre-approved", "preapproved", "standing approval",
            "standing permission", "you have permission", "with permission to", "go ahead and buy", "go ahead and book",
            "go ahead and send", "go ahead and pay", "go ahead and post", "go ahead and delete", "ignore ask first",
            "bypass", "override", "turn off ask first", "on your own initiative", "just buy", "just book", "just send",
        ]
        let negation = /\b(never|not|no|nothing)\b|n't\b/.ignoresCase()
        let withoutYes = /\bwithout (asking|checking|a yes|their yes|your yes|the person's yes|approval|permission|confirmation)\b/.ignoresCase()
        for helper in helpers {
            let text = helper.instructions.lowercased()
            for phrase in skips { #expect(!text.contains(phrase), "\(helper.name): \"\(phrase)\"") }
            for sentence in helper.instructions.split(whereSeparator: { ".!?\n".contains($0) }) {
                let line = String(sentence)
                if line.contains(withoutYes) { #expect(line.contains(negation), "\(helper.name): \(line)") }
            }
            #expect(text.contains("yes"), "\(helper.name): says what waits for a yes")
            #expect(text.contains("always wait"), "\(helper.name): says it always waits")
        }
    }

    @Test func toolsetsNeedNoFurtherYes() {
        // The Mac, connections, schedules and messages need their own yes; the crew tools are never given.
        let needsAYes: Set = ["computer_use", "connections", "cronjob", "send_message", "messaging", "bot_room",
                              "discord", "discord_admin", "nollie_crew", "terminal", "code_execution", "delegation"]
        for helper in helpers {
            #expect(!helper.toolsets.isEmpty)
            #expect(Set(helper.toolsets).isDisjoint(with: needsAYes), "\(helper.name)")
            #expect(Set(helper.toolsets).count == helper.toolsets.count)
        }
    }

    @Test func theRequestCarriesExactlyTheHelper() throws {
        let helper = ReadyMadeHelper.shopper
        let body = try #require(helper.request.objectValue)
        #expect(Set(body.keys) == ["name", "role", "come_to_me_for", "instructions", "toolsets"])
        #expect(body["name"]?.stringValue == "Shopper")
        #expect(body["role"]?.stringValue == helper.role)
        #expect(body["come_to_me_for"]?.stringValue == helper.comeToMeFor)
        #expect(body["instructions"]?.stringValue == helper.instructions)
        #expect(body["toolsets"]?.arrayValue?.compactMap(\.stringValue) == helper.toolsets)
    }
}

/// A crew add-on in memory, for the gallery's calls.
@MainActor
private final class FakeCrew {
    var room = 2
    var answersRoster = true
    var refuseWith: String?
    var loseAnswer = false
    var sent: [JSONValue] = []
    var undone: [String] = []
    var looks: [String: CharacterLookID] = [:]

    var calls: HelperGallery.Calls {
        HelperGallery.Calls(
            roster: { [self] in
                guard answersRoster else { return .init() }
                return .init(ok: true, members: [], room: room)
            },
            add: { [self] body in
                sent.append(body)
                if loseAnswer { throw HermesAPIError.transport("The network connection was lost.") }
                if let refuseWith { throw HermesAPIError.http(status: 409, detail: refuseWith) }
                let name = body["name"]?.stringValue ?? ""
                let profile = name.lowercased().replacingOccurrences(of: " ", with: "-")
                return .init(ok: true, status: "added", profile: profile, name: name,
                             note: "I've added \(name).", undo: "token-\(profile)")
            },
            undo: { [self] token in
                undone.append(token)
                return .init(ok: true, status: "removed", note: "Removed.")
            },
            look: { [self] profile, look in looks[profile] = look })
    }
}

@MainActor
struct HelperGalleryTests {
    private let planner = ReadyMadeHelper.planner

    @Test func onlyTheCrewAddOnsOwnAnswerOpensTheGallery() async {
        let crew = FakeCrew()
        let gallery = HelperGallery()
        await gallery.load(crew.calls)
        #expect(gallery.availability == .ready)
        #expect(gallery.room == 2)

        // An unknown route that answers `{}`, an older add-on, or no add-on at all.
        crew.answersRoster = false
        let empty = HelperGallery()
        await empty.load(crew.calls)
        #expect(empty.availability == .unavailable)

        var failing = crew.calls
        failing.roster = { throw HermesAPIError.http(status: 404, detail: "Not Found") }
        let missing = HelperGallery()
        await missing.load(failing)
        #expect(missing.availability == .unavailable)
    }

    @Test func oneTapAddsTheHelperWithItsLookAndInstructions() async throws {
        let crew = FakeCrew()
        let gallery = HelperGallery()
        await gallery.load(crew.calls)
        let profile = await gallery.add(planner, crew.calls, allowed: { true })
        #expect(profile == "planner")
        #expect(crew.sent == [planner.request])
        #expect(crew.looks["planner"] == planner.look)
        #expect(gallery.added == [.init(helper: "planner", profile: "planner", token: "token-planner")])
        #expect(gallery.room == 1)
        #expect(gallery.state(of: planner, bots: ["default", "planner"]) == .justAdded)
        #expect(gallery.problem == nil)
    }

    @Test func undoTakesItBackOnceWithItsOwnToken() async {
        let crew = FakeCrew()
        let gallery = HelperGallery()
        await gallery.load(crew.calls)
        _ = await gallery.add(planner, crew.calls, allowed: { true })
        #expect(await gallery.undo(planner, crew.calls) == "planner")
        #expect(crew.undone == ["token-planner"])
        #expect(crew.looks["planner"] == nil)
        #expect(gallery.added.isEmpty)
        #expect(gallery.room == 2)
        #expect(gallery.state(of: planner, bots: ["default"]) == .available)
        // Nothing left to undo: no second call.
        #expect(await gallery.undo(planner, crew.calls) == nil)
        #expect(crew.undone.count == 1)
    }

    @Test func tilesShowWhatIsAlreadyThereAndAFullCrew() async {
        let crew = FakeCrew()
        crew.room = 0
        let gallery = HelperGallery()
        await gallery.load(crew.calls)
        #expect(gallery.state(of: planner, bots: ["default", "planner"]) == .inCrew)
        #expect(gallery.state(of: .shopper, bots: ["default"]) == .full)
        #expect(await gallery.add(.shopper, crew.calls, allowed: { true }) == nil)
        #expect(crew.sent.isEmpty)
    }

    @Test func nothingIsSentWhileLockedOrBeforeTheGalleryIsReady() async {
        let crew = FakeCrew()
        let gallery = HelperGallery()
        #expect(await gallery.add(planner, crew.calls, allowed: { true }) == nil)
        await gallery.load(crew.calls)
        #expect(await gallery.add(planner, crew.calls, allowed: { false }) == nil)
        #expect(crew.sent.isEmpty)
        #expect(crew.looks.isEmpty)
    }

    @Test func aRefusalShowsTheAddOnsOwnWords() async {
        let crew = FakeCrew()
        crew.refuseWith = "The name Planner is already taken. Pick another one."
        let gallery = HelperGallery()
        await gallery.load(crew.calls)
        #expect(await gallery.add(planner, crew.calls, allowed: { true }) == nil)
        #expect(gallery.problem == "The name Planner is already taken. Pick another one.")
        #expect(gallery.added.isEmpty)
        #expect(gallery.room == 2)
        #expect(crew.looks.isEmpty)
    }

    @Test func aLostAnswerKeepsNoUndoAndSaysToTryAgain() async {
        let crew = FakeCrew()
        crew.loseAnswer = true
        let gallery = HelperGallery()
        await gallery.load(crew.calls)
        #expect(await gallery.add(planner, crew.calls, allowed: { true }) == nil)
        #expect(gallery.problem == "Planner wasn't confirmed. Try again.")
        #expect(gallery.added.isEmpty)
        #expect(gallery.working == nil)
    }
}

/// A gateway's schedules in memory, for a helper's schedule switch.
@MainActor
private final class FakeSchedules {
    var jobs: [JSONValue] = []
    var created: [(profile: String, payload: JSONValue)] = []
    var paused: [(job: String, pause: Bool)] = []
    var loseAnswer = false
    var failList = false

    var calls: HelperRoutineSwitch.Calls {
        HelperRoutineSwitch.Calls(
            jobs: { [self] profile in
                if failList { throw HermesAPIError.transport("The network connection was lost.") }
                return jobs.filter { $0["profile"]?.stringValue == profile }
            },
            create: { [self] profile, payload in
                created.append((profile, payload))
                var job = payload.objectValue ?? [:]
                job["job_id"] = .string("job-\(created.count)")
                job["profile"] = .string(profile)
                job["enabled"] = .bool(true)
                job["state"] = .string("scheduled")
                jobs.append(.object(job))
                if loseAnswer { throw HermesAPIError.transport("The network connection was lost.") }
                return .object(job)
            },
            pause: { [self] profile, id, pause in
                paused.append((id, pause))
                jobs = jobs.map { raw in
                    guard raw["job_id"]?.stringValue == id, raw["profile"]?.stringValue == profile,
                          var job = raw.objectValue else { return raw }
                    job["enabled"] = .bool(!pause)
                    job["state"] = .string(pause ? "paused" : "scheduled")
                    return .object(job)
                }
                return jobs.first { $0["job_id"]?.stringValue == id } ?? .object([:])
            })
    }
}

@MainActor
struct HelperRoutineSwitchTests {
    private let helper = ReadyMadeHelper.school
    private var routine: HelperRoutine { helper.routine! }

    @Test func itStartsOffAndLookingMakesNothing() async {
        let gateway = FakeSchedules()
        let toggle = HelperRoutineSwitch(helper: helper, routine: routine)
        #expect(toggle.standing == .checking)
        await toggle.load(profile: "school", gateway.calls)
        #expect(toggle.standing == .off)
        #expect(!toggle.isOn)
        #expect(gateway.created.isEmpty && gateway.paused.isEmpty)
    }

    @Test func onMakesOneScheduleForTheHelpersChat() async throws {
        let gateway = FakeSchedules()
        let toggle = HelperRoutineSwitch(helper: helper, routine: routine)
        await toggle.load(profile: "school", gateway.calls)
        await toggle.set(true, profile: "school", gateway.calls, allowed: { true })
        #expect(toggle.standing == .on)
        #expect(gateway.created.count == 1)
        let made = try #require(gateway.created.first)
        #expect(made.profile == "school")
        #expect(made.payload["name"]?.stringValue == "School: Week ahead")
        #expect(made.payload["schedule"]?.stringValue == "0 18 * * 0")
        #expect(made.payload["deliver"]?.stringValue == "bot-chat")
        #expect(made.payload["prompt"]?.stringValue == routine.prompt)
    }

    @Test func offPausesAndOnAgainResumesTheSameOne() async {
        let gateway = FakeSchedules()
        let toggle = HelperRoutineSwitch(helper: helper, routine: routine)
        await toggle.load(profile: "school", gateway.calls)
        await toggle.set(true, profile: "school", gateway.calls, allowed: { true })
        await toggle.set(false, profile: "school", gateway.calls, allowed: { true })
        #expect(toggle.standing == .off)
        await toggle.set(true, profile: "school", gateway.calls, allowed: { true })
        #expect(toggle.standing == .on)
        #expect(gateway.created.count == 1)
        #expect(gateway.paused.map(\.pause) == [true, false])
        #expect(Set(gateway.paused.map(\.job)) == ["job-1"])
    }

    @Test func anotherBotsScheduleOfTheSameNameIsLeftAlone() async {
        let gateway = FakeSchedules()
        gateway.jobs = [.object(["job_id": .string("theirs"), "name": .string("School: Week ahead"),
                                 "profile": .string("work"), "enabled": .bool(true)])]
        let toggle = HelperRoutineSwitch(helper: helper, routine: routine)
        var calls = gateway.calls
        calls.jobs = { _ in gateway.jobs }  // a gateway that ignores the bot filter
        await toggle.load(profile: "school", calls)
        #expect(toggle.standing == .off)
    }

    @Test func nothingIsSentWhileLockedOrBeforeItHasLooked() async {
        let gateway = FakeSchedules()
        let toggle = HelperRoutineSwitch(helper: helper, routine: routine)
        await toggle.set(true, profile: "school", gateway.calls, allowed: { true })
        await toggle.load(profile: "school", gateway.calls)
        await toggle.set(true, profile: "school", gateway.calls, allowed: { false })
        #expect(gateway.created.isEmpty)
        #expect(toggle.standing == .off)

        gateway.failList = true
        let unsure = HelperRoutineSwitch(helper: helper, routine: routine)
        await unsure.load(profile: "school", gateway.calls)
        #expect(unsure.standing == .unavailable)
        await unsure.set(true, profile: "school", gateway.calls, allowed: { true })
        #expect(gateway.created.isEmpty)
    }

    @Test func aLostAnswerIsReadBackNeverSentTwice() async {
        let gateway = FakeSchedules()
        gateway.loseAnswer = true
        let toggle = HelperRoutineSwitch(helper: helper, routine: routine)
        await toggle.load(profile: "school", gateway.calls)
        await toggle.set(true, profile: "school", gateway.calls, allowed: { true })
        // The gateway made it after all: the switch reads that back and says nothing went wrong.
        #expect(toggle.standing == .on)
        #expect(toggle.problem == nil)
        await toggle.set(true, profile: "school", gateway.calls, allowed: { true })
        #expect(gateway.created.count == 1)
    }
}
