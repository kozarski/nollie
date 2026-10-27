import Foundation
import Observation
import NollieCore

/// The gallery's state: whether the crew add-on can take a ready-made helper, the room left, and
/// what was added during this visit with its Undo. The calls are passed in, so the rules can be
/// checked without a gateway.
@MainActor @Observable
final class HelperGallery {
    enum Availability: Equatable { case checking, ready, unavailable }

    /// What a tile offers.
    enum TileState: Equatable {
        case available
        /// Added during this visit: its Undo is still on offer.
        case justAdded
        /// A bot with this name is already there.
        case inCrew
        /// The crew has no room.
        case full
    }

    /// The crew add-on's `GET …/crew`, the parts the gallery reads.
    struct Roster: Decodable, Sendable {
        struct Member: Decodable, Sendable { var profile: String }
        var ok: Bool?
        var members: [Member]?
        var room: Int?
    }

    /// The crew add-on's answer to an add or an undo.
    struct Reply: Decodable, Sendable {
        var ok: Bool?
        var status: String?
        var profile: String?
        var name: String?
        var note: String?
        var undo: String?
        var error: String?
    }

    /// One added helper: which tile, which bot, and the token that takes it back.
    struct Added: Equatable, Sendable {
        var helper: String
        var profile: String
        var token: String
    }

    struct Calls {
        var roster: () async throws -> Roster
        var add: (JSONValue) async throws -> Reply
        var undo: (String) async throws -> Reply
        /// Keeps a bot's look, on this device and for the person's other devices, or forgets it (nil).
        var look: (String, CharacterLookID?) -> Void
    }

    private(set) var availability: Availability = .checking
    private(set) var room = 0
    /// The tile with a request in flight.
    private(set) var working: String?
    /// Added during this visit, oldest first.
    private(set) var added: [Added] = []
    private(set) var problem: String?

    /// Asks the crew add-on whether it is there. Anything but its own answer (an older add-on, no
    /// add-on, a linked phone that can't reach it) keeps the gallery away.
    func load(_ calls: Calls) async {
        do {
            let roster = try await calls.roster()
            guard roster.ok == true, roster.members != nil, let room = roster.room else {
                availability = .unavailable
                return
            }
            self.room = room
            availability = .ready
        } catch {
            availability = .unavailable
        }
    }

    func state(of helper: ReadyMadeHelper, bots: Set<String>) -> TileState {
        if added.contains(where: { $0.helper == helper.id }) { return .justAdded }
        if bots.contains(helper.id) { return .inCrew }
        return room > 0 ? .available : .full
    }

    /// Adds a helper. Returns its profile name once the add-on confirms it, or nil with `problem` set.
    func add(_ helper: ReadyMadeHelper, _ calls: Calls, allowed: () -> Bool) async -> String? {
        guard working == nil, availability == .ready, room > 0, allowed() else { return nil }
        working = helper.id
        problem = nil
        defer { working = nil }
        do {
            let reply = try await calls.add(helper.request)
            guard reply.ok == true, reply.status == "added", let profile = reply.profile, !profile.isEmpty,
                  let token = reply.undo else {
                problem = reply.error ?? String(localized: "\(helper.shownName) wasn't added. Try again.")
                return nil
            }
            // The look belongs to the new bot before it first appears anywhere.
            calls.look(profile, helper.look)
            added.append(Added(helper: helper.id, profile: profile, token: token))
            room -= 1
            return profile
        } catch {
            // A lost answer is safe to try again: a second add of the same name is refused.
            problem = Self.words(error) ?? String(localized: "\(helper.shownName) wasn't confirmed. Try again.")
            return nil
        }
    }

    /// Takes back a helper added during this visit. Returns its profile name once it has gone.
    func undo(_ helper: ReadyMadeHelper, _ calls: Calls) async -> String? {
        guard working == nil, let entry = added.first(where: { $0.helper == helper.id }) else { return nil }
        working = helper.id
        problem = nil
        defer { working = nil }
        do {
            let reply = try await calls.undo(entry.token)
            guard reply.ok == true else {
                problem = reply.error ?? reply.note ?? String(localized: "That didn't go through. Try again.")
                return nil
            }
            added.removeAll { $0.helper == helper.id }
            calls.look(entry.profile, nil)
            room += 1
            return entry.profile
        } catch {
            problem = Self.words(error) ?? String(localized: "That didn't go through. Try again.")
            return nil
        }
    }

    /// The add-on's own sentence from a refusal, without the status code.
    private static func words(_ error: Error) -> String? {
        if case HermesAPIError.http(_, let detail) = error, !detail.isEmpty { return detail }
        return nil
    }
}

extension HelperGallery.Calls {
    static let crewPath = "/api/plugins/nollie-crew"

    /// The crew add-on's routes on this gateway. They belong to Nollie's own profile.
    @MainActor static func gateway(_ runtime: GatewayRuntime) -> Self {
        let api = runtime.api
        return Self(
            roster: { try await api.get(crewPath + "/crew") },
            add: { body in try await api.send("POST", crewPath + "/members", json: body) },
            undo: { token in try await api.send("POST", crewPath + "/undo", json: .object(["token": .string(token)])) },
            look: { profile, look in
                // The other devices draw the helper the same way.
                defer { BotLookSharing.share(profile, runtime: runtime) }
                if let look { return BotAvatarStore.set(.look(look), for: profile) }
                var looks = BotAvatarStore.stored()
                looks.removeValue(forKey: profile)
                BotAvatarStore.save(looks)
            })
    }
}
