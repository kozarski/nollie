import Foundation
import Testing
@testable import NollieCore

// Seq and epoch replay through session.events.since, driven on GatewayMachine directly.
// See Docs/specs/gateway-client.md, "Events, seq and epoch".

private typealias ReplayEffect = GatewayMachine.Effect

private let replayEpochOne = "epoch-1"

private func replayText(_ json: GatewayJSON) -> String {
    String(decoding: (try? json.encoded()) ?? Data("{}".utf8), as: UTF8.self)
}

private func replayParse(_ text: String) -> GatewayJSON? {
    try? GatewayJSON.parse(Data(text.utf8))
}

/// One session event as Hermes sends it inside `params` (or inside a replay answer's `events`).
private func replayEvent(_ session: String, seq: Int?, type: String = "message.delta") -> GatewayJSON {
    var fields: [String: GatewayJSON] = [
        "type": .string(type),
        "session_id": .string(session),
        "payload": ["text": .string("\(session) #\(seq.map(String.init) ?? "none")")],
    ]
    if let seq { fields["seq"] = .integer(seq) }
    return .object(fields)
}

private func replayLiveFrame(_ event: GatewayJSON) -> GatewayJSON {
    ["jsonrpc": "2.0", "method": "event", "params": event]
}

private func replayReadyFrame(_ epoch: String) -> GatewayJSON {
    replayLiveFrame(["type": "gateway.ready", "payload": ["replay_epoch": .string(epoch), "change_events": true]])
}

private func replayAnswerFrame(id: Int, events: [GatewayJSON] = [], latestSeq: Int? = nil, truncated: Bool = false,
                               epoch: String = replayEpochOne, openRequests: [GatewayJSON] = []) -> GatewayJSON {
    let latest = latestSeq ?? events.compactMap { $0["seq"]?.intValue }.max() ?? 0
    return [
        "jsonrpc": "2.0", "id": .integer(id),
        "result": [
            "events": .array(events), "latest_seq": .integer(latest), "truncated": .bool(truncated),
            "count": .integer(events.count), "epoch": .string(epoch), "open_requests": .array(openRequests),
        ],
    ]
}

private func replayRefusalFrame(id: Int, code: Int = 4001, message: String = "session not found") -> GatewayJSON {
    ["jsonrpc": "2.0", "id": .integer(id), "error": ["code": .integer(code), "message": .string(message)]]
}

private func replayQuestionParams(_ session: String) -> GatewayJSON {
    ["session_id": .string(session), "command": "rm -rf build", "description": "clean the build folder"]
}

private func replayOpenRequest(_ id: String, method: String = "approval", session: String) -> GatewayJSON {
    ["id": .string(id), "method": .string(method), "params": replayQuestionParams(session)]
}

private func replayQuestionFrame(_ id: String, method: String = "approval", session: String) -> GatewayJSON {
    ["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": replayQuestionParams(session)]
}

private struct ReplaySentCall {
    let id: Int
    let method: String
    let params: GatewayJSON
}

private func replaySentFrames(_ out: [ReplayEffect]) -> [GatewayJSON] {
    var frames: [GatewayJSON] = []
    for case .send(_, let text) in out {
        if let json = replayParse(text) { frames.append(json) }
    }
    return frames
}

/// Calls the machine wrote (integer ids), optionally only those for one method.
private func replayCalls(_ out: [ReplayEffect], _ method: String? = nil) -> [ReplaySentCall] {
    replaySentFrames(out).compactMap { frame in
        guard let id = frame["id"]?.intValue, let name = frame["method"]?.stringValue else { return nil }
        if let method, method != name { return nil }
        return ReplaySentCall(id: id, method: name, params: frame["params"] ?? [:])
    }
}

private func replaySinceCalls(_ out: [ReplayEffect]) -> [ReplaySentCall] {
    replayCalls(out, "session.events.since")
}

private func replayIsProbe(_ call: ReplaySentCall) -> Bool {
    call.params["last_seen"]?.intValue == GatewayMachine.probeLastSeen
}

/// Catch-up calls that ask for missed events (not probes).
private func replayCatchUpCalls(_ out: [ReplayEffect]) -> [ReplaySentCall] {
    replaySinceCalls(out).filter { !replayIsProbe($0) }
}

/// Probes: calls that only ask where a session's numbering stands.
private func replayProbeCalls(_ out: [ReplayEffect]) -> [ReplaySentCall] {
    replaySinceCalls(out).filter(replayIsProbe)
}

private func replayProbeParams(_ session: String, profile: String? = nil) -> GatewayJSON {
    var fields: [String: GatewayJSON] = ["session_id": .string(session), "last_seen": .integer(GatewayMachine.probeLastSeen)]
    if let profile { fields["profile"] = .string(profile) }
    return .object(fields)
}

/// The catch-up call (not a probe) for `session`.
private func replaySinceId(_ out: [ReplayEffect], session: String) -> Int? {
    replayCatchUpCalls(out).first { $0.params["session_id"]?.stringValue == session }?.id
}

private func replayProbeId(_ out: [ReplayEffect], session: String) -> Int? {
    replayProbeCalls(out).first { $0.params["session_id"]?.stringValue == session }?.id
}

/// Frames sent with string id `id` (replies to a server question).
private func replayRepliesTo(_ out: [ReplayEffect], _ id: String) -> [String] {
    var texts: [String] = []
    for case .send(_, let text) in out where replayParse(text)?["id"] == .string(id) { texts.append(text) }
    return texts
}

/// Events handed to the app, leaving out gateway.ready.
private func replayEvents(_ out: [ReplayEffect]) -> [GatewayEventEnvelope] {
    var events: [GatewayEventEnvelope] = []
    for case .event(let event) in out where event.type != "gateway.ready" { events.append(event) }
    return events
}

private func replaySeqs(_ out: [ReplayEffect], _ session: String) -> [Int] {
    replayEvents(out).filter { $0.sessionId == session }.compactMap(\.seq)
}

private func replayReloads(_ out: [ReplayEffect]) -> [ReplayEffect] {
    out.filter { if case .reload = $0 { true } else { false } }
}

private func replayQuestions(_ out: [ReplayEffect]) -> [GatewayIncomingQuestion] {
    var questions: [GatewayIncomingQuestion] = []
    for case .question(let question) in out { questions.append(question) }
    return questions
}

private func replayWithdrawn(_ out: [ReplayEffect]) -> [String] {
    var ids: [String] = []
    for case .withdrawn(let id) in out { ids.append(id) }
    return ids
}

private func replayWentReady(_ out: [ReplayEffect]) -> Bool {
    out.contains(.phase(.ready))
}

/// A machine plus the socket it last opened and everything it has said, with steps for connecting and dropping.
private struct ReplayRig {
    var machine: GatewayMachine
    var socket = 0
    var log: [ReplayEffect] = []

