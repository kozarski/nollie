import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// System control is kept per bot on each gateway: two gateways can both have a "default", and
/// consent given to one is never the other's.
@MainActor
@Suite(.serialized) struct SystemControlScopeTests {
    private let screen = ApprovalRequest(requestId: "r", sessionId: "s", patternKey: "cua:click:background")

    private func runtime(_ host: String, profile: String = "default") throws -> GatewayRuntime {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScopeStub.self]
        let connection = GatewayConnection(name: host, gateway: try GatewayURL.normalize("https://" + host), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: connection, store: ConnectionStore(),
                                backend: GatewayBackend(urlSession: URLSession(configuration: configuration)))
        rt.profiles = [ProfileInfo(name: profile, path: "/fixture/" + host + "/" + profile)]
        return rt
    }

    private func answer(_ control: SystemControl, _ rt: GatewayRuntime) -> String? {
        control.autoAnswer(screen, profile: "default", connection: rt.connection.id, gateway: rt.connection.gateway)
    }

    @Test func consentForOneGatewaysBotNeverAnswersAnothers() async throws {
        let fixture = ScopeFixture(leases: ["a.invalid": "agent", "b.invalid": "agent"])
        ScopeStub.use(fixture)
        defer { ScopeStub.reset() }
        let a = try runtime("a.invalid"), b = try runtime("b.invalid")
        let control = SystemControl()
        await control.refresh("default", a)
        #expect(control.isOn("default", a))
        #expect(answer(control, a) == "session")
        // Gateway B's bot of the same name has not been read, so it gets its card.
        #expect(control.state("default", b) == nil)
        #expect(!control.isOn("default", b))
        #expect(answer(control, b) == nil)
        // Reading B says what B says, and leaves A alone.
        fixture.setLease("b.invalid", "human")
        await control.refresh("default", b)
        #expect(control.state("default", b) == false)
        #expect(answer(control, b) == nil)
        #expect(answer(control, a) == "session")
    }

    @Test func aRecentReadOfOneGatewayDoesNotHoldBackTheOthers() async throws {
        let fixture = ScopeFixture(leases: ["a.invalid": "agent", "b.invalid": "agent"])
        ScopeStub.use(fixture)
        defer { ScopeStub.reset() }
        let a = try runtime("a.invalid"), b = try runtime("b.invalid")
        let control = SystemControl()
        await control.refreshAll(a)
        #expect(fixture.leaseReads("b.invalid") == 0)
        await control.refreshAll(b)
        #expect(fixture.leaseReads("b.invalid") == 1)
        #expect(control.isOn("default", b))
        // Within the minute, each gateway's own reading is reused.
        await control.refreshAll(a)
        #expect(fixture.leaseReads("a.invalid") == 1)
    }

    @Test func aStateReadFromAnotherAddressDoesNotCount() async throws {
        let fixture = ScopeFixture(leases: ["a.invalid": "agent"])
        ScopeStub.use(fixture)
        defer { ScopeStub.reset() }
        let a = try runtime("a.invalid")
        let control = SystemControl()
        await control.refresh("default", a)
        #expect(answer(control, a) == "session")
        a.connection.gateway = try GatewayURL.normalize("https://moved.invalid")
        #expect(control.state("default", a) == nil)
        #expect(answer(control, a) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aReadThatFinishesAfterTheConnectionMovedIsDropped() async throws {
        let fixture = ScopeFixture(leases: ["a.invalid": "agent"])
        fixture.holdFirstLeaseRead("a.invalid")
        ScopeStub.use(fixture)
        defer { ScopeStub.reset() }
        let a = try runtime("a.invalid")
        let control = SystemControl()
        let read = Task { await control.refresh("default", a) }
        await fixture.waitForHeldRead()
        a.connection.gateway = try GatewayURL.normalize("https://moved.invalid")
        ScopeStub.releaseHeld()
        await read.value
        #expect(control.states[SystemControl.key("default", a)] == nil)
        #expect(answer(control, a) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aReadThatFinishesAfterASwitchWasWrittenIsDropped() async throws {
        // The first read sees the lease as a person's. While it is in flight the switch is turned on.
        let fixture = ScopeFixture(leases: ["a.invalid": "human"])
        fixture.holdFirstLeaseRead("a.invalid")
        ScopeStub.use(fixture)
        defer { ScopeStub.reset() }
        let a = try runtime("a.invalid")
        let control = SystemControl()
        let read = Task { await control.refresh("default", a) }
        await fixture.waitForHeldRead()
        #expect(await control.set(true, profile: "default", rt: a))
        ScopeStub.releaseHeld()
        await read.value
        #expect(control.isOn("default", a))
        #expect(answer(control, a) == "session")
    }

    /// Hermes's own computer_use sends whole screenshots to the bot's model: it stays switched off,
    /// whichever way the switch goes, and an older version's "on" is taken back once. Never for a
    /// private bot, whose settings Nollie doesn't touch.
    @Test func hermesOwnComputerUseStaysOff() async throws {
        // A Private list that reads, as on a signed device: an unreadable one counts every bot as private.
        PrivateBots.useForTesting(PrivateBots(names: ["private", "moss"], settled: true))
        let fixture = ScopeFixture(leases: ["a.invalid": "human"])
        ScopeStub.use(fixture)
        defer { ScopeStub.reset() }
        let a = try runtime("a.invalid")
        let control = SystemControl()
        #expect(await control.set(true, profile: "default", rt: a))
        #expect(fixture.disabledWritten("a.invalid") == [["computer_use"]])
        #expect(control.isOn("default", a))
        await control.refresh("default", a)
        await control.refresh("default", a)
        // The pretend gateway still reports nothing switched off: already asked this run, so left alone.
        #expect(fixture.disabledWritten("a.invalid") == [["computer_use"]])
        #expect(control.isOn("default", a), "the switch is the lease alone")
        // A bot an older version left with it on: taken back once on the next read.
        a.profiles.append(ProfileInfo(name: "career", path: "/fixture/a.invalid/career"))
        await control.refresh("career", a)
        await control.refresh("career", a)
        #expect(fixture.disabledWritten("a.invalid") == [["computer_use"], ["computer_use"]])
        // Never a private bot's settings.
        a.profiles.append(ProfileInfo(name: "moss", path: "/fixture/a.invalid/moss"))
        await control.refresh("moss", a)
        #expect(fixture.disabledWritten("a.invalid").count == 2)
    }

    /// Hermes reads no lease as the bot's. The first read gives the bot a person's, so This Mac is off
    /// until the person turns it on, and the switch shows exactly that.
    @Test func aBotWithoutALeaseStartsOff() async throws {
        // A Private list that reads, as on a signed device: an unreadable one counts every bot as private.
        PrivateBots.useForTesting(PrivateBots(names: ["private", "moss"], settled: true))
        let fixture = ScopeFixture(leases: ["lease-none.invalid": ScopeFixture.missing])
        ScopeStub.use(fixture)
        defer { ScopeStub.reset() }
        let rt = try runtime("lease-none.invalid")
        let control = SystemControl()
        await control.refresh("default", rt)
        #expect(control.state("default", rt) == false)
        #expect(fixture.uploads("lease-none.invalid") == [UploadedLease(holder: "human", epoch: 1, overwrite: false)])
        #expect(answer(control, rt) == nil)
        // Read again, the person's lease is simply read: nothing more is written.
        await control.refresh("default", rt)
        #expect(fixture.uploads("lease-none.invalid").count == 1)
        // Turning it on hands the lease to the bot, past the epoch the person's lease began.
        #expect(await control.set(true, profile: "default", rt: rt))
        #expect(fixture.uploads("lease-none.invalid").last == UploadedLease(holder: "agent", epoch: 2, overwrite: true))
    }

    @Test func aLeaseThatAppearedMeanwhileIsNeverWrittenOver() async throws {
        // A Private list that reads, as on a signed device: an unreadable one counts every bot as private.
        PrivateBots.useForTesting(PrivateBots(names: ["private", "moss"], settled: true))
        let fixture = ScopeFixture(leases: ["lease-race.invalid": ScopeFixture.missing])
        fixture.leaseAppearsOnUpload("lease-race.invalid")
        ScopeStub.use(fixture)
        defer { ScopeStub.reset() }
        let rt = try runtime("lease-race.invalid")
        let control = SystemControl()
        await control.refresh("default", rt)
        #expect(control.state("default", rt) == nil)
        #expect(fixture.uploads("lease-race.invalid") == [UploadedLease(holder: "human", epoch: 1, overwrite: false)])
    }

    @Test func aPrivateBotWithoutALeaseIsLeftAlone() async throws {
        // A Private list that reads, as on a signed device: an unreadable one counts every bot as private.
        PrivateBots.useForTesting(PrivateBots(names: ["private", "moss"], settled: true))
        let fixture = ScopeFixture(leases: ["lease-private.invalid": ScopeFixture.missing])
        ScopeStub.use(fixture)
        defer { ScopeStub.reset() }
        let rt = try runtime("lease-private.invalid", profile: "moss")
        let control = SystemControl()
        await control.refresh("moss", rt)
        #expect(fixture.uploads("lease-private.invalid").isEmpty)
        #expect(control.state("moss", rt) == false)
    }

    @Test func aFailedWriteRestoresWhatWasKnownForThatGatewayOnly() async throws {
        let fixture = ScopeFixture(leases: ["a.invalid": "agent", "b.invalid": "agent"])
        ScopeStub.use(fixture)
        defer { ScopeStub.reset() }
        let a = try runtime("a.invalid"), b = try runtime("b.invalid")
        let control = SystemControl()
        await control.refresh("default", a)
        await control.refresh("default", b)
        fixture.failUploads("a.invalid")
        #expect(!(await control.set(false, profile: "default", rt: a)))
        #expect(control.isOn("default", a))
        #expect(control.isOn("default", b))
        #expect(!control.isBusy("default", a))
    }
}

