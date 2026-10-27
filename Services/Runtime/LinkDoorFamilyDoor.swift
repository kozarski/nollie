#if os(macOS)
import Foundation

/// The door's side of sharing a helper at home: what it answers members itself, the owner's routes,
/// and asks. The phone's screens follow these answers; they never decide anything.
extension LinkDoor {
    enum FamilyFailure: Error, Equatable, Sendable {
        case invalid, privateHelper, unknownHelper, unavailable, notFound, unsaved, notCopied

        var status: Int {
            switch self {
            case .invalid: 400
            case .privateHelper: 403
            case .unknownHelper, .notFound: 404
            case .unavailable, .unsaved, .notCopied: 503
            }
        }

        var message: String {
            switch self {
            case .invalid: "That can't be shared."
            case .privateHelper: "Private helpers stay yours."
            case .unknownHelper: "That helper isn't on your Mac."
            case .notFound: "That isn't here any more."
            case .unavailable: "Your Mac couldn't check your helpers. Try again in a moment."
            case .unsaved: "Your Mac couldn't save that. Try again."
            case .notCopied: "Your Mac couldn't make their copy of this helper. Try again."
            }
        }
    }

    static let maximumSharedHelpers = 8

    // MARK: What a member may reach

    /// Read now, with a Private list no more than five seconds old.
    func memberAccess(_ device: UUID) async -> LinkDoorMemberAccess? {
        guard devices.member(device) != nil else { return nil }
        // Sharing touched again: copies from before the lock-down get it now, or nothing passes.
        guard await lockDownOlderCopies(of: device) else { return nil }
        let names = await family.privateNames()
        // Read again after the wait: a member removed meanwhile gets nothing.
        guard let member = devices.member(device) else { return nil }
        return LinkDoorMemberAccess(device: device, member: member, privateNames: names)
    }

    /// For a socket that can't wait: the last Private list read (read again in the background).
    func memberAccessNow(_ device: UUID) -> LinkDoorMemberAccess? {
        guard let member = devices.member(device) else { return nil }
        return LinkDoorMemberAccess(device: device, member: member, privateNames: family.cachedPrivateNames())
    }

    func applyFamily(_ effects: [LinkDoorMemberSocket.Effect], device: UUID) {
        for effect in effects {
            switch effect {
            case .chat(let chat): devices.addChat(chat, for: device)
            case .ask(let ask): asks.add(ask)
            case .askGone(let id): asks.remove(id)
            }
        }
    }

    /// `/api/profiles` for a member: the helpers shared with them, no others.
    func memberProfiles(_ access: LinkDoorMemberAccess) async -> Data {
        guard let reply = await family.get("/api/profiles"), reply.status == 200,
              let body = LinkDoorFamily.filterProfiles(reply.body, access: access) else {
            return LinkDoorHTTP.reply(502, "Your assistant on this Mac didn't answer.")
        }
        return Self.json(200, data: body)
    }

    /// `/api/sessions?profile=` for a member: their own chats with that helper, newest first, each read
    /// from Hermes. Hermes's own list would page through everyone's chats.
    func memberChats(_ access: LinkDoorMemberAccess, profile: String, query: String?) async -> Data {
        let archived = LinkDoorHTTP.queryItems(query).first { $0.name == "archived" }?.value ?? "exclude"
        let wanted = Array(access.chats.filter { $0.profile == profile }.sorted { $0.id > $1.id }.prefix(100))
        let family = self.family
        // Each row comes back as JSON, already cut down to the fields a list shows.
        let found = await withTaskGroup(of: Data?.self) { group in
            for chat in wanted {
                group.addTask {
                    guard let reply = await family.get("/api/sessions/\(chat.id)", query: [URLQueryItem(name: "profile", value: profile)]),
                          reply.status == 200, let row = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
                          row["id"] as? String == chat.id else { return nil }
                    return try? JSONSerialization.data(withJSONObject: LinkDoorFamily.chatRow(row, profile: profile))
                }
            }
            var all: [Data] = []
            for await row in group { if let row { all.append(row) } }
            return all
        }
        let rows = found.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let kept = rows.filter { row in
            let isArchived = (row["archived"] as? Bool) ?? ((row["archived"] as? NSNumber)?.boolValue ?? false)
            switch archived {
            case "only": return isArchived
            case "include": return true
            default: return !isArchived
            }
        }.sorted { Self.activity($0) > Self.activity($1) }
        return Self.json(200, object: ["sessions": kept, "total": kept.count, "limit": kept.count, "offset": 0, "storage": [String: Any]()])
    }

    private static func activity(_ row: [String: Any]) -> Double {
        for key in ["last_active", "started_at"] {
            if let value = row[key] as? NSNumber { return value.doubleValue }
        }
        return 0
    }

    // MARK: The owner's routes