    init(configuration: GatewayConfiguration = GatewayConfiguration()) {
        machine = GatewayMachine(configuration: configuration)
    }

    @discardableResult
    mutating func handle(_ input: GatewayMachine.Input) -> [ReplayEffect] {
        let out = machine.handle(input)
        log += out
        for case .open(let number) in out { socket = number }
        return out
    }

    @discardableResult
    mutating func receive(_ json: GatewayJSON) -> [ReplayEffect] {
        handle(.received(socket: socket, replayText(json)))
    }

    @discardableResult
    mutating func receive(text: String) -> [ReplayEffect] {
        handle(.received(socket: socket, text))
    }

    mutating func watch(_ session: String, profile: String? = nil, from: Int? = nil) {
        handle(.watch(session: session, profile: profile, from: from))
    }

    /// Fires the most recently scheduled run of `timer`.
    @discardableResult
    mutating func fire(_ timer: GatewayTimer) -> [ReplayEffect] {
        var generation: Int?
        for effect in log.reversed() {
            if case .schedule(timer, let scheduled, _) = effect { generation = scheduled; break }
        }
        guard let generation else {
            Issue.record("\(timer) was never scheduled")
            return []
        }
        return handle(.timerFired(timer, generation: generation))
    }

    /// Opens a socket (first start or the next retry) and receives gateway.ready, stopping before the
    /// capabilities answer.
    @discardableResult
    mutating func openAndGetReady(epoch: String) -> [ReplayEffect] {
        var out: [ReplayEffect] = []
        switch machine.phase {
        case .idle, .closed: out += handle(.start)
        case .retrying: out += fire(.retry)
        default: break
        }
        out += handle(.opened(socket: socket))
        out += receive(replayReadyFrame(epoch))
        return out
    }

    /// Opens a socket and completes the handshake up to any catch-up calls. Probes are answered as Hermes would
    /// (no events, `latest_seq` from `latest`, 0 when missing, in `epoch`) unless `answerProbes` is false.
    /// Returns every effect from opening on.
    @discardableResult
    mutating func connect(epoch: String = replayEpochOne, latest: [String: Int] = [:],
                          answerProbes: Bool = true) -> [ReplayEffect] {
        var out = openAndGetReady(epoch: epoch)
        guard let capabilities = replayCalls(out, "client.capabilities").last else {
            Issue.record("client.capabilities was not sent")
            return out
        }
        out += receive([
            "jsonrpc": "2.0", "id": .integer(capabilities.id),
            "result": ["server_requests": ["approval", "clarify", "sudo"], "declines_not_shown": true],
        ])
        guard answerProbes else { return out }
        for probe in replayProbeCalls(out) {
            let session = probe.params["session_id"]?.stringValue ?? ""
            out += receive(replayAnswerFrame(id: probe.id, latestSeq: latest[session] ?? 0, epoch: epoch))
        }
        return out
    }

    /// The line drops without a refusal code, so the machine schedules a retry.
    @discardableResult
    mutating func drop() -> [ReplayEffect] {
        handle(.closed(socket: socket, code: 1006))
    }

    @discardableResult
    mutating func reconnect(epoch: String = replayEpochOne, latest: [String: Int] = [:],
                            answerProbes: Bool = true) -> [ReplayEffect] {
        drop()
        return connect(epoch: epoch, latest: latest, answerProbes: answerProbes)
    }

    @discardableResult
    mutating func live(_ session: String, seq: Int?, type: String = "message.delta") -> [ReplayEffect] {
        receive(replayLiveFrame(replayEvent(session, seq: seq, type: type)))
    }
}

/// The recorded frame that answers wire id `id`, with its id changed to `newId`.
private func replayRecordedAnswer(_ id: Int, as newId: Int) throws -> String {
    let text = try #require(gatewayRecordedFrames.first { replayParse($0)?["id"]?.intValue == id && replayParse($0)?["method"] == nil })
    var fields = try #require(replayParse(text)?.objectValue)
    fields["id"] = .integer(newId)
    return replayText(.object(fields))
}

@Suite struct GatewayReplayTests {
    // MARK: Watermarks on live events

    @Test func liveSessionEventsAreDeliveredOnceAndRepeatsAreDropped() {
        var rig = ReplayRig()
        rig.connect()
        var out: [ReplayEffect] = []
        for seq in [1, 2, 2, 1, 3, 3, 4] { out += rig.live("s1", seq: seq) }
        #expect(replaySeqs(out, "s1") == [1, 2, 3, 4])
    }

    @Test func eachSessionKeepsItsOwnWatermark() {
        var rig = ReplayRig()
        rig.connect()
        var out = rig.live("s1", seq: 9)
        out += rig.live("s2", seq: 1)
        out += rig.live("s2", seq: 2)
        out += rig.live("s1", seq: 9)
        #expect(replaySeqs(out, "s1") == [9])
        #expect(replaySeqs(out, "s2") == [1, 2])
    }

