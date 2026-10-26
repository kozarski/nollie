import Foundation
import Testing
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

    @Test func aGalleryOfSixToEight() {
        #expect((6...8).contains(helpers.count))
        #expect(Set(helpers.map(\.id)).count == helpers.count)
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
            for text in [helper.name, helper.promise, helper.role, helper.comeToMeFor, helper.instructions] {
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
