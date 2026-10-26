import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// The Private list is kept per gateway, read afresh where it matters, and a choice the gateway
/// hasn't acknowledged is never undone by what the gateway holds.
@Suite(.serialized) struct PrivateBotsScopeTests {
    private let one = UUID(), two = UUID()

    // MARK: Scoping

    @Test func aBotIsPrivateOnTheGatewayThatSaysSo() {
        let bots = PrivateBots()
            .replacing(PrivateBots.Policy(names: ["scout"], settled: true), for: one)
            .replacing(PrivateBots.Policy(names: [], settled: true), for: two)
        #expect(bots.isPrivate("Scout", connection: one))
        #expect(!bots.isPrivate("scout", connection: two))
        // Not knowing which gateway is asking gets the stricter answer.
        #expect(bots.isPrivate("scout", connection: nil))
        #expect(!bots.isPrivate("career", connection: nil))
    }

    @Test func aGatewayWithNoListYetStartsFromTheOlderSharedOne() {
        let bots = PrivateBots(names: ["scout"], settled: true)
        #expect(bots.isPrivate("scout", connection: one) && bots.isPrivate("scout", connection: two))
        let moved = bots.replacing(PrivateBots.Policy(names: [], settled: true), for: one)
        #expect(!moved.isPrivate("scout", connection: one), "the first gateway's own list now decides")
        #expect(moved.isPrivate("scout", connection: two), "the other has not been read yet, so it keeps what was private")
    }

