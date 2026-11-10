import Foundation
import Testing
@testable import NollieCore

// Renaming, archiving and deleting a chat with the identity Hermes 0.23 asks for, and the same on Hermes 0.22.

/// A scripted Hermes: each call is recorded, and the next answer for its method is taken off the list.
private final class ScriptedHermes: @unchecked Sendable {
    struct Call: Equatable {
        var method: String
        var path: String
        var query: [String: String]
        var body: JSONValue?
    }

    private let lock = NSLock()
    private var answers: [String: [Result<String, HermesAPIError>]]
    private(set) var calls: [Call] = []

    init(_ answers: [String: [Result<String, HermesAPIError>]]) { self.answers = answers }

    func send(_ method: String, _ path: String, _ query: [URLQueryItem], _ body: JSONValue?) throws -> Data {
        try lock.withLock {
            let names = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
            calls.append(Call(method: method, path: path, query: names, body: body))
            guard var queue = answers[method], !queue.isEmpty else { throw HermesAPIError.transport("no answer scripted") }
            let next = queue.removeFirst()
            answers[method] = queue
            return Data(try next.get().utf8)
        }
    }

    func mutator(attempts: Int = 4) -> SessionMutator {
        SessionMutator(attempts: attempts, pause: { _ in }, makeRequestID: { "req-1" }) { [self] method, path, query, body in
            try send(method, path, query, body)
        }
    }
}