    func answerFamily(_ route: LinkDoorFamily.Route, body: Data, device: UUID) async -> Data {
        switch route {
        case .me:
            return Self.json(200, object: me(device))
        case .overview:
            return Self.json(200, object: overview())
        case .invite:
            guard let object = Self.object(body, keys: ["person", "helpers"], required: ["person", "helpers"]),
                  let person = object["person"] as? String, let helpers = object["helpers"] as? [String] else {
                return LinkDoorHTTP.reply(400, FamilyFailure.invalid.message)
            }
            switch await invite(person: person, helpers: helpers) {
            case .failure(let failure): return LinkDoorHTTP.reply(failure.status, failure.message)
            case .success(let code): return Self.json(200, object: code)
            }
        case .update(let id):
            guard let object = Self.object(body, keys: ["helpers", "small"], required: []), !object.isEmpty else {
                return LinkDoorHTTP.reply(400, FamilyFailure.invalid.message)
            }
            let helpers = object["helpers"].map { $0 as? [String] }
            let small = object["small"].map { $0 as? Bool }
            guard helpers.map({ $0 != nil }) ?? true, small.map({ $0 != nil }) ?? true else {
                return LinkDoorHTTP.reply(400, FamilyFailure.invalid.message)
            }
            if let failure = await updateMember(id, helpers: helpers ?? nil, small: small ?? nil) {
                return LinkDoorHTTP.reply(failure.status, failure.message)
            }
            return Self.json(200, object: overview())
        case .remove(let id):
            guard devices.member(id) != nil else { return LinkDoorHTTP.reply(404, FamilyFailure.notFound.message) }
            do { try remove(id) } catch { return LinkDoorHTTP.reply(503, FamilyFailure.unsaved.message) }
            return Self.json(200, object: overview())
        case .answer(let id):
            guard let object = Self.object(body, keys: ["choice"], required: ["choice"]),
                  let choice = object["choice"] as? String, ["once", "deny"].contains(choice) else {
                return LinkDoorHTTP.reply(400, FamilyFailure.invalid.message)
            }
            switch await answerAsk(id, choice: choice) {
            case .failure(let failure): return LinkDoorHTTP.reply(failure.status, failure.message)
            case .success: return Self.json(200, object: overview())
            }
        case .refused:
            return LinkDoorHTTP.reply(404, "The request was refused.")
        }
    }

    func me(_ device: UUID) -> [String: Any] {
        guard let member = devices.member(device) else { return ["role": "owner"] }
        return ["role": "member", "owner": configuration.owner, "person": member.person, "helpers": member.helpers, "small": member.small]
    }

    /// The members and their open asks, as the owner's screens show them.
    func overview() -> [String: Any] {
        let members: [[String: Any]] = devices.members.compactMap { device in
            guard let member = device.member else { return nil }
            var row: [String: Any] = ["id": device.id.uuidString.lowercased(), "person": member.person, "device": device.name,
                                      "helpers": member.helpers, "small": member.small,
                                      "linkedAt": device.linkedAt.timeIntervalSince1970]
            if let last = device.lastActive { row["lastActive"] = last.timeIntervalSince1970 }
            return row
        }
        return ["members": members, "asks": asks.all.map { $0.json() }]
    }

    // MARK: Sharing

