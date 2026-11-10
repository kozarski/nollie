import Foundation

/// One change to a stored chat: new title or flags (archive, pin, unread), or deleting it.
public enum SessionChange: Sendable, Equatable {
    case update([String: JSONValue])
    case delete
}

/// Why a chat change did not go through, in words a person can act on.
public enum SessionChangeError: LocalizedError, Sendable, Equatable {
    /// Hermes kept seeing a newer version of the chat, however often the change was tried again.
    case changedElsewhere
    /// The chat is in the middle of a reply.
    case busy
    /// The chat is no longer there.
    case gone
    /// Hermes refused it for this bot.
    case notAllowed
    /// Hermes wants a newer app for this change.
    case needsNewerApp

    public var errorDescription: String? {
        switch self {
        case .changedElsewhere: String(localized: "This chat changed somewhere else. Try again.", table: "Core")
        case .busy: String(localized: "This chat is busy with a reply. Try again when it is done.", table: "Core")
        case .gone: String(localized: "This chat is no longer there.", table: "Core")
        case .notAllowed: String(localized: "This bot does not allow that change.", table: "Core")
        case .needsNewerApp: String(localized: "Hermes needs a newer Nollie for this. Update Nollie and try again.", table: "Core")
        }
    }
}

/// What Hermes 0.23 says about a chat before a change: `GET /api/sessions/{id}/mutation-snapshot`.
public struct SessionMutationSnapshot: Decodable, Sendable, Equatable {
    public var exists: Bool
    public var runtimeRevision: Int
    public var runtimeGeneration: Int?

    public init(exists: Bool, runtimeRevision: Int, runtimeGeneration: Int?) {
        (self.exists, self.runtimeRevision, self.runtimeGeneration) = (exists, runtimeRevision, runtimeGeneration)
    }

    enum CodingKeys: String, CodingKey {
        case exists
        case runtimeRevision = "runtime_revision"
        case runtimeGeneration = "runtime_generation"
    }
}

/// Renames, flags and deletes stored chats with the identity Hermes 0.23 asks for: a request id that stays the
/// same for every try of one change, plus the chat's revision and generation from a fresh snapshot.
///
/// - A revision or generation conflict, or a busy chat, is a definite refusal: nothing was written, so the
///   snapshot is read again and the change tried again a few times, with the same request id.
/// - A lost answer (no connection, Hermes's owner unreachable) is tried again with the identical identity, so a
///   change that did land is answered from Hermes's receipt instead of being made twice.
/// - Hermes 0.22 has no snapshot route (404). Then the change goes out as before; 0.22 ignores the extra fields.
public struct SessionMutator: Sendable {
    /// One HTTP call: method, path, query and JSON body (nil for none). Throws `HermesAPIError` on a refusal.
    public typealias Send = @Sendable (_ method: String, _ path: String, _ query: [URLQueryItem], _ body: JSONValue?) async throws -> Data

    let send: Send
    let attempts: Int
    let pause: @Sendable (Int) async -> Void
    let makeRequestID: @Sendable () -> String