    @Test func eventsWithoutSeqOrWithoutSessionPassStraightThrough() {
        var rig = ReplayRig()
        rig.connect()
        var out = rig.live("s1", seq: 5)
        // A session event without seq, twice.
        out += rig.live("s1", seq: nil, type: "status.update")
        out += rig.live("s1", seq: nil, type: "status.update")
        // App-level events have no session; one carrying a stray seq is still not deduplicated.
        out += rig.receive(replayLiveFrame(["type": "sessions.changed", "session_id": "", "payload": [:]]))
        out += rig.receive(replayLiveFrame(["type": "sessions.changed", "session_id": "", "payload": [:]]))
        out += rig.live("", seq: 1, type: "profiles.changed")
        out += rig.live("", seq: 1, type: "profiles.changed")
        let types = replayEvents(out).map(\.type)
        #expect(types == ["message.delta", "status.update", "status.update", "sessions.changed", "sessions.changed",
                          "profiles.changed", "profiles.changed"])
        // Events without seq leave the watermark alone.
        #expect(replaySeqs(rig.live("s1", seq: 5), "s1").isEmpty)
        #expect(replaySeqs(rig.live("s1", seq: 6), "s1") == [6])
    }

    // MARK: Which sessions replay

    @Test func firstConnectionProbesSessionsWithoutAPositionAndWaitsForThem() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.watch("s2", profile: "career")
        let out = rig.connect(answerProbes: false)
        #expect(replayCatchUpCalls(out).isEmpty)
        #expect(replayProbeCalls(out).map(\.params) == [replayProbeParams("s1"), replayProbeParams("s2", profile: "career")])
        #expect(!replayWentReady(out))
        #expect(rig.machine.phase == .handshaking(attempt: 1))
        // A probe answer only gives the position: any events in it are not delivered and nothing reloads.
        let first = rig.receive(replayAnswerFrame(id: try #require(replayProbeId(out, session: "s1")),
                                                  events: [replayEvent("s1", seq: 12)], latestSeq: 12))
        #expect(replayEvents(first).isEmpty)
        #expect(replayReloads(first).isEmpty)
        #expect(!replayWentReady(first))
        let second = rig.receive(replayAnswerFrame(id: try #require(replayProbeId(out, session: "s2")), latestSeq: 0))
        #expect(replayWentReady(second))
        #expect(rig.machine.watermarks == ["s1": 12, "s2": 0])
        #expect(rig.machine.known == ["s1", "s2"])
        // Live events go on from the probed position.
        #expect(replaySeqs(rig.live("s1", seq: 12), "s1").isEmpty)
        #expect(replaySeqs(rig.live("s1", seq: 13), "s1") == [13])
        #expect(replaySeqs(rig.live("s2", seq: 1), "s2") == [1])
    }

    @Test func watchFromReplaysThatSessionOnTheFirstConnectionAndProbesTheRest() throws {
        var rig = ReplayRig()
        rig.watch("s1", from: 7)
        rig.watch("s2")
        let out = rig.connect()
        let calls = replayCatchUpCalls(out)
        #expect(calls.map(\.params) == [["session_id": "s1", "last_seen": 7]])
        #expect(replayProbeCalls(out).map(\.params) == [replayProbeParams("s2")])
        // The probe was answered, but the catch-up for s1 still holds ready back.
        #expect(!replayWentReady(out))
        #expect(rig.machine.phase == .handshaking(attempt: 1))
        let answered = rig.receive(replayAnswerFrame(id: try #require(calls.first?.id), events: [replayEvent("s1", seq: 8)]))
        #expect(replaySeqs(answered, "s1") == [8])
        #expect(replayWentReady(answered))
    }

    @Test func watchFromZeroAsksForEverythingOnTheFirstConnection() throws {
        // The app says it has nothing for s1, so the whole buffer is wanted, not a probe.
        var rig = ReplayRig()
        rig.watch("s1", from: 0)
        let out = rig.connect()
        #expect(replayProbeCalls(out).isEmpty)
        let calls = replayCatchUpCalls(out)
        #expect(calls.map(\.params) == [["session_id": "s1", "last_seen": 0]])
        let events = [1, 2].map { replayEvent("s1", seq: $0) }
        let answered = rig.receive(replayAnswerFrame(id: try #require(calls.first?.id), events: events))
        #expect(replaySeqs(answered, "s1") == [1, 2])
        #expect(replayWentReady(answered))
    }

    @Test func reconnectReplaysEveryWatchedSessionFromItsWatermark() {
        var rig = ReplayRig()
        rig.watch("s1", profile: "career")
        rig.watch("s2")
        rig.connect()
        rig.live("s1", seq: 1)
        rig.live("s1", seq: 2)
        rig.live("s1", seq: 3)
        let out = rig.reconnect()
        // Both are known now (s2 from the first probe), so both catch up; no probes.
        let params = replaySinceCalls(out).map(\.params)
        #expect(params.count == 2)
        #expect(params.contains(["session_id": "s1", "last_seen": 3, "profile": "career"]))
        #expect(params.contains(["session_id": "s2", "last_seen": 0]))
        #expect(!replayWentReady(out))
    }

    @Test func replayCallsGoOutOnlyAfterTheCapabilitiesAnswer() {
        var rig = ReplayRig()
        rig.watch("s1", from: 2)
        let beforeAnswer = rig.openAndGetReady(epoch: replayEpochOne)
        #expect(replayCalls(beforeAnswer).map(\.method) == ["client.capabilities"])
        #expect(replaySinceCalls(beforeAnswer).isEmpty)
    }

    @Test func unwatchStopsReplay() {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.watch("s2")
        rig.connect(latest: ["s1": 3, "s2": 5])
        rig.live("s1", seq: 4)
        rig.live("s2", seq: 6)
        rig.handle(.unwatch(session: "s2"))
        let out = rig.reconnect()
        #expect(replaySinceCalls(out).map(\.params) == [["session_id": "s1", "last_seen": 4]])
    }

    @Test func aSessionWithNoWatchersIsNeverReplayed() {
        var rig = ReplayRig()
        rig.connect()
        rig.live("loose", seq: 3)
        let out = rig.reconnect()
        #expect(replaySinceCalls(out).isEmpty)
        #expect(replayWentReady(out))
    }

    // MARK: Ready waits for every replay

    @Test func readyComesOnlyAfterEveryReplaySettles() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.watch("s2")
        rig.connect()
        rig.live("s1", seq: 1)
        rig.live("s2", seq: 1)
        let out = rig.reconnect()
        let first = try #require(replaySinceId(out, session: "s1"))
        let second = try #require(replaySinceId(out, session: "s2"))
        let afterFirst = rig.receive(replayAnswerFrame(id: first, events: [replayEvent("s1", seq: 2)]))
        #expect(replaySeqs(afterFirst, "s1") == [2])
        #expect(!replayWentReady(afterFirst))
        guard case .handshaking = rig.machine.phase else {
            Issue.record("went past handshaking before every replay settled: \(rig.machine.phase)")
            return
        }
        let afterSecond = rig.receive(replayRefusalFrame(id: second))
        #expect(replayWentReady(afterSecond))
        #expect(rig.machine.phase == .ready)
    }

    @Test func appCallsWaitUntilEveryReplayHasSettled() throws {
        var rig = ReplayRig()
        rig.watch("s1", from: 3)
        let out = rig.connect()
        let replay = try #require(replaySinceId(out, session: "s1"))
        let call = rig.handle(.call(41, method: "session.list", params: [:], deadline: nil))
        #expect(replayCalls(call).isEmpty)
        let answered = rig.receive(replayAnswerFrame(id: replay))
        #expect(replayCalls(answered, "session.list").count == 1)
    }

    // MARK: Replayed events

    @Test func replayedEventsAreDeliveredInSeqOrderWithoutRepeats() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect()
        rig.live("s1", seq: 1)
        rig.live("s1", seq: 2)
        let out = rig.reconnect()
        let id = try #require(replaySinceId(out, session: "s1"))
        let events = [5, 3, 4, 2, 1, 4].map { replayEvent("s1", seq: $0) }
        let answered = rig.receive(replayAnswerFrame(id: id, events: events))
        #expect(replaySeqs(answered, "s1") == [3, 4, 5])
        #expect(replaySeqs(rig.live("s1", seq: 5), "s1").isEmpty)
        #expect(replaySeqs(rig.live("s1", seq: 6), "s1") == [6])
    }

    @Test func replayedEventsCarryTheirPayloadsThrough() throws {
        var rig = ReplayRig()
        rig.watch("s1", from: 1)
        let out = rig.connect()
        let id = try #require(replaySinceId(out, session: "s1"))
        let event = replayEvent("s1", seq: 2, type: "message.complete")
        let answered = rig.receive(replayAnswerFrame(id: id, events: [event]))
        #expect(replayEvents(answered) == [GatewayEventEnvelope(type: "message.complete", sessionId: "s1", seq: 2,
                                                                payload: event["payload"])])
    }

    @Test func liveEventsDuringReplayWaitAndFollowTheReplayedOnes() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect(latest: ["s1": 1])
        rig.live("s1", seq: 2)
        let out = rig.reconnect()
        let id = try #require(replaySinceId(out, session: "s1"))
        // Live events cannot jump ahead of the catch-up.
        var early = rig.live("s1", seq: 6)
        early += rig.live("s1", seq: 4)
        early += rig.live("s1", seq: 5)
        #expect(replaySeqs(early, "s1").isEmpty)
        let answered = rig.receive(replayAnswerFrame(id: id, events: [3, 4].map { replayEvent("s1", seq: $0) }))
        #expect(replaySeqs(answered, "s1") == [3, 4, 5, 6])
        #expect(replayWentReady(answered))
    }

    @Test func liveEventsForOtherSessionsAreNotHeldBehindAReplay() throws {
        var rig = ReplayRig()
        rig.watch("s1", from: 2)
        let out = rig.connect()
        _ = try #require(replaySinceId(out, session: "s1"))
        let other = rig.live("s2", seq: 1)
        #expect(replaySeqs(other, "s2") == [1])
        let appLevel = rig.receive(replayLiveFrame(["type": "sessions.changed", "session_id": "", "payload": [:]]))
        #expect(replayEvents(appLevel).map(\.type) == ["sessions.changed"])
    }

    @Test func heldLiveEventsDoNotCountAsDeliveredWhenTheLineDropsAgain() {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect(latest: ["s1": 1])
        rig.live("s1", seq: 2)
        rig.reconnect()
        rig.live("s1", seq: 3)
        rig.live("s1", seq: 4)
        let out = rig.reconnect()
        #expect(replaySinceCalls(out).map(\.params) == [["session_id": "s1", "last_seen": 2]])
        #expect(replaySeqs(out, "s1").isEmpty)
    }

    // MARK: Truncated and restarted

    @Test func truncatedReplayReloadsAndMovesTheWatermarkToLatestSeq() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect(latest: ["s1": 1])
        rig.live("s1", seq: 2)
        let out = rig.reconnect()
        let id = try #require(replaySinceId(out, session: "s1"))
        let kept = (30...40).map { replayEvent("s1", seq: $0) }
        let answered = rig.receive(replayAnswerFrame(id: id, events: kept, latestSeq: 40, truncated: true))
        #expect(replayReloads(answered) == [.reload(session: "s1", .truncated)])
        #expect(replaySeqs(answered, "s1").isEmpty)
        #expect(replayWentReady(answered))
        #expect(replaySeqs(rig.live("s1", seq: 40), "s1").isEmpty)
        #expect(replaySeqs(rig.live("s1", seq: 41), "s1") == [41])
    }

    @Test func liveEventsHeldDuringATruncatedReplayAreStillDelivered() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect(latest: ["s1": 1])
        rig.live("s1", seq: 2)
        let out = rig.reconnect()
        let id = try #require(replaySinceId(out, session: "s1"))
        rig.live("s1", seq: 39)
        rig.live("s1", seq: 41)
        let answered = rig.receive(replayAnswerFrame(id: id, latestSeq: 40, truncated: true))
        #expect(replayReloads(answered) == [.reload(session: "s1", .truncated)])
        // The watermark stops below the lowest held live event, so none of them is lost.
        #expect(replaySeqs(answered, "s1") == [39, 41])
        #expect(replaySeqs(rig.live("s1", seq: 40), "s1").isEmpty)
    }

    @Test func replayAnswerFromAnotherEpochReloadsAsRestarted() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect(latest: ["s1": 1])
        rig.live("s1", seq: 2)
        let out = rig.reconnect()
        let id = try #require(replaySinceId(out, session: "s1"))
        let answered = rig.receive(replayAnswerFrame(id: id, events: [replayEvent("s1", seq: 3)], epoch: "epoch-other"))
        #expect(replayReloads(answered) == [.reload(session: "s1", .restarted)])
        #expect(replaySeqs(answered, "s1").isEmpty)
        #expect(replayWentReady(answered))
    }

    @Test func firstReadyAdoptsTheEpochWithoutReloading() {
        var rig = ReplayRig()
        rig.watch("s1", from: 4)
        let out = rig.connect(epoch: "first-epoch")
        #expect(replayReloads(out).isEmpty)
        #expect(rig.machine.epoch == "first-epoch")
        #expect(replaySinceCalls(out).count == 1)
    }

    @Test func newEpochOnReadyResetsWatermarksAndReloadsEveryWatchedSession() {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.watch("s2")
        rig.connect(latest: ["s1": 9, "s2": 2])
        rig.live("s1", seq: 10)
        rig.live("s2", seq: 3)
        let out = rig.reconnect(epoch: "epoch-2", answerProbes: false)
        #expect(Set(replayReloads(out)) == [.reload(session: "s1", .restarted), .reload(session: "s2", .restarted)])
        #expect(replayReloads(out).count == 2)
        #expect(rig.machine.epoch == "epoch-2")
        #expect(rig.machine.watermarks == ["s1": 0, "s2": 0])
        #expect(rig.machine.known.isEmpty)
        // No old position means anything in the new process: every watched session is probed, none replayed.
        #expect(replayCatchUpCalls(out).isEmpty)
        #expect(replayProbeCalls(out).map(\.params) == [replayProbeParams("s1"), replayProbeParams("s2")])
        #expect(!replayWentReady(out))
        var probed: [ReplayEffect] = []
        for probe in replayProbeCalls(out) {
            probed += rig.receive(replayAnswerFrame(id: probe.id, latestSeq: 0, epoch: "epoch-2"))
        }
        #expect(replayReloads(probed).isEmpty)
        #expect(replayWentReady(probed))
        // Numbering started over in the new process.
        #expect(replaySeqs(rig.live("s1", seq: 1), "s1") == [1])
        #expect(replaySeqs(rig.live("s2", seq: 1), "s2") == [1])
    }

    @Test func replayResumesOnTheDropAfterARestart() {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect(latest: ["s1": 9])
        rig.live("s1", seq: 10)
        rig.reconnect(epoch: "epoch-2")
        rig.live("s1", seq: 1)
        rig.live("s1", seq: 2)
        let out = rig.reconnect(epoch: "epoch-2")
        #expect(replayReloads(out).isEmpty)
        #expect(replaySinceCalls(out).map(\.params) == [["session_id": "s1", "last_seen": 2]])
    }

    @Test func aRestartSeenOnASocketThatDroppedBeforeCapabilitiesIsStillProbedOnTheNext() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect(latest: ["s1": 9])
        rig.live("s1", seq: 10)
        rig.drop()
        // The restart is seen, then the line drops before the capabilities answer.
        let restart = rig.openAndGetReady(epoch: "epoch-2")
        #expect(replayReloads(restart) == [.reload(session: "s1", .restarted)])
        rig.drop()
        // The next socket is in the same new process: no second reload, but s1's position there is still
        // unknown, so it is probed before ready.
        let out = rig.connect(epoch: "epoch-2", answerProbes: false)
        #expect(replayReloads(out).isEmpty)
        #expect(replayCatchUpCalls(out).isEmpty)
        #expect(replayProbeCalls(out).map(\.params) == [replayProbeParams("s1")])
        #expect(!replayWentReady(out))
        let probed = rig.receive(replayAnswerFrame(id: try #require(replayProbeId(out, session: "s1")), latestSeq: 5,
                                                   epoch: "epoch-2"))
        #expect(replayReloads(probed).isEmpty)
        #expect(replayWentReady(probed))
        #expect(rig.machine.watermarks["s1"] == 5)
        #expect(replaySeqs(rig.live("s1", seq: 6), "s1") == [6])
    }

    // MARK: Failed and slow replays

    @Test func replayErrorReloadsThatSessionAndStillGoesReady() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect(latest: ["s1": 1])
        rig.live("s1", seq: 2)
        let out = rig.reconnect()
        let id = try #require(replaySinceId(out, session: "s1"))
        let answered = rig.receive(replayRefusalFrame(id: id, code: -32601, message: "unknown method"))
        #expect(replayReloads(answered) == [.reload(session: "s1", .replayFailed)])
        #expect(replayWentReady(answered))
    }

    @Test func replayDeadlineIsTenSeconds() {
        var rig = ReplayRig()
        rig.watch("s1", from: 1)
        let out = rig.connect()
        var deadlines: [Duration] = []
        for case .schedule(.replayDeadline, _, let after) in out { deadlines.append(after) }
        #expect(deadlines == [.seconds(10)])
    }

    @Test func replayDeadlineReloadsUnansweredSessionsAndIgnoresLateAnswers() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.watch("s2")
        rig.connect()
        rig.live("s1", seq: 1)
        rig.live("s2", seq: 1)
        let out = rig.reconnect()
        let first = try #require(replaySinceId(out, session: "s1"))
        let second = try #require(replaySinceId(out, session: "s2"))
        rig.receive(replayAnswerFrame(id: first, events: [replayEvent("s1", seq: 2)]))
        let timedOut = rig.fire(.replayDeadline)
        #expect(replayReloads(timedOut) == [.reload(session: "s2", .replayFailed)])
        #expect(replayWentReady(timedOut))
        let late = rig.receive(replayAnswerFrame(id: second, events: [replayEvent("s2", seq: 2)]))
        #expect(replayEvents(late).isEmpty)
        #expect(replayReloads(late).isEmpty)
    }

    @Test func settledReplayCancelsItsDeadline() throws {
        var rig = ReplayRig()
        rig.watch("s1", from: 1)
        let out = rig.connect()
        let id = try #require(replaySinceId(out, session: "s1"))
        let answered = rig.receive(replayAnswerFrame(id: id))
        #expect(answered.contains(.cancelTimer(.replayDeadline)))
        // A stale firing of the old deadline changes nothing.
        let stale = rig.fire(.replayDeadline)
        #expect(replayReloads(stale).isEmpty)
        #expect(rig.machine.phase == .ready)
    }

    // MARK: Open requests

    @Test func openRequestsComeBackAsReplayedQuestions() throws {
        var rig = ReplayRig()
        rig.watch("s1", from: 2)
        let out = rig.connect()
        let id = try #require(replaySinceId(out, session: "s1"))
        let answered = rig.receive(replayAnswerFrame(id: id, openRequests: [replayOpenRequest("srq-a1", session: "s1"),
                                                                            replayOpenRequest("srq-a2", method: "clarify", session: "s1")]))
        let questions = replayQuestions(answered)
        #expect(questions == [
            GatewayIncomingQuestion(id: "srq-a1", method: "approval", params: replayQuestionParams("s1"), replayed: true),
            GatewayIncomingQuestion(id: "srq-a2", method: "clarify", params: replayQuestionParams("s1"), replayed: true),
        ])
        #expect(questions.allSatisfy { $0.sessionId == "s1" })
    }

    @Test func aQuestionAlreadyShownIsNotShownAgainByReplay() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect()
        rig.live("s1", seq: 1)
        let live = rig.receive(replayQuestionFrame("srq-b1", session: "s1"))
        #expect(replayQuestions(live).map(\.replayed) == [false])
        let out = rig.reconnect()
        let id = try #require(replaySinceId(out, session: "s1"))
        let answered = rig.receive(replayAnswerFrame(id: id, openRequests: [replayOpenRequest("srq-b1", session: "s1")]))
        #expect(replayQuestions(answered).isEmpty)
        #expect(replayWithdrawn(answered).isEmpty)
    }

    @Test func anOpenRequestListedByTwoReplaysIsShownOnce() throws {
        var rig = ReplayRig()
        rig.watch("s1", from: 1)
        let first = rig.connect()
        let request = replayOpenRequest("srq-c1", session: "s1")
        let shown = rig.receive(replayAnswerFrame(id: try #require(replaySinceId(first, session: "s1")), openRequests: [request]))
        #expect(replayQuestions(shown).map(\.id) == ["srq-c1"])
        let second = rig.reconnect()
        let again = rig.receive(replayAnswerFrame(id: try #require(replaySinceId(second, session: "s1")), openRequests: [request]))
        #expect(replayQuestions(again).isEmpty)
    }

    @Test func anAnsweredQuestionHermesStillListsIsAnsweredAgainNotShown() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect()
        rig.live("s1", seq: 1)
        rig.receive(replayQuestionFrame("srq-d1", session: "s1"))
        let reply = rig.handle(.answer(question: "srq-d1", result: ["choice": "once"]))
        let sent = replayRepliesTo(reply, "srq-d1")
        #expect(sent.count == 1)
        let out = rig.reconnect()
        let id = try #require(replaySinceId(out, session: "s1"))
        // Hermes still waits on it, so the reply was lost with the old socket: the same frame goes out again.
        let answered = rig.receive(replayAnswerFrame(id: id, openRequests: [replayOpenRequest("srq-d1", session: "s1")]))
        #expect(replayQuestions(answered).isEmpty)
        #expect(replayWithdrawn(answered).isEmpty)
        #expect(replayRepliesTo(answered, "srq-d1") == sent)
    }

    @Test func aShownQuestionMissingFromOpenRequestsIsWithdrawn() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.watch("s2")
        rig.connect()
        rig.live("s1", seq: 1)
        rig.live("s2", seq: 1)
        rig.receive(replayQuestionFrame("srq-e1", session: "s1"))
        rig.receive(replayQuestionFrame("srq-e2", session: "s2"))
        let out = rig.reconnect()
        let first = try #require(replaySinceId(out, session: "s1"))
        let second = try #require(replaySinceId(out, session: "s2"))
        let s1Answer = rig.receive(replayAnswerFrame(id: first))
        #expect(replayWithdrawn(s1Answer) == ["srq-e1"])
        let s2Answer = rig.receive(replayAnswerFrame(id: second, openRequests: [replayOpenRequest("srq-e2", session: "s2")]))
        #expect(replayWithdrawn(s2Answer).isEmpty)
        #expect(replayQuestions(s2Answer).isEmpty)
        // A withdrawn question cannot be answered on the wire any more.
        let late = rig.handle(.answer(question: "srq-e1", result: ["choice": "once"]))
        #expect(replaySentFrames(late).isEmpty)
    }

    @Test func openRequestsTheAppCannotShowAreDeclined() throws {
        var rig = ReplayRig()
        rig.watch("s1", from: 1)
        let out = rig.connect()
        let id = try #require(replaySinceId(out, session: "s1"))
        let answered = rig.receive(replayAnswerFrame(id: id, openRequests: [replayOpenRequest("srq-f1", method: "sudo", session: "s1")]))
        #expect(replayQuestions(answered).isEmpty)
        let replies = replaySentFrames(answered).filter { $0["id"] == "srq-f1" }
        #expect(replies.count == 1)
        #expect(replies.first?["error"]?["code"] == .integer(GatewayRPCError.unknownMethod))
    }

    // MARK: Probes

    @Test func aProbeAnswerKeepsLiveEventsHeldBelowLatestSeq() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        let out = rig.connect(answerProbes: false)
        let probe = try #require(replayProbeId(out, session: "s1"))
        // Live events that arrive while the probe is out wait for it.
        let six = rig.live("s1", seq: 6)
        let five = rig.live("s1", seq: 5)
        #expect(replaySeqs(six, "s1").isEmpty)
        #expect(replaySeqs(five, "s1").isEmpty)
        // latest_seq counts them already, but the app never got them: they still go out, in order.
        let answered = rig.receive(replayAnswerFrame(id: probe, latestSeq: 7))
        #expect(replaySeqs(answered, "s1") == [5, 6])
        #expect(replayReloads(answered).isEmpty)
        #expect(replayWentReady(answered))
        #expect(replaySeqs(rig.live("s1", seq: 7), "s1") == [7])
    }

    @Test func aFailedProbeDoesNotReloadAndTheSessionIsProbedAgainNextTime() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        let out = rig.connect(answerProbes: false)
        let answered = rig.receive(replayRefusalFrame(id: try #require(replayProbeId(out, session: "s1"))))
        #expect(replayReloads(answered).isEmpty)
        #expect(replayWentReady(answered))
        #expect(!rig.machine.known.contains("s1"))
        let again = rig.reconnect(answerProbes: false)
        #expect(replayCatchUpCalls(again).isEmpty)
        #expect(replayProbeCalls(again).map(\.params) == [replayProbeParams("s1")])
    }

    @Test func aProbeThatTimesOutDoesNotReloadButACatchUpDoes() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.watch("s2", from: 4)
        let out = rig.connect(answerProbes: false)
        _ = try #require(replayProbeId(out, session: "s1"))
        _ = try #require(replaySinceId(out, session: "s2"))
        let timedOut = rig.fire(.replayDeadline)
        #expect(replayReloads(timedOut) == [.reload(session: "s2", .replayFailed)])
        #expect(replayWentReady(timedOut))
        #expect(!rig.machine.known.contains("s1"))
    }

    @Test func aProbeAnswerFromAnotherEpochReloadsAsRestarted() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        let out = rig.connect(answerProbes: false)
        let probe = try #require(replayProbeId(out, session: "s1"))
        let answered = rig.receive(replayAnswerFrame(id: probe, latestSeq: 8, epoch: "epoch-other"))
        #expect(replayReloads(answered) == [.reload(session: "s1", .restarted)])
        #expect(replayEvents(answered).isEmpty)
        #expect(rig.machine.watermarks["s1"] == 0)
        #expect(!rig.machine.known.contains("s1"))
        #expect(replayWentReady(answered))
    }

    @Test func anUnwatchedSessionThatOwnsAShownQuestionIsProbed() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect()
        rig.live("s1", seq: 1)
        rig.receive(replayQuestionFrame("srq-p1", session: "s9"))
        rig.receive(replayQuestionFrame("srq-p2", session: "s9"))
        // An app-level question has no session to ask about.
        rig.receive(replayQuestionFrame("srq-p3", session: ""))
        let out = rig.reconnect(answerProbes: false)
        #expect(replayCatchUpCalls(out).map(\.params) == [["session_id": "s1", "last_seen": 1]])
        #expect(replayProbeCalls(out).map(\.params) == [replayProbeParams("s9")])
        let caughtUp = rig.receive(replayAnswerFrame(id: try #require(replaySinceId(out, session: "s1"))))
        #expect(!replayWentReady(caughtUp))
        let probed = rig.receive(replayAnswerFrame(id: try #require(replayProbeId(out, session: "s9")), latestSeq: 3,
                                                   openRequests: [replayOpenRequest("srq-p2", session: "s9")]))
        #expect(replayWithdrawn(probed) == ["srq-p1"])
        #expect(replayQuestions(probed).isEmpty)
        #expect(replayEvents(probed).isEmpty)
        #expect(replayReloads(probed).isEmpty)
        #expect(replayWentReady(probed))
    }

    // MARK: Numbering behind the app

    @Test func aReplayAnswerBehindLastSeenReloadsAsRestarted() throws {
        var rig = ReplayRig()
        rig.watch("s1", from: 10)
        let out = rig.connect()
        let id = try #require(replaySinceId(out, session: "s1"))
        let answered = rig.receive(replayAnswerFrame(id: id, events: [2, 3].map { replayEvent("s1", seq: $0) }, latestSeq: 3))
        #expect(replayReloads(answered) == [.reload(session: "s1", .restarted)])
        #expect(replaySeqs(answered, "s1").isEmpty)
        #expect(replayWentReady(answered))
        #expect(rig.machine.watermarks["s1"] == 3)
        #expect(replaySeqs(rig.live("s1", seq: 3), "s1").isEmpty)
        #expect(replaySeqs(rig.live("s1", seq: 4), "s1") == [4])
    }

    @Test func aReplayAnswerBehindLastSeenKeepsHeldLiveEvents() throws {
        var rig = ReplayRig()
        rig.watch("s1", from: 10)
        let out = rig.connect()
        let id = try #require(replaySinceId(out, session: "s1"))
        rig.live("s1", seq: 2)
        let answered = rig.receive(replayAnswerFrame(id: id, latestSeq: 3))
        #expect(replayReloads(answered) == [.reload(session: "s1", .restarted)])
        #expect(replaySeqs(answered, "s1") == [2])
        #expect(replaySeqs(rig.live("s1", seq: 3), "s1") == [3])
    }

    // MARK: Lost replies

    @Test func declinesHermesStillListsAreSentAgainOnTheNextSocket() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect()
        rig.live("s1", seq: 1)
        // One the app cannot show, declined at once, and one the app declines itself.
        let auto = rig.receive(replayQuestionFrame("srq-g1", method: "sudo", session: "s1"))
        #expect(replayQuestions(auto).isEmpty)
        let autoSent = replayRepliesTo(auto, "srq-g1")
        #expect(autoSent.count == 1)
        rig.receive(replayQuestionFrame("srq-g2", session: "s1"))
        let declined = rig.handle(.decline(question: "srq-g2", message: "Not now"))
        let declineSent = replayRepliesTo(declined, "srq-g2")
        #expect(declineSent.count == 1)
        let out = rig.reconnect()
        let id = try #require(replaySinceId(out, session: "s1"))
        let answered = rig.receive(replayAnswerFrame(id: id, openRequests: [
            replayOpenRequest("srq-g1", method: "sudo", session: "s1"), replayOpenRequest("srq-g2", session: "s1"),
        ]))
        #expect(replayRepliesTo(answered, "srq-g1") == autoSent)
        #expect(replayRepliesTo(answered, "srq-g2") == declineSent)
        #expect(replayQuestions(answered).isEmpty)
        #expect(replayWithdrawn(answered).isEmpty)
    }

    @Test func aReplyGivenWhileTheLineWasDownIsSentOnce() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect()
        rig.live("s1", seq: 1)
        rig.receive(replayQuestionFrame("srq-h1", session: "s1"))
        rig.drop()
        let queued = rig.handle(.answer(question: "srq-h1", result: ["choice": "once"]))
        #expect(replaySentFrames(queued).isEmpty)
        let out = rig.connect()
        #expect(replayRepliesTo(out, "srq-h1").isEmpty)
        let id = try #require(replaySinceId(out, session: "s1"))
        let answered = rig.receive(replayAnswerFrame(id: id, openRequests: [replayOpenRequest("srq-h1", session: "s1")]))
        #expect(replayRepliesTo(answered, "srq-h1").count == 1)
        #expect(replayQuestions(answered).isEmpty)
        #expect(replayWentReady(answered))
    }

    @Test func aRestartWithdrawsShownQuestionsAndForgetsOldReplies() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect()
        rig.live("s1", seq: 1)
        rig.receive(replayQuestionFrame("srq-r1", session: "s1"))
        rig.receive(replayQuestionFrame("srq-r2", session: "s1"))
        rig.handle(.answer(question: "srq-r2", result: ["choice": "once"]))
        let out = rig.reconnect(epoch: "epoch-2", answerProbes: false)
        #expect(replayWithdrawn(out) == ["srq-r1"])
        // A question with the same id in the new process is a new one: shown, not answered with the old reply.
        let probed = rig.receive(replayAnswerFrame(id: try #require(replayProbeId(out, session: "s1")), epoch: "epoch-2",
                                                   openRequests: [replayOpenRequest("srq-r2", session: "s1")]))
        #expect(replayQuestions(probed).map(\.id) == ["srq-r2"])
        #expect(replayRepliesTo(probed, "srq-r2").isEmpty)
        // The withdrawn one cannot be answered any more.
        #expect(replaySentFrames(rig.handle(.answer(question: "srq-r1", result: ["choice": "once"]))).isEmpty)
    }

    @Test func aReplyGivenWhileTheLineWasDownIsNotSentToARestartedHermes() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect()
        rig.live("s1", seq: 1)
        rig.receive(replayQuestionFrame("srq-r3", session: "s1"))
        rig.drop()
        rig.handle(.answer(question: "srq-r3", result: ["choice": "once"]))
        // Hermes restarted meanwhile: the question the reply was for is gone with the old process.
        let out = rig.connect(epoch: "epoch-2", answerProbes: false)
        let probed = rig.receive(replayAnswerFrame(id: try #require(replayProbeId(out, session: "s1")), epoch: "epoch-2",
                                                   openRequests: [replayOpenRequest("srq-r3", session: "s1")]))
        #expect(replayWentReady(probed))
        // The same id in the new process is a new question: shown, and not answered with the old reply.
        #expect(replayQuestions(probed).map(\.id) == ["srq-r3"])
        #expect(replayRepliesTo(out + probed, "srq-r3").isEmpty)
    }

    // MARK: Gaps while ready

    @Test func aGapWhileReadyIsCaughtUpBeforeTheLaterEvent() throws {
        var rig = ReplayRig()
        rig.watch("s1", profile: "career")
        rig.connect()
        #expect(replaySeqs(rig.live("s1", seq: 1), "s1") == [1])
        let gap = rig.live("s1", seq: 4)
        #expect(replaySeqs(gap, "s1").isEmpty)
        let calls = replaySinceCalls(gap)
        #expect(calls.map(\.params) == [["session_id": "s1", "last_seen": 1, "profile": "career"]])
        #expect(gap.contains { if case .schedule(.replayDeadline, _, _) = $0 { true } else { false } })
        // Live events during the catch-up wait too.
        #expect(replaySeqs(rig.live("s1", seq: 3), "s1").isEmpty)
        let caught = rig.receive(replayAnswerFrame(id: try #require(calls.first?.id),
                                                   events: [2, 3, 4].map { replayEvent("s1", seq: $0) }))
        #expect(replaySeqs(caught, "s1") == [2, 3, 4])
        #expect(replayReloads(caught).isEmpty)
        #expect(caught.contains(.cancelTimer(.replayDeadline)))
        #expect(!caught.contains { if case .phase = $0 { true } else { false } })
        #expect(rig.machine.phase == .ready)
        #expect(replaySeqs(rig.live("s1", seq: 4), "s1").isEmpty)
        #expect(replaySeqs(rig.live("s1", seq: 5), "s1") == [5])
    }

    @Test func aGapInAnUnwatchedSessionIsNotCaughtUp() {
        var rig = ReplayRig()
        rig.connect()
        var out = rig.live("loose", seq: 1)
        out += rig.live("loose", seq: 5)
        #expect(replaySeqs(out, "loose") == [1, 5])
        #expect(replaySinceCalls(out).isEmpty)
    }

    @Test func aFailedGapCatchUpReloadsAndStillDeliversTheHeldEvent() throws {
        var rig = ReplayRig()
        rig.watch("s1")
        rig.connect()
        rig.live("s1", seq: 1)
        let gap = rig.live("s1", seq: 4)
        let id = try #require(replaySinceId(gap, session: "s1"))
        let failed = rig.receive(replayRefusalFrame(id: id))
        #expect(replayReloads(failed) == [.reload(session: "s1", .replayFailed)])
        #expect(replaySeqs(failed, "s1") == [4])
        #expect(rig.machine.phase == .ready)
        #expect(replaySeqs(rig.live("s1", seq: 5), "s1") == [5])
    }

    // MARK: Watching while ready

    @Test func watchingAnUnknownSessionWhileReadyProbesItAtOnce() throws {
        var rig = ReplayRig()
        rig.connect()
        #expect(rig.machine.phase == .ready)
        let watch = rig.handle(.watch(session: "s1", profile: "career", from: nil))
        let probes = replaySinceCalls(watch)
        #expect(probes.map(\.params) == [replayProbeParams("s1", profile: "career")])
        #expect(watch.contains { if case .schedule(.replayDeadline, _, _) = $0 { true } else { false } })
        // Watching again while the probe is out asks nothing more.
        #expect(replaySinceCalls(rig.handle(.watch(session: "s1", profile: "career", from: nil))).isEmpty)
        let answered = rig.receive(replayAnswerFrame(id: try #require(probes.first?.id), latestSeq: 5))
        #expect(replayEvents(answered).isEmpty)
        #expect(replayReloads(answered).isEmpty)
        #expect(!answered.contains { if case .phase = $0 { true } else { false } })
        #expect(rig.machine.watermarks["s1"] == 5)
        #expect(replaySeqs(rig.live("s1", seq: 5), "s1").isEmpty)
        #expect(replaySeqs(rig.live("s1", seq: 6), "s1") == [6])
    }

    @Test func watchingAKnownSessionOrOneWithFromWhileReadySendsNothing() {
        var rig = ReplayRig()
        rig.connect()
        rig.live("s1", seq: 2)
        #expect(replaySinceCalls(rig.handle(.watch(session: "s1", profile: nil, from: nil))).isEmpty)
        #expect(replaySinceCalls(rig.handle(.watch(session: "s2", profile: nil, from: 4))).isEmpty)
        #expect(rig.machine.watermarks["s2"] == 4)
        #expect(rig.machine.known == ["s1", "s2"])
    }

    // MARK: Real frames

    @Test func realRecordedFramesKeepTheirSeqNumbersAcrossAReplay() throws {
        let session = "b9ba6931"
        let readyText = try #require(gatewayRecordedFrames.first)
        let epoch = try #require(replayParse(readyText)?["params"]?["payload"]?["replay_epoch"]?.stringValue)
        let liveTexts = gatewayRecordedFrames.dropFirst().filter { replayParse($0)?["method"] == "event" }
        let liveSeqs = liveTexts.compactMap { replayParse($0)?["params"]?["seq"]?.intValue }
        #expect(liveSeqs == [1, 2, 3, 4])

        var rig = ReplayRig()
        rig.watch(session)
        var delivered: [ReplayEffect] = []

        // First connection: the real ready event and the real capabilities answer (wire id 1).
        rig.handle(.start)
        rig.handle(.opened(socket: rig.socket))
        let ready = rig.receive(text: readyText)
        #expect(replayCalls(ready).map(\.id) == [1])
        let capabilities = rig.receive(text: try replayRecordedAnswer(1, as: 1))
        #expect(rig.machine.epoch == epoch)
        #expect(rig.machine.questionsHermesMaySend.contains("approval"))
        // The app gave no position, so the session is probed first.
        let probe = try #require(replayProbeCalls(capabilities).first)
        #expect(replaySinceCalls(capabilities).count == 1)
        #expect(probe.params == replayProbeParams(session))
        #expect(!replayWentReady(capabilities))
        // Hermes's real answer for a session with nothing yet (call 12): latest_seq 0 in the same epoch.
        let probed = rig.receive(text: try replayRecordedAnswer(12, as: probe.id))
        #expect(replayReloads(probed).isEmpty)
        #expect(replayEvents(probed).isEmpty)
        #expect(replayWentReady(probed))

        // Live events up to seq 2, then the line drops.
        let upToTwo = liveTexts.prefix { (replayParse($0)?["params"]?["seq"]?.intValue ?? 0) <= 2 }
        for text in upToTwo { delivered += rig.receive(text: text) }
        #expect(replaySeqs(delivered, session) == [1, 2])
        rig.drop()

        // The reconnect asks for exactly what the recorder asked for (call 9) and gets its real answer.
        rig.fire(.retry)
        rig.handle(.opened(socket: rig.socket))
        rig.receive(text: readyText)
        let second = rig.receive(text: try replayRecordedAnswer(1, as: 1))
        let since = try #require(replaySinceCalls(second).first)
        let recordedCall = try #require(gatewayRecordedCalls.first { $0.id == 9 })
        #expect(since.params == replayParse(recordedCall.params))
        let replayed = rig.receive(text: try replayRecordedAnswer(9, as: since.id))
        #expect(replaySeqs(replayed, session) == [3, 4])
        #expect(replayEvents(replayed).map(\.type) == ["message.complete", "session.info"])
        #expect(replayReloads(replayed).isEmpty)
        #expect(replayWentReady(replayed))
        delivered += replayed

        // The same events arriving live afterwards are repeats.
        var after: [ReplayEffect] = []
        for text in liveTexts.dropFirst(upToTwo.count) { after += rig.receive(text: text) }
        #expect(replaySeqs(after, session).isEmpty)

        // One more drop: the full recorded history (call 8) brings nothing new.
        rig.drop()
        rig.fire(.retry)
        rig.handle(.opened(socket: rig.socket))
        rig.receive(text: readyText)
        let third = rig.receive(text: try replayRecordedAnswer(1, as: 1))
        let lastSince = try #require(replaySinceCalls(third).first)
        #expect(lastSince.params == ["session_id": .string(session), "last_seen": 4])
        let full = rig.receive(text: try replayRecordedAnswer(8, as: lastSince.id))
        #expect(replaySeqs(full, session).isEmpty)
        #expect(replayReloads(full).isEmpty)
        #expect(replayWentReady(full))
        #expect(replaySeqs(delivered, session) == [1, 2, 3, 4])
    }
}