    /// Shares helpers with a person: checks the name and the helpers (one to eight on this Mac, none
    /// Private), makes the person's own copy of each (a name already in `keeping` is already theirs),
    /// and locks each copy's tools down in its Hermes config. Gives the invite, naming the copies, and
    /// the helpers' shown names. The owner's own helpers are only ever copied, never changed.
    func prepareShare(person: String, helpers: [String], keeping: Set<String> = []) async
        -> Result<(invite: LinkDoorDevices.Invite, shown: [String]), FamilyFailure> {
        guard let name = LinkDoorDevices.cleanName(person), name.count <= 40 else { return .failure(.invalid) }
        guard (1...Self.maximumSharedHelpers).contains(helpers.count), Set(helpers).count == helpers.count,
              helpers.allSatisfy(LinkDoorFamily.validProfile) else { return .failure(.invalid) }
        guard let privateNames = await family.privateNames() else { return .failure(.unavailable) }
        guard !helpers.contains(where: { LinkDoorFamily.isPrivate($0, list: privateNames) }) else { return .failure(.privateHelper) }
        guard let reply = await family.get("/api/profiles"), reply.status == 200,
              let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
              let profiles = object["profiles"] as? [[String: Any]] else { return .failure(.unavailable) }
        let known = Set(profiles.compactMap { $0["name"] as? String })
        guard helpers.allSatisfy(known.contains) else { return .failure(.unknownHelper) }
        var copies: [String] = []
        var shown: [String] = []
        for helper in helpers {
            let copy = keeping.contains(helper) ? helper : LinkDoorFamily.copyName(helper: helper, person: name)
            guard !LinkDoorFamily.isPrivate(copy, list: privateNames) else { return .failure(.privateHelper) }
            if !known.contains(copy), !(await family.makeCopy(copy, of: helper, person: name)) { return .failure(.notCopied) }
            guard await family.lockDown(copy) else { return .failure(.notCopied) }
            copies.append(copy)
            let profile = profiles.first { $0["name"] as? String == helper }
            let display = (profile?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            shown.append(LinkDoorDevices.cleanName(display ?? helper.capitalized) ?? helper)
        }
        return .success((.init(person: name, helpers: copies), shown))
    }

    /// Copies a member had before the door locked copies down (made by an earlier build): locked down
    /// on their next use. False when that couldn't be done; the member is refused until it can.
    func lockDownOlderCopies(of device: UUID) async -> Bool {
        guard let member = devices.member(device) else { return false }
        let locked = member.lockVersion == LinkDoorFamily.lockVersion ? Set(member.locked ?? []) : []
        let waiting = member.helpers.filter { !locked.contains($0) }
        guard !waiting.isEmpty else { return true }
        for copy in waiting { guard await family.lockDown(copy) else { return false } }
        devices.markLocked(waiting, for: device)
        return true
    }

    /// A code for someone at home, from a linked owner phone: the fields the Mac's own offer gives,
    /// plus who shares and what.
    func invite(person: String, helpers: [String]) async -> Result<[String: Any], FamilyFailure> {
        let invite: LinkDoorDevices.Invite, shown: [String]
        switch await prepareShare(person: person, helpers: helpers) {
        case .failure(let failure): return .failure(failure)
        case .success(let checked): (invite, shown) = checked
        }
        let made = devices.makeOffer(invite: invite)
        guard let port = try? await start() else {
            devices.cancelOffer()
            return .failure(.unavailable)
        }
        let found = await hostsProvider()
        let hosts = Array(found.hosts.filter { !LinkDoorPolicy.isTailnetHost($0) }.prefix(8))
        guard !hosts.isEmpty else {
            devices.cancelOffer()
            return .failure(.unavailable)
        }
        return .success(["macName": configuration.name, "pin": LinkDoorBase64URL.encode(identity.pin), "port": Int(port),
                         "hosts": hosts, "tag": devices.installTag, "secret": LinkDoorBase64URL.encode(made.secret),
                         "expiresAt": made.expiresAt.timeIntervalSince1970, "owner": configuration.owner, "helpers": shown])
    }

    /// Changes what a member may reach. Their open connections close, so the next request is checked
    /// against the new list.
    func updateMember(_ id: UUID, helpers: [String]?, small: Bool?) async -> FamilyFailure? {
        guard let member = devices.member(id) else { return .notFound }
        var copies: [String]?
        if let helpers {
            // A helper they don't have yet is copied for them; one they have is theirs already.
            switch await prepareShare(person: member.person, helpers: helpers, keeping: Set(member.helpers)) {
            case .failure(let failure): return failure
            case .success(let checked): copies = checked.invite.helpers
            }
        }
        do { try devices.updateMember(id, helpers: copies, small: small) } catch { return .unsaved }
        if let copies {
            devices.markLocked(copies, for: id)
            if Set(copies) != Set(member.helpers) { cut(id) }
        }
        return nil
    }

    // MARK: Asks

    /// The owner's Allow once or Deny, given to Hermes as an answer to that approval.
    func answerAsk(_ id: String, choice: String) async -> Result<Void, FamilyFailure> {
        guard let ask = asks.find(id) else { return .failure(.notFound) }
        guard await family.call("approval.respond", params: ["session_id": ask.chat, "profile": ask.profile,
                                                             "request_id": ask.approvalID, "choice": choice]) else {
            return .failure(.unavailable)
        }
        asks.remove(ask.id)
        return .success(())
    }

    /// A removed member's open asks, answered Deny.
    func denyAsks(of device: UUID) {
        let theirs = asks.removeAll(for: device)
        guard !theirs.isEmpty else { return }
        let family = self.family
        Task {
            for ask in theirs {
                _ = await family.call("approval.respond", params: ["session_id": ask.chat, "profile": ask.profile,
                                                                   "request_id": ask.approvalID, "choice": "deny"])
            }
        }
    }

    // MARK: Pieces

    static func json(_ status: Int, object: Any) -> Data {
        json(status, data: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8))
    }

    static func json(_ status: Int, data body: Data) -> Data {
        var head = LinkDoorHTTP.serializeResponse(status: status, reason: status == 200 ? "OK" : "Error", headers: [
            .init(name: "Content-Type", value: "application/json"),
            .init(name: "Content-Length", value: String(body.count)),
            .init(name: "Cache-Control", value: "no-store"),
            .init(name: "Connection", value: "close"),
        ])
        head.append(body)
        return head
    }

    /// A JSON object with only these keys and all the required ones.
    static func object(_ body: Data, keys: Set<String>, required: Set<String>) -> [String: Any]? {
        if body.isEmpty { return required.isEmpty ? [:] : nil }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(object.keys).isSubset(of: keys), required.isSubset(of: Set(object.keys)) else { return nil }
        return object
    }
}
#endif