    public init(attempts: Int = 4, pause: (@Sendable (Int) async -> Void)? = nil,
                makeRequestID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }, send: @escaping Send) {
        self.send = send
        self.attempts = max(1, attempts)
        self.pause = pause ?? { attempt in try? await Task.sleep(for: .milliseconds(150 * attempt)) }
        self.makeRequestID = makeRequestID
    }

    /// Refusals that wrote nothing, after which a fresh snapshot may succeed.
    static let refreshable: Set<String> = ["revision_conflict", "stale_generation", "session_busy"]

    public static func path(_ id: String) -> String { "/api/sessions/\(id)" }
    public static func snapshotPath(_ id: String) -> String { "/api/sessions/\(id)/mutation-snapshot" }

    public func apply(_ change: SessionChange, to id: String, profile: String?) async throws {
        let requestID = makeRequestID()
        var snapshot = try await read(id, profile: profile)
        var attempt = 1
        while true {
            if let snapshot, !snapshot.exists {
                if change == .delete { return }
                throw SessionChangeError.gone
            }
            do {
                try await write(change, id: id, profile: profile, requestID: requestID, snapshot: snapshot)
                return
            } catch let error as HermesAPIError {
                let reason = Self.reason(of: error)
                let more = attempt < attempts
                if more, snapshot != nil, let reason, Self.refreshable.contains(reason) {
                    await pause(attempt)
                    snapshot = try await read(id, profile: profile)
                } else if more, Self.answerWasLost(error, reason: reason) {
                    await pause(attempt)
                } else {
                    throw Self.plain(error, reason: reason, change: change)
                }
            }
            attempt += 1
        }
    }

    /// The snapshot, or nil when this Hermes has no such route (0.22 and earlier).
    func read(_ id: String, profile: String?) async throws -> SessionMutationSnapshot? {
        let data: Data
        do {
            data = try await send("GET", Self.snapshotPath(id), Self.profileQuery(profile), nil)
        } catch HermesAPIError.http(let status, _) where status == 404 || status == 405 {
            return nil
        }
        do {
            return try JSONDecoder().decode(SessionMutationSnapshot.self, from: data)
        } catch {
            throw HermesAPIError.decoding(String(String(describing: error).prefix(200)))
        }
    }

    private func write(_ change: SessionChange, id: String, profile: String?, requestID: String,
                       snapshot: SessionMutationSnapshot?) async throws {
        // Wire names and values, in the order the DELETE query lists them.
        var identity: [(String, Int?, String?)] = []
        if let snapshot {
            identity.append(("request_id", nil, requestID))
            identity.append(("expected_revision", snapshot.runtimeRevision, nil))
            if let generation = snapshot.runtimeGeneration { identity.append(("expected_generation", generation, nil)) }
        }
        switch change {
        case .update(let fields):
            var body = fields
            for (name, number, text) in identity { body[name] = number.map { .number(Double($0)) } ?? text.map { .string($0) } }
            if let profile, !profile.isEmpty { body["profile"] = .string(profile) } else { body["profile"] = nil }
            _ = try await send("PATCH", Self.path(id), Self.profileQuery(profile), .object(body))
        case .delete:
            let extra = identity.map { name, number, text in URLQueryItem(name: name, value: number.map(String.init) ?? text) }
            _ = try await send("DELETE", Self.path(id), Self.profileQuery(profile) + extra, nil)
        }
    }

    static func profileQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    /// Hermes's one-word reason (`revision_conflict`), when the refusal carries one.
    static func reason(of error: HermesAPIError) -> String? {
        guard case .http(_, let detail) = error else { return nil }
        let word = detail.split(whereSeparator: { $0 == ":" || $0.isWhitespace }).first.map(String.init) ?? ""
        return word.isEmpty ? nil : word
    }

    /// The change may or may not have landed: the same identity again is safe.
    static func answerWasLost(_ error: HermesAPIError, reason: String?) -> Bool {
        switch error {
        case .transport: true
        case .http(let status, _): status == 503 && (reason == "owner_unreachable" || reason == "runtime_draining")
        default: false
        }
    }

    static func plain(_ error: HermesAPIError, reason: String?, change: SessionChange) -> Error {
        switch reason {
        case "revision_conflict", "stale_generation", "admission_conflict": SessionChangeError.changedElsewhere
        case "session_busy": SessionChangeError.busy
        case "not_found": change == .delete ? error : SessionChangeError.gone
        case "permission_denied", "profile_mismatch": SessionChangeError.notAllowed
        case "client_upgrade_required", "mutation_identity_required": SessionChangeError.needsNewerApp
        default:
            if case .http(404, _) = error, change != .delete { SessionChangeError.gone } else { error }
        }
    }
}

extension HermesAPI {
    /// The mutator that sends through this connection.
    public nonisolated func sessionMutator() -> SessionMutator {
        SessionMutator { [self] method, path, query, body in
            let encoded: Body? = try body.map { (try JSONEncoder().encode($0), "application/json") }
            return try await raw(method, path, query: query, body: encoded, authenticated: true).0
        }
    }

    /// Changes a stored chat's title or flags (`archived`, `pinned`, `unread`, `hidden`).
    public func updateSession(_ id: String, profile: String?, fields: [String: JSONValue]) async throws {
        try await sessionMutator().apply(.update(fields), to: id, profile: profile)
    }

    /// Deletes a stored chat. One already gone counts as deleted.
    public func deleteSession(_ id: String, profile: String?) async throws {
        try await sessionMutator().apply(.delete, to: id, profile: profile)
    }
}
