import Foundation
import Testing
@testable import NollieCore

// MARK: Helpers (prefixed GMT so they never clash with other gateway test files)

/// Runs a `GatewayMachine` and remembers what a real driver would: the socket it last opened and the
/// latest generation of every timer it scheduled.
private struct GMTDriver {
    var machine: GatewayMachine
    var socket = 0
    var generations: [GatewayTimer: Int] = [:]
    var log: [GatewayMachine.Effect] = []

    init(_ configure: (inout GatewayConfiguration) -> Void = { _ in }) {
        var configuration = GatewayConfiguration()
        configure(&configuration)
        machine = GatewayMachine(configuration: configuration)
    }

    @discardableResult
    mutating func feed(_ input: GatewayMachine.Input) -> [GatewayMachine.Effect] {
        let effects = machine.handle(input)
        for effect in effects {
            switch effect {
            case .schedule(let timer, let generation, _): generations[timer] = generation
            case .open(let number): socket = number
            default: break
            }
        }
        log += effects
        return effects
    }

    /// Fires the latest scheduled generation of `timer`.
    @discardableResult
    mutating func fire(_ timer: GatewayTimer) -> [GatewayMachine.Effect] {
        guard let generation = generations[timer] else {
            Issue.record("\(timer) was never scheduled")
            return []
        }
        return feed(.timerFired(timer, generation: generation))
    }

    @discardableResult
    mutating func receive(_ text: String) -> [GatewayMachine.Effect] {
        feed(.received(socket: socket, text))
    }

    /// Sends `gateway.ready` and answers the capabilities call it causes.
    @discardableResult
    mutating func handshake(epoch: String = "epoch-1") -> [GatewayMachine.Effect] {
        let readyEffects = receive(gmtReadyFrame(epoch: epoch))
        guard let capabilities = gmtSent(readyEffects).first(where: { $0["method"] == "client.capabilities" }),
              let id = capabilities["id"]?.intValue else {
            Issue.record("gateway.ready did not send client.capabilities")
            return readyEffects
        }
        return readyEffects + receive(gmtResult(id: id, ["server_requests": ["approval", "clarify"]]))
    }

    /// From idle or closed: start, open and finish the handshake.
    @discardableResult
    mutating func bringUp(epoch: String = "epoch-1") -> [GatewayMachine.Effect] {
        var effects = feed(.start)
        effects += feed(.opened(socket: socket))
        effects += handshake(epoch: epoch)
        return effects
    }

    /// From retrying: fire the retry timer, open and finish the handshake.
    @discardableResult
    mutating func reconnect(epoch: String = "epoch-1") -> [GatewayMachine.Effect] {
        var effects = fire(.retry)
        effects += feed(.opened(socket: socket))
        effects += handshake(epoch: epoch)
        return effects
    }
}

private func gmtText(_ json: GatewayJSON) -> String {
    String(decoding: (try? json.encoded()) ?? Data(), as: UTF8.self)
}

private func gmtReadyFrame(epoch: String) -> String {
    gmtText(["jsonrpc": "2.0", "method": "event",
             "params": ["type": "gateway.ready", "payload": ["replay_epoch": .string(epoch)]]])
}

private func gmtResult(id: Int, _ result: GatewayJSON) -> String {
    gmtText(["jsonrpc": "2.0", "id": .integer(id), "result": result])
}

private func gmtFailure(id: Int, code: Int, message: String, data: GatewayJSON? = nil) -> String {
    var error: [String: GatewayJSON] = ["code": .integer(code), "message": .string(message)]
    if let data { error["data"] = data }
    return gmtText(["jsonrpc": "2.0", "id": .integer(id), "error": .object(error)])
}

private func gmtEventFrame(type: String, session: String = "", seq: Int? = nil) -> String {
    var params: [String: GatewayJSON] = ["type": .string(type), "session_id": .string(session)]
    if let seq { params["seq"] = .integer(seq) }
    return gmtText(["jsonrpc": "2.0", "method": "event", "params": .object(params)])
}

/// Every frame the effects write, read back as JSON.
private func gmtSent(_ effects: [GatewayMachine.Effect]) -> [GatewayJSON] {
    effects.compactMap { effect in
        guard case .send(_, let text) = effect else { return nil }
        return try? GatewayJSON.parse(Data(text.utf8))
    }
}

private func gmtSentMethods(_ effects: [GatewayMachine.Effect]) -> [String] {
    gmtSent(effects).compactMap { $0["method"]?.stringValue }
}

private func gmtPhases(_ effects: [GatewayMachine.Effect]) -> [GatewayPhase] {
    effects.compactMap { effect in
        guard case .phase(let phase) = effect else { return nil }
        return phase
    }
}

