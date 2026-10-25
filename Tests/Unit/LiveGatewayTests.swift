import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Live checks against a real gateway or against the mock. They are skipped when `LiveGatewaySettings`
/// finds nothing. The streaming test starts its prompt with `nollie-e2e-` and cleans up the session it
/// creates. Every test in this suite, nested suites in other files included, runs one at a time
/// because they share a single gateway.
@Suite(.serialized) struct LiveGatewayTests {
    static let isConfigured: Bool = {
        let configured = LiveGatewaySettings.load() != nil
        if !configured { print("live gateway tests skipped:", LiveGatewaySettings.whySkipped()) }
        return configured
    }()

    /// Address and session token, for tests that attach several connections by token (signing in
    /// with a password would cost an exchange each time).
    static var tokenTarget: (url: String, token: String)? {
        guard let settings = LiveGatewaySettings.load(), let token = settings.token, !token.isEmpty else { return nil }
        return (settings.url, token)
    }

    /// The same target, but only when it is the mock gateway, which these tests are free to modify.
    static var mockTarget: (url: String, token: String)? {
        guard let target = tokenTarget, target.token == "mock-token" else { return nil }
        return target
    }

    /// Connects the socket and waits until it can take calls.
    static func bringUp(_ socket: GatewaySocket) async throws {
        await socket.connect()
        try await socket.waitUntilReady(timeout: 30)
    }

    /// A runtime connected to the target over a store that holds only that connection; remove it with `forget`.
    @MainActor static func connect(_ target: (url: String, token: String), named name: String, store: ConnectionStore) throws -> (GatewayConnection, GatewayRuntime) {
        let connection = GatewayConnection(name: name, gateway: try GatewayURL.normalize(target.url), authMode: .sessionToken)
        try store.upsert(connection, secrets: GatewaySecrets(sessionToken: target.token))
        return (connection, GatewayRuntime(connection: connection, store: store))
    }

    private static let needsSettings: Comment = "no HERMES_E2E_URL with a token or user and password"

    /// With no settings this fails, naming the paths it tried and the keys that are missing (never
    /// the values). It only runs if HERMES_E2E_REQUIRED has been set; otherwise live tests are skipped.
    @Test(.enabled(if: LiveGatewaySettings.isRequired, "set HERMES_E2E_REQUIRED=1 to require the settings"))
    func theSettingsAreFound() {
        #expect(LiveGatewaySettings.load() != nil, "\(LiveGatewaySettings.whySkipped())")
    }

    @Test func aSettingsFileIsReadLineByLine() {
        let text = """
        # a comment
        HERMES_E2E_URL = https://gateway.example.org
        export HERMES_E2E_TOKEN="quoted token"
        HERMES_E2E_USER='someone'
        HERMES_E2E_PASSWORD=
        not a pair
        """
        let found = LiveGatewaySettings.parse(settingsFile: text)
        #expect(found == ["HERMES_E2E_URL": "https://gateway.example.org", "HERMES_E2E_TOKEN": "quoted token", "HERMES_E2E_USER": "someone"])
    }

    @Test(.enabled(if: LiveGatewayTests.isConfigured, LiveGatewayTests.needsSettings))
    func theConnectionTestPassesEveryStep() async throws {
        let settings = try #require(LiveGatewaySettings.load())
        let account = try await settings.signIn()
        let connection = GatewayConnection(name: "live", gateway: account.gateway, authMode: account.mode)
        let outcome = await ConnectionTester.run(connection: connection, secrets: account.secrets) { _ in }
        print("live steps:", outcome.steps.map { "\($0.title)=\($0.status)" }.joined(separator: ", "))
        #expect(outcome.succeeded && outcome.version != nil)
    }

    @Test(.enabled(if: LiveGatewayTests.isConfigured, LiveGatewayTests.needsSettings))
    func theRestEndpointsAnswerWithJSON() async throws {
        let settings = try #require(LiveGatewaySettings.load())
        let account = try await settings.signIn()
        let api = HermesAPI(gateway: account.gateway, signer: RequestSigner(authMode: account.mode, secrets: account.secrets))

        func answer<T: Decodable & Sendable>(_ path: String, as _: T.Type = T.self) async throws -> T { try await api.get(path) }

        #expect(try await answer("/api/profiles", as: ProfilesResponse.self).profiles.isEmpty == false)
        #expect(try await answer("/api/model/options", as: ModelOptionsResult.self).providers.isEmpty == false)
        let config = try await answer("/api/config", as: JSONValue.self)
        #expect([config["config"], config["approvals"]].contains { $0 != nil })
        let schema = try await answer("/api/config/schema", as: ConfigSchemaResponse.self)
        #expect(schema.fields["approvals.mode"]?.type == "select")
        #expect(try await answer("/api/tools/toolsets", as: [ToolsetInfo].self).isEmpty == false)
        #expect(try await answer("/api/env", as: [String: EnvVarInfo].self).isEmpty == false)
    }