private func snapshot(revision: Int, generation: Int? = 2, exists: Bool = true) -> Result<String, HermesAPIError> {
    .success(#"{"session_id":"s1","exists":\#(exists),"runtime_revision":\#(revision),"runtime_generation":\#(generation.map(String.init) ?? "null")}"#)
}

private func refused(_ status: Int, _ detail: String) -> Result<String, HermesAPIError> { .failure(.http(status: status, detail: detail)) }

@Suite struct SessionMutationTests {
    @Test func renameSendsTheIdentityFromTheSnapshotInTheBody() async throws {
        let hermes = ScriptedHermes(["GET": [snapshot(revision: 7)], "PATCH": [.success(#"{"ok":true}"#)]])
        try await hermes.mutator().apply(.update(["title": "Trip plans"]), to: "s1", profile: "scout")

        #expect(hermes.calls.map(\.path) == ["/api/sessions/s1/mutation-snapshot", "/api/sessions/s1"])
        #expect(hermes.calls[0].query == ["profile": "scout"])
        let body = try #require(hermes.calls[1].body)
        #expect(body == .object(["title": "Trip plans", "profile": "scout", "request_id": "req-1",
                                 "expected_revision": 7, "expected_generation": 2]))
    }

    @Test func deleteSendsTheIdentityInTheQueryAndNoBody() async throws {
        let hermes = ScriptedHermes(["GET": [snapshot(revision: 3, generation: 0)], "DELETE": [.success(#"{"ok":true}"#)]])
        try await hermes.mutator().apply(.delete, to: "s1", profile: "default")

        let delete = hermes.calls[1]
        #expect(delete.method == "DELETE" && delete.body == nil)
        #expect(delete.query == ["profile": "default", "request_id": "req-1", "expected_revision": "3", "expected_generation": "0"])
    }

    @Test func aConflictReadsTheSnapshotAgainAndKeepsTheRequestID() async throws {
        let hermes = ScriptedHermes([
            "GET": [snapshot(revision: 1), snapshot(revision: 2), snapshot(revision: 2, generation: 3)],
            "PATCH": [refused(409, "revision_conflict"), refused(409, "stale_generation"), .success("{}")],
        ])
        try await hermes.mutator().apply(.update(["archived": true]), to: "s1", profile: nil)

        let patches = hermes.calls.filter { $0.method == "PATCH" }.compactMap(\.body)
        #expect(patches.map { $0["request_id"] } == [.string("req-1"), .string("req-1"), .string("req-1")])
        #expect(patches.map { $0["expected_revision"] } == [1, 2, 2])
        #expect(patches.last?["expected_generation"] == 3)
        #expect(patches.allSatisfy { $0["profile"] == nil })
    }

    @Test func aBusyChatIsTriedAFewTimesThenSaidPlainly() async throws {
        let hermes = ScriptedHermes([
            "GET": Array(repeating: snapshot(revision: 1), count: 3),
            "PATCH": Array(repeating: refused(409, "session_busy"), count: 3),
        ])
        await #expect(throws: SessionChangeError.busy) {
            try await hermes.mutator(attempts: 3).apply(.update(["title": "x"]), to: "s1", profile: nil)
        }
        #expect(hermes.calls.filter { $0.method == "PATCH" }.count == 3)
    }

    @Test func endlessConflictsSayTheChatChangedElsewhere() async throws {
        let hermes = ScriptedHermes([
            "GET": Array(repeating: snapshot(revision: 1), count: 4),
            "PATCH": Array(repeating: refused(409, "revision_conflict"), count: 4),
        ])
        await #expect(throws: SessionChangeError.changedElsewhere) {
            try await hermes.mutator().apply(.update(["title": "x"]), to: "s1", profile: nil)
        }
        #expect(SessionChangeError.changedElsewhere.errorDescription?.isEmpty == false)
    }

    @Test func aLostAnswerIsSentAgainWithTheSameIdentity() async throws {
        let hermes = ScriptedHermes([
            "GET": [snapshot(revision: 4)],
            "DELETE": [.failure(.transport("The network connection was lost.")), refused(503, "owner_unreachable"), .success("{}")],
        ])
        try await hermes.mutator().apply(.delete, to: "s1", profile: nil)

        let deletes = hermes.calls.filter { $0.method == "DELETE" }.map(\.query)
        #expect(deletes.count == 3 && Set(deletes).count == 1)
        #expect(hermes.calls.filter { $0.method == "GET" }.count == 1)
    }

    @Test func aChatAlreadyGoneIsDeletedButCannotBeRenamed() async throws {
        let gone = ScriptedHermes(["GET": [snapshot(revision: 0, generation: nil, exists: false)]])
        try await gone.mutator().apply(.delete, to: "s1", profile: nil)
        #expect(gone.calls.count == 1)

        let missing = ScriptedHermes(["GET": [snapshot(revision: 0, generation: nil, exists: false)]])
        await #expect(throws: SessionChangeError.gone) {
            try await missing.mutator().apply(.update(["title": "x"]), to: "s1", profile: nil)
        }
    }

    @Test func otherRefusalsAreNotRetried() async throws {
        let hermes = ScriptedHermes(["GET": [snapshot(revision: 1)], "PATCH": [refused(403, "permission_denied")]])
        await #expect(throws: SessionChangeError.notAllowed) {
            try await hermes.mutator().apply(.update(["pinned": true]), to: "s1", profile: nil)
        }
        #expect(hermes.calls.count == 2)

        let upgrade = ScriptedHermes(["GET": [snapshot(revision: 1)],
                                      "PATCH": [refused(409, "client_upgrade_required: this app is out of sync")]])
        await #expect(throws: SessionChangeError.needsNewerApp) {
            try await upgrade.mutator().apply(.update(["pinned": true]), to: "s1", profile: nil)
        }
    }

    @Test func hermes022HasNoSnapshotSoTheChangeGoesOutAsBefore() async throws {
        let hermes = ScriptedHermes(["GET": [refused(404, "No such API endpoint: api/sessions/s1/mutation-snapshot")],
                                     "PATCH": [.success("{}")], "DELETE": [.success("{}")]])
        try await hermes.mutator().apply(.update(["title": "Plain"]), to: "s1", profile: "default")
        #expect(hermes.calls[1].body == .object(["title": "Plain", "profile": "default"]))

        let again = ScriptedHermes(["GET": [refused(404, "Not Found")], "DELETE": [.success("{}")]])
        try await again.mutator().apply(.delete, to: "s1", profile: "default")
        #expect(again.calls[1].query == ["profile": "default"])
    }

    @Test func theDemoAnswersTheSnapshotAndMovesTheRevision() async throws {
        let demo = DemoGateway(pace: InstantClock())
        let listed = try JSONDecoder().decode(JSONValue.self, from: await demo.rest("GET", "/api/sessions", body: nil).body)
        let id = try #require(listed["sessions"]?.arrayValue?.first?["id"]?.stringValue)
        let mutator = SessionMutator(pause: { _ in }) { method, path, query, body in
            var parts = URLComponents()
            parts.path = path
            parts.queryItems = query.isEmpty ? nil : query
            let answer = await demo.rest(method, parts.string ?? path, body: try body.map { try JSONEncoder().encode($0) })
            if answer.status >= 400 {
                let said = try? JSONDecoder().decode(JSONValue.self, from: answer.body)
                throw HermesAPIError.http(status: answer.status, detail: said?["detail"]?.stringValue ?? "")
            }
            return answer.body
        }
        let before = try #require(try await mutator.read(id, profile: nil))
        try await mutator.apply(.update(["title": "Renamed"]), to: id, profile: nil)
        let after = try #require(try await mutator.read(id, profile: nil))
        #expect(before.exists && after.runtimeRevision == before.runtimeRevision + 1)
        try await mutator.apply(.delete, to: id, profile: nil)
        #expect(try await mutator.read(id, profile: nil)?.exists == false)
        try await mutator.apply(.delete, to: id, profile: nil)
    }
}