private func gmtScheduled(_ timer: GatewayTimer, in effects: [GatewayMachine.Effect]) -> [Duration] {
    effects.compactMap { effect in
        guard case .schedule(timer, _, let after) = effect else { return nil }
        return after
    }
}

private func gmtFinishes(_ effects: [GatewayMachine.Effect]) -> [(call: Int, result: Result<GatewayJSON, GatewayCallFailure>)] {
    effects.compactMap { effect in
        guard case .finish(let call, let result) = effect else { return nil }
        return (call, result)
    }
}

private func gmtOpens(_ effects: [GatewayMachine.Effect]) -> [Int] {
    effects.compactMap { effect in
        guard case .open(let number) = effect else { return nil }
        return number
    }
}

private func gmtCloses(_ effects: [GatewayMachine.Effect]) -> [(socket: Int, code: Int)] {
    effects.compactMap { effect in
        guard case .close(let number, let code) = effect else { return nil }
        return (number, code)
    }
}

/// The delays of every `retrying` phase in the log, in order.
private func gmtRetryDelays(_ effects: [GatewayMachine.Effect]) -> [Duration] {
    gmtPhases(effects).compactMap { phase in
        guard case .retrying(_, let delay) = phase else { return nil }
        return delay
    }
}

private func gmtMilliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
}

/// Fails the open of every attempt until `count` retry delays have been chosen.
private func gmtCollectRetryDelays(_ driver: inout GMTDriver, count: Int) -> [Duration] {
    driver.feed(.start)
    driver.feed(.openFailed(socket: driver.socket, .unreachable("down")))
    while gmtRetryDelays(driver.log).count < count {
        driver.fire(.retry)
        driver.feed(.openFailed(socket: driver.socket, .unreachable("down")))
    }
    return gmtRetryDelays(driver.log)
}

// MARK: Tests

@Suite struct GatewayMachineTests {
    // MARK: Connecting and the handshake

    @Test func startOpensTheFirstSocketUnderAConnectDeadline() {
        var driver = GMTDriver()
        #expect(driver.machine.phase == .idle)
        let effects = driver.feed(.start)
        #expect(gmtPhases(effects) == [.connecting(attempt: 1)])
        #expect(gmtOpens(effects) == [1])
        #expect(gmtScheduled(.connectDeadline, in: effects) == [.seconds(15)])
        #expect(gmtSent(effects).isEmpty)
        #expect(driver.machine.phase == .connecting(attempt: 1))
    }

    @Test func startWhileAlreadyConnectingDoesNothing() {
        var driver = GMTDriver()
        driver.feed(.start)
        #expect(driver.feed(.start).isEmpty)
        driver.feed(.opened(socket: 1))
        #expect(driver.feed(.start).isEmpty)
        driver.handshake()
        #expect(driver.feed(.start).isEmpty)
        #expect(driver.machine.phase == .ready)
    }

    @Test func openingTheSocketStartsTheHandshakeAndWatchesForSilence() {
        var driver = GMTDriver()
        driver.feed(.start)
        let effects = driver.feed(.opened(socket: 1))
        #expect(gmtPhases(effects) == [.handshaking(attempt: 1)])
        #expect(gmtScheduled(.silence, in: effects) == [.seconds(45)])
        #expect(gmtSent(effects).isEmpty, "nothing is written before Hermes says it is ready")
    }

    @Test func gatewayReadyIsPassedOnAndAsksForServerRequests() throws {
        var driver = GMTDriver()
        driver.feed(.start)
        driver.feed(.opened(socket: 1))
        let effects = driver.receive(gmtReadyFrame(epoch: "e-1"))

        #expect(effects.contains { if case .event(let event) = $0 { event.type == "gateway.ready" } else { false } })
        let sent = gmtSent(effects)
        try #require(sent.count == 1)
        #expect(sent[0]["jsonrpc"] == "2.0")
        #expect(sent[0]["id"] == .integer(1))
        #expect(sent[0]["method"] == "client.capabilities")
        #expect(sent[0]["params"]?["server_requests"] == .bool(true))
        #expect(effects.allSatisfy { if case .send(let socket, _) = $0 { socket == 1 } else { true } })
        #expect(driver.machine.phase == .handshaking(attempt: 1), "still handshaking until capabilities answer")
        #expect(driver.machine.epoch == "e-1")
    }

    @Test func aSecondGatewayReadyOnTheSameSocketDoesNotRepeatTheHandshake() {
        var driver = GMTDriver()
        driver.feed(.start)
        driver.feed(.opened(socket: 1))
        driver.receive(gmtReadyFrame(epoch: "e-1"))
        let again = driver.receive(gmtReadyFrame(epoch: "e-1"))
        #expect(gmtSentMethods(again).isEmpty)
    }