    @Test func anOlderSavedListStillReadsAndCarriesOver() throws {
        let old = Data(#"{"names":["scout","moss"],"settled":true}"#.utf8)
        let bots = try JSONDecoder().decode(PrivateBots.self, from: old)
        #expect(bots.connections == nil)
        #expect(bots.policy(for: one).contains("scout") && bots.policy(for: one).settled)
        #expect(bots.isPrivate("moss", connection: nil))
        // Saving writes the gateway's list beside the old fields, which stay readable.
        let saved = bots.replacing(bots.policy(for: one).setting("career", private: true), for: one)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        #expect(Set(object["names"] as? [String] ?? []) == ["scout", "moss"])
        #expect(object["settled"] as? Bool == true)
        let again = try JSONDecoder().decode(PrivateBots.self, from: JSONEncoder().encode(saved))
        #expect(again == saved)
        #expect(again.isPrivate("career", connection: one) && !again.isPrivate("career", connection: two))
    }

    @Test func theFirstSaveMigratesTheOlderListIntoThatGateway() throws {
        let store = PrivateBotsStore.inMemory(PrivateBots(names: ["scout"], settled: true))
        try store.change(one) { $0.setting("career", private: true) }
        let policy = try #require(store.policy(for: one))
        #expect(policy.contains("scout") && policy.contains("career"))
    }

    // MARK: Unreadable and out of date

    @Test func anUnreadableListCountsAsPrivateAndIsNeverWrittenOver() throws {
        let written = Counter()
        let store = PrivateBotsStore(load: { .unreadable }, write: { _ in written.add() })
        #expect(store.isPrivate("career", connection: one, fresh: true))
        #expect(store.isPrivate("career", connection: nil))
        #expect(store.policy(for: one) == nil)
        #expect(throws: PrivateBotsStore.Failure.self) { try store.change(one) { $0.setting("career", private: true) } }
        #expect(written.count == 0)
    }

    @Test func nothingSavedYetMeansNothingIsPrivate() {
        let store = PrivateBotsStore.inMemory()
        #expect(!store.isPrivate("career", connection: one))
        #expect(!store.isPrivate(nil, connection: one))
    }

    @Test func aFreshReadSeesWhatAnotherProcessSaved() {
        let box = Box(.nothingSaved)
        let store = PrivateBotsStore(load: { box.value }, write: { box.value = .saved($0) })
        #expect(!store.isPrivate("career", connection: one))
        // The app saves from its own process; this one has not looked again.
        box.value = .saved(PrivateBots().replacing(PrivateBots.Policy(names: ["career"], settled: true), for: one))
        #expect(!store.isPrivate("career", connection: one), "an answer is only reused for a moment")
        #expect(store.isPrivate("career", connection: one, fresh: true), "a notification asks afresh")
        #expect(store.isPrivate("career", connection: one), "and the fresh answer is kept")
    }

    @Test func aChangeStartsFromWhatIsSavedNowNotWhatWasSeenBefore() throws {
        let box = Box(.nothingSaved)
        let store = PrivateBotsStore(load: { box.value }, write: { box.value = .saved($0) })
        _ = store.isPrivate("x", connection: one)
        box.value = .saved(PrivateBots().replacing(PrivateBots.Policy(names: ["career"], settled: true), for: two))
        try store.change(one) { $0.setting("scout", private: true) }
        #expect(store.isPrivate("career", connection: two, fresh: true), "the other gateway's list is kept")
        #expect(store.isPrivate("scout", connection: one, fresh: true))
    }

    // MARK: A choice the gateway has not acknowledged

    @Test func aWaitingChoiceIsNotUndoneByTheGatewaysList() {
        let chosen = PrivateBots.Policy(names: [], settled: true).setting("scout", private: true)
        #expect(chosen.pending && chosen.contains("scout"))
        #expect(chosen.taking([]).contains("scout"), "the gateway's old list changes nothing while the choice waits")
        let older = chosen.acknowledged(revision: chosen.revision - 1)
        #expect(older.pending, "an acknowledgement for an earlier choice does not clear a later one")
        let acknowledged = chosen.acknowledged(revision: chosen.revision)
        #expect(!acknowledged.pending)
        #expect(!acknowledged.taking([]).contains("scout"), "once the gateway has it, the gateway's list counts again")
    }

    @MainActor @Test func aFailedWriteKeepsTheBotPrivateAndSaysSo() async throws {
        let gateway = PrivateGateway()
        PrivateGatewayStub.use(gateway)
        defer { PrivateGatewayStub.reset() }
        let rt = try runtime()
        let store = PrivateBotsStore.inMemory()
        gateway.failPuts = true
        let failure = await #expect(throws: PrivateBotsSyncError.self) { try await rt.setPrivate("scout", true, store: store) }
        #expect(failure?.kind == .notTold)
        let words = failure?.errorDescription ?? ""
        #expect(!words.isEmpty)
        #expect(words.unicodeScalars.allSatisfy { $0 != "\u{2014}" }, "no em-dashes in what people read")
        #expect(store.isPrivate("scout", connection: rt.connection.id, fresh: true), "private here at once")
        #expect(rt.privateSyncPending(store: store))
    }

    @MainActor @Test func theGatewaysStaleListCannotMakeAPendingBotPublic() async throws {
        let gateway = PrivateGateway()
        PrivateGatewayStub.use(gateway)
        defer { PrivateGatewayStub.reset() }
        let rt = try runtime()
        let store = PrivateBotsStore.inMemory()
        gateway.failPuts = true
        _ = await #expect(throws: PrivateBotsSyncError.self) { try await rt.setPrivate("scout", true, store: store) }
        // The gateway still has its old, empty list, and a sync happens before the write can be sent.
        await rt.syncPrivateBots(profiles: ["default", "scout"], store: store)
        #expect(store.isPrivate("scout", connection: rt.connection.id, fresh: true))
        #expect(rt.privateSyncPending(store: store))
        // Once the gateway takes the write, the choice is shared and cleared.
        gateway.failPuts = false
        await rt.syncPrivateBots(profiles: ["default", "scout"], store: store)
        #expect(gateway.list == ["scout"])
        #expect(!rt.privateSyncPending(store: store))
        #expect(store.isPrivate("scout", connection: rt.connection.id, fresh: true))
        // From here the gateway's list is the one that counts again.
        gateway.list = []
        await rt.syncPrivateBots(profiles: ["default", "scout"], store: store)
        #expect(!store.isPrivate("scout", connection: rt.connection.id, fresh: true))
    }

    @MainActor @Test func tryingAgainSendsTheWaitingChoice() async throws {
        let gateway = PrivateGateway()
        PrivateGatewayStub.use(gateway)
        defer { PrivateGatewayStub.reset() }
        let rt = try runtime()
        let store = PrivateBotsStore.inMemory()
        gateway.failPuts = true
        _ = await #expect(throws: PrivateBotsSyncError.self) { try await rt.setPrivate("scout", true, store: store) }
        _ = await #expect(throws: PrivateBotsSyncError.self) { try await rt.retryPrivateSync(store: store) }
        #expect(rt.privateSyncPending(store: store))
        gateway.failPuts = false
        try await rt.retryPrivateSync(store: store)
        #expect(gateway.list == ["scout"])
        #expect(!rt.privateSyncPending(store: store))
    }

    @MainActor @Test func turningPrivateOffWaitsForTheGatewaysYes() async throws {
        let gateway = PrivateGateway()
        gateway.list = ["scout"]
        PrivateGatewayStub.use(gateway)
        defer { PrivateGatewayStub.reset() }
        let rt = try runtime()
        let store = PrivateBotsStore.inMemory(PrivateBots().replacing(PrivateBots.Policy(names: ["scout"], settled: true), for: rt.connection.id))
        gateway.failPuts = true
        let failure = await #expect(throws: PrivateBotsSyncError.self) { try await rt.setPrivate("scout", false, store: store) }
        #expect(failure?.kind == .notChanged)
        #expect(store.isPrivate("scout", connection: rt.connection.id, fresh: true), "still private")
        gateway.failPuts = false
        try await rt.setPrivate("scout", false, store: store)
        #expect(gateway.list.isEmpty)
        #expect(!store.isPrivate("scout", connection: rt.connection.id, fresh: true))
        #expect(!rt.privateSyncPending(store: store))
    }

    @MainActor @Test func aGatewayWithoutTheAddOnIsNotAFailure() async throws {
        let gateway = PrivateGateway()
        gateway.hasAddOn = false
        PrivateGatewayStub.use(gateway)
        defer { PrivateGatewayStub.reset() }
        let rt = try runtime()
        let store = PrivateBotsStore.inMemory()
        try await rt.setPrivate("scout", true, store: store)
        #expect(store.isPrivate("scout", connection: rt.connection.id, fresh: true))
        #expect(!rt.privateSyncPending(store: store))
    }

    @MainActor @Test func twoGatewaysKeepSeparateLists() async throws {
        let gateway = PrivateGateway()
        PrivateGatewayStub.use(gateway)
        defer { PrivateGatewayStub.reset() }
        let first = try runtime(), second = try runtime()
        let store = PrivateBotsStore.inMemory()
        try await first.setPrivate("default", true, store: store)
        #expect(store.isPrivate("default", connection: first.connection.id, fresh: true))
        #expect(!store.isPrivate("default", connection: second.connection.id, fresh: true))
        // Reading the second gateway's list does not take the first one's away.
        gateway.list = []
        await second.syncPrivateBots(profiles: ["default"], store: store)
        #expect(store.isPrivate("default", connection: first.connection.id, fresh: true))
    }

    // MARK: Pieces

    @MainActor private func runtime() throws -> GatewayRuntime {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivateGatewayStub.self]
        let connection = GatewayConnection(name: "private-unit", gateway: try GatewayURL.normalize("https://private.invalid"), authMode: .sessionToken)
        return GatewayRuntime(connection: connection, store: ConnectionStore(),
                              backend: GatewayBackend(urlSession: URLSession(configuration: configuration)))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PrivateBotsStore.Reading
    init(_ stored: PrivateBotsStore.Reading) { self.stored = stored }
    var value: PrivateBotsStore.Reading {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A pretend gateway with the Private list add-on.
private final class PrivateGateway: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private var failing = false
    private var present = true
    private var saved = false

    var list: [String] {
        get { lock.withLock { names } }
        set { lock.withLock { names = newValue; saved = true } }
    }
    var failPuts: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    var hasAddOn: Bool {
        get { lock.withLock { present } }
        set { lock.withLock { present = newValue } }
    }

    func respond(_ request: URLRequest) -> (Int, Data) {
        lock.withLock {
            guard present, request.url?.path == "/api/plugins/nollie-workflow/private-bots" else { return (404, Data("{}".utf8)) }
            if request.httpMethod == "PUT" {
                if failing { return (503, Data("{}".utf8)) }
                let body = (try? JSONSerialization.jsonObject(with: PrivateGatewayStub.body(request))) as? [String: Any]
                names = (body?["profiles"] as? [String] ?? []).sorted()
                saved = true
            }
            return (200, try! JSONSerialization.data(withJSONObject: ["profiles": names, "saved": saved]))
        }
    }
}

private final class PrivateGatewayStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gateway: PrivateGateway?

    static func use(_ gateway: PrivateGateway) { lock.withLock { Self.gateway = gateway } }
    static func reset() { lock.withLock { gateway = nil } }

    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let gateway = Self.lock.withLock({ Self.gateway }) else { return }
        let (status, data) = gateway.respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