// MARK: A pretend gateway

private struct UploadedLease: Equatable {
    var holder: String
    var epoch: Int
    var overwrite: Bool
}

/// What each pretend gateway holds, by host, and what has been asked of it.
private final class ScopeFixture: @unchecked Sendable {
    /// A host whose bot has no lease file yet.
    static let missing = "(none)"
    private let lock = NSLock()
    private var leases: [String: String]
    private var epochs: [String: Int] = [:]
    private var reads: [String: Int] = [:]
    private var uploaded: [String: [UploadedLease]] = [:]
    private var appears: Set<String> = []
    private var uploadsFail: Set<String> = []
    private var holdFirst: Set<String> = []
    private var disabled: [String: [[String]]] = [:]
    let heldRead = AsyncStream<Void>.makeStream()

    init(leases: [String: String]) { self.leases = leases }

    func setLease(_ host: String, _ holder: String) { lock.withLock { leases[host] = holder } }
    func leaseReads(_ host: String) -> Int { lock.withLock { reads[host] ?? 0 } }
    func failUploads(_ host: String) { lock.withLock { _ = uploadsFail.insert(host) } }
    func uploads(_ host: String) -> [UploadedLease] { lock.withLock { uploaded[host] ?? [] } }
    /// Someone else writes a lease between the read and the upload.
    func leaseAppearsOnUpload(_ host: String) { lock.withLock { _ = appears.insert(host) } }
    func holdFirstLeaseRead(_ host: String) { lock.withLock { _ = holdFirst.insert(host) } }
    /// Each switched-off tool list a config write sent.
    func disabledWritten(_ host: String) -> [[String]] { lock.withLock { disabled[host] ?? [] } }