    @Test func capabilitiesAnswerMakesTheConnectionReadyWithHeartbeatAndStableTimers() {
        var driver = GMTDriver()
        driver.feed(.start)
        driver.feed(.opened(socket: 1))
        driver.receive(gmtReadyFrame(epoch: "e-1"))
        let effects = driver.receive(gmtResult(id: 1, ["server_requests": ["approval"]]))

        #expect(gmtPhases(effects) == [.ready])
        #expect(gmtScheduled(.heartbeat, in: effects) == [.seconds(15)])
        #expect(gmtScheduled(.stable, in: effects) == [.seconds(10)])
        #expect(effects.contains(.cancelTimer(.connectDeadline)))
        #expect(driver.machine.questionsHermesMaySend == ["approval"])
    }

    @Test func theFirstConnectionNeverReplaysButLearnsWhereUnknownSessionsStand() throws {
        var driver = GMTDriver()
        #expect(gmtSentMethods(driver.bringUp()) == ["client.capabilities"])
        #expect(driver.machine.phase == .ready)

        // A watched session the app has no position for gets a probe, not a replay from 0.
        var watching = GMTDriver()
        watching.feed(.watch(session: "s-1", profile: nil, from: nil))
        let effects = watching.bringUp()
        #expect(gmtSentMethods(effects) == ["client.capabilities", "session.events.since"])
        let probe = try #require(gmtSent(effects).last)
        #expect(probe["params"] == ["session_id": "s-1", "last_seen": .integer(GatewayMachine.probeLastSeen)])
        #expect(gmtScheduled(.replayDeadline, in: effects) == [.seconds(10)])
        #expect(watching.machine.phase != .ready)
        let answered = watching.receive(gmtResult(id: 2, ["events": [], "latest_seq": 12, "truncated": false, "count": 0,
                                                          "epoch": "epoch-1", "open_requests": []]))
        #expect(gmtPhases(answered) == [.ready])
        #expect(watching.machine.watermarks["s-1"] == 12)
        #expect(watching.machine.known.contains("s-1"))
    }

    @Test func aReconnectCatchesUpOnWatchedSessionsBeforeReady() {
        var driver = GMTDriver { $0.retryJitter = 0 }
        driver.feed(.watch(session: "s-1", profile: nil, from: nil))
        driver.bringUp()
        driver.feed(.closed(socket: driver.socket, code: 1006))
        driver.fire(.retry)
        driver.feed(.opened(socket: driver.socket))
        let effects = driver.handshake()
        #expect(gmtSentMethods(effects) == ["client.capabilities", "session.events.since"])
        #expect(driver.machine.phase == .handshaking(attempt: 2), "ready waits for the catch-up")
    }

    // MARK: Retrying