    @Test(.enabled(if: LiveGatewayTests.isConfigured, LiveGatewayTests.needsSettings))
    func aTurnStreamsOverTheWebSocket() async throws {
        let settings = try #require(LiveGatewaySettings.load())
        let account = try await settings.signIn()
        let api = HermesAPI(gateway: account.gateway, signer: RequestSigner(authMode: account.mode, secrets: account.secrets))
        let tape = EventTape()
        // Approvals get a one-time yes so the test never waits on a person.
        let yesOnce: JSONValue = ["choice": "once"]
        let socket = GatewaySocket.live(gateway: account.gateway, mode: account.mode, secrets: account.secrets, api: api,
                                        onEvent: { event in Task { await tape.record(event) } },
                                        onRequest: { request in request.method == "approval" ? yesOnce : nil })
        try await Self.bringUp(socket)

        let offered = try await socket.call("client.capabilities", params: ["server_requests": true])["server_requests"]?.arrayValue ?? []
        #expect(offered.contains(.string("approval")))
        let pong = try await socket.call("ping")["pong"]?.boolValue
        #expect(pong == true)

        let created = try await socket.call("session.create", params: ["cols": 80])
        let live = try #require(created["session_id"]?.stringValue)
        let stored = created["stored_session_id"]?.stringValue ?? live
        print("live session", live, stored)

        // Closes the live session and removes the stored row, leaving the gateway clean.
        func tidy() async {
            for (method, id) in [("session.close", live), ("session.delete", stored)] {
                _ = try? await socket.call(method, params: ["session_id": .string(id)])
            }
            await socket.disconnect()
        }

        let marker = "nollie-e2e-\(UUID().uuidString.prefix(8))"
        let submitted: JSONValue
        do {
            submitted = try await socket.call("prompt.submit", params: ["session_id": .string(live), "text": .string("\(marker): answer with one word only: pong")], timeout: 60)
        } catch {
            await tidy()
            throw error
        }
        #expect(submitted["status"]?.stringValue != nil)

        let giveUp = Date().addingTimeInterval(180)
        var complete: GatewayEvent?
        while Date() < giveUp, complete == nil {
            complete = await tape.first { $0.type == "message.complete" && $0.sessionID == live }
            if complete == nil { try await Task.sleep(for: .milliseconds(250)) }
        }
        guard let finished = complete else {
            await tidy()
            Issue.record("no message.complete came back before the deadline")
            return
        }
        let deltas = await tape.count { $0.type == "message.delta" && $0.sessionID == live }
        let finalText = finished.payload["text"]?.stringValue ?? ""
        let turnError = finished.payload["error"]?.stringValue ?? ""
        let status = finished.payload["status"]?.stringValue
        print("live turn: \(deltas) deltas, status \(status ?? "?"), text \(finalText.prefix(80))")

        if turnError.localizedCaseInsensitiveContains("provider") {
            // No model provider is configured at the gateway, so transport, session and error paths are
            // covered but streaming is not. That gets logged and not failed, which keeps a bare install passing.
            print("live streaming skipped, the gateway has no AI provider: \(turnError)")
            #expect(status == "error")
        } else {
            #expect(turnError.isEmpty, "turn error: \(turnError)")
            #expect(!finalText.isEmpty)
            #expect(deltas >= 1, "expected streamed deltas")
            let sessionParams: JSONValue = ["session_id": .string(live)]
            if let reported = try? finished.payload["usage"]?.decode(Usage.self) { #expect((reported.output ?? 0) > 0) }
            let usage: Usage = try await socket.call("session.usage", params: sessionParams).decode()
            #expect((usage.calls ?? 0) > 0)
            let breakdown: ContextBreakdown = try await socket.call("session.context_breakdown", params: sessionParams).decode()
            #expect(breakdown.contextMax > 0 && breakdown.categories.count > 0)
        }

        let catalog: CommandsCatalog = try await socket.call("commands.catalog", params: ["session_id": .string(live)]).decode()
        #expect(!catalog.allPairs.isEmpty)
        await tidy()
    }

    /// Deletes each stored session with a title or first prompt that begins with `nollie-e2e`, in any
    /// letter case (leftover UI-test chats included), then lists again to prove they vanished. Nothing
    /// else is touched.
    @Test(.enabled(if: LiveGatewayTests.isConfigured, LiveGatewayTests.needsSettings))
    func leftoverTestChatsAreCleanedUp() async throws {
        let settings = try #require(LiveGatewaySettings.load())
        let result = try await LiveGatewayLeftovers.remove(using: settings)
        print("live cleanup found=\(result.found) deleted=\(result.deleted) remaining=\(result.remaining)")
        let report = "cleanup saw \(result.found), removed \(result.deleted), \(result.remaining) still listed. " + result.notes.joined(separator: " | ")
        // On a clean gateway finding nothing is expected. Right after a UI run that created some, set
        // HERMES_E2E_EXPECT_LEFTOVERS to stop a failing listing or filter from passing as clean.
        if ProcessInfo.processInfo.environment["HERMES_E2E_EXPECT_LEFTOVERS"] != nil {
            #expect(result.found > 0, "expected leftover nollie-e2e chats but none turned up. \(report)")
        }
        #expect(result.deleted == result.found && result.remaining == 0, "\(report)")
    }
}

/// Finds and deletes the chats the live tests leave behind.
enum LiveGatewayLeftovers {
    static func isTestChat(_ session: StoredSession) -> Bool {
        let candidates = [session.title, session.preview].compactMap { $0 }
        return candidates.contains { text in
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("nollie-e2e")
        }
    }