    func waitForHeldRead() async {
        var iterator = heldRead.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func respond(_ request: URLRequest) -> ScopeStub.Outcome {
        let host = request.url?.host ?? ""
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? ""
        return lock.withLock {
            switch (method, path) {
            case ("GET", "/api/fs/read-text"):
                reads[host, default: 0] += 1
                if leases[host] == Self.missing { return .reply(ScopeStub.Reply(404, [:])) }
                let text = String(data: try! JSONSerialization.data(withJSONObject: ["holder": leases[host] ?? "agent", "epoch": epochs[host] ?? 3]), encoding: .utf8)!
                let reply = ScopeStub.Reply(200, ["text": text])
                if holdFirst.remove(host) != nil {
                    heldRead.continuation.yield(())
                    return .hold(reply)
                }
                return .reply(reply)
            case ("GET", "/api/config"):
                return .reply(ScopeStub.Reply(200, ["config": ["command_allowlist": [String](), "agent": ["disabled_toolsets": [String]()]]]))
            case ("PUT", "/api/config"):
                let body = (try? JSONSerialization.jsonObject(with: ScopeStub.body(request))) as? [String: Any]
                let agent = (body?["config"] as? [String: Any])?["agent"] as? [String: Any]
                if let tools = agent?["disabled_toolsets"] as? [String] { disabled[host, default: []].append(tools) }
                return .reply(ScopeStub.Reply(200, [:]))
            case ("POST", "/api/files/upload"):
                if uploadsFail.contains(host) { return .reply(ScopeStub.Reply(503, [:])) }
                let body = (try? JSONSerialization.jsonObject(with: ScopeStub.body(request))) as? [String: Any]
                let overwrite = body?["overwrite"] as? Bool ?? false
                if let encoded = (body?["data_url"] as? String)?.split(separator: ",", maxSplits: 1).last,
                   let data = Data(base64Encoded: String(encoded)),
                   let written = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let holder = written["holder"] as? String {
                    uploaded[host, default: []].append(UploadedLease(holder: holder, epoch: (written["epoch"] as? Int) ?? -1,
                                                                     overwrite: overwrite))
                    if !overwrite, appears.contains(host) || leases[host] != Self.missing {
                        return .reply(ScopeStub.Reply(409, ["detail": "File already exists"]))
                    }
                    leases[host] = holder
                    epochs[host] = written["epoch"] as? Int
                }
                return .reply(ScopeStub.Reply(200, ["ok": true, "path": body?["path"] as? String ?? ""]))
            default:
                return .reply(ScopeStub.Reply(404, [:]))
            }
        }
    }
}

private final class ScopeStub: URLProtocol, @unchecked Sendable {
    struct Reply: @unchecked Sendable {
        var status: Int
        var json: [String: Any]
        init(_ status: Int, _ json: [String: Any]) { (self.status, self.json) = (status, json) }
    }

    enum Outcome: @unchecked Sendable {
        case reply(Reply)
        /// Answered later, by `releaseHeld`.
        case hold(Reply)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture: ScopeFixture?
    nonisolated(unsafe) private static var held: [(stub: ScopeStub, reply: Reply)] = []

    static func use(_ fixture: ScopeFixture) { lock.withLock { Self.fixture = fixture; held = [] } }
    static func reset() { lock.withLock { fixture = nil; held = [] } }

    static func releaseHeld() {
        let waiting = lock.withLock { let all = held; held = []; return all }
        for (stub, reply) in waiting { stub.deliver(reply) }
    }

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
        guard let fixture = Self.lock.withLock({ Self.fixture }) else { return }
        switch fixture.respond(request) {
        case .reply(let reply): deliver(reply)
        case .hold(let reply): Self.lock.withLock { Self.held.append((self, reply)) }
        }
    }

    func deliver(_ reply: Reply) {
        let data = (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