    @Test func retryDelaysDoubleFromTheBaseUpToTheCap() {
        var driver = GMTDriver { $0.retryJitter = 0 }
        let delays = gmtCollectRetryDelays(&driver, count: 9)
        #expect(delays == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16),
                           .seconds(30), .seconds(30), .seconds(30)])
    }

    @Test func aDropFromReadyRetriesAndTheRetryTimerConnectsAgain() {
        var driver = GMTDriver { $0.retryJitter = 0 }
        driver.bringUp()
        let dropped = driver.feed(.closed(socket: 1, code: 1006))
        #expect(gmtPhases(dropped) == [.retrying(attempt: 2, delay: .milliseconds(500))])
        #expect(gmtScheduled(.retry, in: dropped) == [.milliseconds(500)])
        #expect(gmtCloses(dropped).isEmpty, "the socket is already closed")
        for timer in [GatewayTimer.heartbeat, .silence, .stable] {
            #expect(dropped.contains(.cancelTimer(timer)), "\(timer) stops with the socket")
        }

        let again = driver.fire(.retry)
        #expect(gmtPhases(again) == [.connecting(attempt: 2)])
        #expect(gmtOpens(again) == [2])
        #expect(gmtScheduled(.connectDeadline, in: again) == [.seconds(15)])
    }

    @Test func retryDelaysUseTheConfiguredBaseAndCap() {
        var driver = GMTDriver {
            $0.retryJitter = 0
            $0.retryBase = .seconds(1)
            $0.retryCap = .seconds(5)
        }
        let delays = gmtCollectRetryDelays(&driver, count: 5)
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5)])
    }

    @Test func jitterStaysWithinItsBounds() {
        var driver = GMTDriver { $0.retryJitter = 0.2 }
        let delays = gmtCollectRetryDelays(&driver, count: 40)
        var exact: [Double] = []
        var step = 500.0
        for _ in delays {
            exact.append(min(step, 30_000))
            step *= 2
        }
        for (delay, nominal) in zip(delays, exact) {
            let ms = gmtMilliseconds(delay)
            #expect(ms >= nominal * 0.8 - 1 && ms <= nominal * 1.2 + 1, "\(ms) ms is outside 20% of \(nominal) ms")
        }
        #expect(zip(delays, exact).contains { gmtMilliseconds($0) != $1 }, "jitter moves at least some delays")
    }

    @Test func theSameSeedGivesTheSameDelays() {
        var first = GMTDriver { $0.seed = 42 }
        var second = GMTDriver { $0.seed = 42 }
        var other = GMTDriver { $0.seed = 43 }
        let a = gmtCollectRetryDelays(&first, count: 12)
        let b = gmtCollectRetryDelays(&second, count: 12)
        let c = gmtCollectRetryDelays(&other, count: 12)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func stayingReadyResetsTheAttemptCount() {
        var driver = GMTDriver { $0.retryJitter = 0 }
        driver.bringUp()
        driver.feed(.closed(socket: driver.socket, code: 1006))
        driver.reconnect()
        #expect(driver.machine.phase == .ready)
        driver.fire(.stable)
        // The count starts over from 1 since the connection stayed up, and the delay drops back to the base.
        let dropped = driver.feed(.closed(socket: driver.socket, code: 1006))
        #expect(gmtPhases(dropped) == [.retrying(attempt: 1, delay: .milliseconds(500))])
        #expect(gmtPhases(driver.fire(.retry)) == [.connecting(attempt: 1)])
    }

    @Test func aShortLivedConnectionKeepsCountingAttempts() {
        var driver = GMTDriver { $0.retryJitter = 0 }
        driver.bringUp()
        driver.feed(.closed(socket: driver.socket, code: 1006))
        driver.reconnect()
        // Dropped again before the stable timer fired.
        let dropped = driver.feed(.closed(socket: driver.socket, code: 1006))
        #expect(gmtPhases(dropped) == [.retrying(attempt: 3, delay: .seconds(1))])
    }

    @Test func runningOutOfAttemptsGivesUp() {
        var driver = GMTDriver {
            $0.retryJitter = 0
            $0.maxAttempts = 3
        }
        driver.feed(.start)
        driver.feed(.openFailed(socket: driver.socket, .unreachable("down")))
        driver.fire(.retry)
        driver.feed(.openFailed(socket: driver.socket, .unreachable("down")))
        driver.fire(.retry)
        let last = driver.feed(.openFailed(socket: driver.socket, .unreachable("down")))

        #expect(gmtPhases(last) == [.closed(.gaveUp)])
        #expect(gmtScheduled(.retry, in: last).isEmpty)
        #expect(gmtOpens(driver.log).count == 3)
        #expect(driver.machine.phase == .closed(.gaveUp))
    }

    @Test(arguments: [401, 403])
    func aRefusedOpenClosesWithoutRetrying(status: Int) {
        var driver = GMTDriver()
        driver.feed(.start)
        let effects = driver.feed(.openFailed(socket: 1, .refused(status: status)))
        #expect(gmtPhases(effects) == [.closed(.refused(code: status))])
        #expect(gmtScheduled(.retry, in: effects).isEmpty)
        #expect(driver.machine.phase == .closed(.refused(code: status)))
    }

    @Test(arguments: [GatewayTransportError.refused(status: 500), .refused(status: 404), .unreachable("no route")])
    func otherOpenFailuresRetry(error: GatewayTransportError) {
        var driver = GMTDriver { $0.retryJitter = 0 }
        driver.feed(.start)
        let effects = driver.feed(.openFailed(socket: 1, error))
        #expect(gmtPhases(effects) == [.retrying(attempt: 2, delay: .milliseconds(500))])
        #expect(gmtScheduled(.retry, in: effects) == [.milliseconds(500)])
    }

    @Test(arguments: [4401, 4403])
    func refusalCloseCodesCloseWithoutRetrying(code: Int) {
        var driver = GMTDriver()
        driver.bringUp()
        let effects = driver.feed(.closed(socket: 1, code: code))
        #expect(gmtPhases(effects) == [.closed(.refused(code: code))])
        #expect(gmtScheduled(.retry, in: effects).isEmpty)
    }

    @Test(arguments: [Int?.none, 1000, 1001, 1006, 1011, 4000])
    func otherClosesRetry(code: Int?) {
        var driver = GMTDriver()
        driver.bringUp()
        let effects = driver.feed(.closed(socket: 1, code: code))
        #expect(gmtScheduled(.retry, in: effects).count == 1)
        guard case .retrying(attempt: 2, _) = driver.machine.phase else {
            Issue.record("expected retrying, got \(driver.machine.phase)")
            return
        }
    }

    // MARK: Deadlines, silence and heartbeat

    @Test func theConnectDeadlineRetriesWhileTheSocketIsStillOpening() {
        var driver = GMTDriver { $0.retryJitter = 0 }
        driver.feed(.start)
        let effects = driver.fire(.connectDeadline)
        #expect(gmtCloses(effects).isEmpty, "nothing open to close yet")
        #expect(gmtPhases(effects) == [.retrying(attempt: 2, delay: .milliseconds(500))])
        // The socket the machine gave up on opens late: it is closed straight away.
        #expect(driver.feed(.opened(socket: 1)) == [.close(socket: 1, code: 1000)])
    }

    @Test func theConnectDeadlineClosesAHandshakeThatStalls() {
        var driver = GMTDriver { $0.retryJitter = 0 }
        driver.feed(.start)
        driver.feed(.opened(socket: 1))
        driver.receive(gmtReadyFrame(epoch: "e-1"))
        let effects = driver.fire(.connectDeadline)
        #expect(gmtCloses(effects).map(\.socket) == [1])
        #expect(gmtPhases(effects) == [.retrying(attempt: 2, delay: .milliseconds(500))])
        // The capabilities answer arrives on the abandoned socket: ignored.
        #expect(driver.receive(gmtResult(id: 1, [:])).isEmpty)
    }

    @Test func silenceClosesTheSocketAndRetries() {
        var driver = GMTDriver { $0.retryJitter = 0 }
        driver.bringUp()
        let effects = driver.fire(.silence)
        #expect(gmtCloses(effects).map(\.socket) == [1])
        #expect(gmtCloses(effects).map(\.code) == [GatewayMachine.silentCloseCode])
        #expect(gmtPhases(effects) == [.retrying(attempt: 2, delay: .milliseconds(500))])
    }

    @Test func everyFramePushesTheSilenceTimerOut() throws {
        var driver = GMTDriver()
        driver.bringUp()
        let before = try #require(driver.generations[.silence])

        let event = driver.receive(gmtEventFrame(type: "status.update"))
        #expect(gmtScheduled(.silence, in: event) == [.seconds(45)])
        let afterEvent = try #require(driver.generations[.silence])
        #expect(afterEvent != before)

        // Even a frame the client cannot read shows the line is alive.
        let junk = driver.receive("not json at all")
        #expect(gmtScheduled(.silence, in: junk) == [.seconds(45)])

        // The superseded silence timers no longer drop the line.
        #expect(driver.feed(.timerFired(.silence, generation: before)).isEmpty)
        #expect(driver.feed(.timerFired(.silence, generation: afterEvent)).isEmpty)
        #expect(driver.machine.phase == .ready)
    }

    @Test func heartbeatPingsOnlyWhenNoPingIsOutstanding() throws {
        var driver = GMTDriver()
        driver.bringUp()

        let first = driver.fire(.heartbeat)
        let ping = try #require(gmtSent(first).first)
        #expect(gmtSent(first).count == 1)
        #expect(ping["method"] == "ping")
        #expect(ping["id"] == .integer(2), "capabilities took id 1")
        #expect(gmtScheduled(.heartbeat, in: first) == [.seconds(15)])

        let unanswered = driver.fire(.heartbeat)
        #expect(gmtSent(unanswered).isEmpty, "the first ping has no answer yet")
        #expect(gmtScheduled(.heartbeat, in: unanswered) == [.seconds(15)])

        driver.receive(gmtResult(id: 2, [:]))
        let next = driver.fire(.heartbeat)
        #expect(gmtSentMethods(next) == ["ping"])
        #expect(gmtSent(next).first?["id"] == .integer(3))
    }

    @Test func aPingAnswerIsNotTreatedAsACallResult() {
        var driver = GMTDriver()
        driver.bringUp()
        driver.fire(.heartbeat)
        let effects = driver.receive(gmtResult(id: 2, [:]))
        #expect(gmtFinishes(effects).isEmpty)
    }

    // MARK: Stale inputs

    @Test func staleTimerGenerationsAreIgnored() throws {
        var driver = GMTDriver()
        driver.feed(.start)
        let connectDeadline = try #require(driver.generations[.connectDeadline])
        driver.feed(.opened(socket: 1))
        driver.handshake()
        let heartbeat = try #require(driver.generations[.heartbeat])
        driver.fire(.heartbeat)

        // The handshake finished, so its deadline is spent.
        #expect(driver.feed(.timerFired(.connectDeadline, generation: connectDeadline)).isEmpty)
        // The heartbeat was rescheduled; the old generation does nothing.
        #expect(driver.feed(.timerFired(.heartbeat, generation: heartbeat)).isEmpty)
        // A generation never handed out does nothing either.
        #expect(driver.feed(.timerFired(.retry, generation: 9_999)).isEmpty)
        #expect(driver.machine.phase == .ready)
    }

    @Test func inputsForAnOldSocketAreIgnored() {
        var driver = GMTDriver { $0.retryJitter = 0 }
        driver.bringUp()
        driver.feed(.closed(socket: 1, code: 1006))
        driver.fire(.retry)
        driver.feed(.opened(socket: 2))
        #expect(driver.socket == 2)

        #expect(driver.feed(.received(socket: 1, gmtReadyFrame(epoch: "e-1"))).isEmpty)
        #expect(driver.feed(.received(socket: 1, gmtEventFrame(type: "status.update"))).isEmpty)
        #expect(driver.feed(.closed(socket: 1, code: 1006)).isEmpty)
        #expect(driver.feed(.openFailed(socket: 1, .refused(status: 401))).isEmpty)
        #expect(driver.machine.phase == .handshaking(attempt: 2))
    }

    @Test func anOpenedSocketTheMachineNoLongerWantsIsClosed() {
        var driver = GMTDriver()
        driver.bringUp()
        // A second "opened" for the live socket, and one for a number never asked for.
        #expect(driver.feed(.opened(socket: 1)) == [.close(socket: 1, code: 1000)])
        #expect(driver.feed(.opened(socket: 7)) == [.close(socket: 7, code: 1000)])
        #expect(driver.machine.phase == .ready)
    }

    // MARK: Calls

    @Test func callsMadeBeforeReadyWaitAndGoOutInOrderOnReady() throws {
        var driver = GMTDriver()
        driver.feed(.start)
        let first = driver.feed(.call(1, method: "session.list", params: ["limit": 5], deadline: nil))
        let second = driver.feed(.call(2, method: "config.get", params: [:], deadline: .seconds(90)))
        #expect(gmtSent(first + second).isEmpty)
        #expect(gmtScheduled(.callDeadline(1), in: first) == [.seconds(30)])
        #expect(gmtScheduled(.callDeadline(2), in: second) == [.seconds(90)])

        driver.feed(.opened(socket: 1))
        let readyEffects = driver.receive(gmtReadyFrame(epoch: "e-1"))
        #expect(gmtSentMethods(readyEffects) == ["client.capabilities"], "app calls never go out mid-handshake")

        let effects = driver.receive(gmtResult(id: 1, [:]))
        let sent = gmtSent(effects)
        #expect(sent.map { $0["method"]?.stringValue } == ["session.list", "config.get"])
        #expect(sent.map { $0["id"] } == [.integer(2), .integer(3)])
        #expect(sent.first?["params"] == ["limit": 5])
        let readyIndex = try #require(effects.firstIndex(of: .phase(.ready)))
        let firstSend = try #require(effects.firstIndex { if case .send = $0 { true } else { false } })
        #expect(readyIndex < firstSend)
    }

    @Test func wireIdsStartAgainFromOneOnEachSocket() {
        var driver = GMTDriver { $0.retryJitter = 0 }
        driver.bringUp()
        let firstSocket = driver.feed(.call(1, method: "session.list", params: [:], deadline: nil))
        #expect(gmtSent(firstSocket).map { $0["id"] } == [.integer(2)])
        driver.feed(.closed(socket: 1, code: 1006))

        driver.fire(.retry)
        driver.feed(.opened(socket: 2))
        let ready = driver.receive(gmtReadyFrame(epoch: "e-1"))
        #expect(gmtSent(ready).map { $0["id"] } == [.integer(1)])
        driver.receive(gmtResult(id: 1, [:]))
        let secondSocket = driver.feed(.call(2, method: "session.list", params: [:], deadline: nil))
        #expect(gmtSent(secondSocket).map { $0["id"] } == [.integer(2)])
        #expect(secondSocket.allSatisfy { if case .send(let socket, _) = $0 { socket == 2 } else { true } })
    }

    @Test func anAnswerFinishesTheCall() {
        var driver = GMTDriver()
        driver.bringUp()
        driver.feed(.call(5, method: "session.list", params: [:], deadline: nil))
        let effects = driver.receive(gmtResult(id: 2, ["sessions": []]))
        #expect(effects.contains(.finish(call: 5, .success(["sessions": []]))))
        #expect(effects.contains(.cancelTimer(.callDeadline(5))))
        #expect(gmtFinishes(effects).count == 1)
        // A repeated answer for the same id finishes nothing.
        #expect(gmtFinishes(driver.receive(gmtResult(id: 2, [:]))).isEmpty)
    }

    @Test func anErrorAnswerRefusesTheCall() {
        var driver = GMTDriver()
        driver.bringUp()
        driver.feed(.call(5, method: "session.resume", params: ["session_id": "gone"], deadline: nil))
        let effects = driver.receive(gmtFailure(id: 2, code: 4001, message: "session not found", data: ["id": "gone"]))
        let expected = GatewayRPCError(code: 4001, message: "session not found", data: ["id": "gone"])
        #expect(effects.contains(.finish(call: 5, .failure(.refused(expected)))))
        #expect(effects.contains(.cancelTimer(.callDeadline(5))))
    }

    @Test func aDropLosesCallsInFlight() {
        var driver = GMTDriver()
        driver.bringUp()
        driver.feed(.call(1, method: "prompt.submit", params: [:], deadline: nil))
        driver.feed(.call(2, method: "session.list", params: [:], deadline: nil))
        let effects = driver.feed(.closed(socket: 1, code: 1006))
        let finishes = gmtFinishes(effects)
        #expect(finishes.map(\.call).sorted() == [1, 2])
        #expect(finishes.allSatisfy { $0.result == .failure(.connectionLost) })
        #expect(effects.contains(.cancelTimer(.callDeadline(1))))
        #expect(effects.contains(.cancelTimer(.callDeadline(2))))

        // Lost calls are not sent again on the next socket.
        let next = driver.reconnect()
        #expect(gmtSentMethods(next) == ["client.capabilities"])
    }

    @Test func queuedCallsSurviveADropAndGoOutOnTheNextSocket() {
        var driver = GMTDriver { $0.retryJitter = 0 }
        driver.feed(.start)
        driver.feed(.opened(socket: 1))
        driver.feed(.call(1, method: "session.list", params: [:], deadline: nil))
        let dropped = driver.feed(.closed(socket: 1, code: 1006))
        #expect(gmtFinishes(dropped).isEmpty, "a call that was never sent is not lost")

        // Calls made while retrying wait too.
        driver.feed(.call(2, method: "config.get", params: [:], deadline: nil))
        let effects = driver.reconnect()
        #expect(gmtSentMethods(effects) == ["client.capabilities", "session.list", "config.get"])
        #expect(effects.allSatisfy { if case .send(let socket, _) = $0 { socket == 2 } else { true } })
    }

    @Test func aCallPastItsDeadlineTimesOutAndALateAnswerIsIgnored() {
        var driver = GMTDriver()
        driver.bringUp()
        driver.feed(.call(1, method: "session.list", params: [:], deadline: .seconds(3)))
        #expect(gmtScheduled(.callDeadline(1), in: driver.log) == [.seconds(3)])
        let expired = driver.fire(.callDeadline(1))
        #expect(gmtFinishes(expired).map(\.call) == [1])
        #expect(expired.contains(.finish(call: 1, .failure(.timedOut))))

        let late = driver.receive(gmtResult(id: 2, ["sessions": []]))
        #expect(gmtFinishes(late).isEmpty)
    }

    @Test func aQueuedCallPastItsDeadlineTimesOutAndIsNeverSent() {
        var driver = GMTDriver()
        driver.feed(.start)
        driver.feed(.call(1, method: "session.list", params: [:], deadline: .seconds(1)))
        #expect(driver.fire(.callDeadline(1)).contains(.finish(call: 1, .failure(.timedOut))))
        driver.feed(.opened(socket: 1))
        let effects = driver.handshake()
        #expect(gmtSentMethods(effects) == ["client.capabilities"])
    }

    @Test func cancellingACallFinishesItOnce() {
        var driver = GMTDriver()
        driver.bringUp()
        driver.feed(.call(1, method: "session.list", params: [:], deadline: nil))
        let cancelled = driver.feed(.cancel(call: 1))
        #expect(cancelled.contains(.finish(call: 1, .failure(.cancelled))))
        #expect(cancelled.contains(.cancelTimer(.callDeadline(1))))
        #expect(driver.feed(.cancel(call: 1)).isEmpty)
        #expect(gmtFinishes(driver.receive(gmtResult(id: 2, [:]))).isEmpty, "the late answer is dropped")
        #expect(gmtFinishes(driver.fire(.callDeadline(1))).isEmpty)
    }

    @Test func aCancelledQueuedCallIsNeverSent() {
        var driver = GMTDriver()
        driver.feed(.start)
        driver.feed(.call(1, method: "session.list", params: [:], deadline: nil))
        driver.feed(.call(2, method: "config.get", params: [:], deadline: nil))
        #expect(driver.feed(.cancel(call: 1)).contains(.finish(call: 1, .failure(.cancelled))))
        driver.feed(.opened(socket: 1))
        let effects = driver.handshake()
        #expect(gmtSentMethods(effects) == ["client.capabilities", "config.get"])
        #expect(gmtSent(effects).last?["id"] == .integer(2))
    }

    @Test func aCallWhileClosedFailsAtOnce() {
        var stopped = GMTDriver()
        stopped.feed(.start)
        stopped.feed(.stop)
        #expect(stopped.feed(.call(1, method: "session.list", params: [:], deadline: nil)) == [.finish(call: 1, .failure(.closed))])

        var refused = GMTDriver()
        refused.feed(.start)
        refused.feed(.openFailed(socket: 1, .refused(status: 401)))
        #expect(refused.feed(.call(1, method: "session.list", params: [:], deadline: nil)) == [.finish(call: 1, .failure(.closed))])
    }

    @Test func aCallBeforeStartWaitsForTheConnection() {
        var driver = GMTDriver()
        let effects = driver.feed(.call(1, method: "session.list", params: [:], deadline: nil))
        #expect(gmtFinishes(effects).isEmpty)
        #expect(gmtSent(effects).isEmpty)
        let up = driver.bringUp()
        #expect(gmtSentMethods(up) == ["client.capabilities", "session.list"])
    }

    // MARK: Stop and start

    @Test func stopClosesTheSocketAndFailsEveryCall() {
        var driver = GMTDriver()
        driver.bringUp()
        driver.feed(.call(1, method: "prompt.submit", params: [:], deadline: nil))
        let effects = driver.feed(.stop)

        #expect(gmtCloses(effects).map(\.socket) == [1])
        #expect(gmtCloses(effects).map(\.code) == [1000])
        #expect(gmtPhases(effects) == [.closed(.stopped)])
        let finishes = gmtFinishes(effects)
        #expect(finishes.map(\.call) == [1], "each call finishes exactly once")
        #expect(finishes.allSatisfy { if case .failure = $0.result { true } else { false } })
    }

    @Test func stopFailsACallAlreadySentAsConnectionLost() {
        // Hermes may have acted on a call it received, so the outcome is unknown rather than "never sent".
        var driver = GMTDriver()
        driver.bringUp()
        driver.feed(.call(1, method: "session.list", params: [:], deadline: nil))
        let effects = driver.feed(.stop)
        #expect(gmtFinishes(effects).map(\.result) == [.failure(.connectionLost)])
    }

    @Test func stopFailsQueuedCallsAsClosed() {
        var driver = GMTDriver()
        driver.feed(.start)
        driver.feed(.call(1, method: "session.list", params: [:], deadline: nil))
        driver.feed(.call(2, method: "config.get", params: [:], deadline: nil))
        let effects = driver.feed(.stop)
        let finishes = gmtFinishes(effects)
        #expect(finishes.map(\.call).sorted() == [1, 2])
        #expect(finishes.allSatisfy { $0.result == .failure(.closed) })
        #expect(gmtPhases(effects) == [.closed(.stopped)])
        #expect(gmtCloses(effects).isEmpty, "the socket never opened")
    }

    @Test func afterStopNothingStirs() throws {
        var driver = GMTDriver()
        driver.bringUp()
        let heartbeat = try #require(driver.generations[.heartbeat])
        let silence = try #require(driver.generations[.silence])
        driver.feed(.stop)

        #expect(driver.feed(.stop).isEmpty)
        #expect(driver.feed(.timerFired(.heartbeat, generation: heartbeat)).isEmpty)
        #expect(driver.feed(.timerFired(.silence, generation: silence)).isEmpty)
        #expect(driver.feed(.received(socket: 1, gmtEventFrame(type: "status.update"))).isEmpty)
        #expect(driver.feed(.closed(socket: 1, code: 1006)).isEmpty)
        #expect(driver.feed(.opened(socket: 1)) == [.close(socket: 1, code: 1000)])
        #expect(driver.machine.phase == .closed(.stopped))
    }

    @Test func stopWhileRetryingCancelsTheRetry() {
        var driver = GMTDriver()
        driver.feed(.start)
        driver.feed(.openFailed(socket: 1, .unreachable("down")))
        let retryGeneration = driver.generations[.retry]
        let effects = driver.feed(.stop)
        #expect(effects.contains(.cancelTimer(.retry)))
        #expect(gmtPhases(effects) == [.closed(.stopped)])
        if let retryGeneration {
            #expect(driver.feed(.timerFired(.retry, generation: retryGeneration)).isEmpty)
        }
        #expect(driver.machine.phase == .closed(.stopped))
    }

    @Test func startAfterStopConnectsAgainFromTheFirstAttempt() {
        var driver = GMTDriver { $0.retryJitter = 0 }
        driver.bringUp()
        driver.feed(.closed(socket: 1, code: 1006))
        driver.feed(.stop)

        let effects = driver.feed(.start)
        #expect(gmtPhases(effects) == [.connecting(attempt: 1)])
        let opened = gmtOpens(effects)
        #expect(opened.count == 1)
        #expect((opened.first ?? 0) > 1, "a fresh socket number, so late input for the old one is ignored")

        let up = driver.feed(.opened(socket: driver.socket)) + driver.handshake()
        #expect(gmtSent(up).first?["id"] == .integer(1))
        #expect(driver.machine.phase == .ready)
    }

    @Test func startAfterGivingUpConnectsAgain() {
        var driver = GMTDriver { $0.maxAttempts = 1 }
        driver.feed(.start)
        driver.feed(.openFailed(socket: driver.socket, .unreachable("down")))
        #expect(driver.machine.phase == .closed(.gaveUp))
        #expect(gmtPhases(driver.feed(.start)) == [.connecting(attempt: 1)])
    }
}