    /// Gathers the ids of matching sessions for all bots and adds a note per bot with counts and any
    /// error text (never titles), so that an empty listing gets noticed instead of passing unseen.
    static func find(using api: HermesAPI) async throws -> (ids: Set<String>, notes: [String]) {
        let profiles: ProfilesResponse = try await api.get("/api/profiles")
        let bots: [String?] = [nil] + profiles.profiles.map { Optional($0.name) }
        var ids = Set<String>()
        var notes: [String] = []
        for bot in bots {
            let label = bot ?? "(no profile)"
            let query = [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "100")]
            do {
                let page: SessionListResponse = try await api.get("/api/sessions", query: query, profile: bot)
                let matches = page.sessions.filter(isTestChat)
                ids.formUnion(matches.map(\.id))
                let sources = Set(page.sessions.compactMap(\.source)).sorted().joined(separator: "/")
                notes.append("\(label): \(page.sessions.count) listed (total \(page.total.map(String.init) ?? "?")), \(matches.count) matched, sources [\(sources)]")
            } catch {
                notes.append("\(label): list failed: \(String(describing: error).replacingOccurrences(of: "\n", with: " ").prefix(160))")
            }
        }
        return (ids, notes)
    }

    static func remove(using settings: LiveGatewaySettings) async throws -> (found: Int, deleted: Int, remaining: Int, notes: [String]) {
        let account = try await settings.signIn()
        let api = HermesAPI(gateway: account.gateway, signer: RequestSigner(authMode: account.mode, secrets: account.secrets))
        let (ids, notes) = try await find(using: api)
        guard !ids.isEmpty else { return (0, 0, 0, notes) }

        let socket = GatewaySocket.live(gateway: account.gateway, mode: account.mode, secrets: account.secrets, api: api)
        try await LiveGatewayTests.bringUp(socket)

        // A session left open by a different client counts as "active" and refuses deletion. Resume it
        // (this returns a live id), close that live id, and then the stored row can be deleted.
        func takeOver(_ id: String) async {
            let resumeParams: JSONValue = ["session_id": .string(id), "cols": 80]
            guard let resumed = try? await socket.call("session.resume", params: resumeParams) else { return }
            let liveID = resumed["session_id"]?.stringValue ?? id
            _ = try? await socket.call("session.close", params: ["session_id": .string(liveID)])
        }
        var deleted = 0
        var failures: [String] = []
        for id in ids.sorted() {
            await takeOver(id)
            do {
                _ = try await socket.call("session.delete", params: ["session_id": .string(id)])
                deleted += 1
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        await socket.disconnect()
        let after = try await find(using: api)
        return (ids.count, deleted, after.ids.count, notes + failures.prefix(3).map { "delete failed: \($0)" })
    }
}
