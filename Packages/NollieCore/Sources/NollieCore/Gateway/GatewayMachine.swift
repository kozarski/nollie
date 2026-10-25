import Foundation

/// Where the connection stands, as the app sees it.
public enum GatewayPhase: Hashable, Sendable {
    case idle
    /// Opening the socket. `attempt` counts from 1 since the connection last stayed up.
    case connecting(attempt: Int)
    /// The socket is open; waiting for Hermes to say it is ready, telling it what the app handles, and
    /// catching up on missed events.
    case handshaking(attempt: Int)
    case ready
    /// The line dropped; the next attempt starts after `delay`.
    case retrying(attempt: Int, delay: Duration)
    case closed(GatewayCloseReason)
}

public enum GatewayCloseReason: Hashable, Sendable {
    /// The app stopped the connection.
    case stopped
    /// Hermes refused the credentials or the origin (HTTP status or close code). Retrying cannot fix it.
    case refused(code: Int)
    /// The retry budget ran out.
    case gaveUp
}

/// Why the app should reload a session from stored history instead of trusting the events it has.
public enum GatewayReloadReason: Hashable, Sendable {
    /// Hermes restarted, so its event numbering started over.
    case restarted
    /// Hermes no longer had every event since the last one the app saw.
    case truncated
    /// Catching up failed or took too long.
    case replayFailed
}

/// Why a call did not get an answer.
public enum GatewayCallFailure: Error, Hashable, Sendable {
    /// Hermes answered with an error.
    case refused(GatewayRPCError)
    /// The line dropped after the call was sent. Hermes may or may not have acted on it.
    case connectionLost
    /// No answer before the deadline. Hermes may or may not have acted on it.
    case timedOut
    /// The connection is closed (stopped, refused or out of retries) and the call was never sent.
    case closed
    case cancelled
}

/// A timer the machine asks its driver to run.
public enum GatewayTimer: Hashable, Sendable {
    case connectDeadline
    case heartbeat
    case silence
    case retry
    case stable
    case replayDeadline
    case callDeadline(Int)
}

/// Tuning for the connection. The defaults are the spec's (`Docs/specs/gateway-client.md`).
public struct GatewayConfiguration: Sendable {
    public var connectDeadline: Duration = .seconds(15)
    public var heartbeatInterval: Duration = .seconds(15)
    public var silenceLimit: Duration = .seconds(45)
    public var callDeadline: Duration = .seconds(30)
    public var replayDeadline: Duration = .seconds(10)
    public var retryBase: Duration = .milliseconds(500)
    public var retryCap: Duration = .seconds(30)
    /// Each retry delay is moved by up to this fraction either way, so many clients do not retry in step.
    public var retryJitter: Double = 0.2
    /// A connection that stays ready this long resets the attempt count.
    public var stableAfter: Duration = .seconds(10)
    /// Attempts before giving up; nil keeps trying.
    public var maxAttempts: Int?
    /// Server questions the app can show. Every other question is declined at once.
    public var shownQuestions: Set<String> = ["approval", "clarify"]
    /// Seeds the jitter, so a run can be repeated exactly.
    public var seed: UInt64 = 0x6e6f6c6c6965

    public init() {}

    /// Questions only a window that shows the chat can answer. They are declined as "not shown" so such a
    /// window elsewhere can still answer.
    public static let windowQuestions: Set<String> = ["preview.act", "preview.read", "terminal.read", "window.read",
                                                     "tour", "theme.apply"]
}

/// The gateway connection as a pure state machine: inputs in, effects out, no clocks, sockets or tasks.
/// `GatewayClient` runs it. See `Docs/specs/gateway-client.md`.
struct GatewayMachine {
    enum Input: Sendable {
        case start
        case stop
        /// The socket the machine asked for (by number) opened.
        case opened(socket: Int)
        case openFailed(socket: Int, GatewayTransportError)
        case received(socket: Int, String)
        case closed(socket: Int, code: Int?)
        case timerFired(GatewayTimer, generation: Int)
        /// The app calls a method. `call` is the app's handle for it.
        case call(Int, method: String, params: GatewayJSON, deadline: Duration?)
        case cancel(call: Int)
        /// The app answers a question it was shown.
        case answer(question: String, result: GatewayJSON)
        /// The app sets a shown question aside without answering it.
        case decline(question: String, message: String)
        /// Keep this session's events in order and catch up on them after a drop. `from` is the last seq the app
        /// already has, if it knows it.
        case watch(session: String, profile: String?, from: Int?)
        case unwatch(session: String)
    }

    enum Effect: Hashable, Sendable {
        case open(socket: Int)
        case send(socket: Int, String)
        case close(socket: Int, code: Int)
        case schedule(GatewayTimer, generation: Int, after: Duration)
        case cancelTimer(GatewayTimer)
        case phase(GatewayPhase)
        case finish(call: Int, Result<GatewayJSON, GatewayCallFailure>)
        case event(GatewayEventEnvelope)
        case question(GatewayIncomingQuestion)
        /// A question the app was shown is no longer waiting: Hermes cancelled it or it timed out.
        case withdrawn(question: String)
        case reload(session: String, GatewayReloadReason)
    }

    /// Why the machine sent a call on the socket.
    private enum Purpose: Hashable {
        case app(Int)
        case capabilities
        /// `probe` asks only where the session's numbering stands, because the app has no baseline for it.
        case replay(session: String, probe: Bool)
        case ping
    }

    private struct PendingCall {
        var method: String
        var params: GatewayJSON
    }

    /// A drop code the machine uses when it gives up on a silent socket.
    static let silentCloseCode = 4000
    /// `last_seen` for a probe: higher than any seq, so Hermes answers with no events but with `latest_seq`.
    /// The largest 32-bit number, so it fits an `Int` on the Watch too.
    static let probeLastSeen = Int(Int32.max)
    /// How many sent replies to remember, to send again if Hermes shows it never got them.
    static let rememberedReplies = 256
    /// Methods the machine sends on its own, whatever the app does. The Nollie Link door must allow them.
    static let ownMethods = [GatewayWire.Calls.clientCapabilities.name, GatewayWire.Calls.ping.name,
                             GatewayWire.Calls.sessionEventsSince.name]

    let configuration: GatewayConfiguration
    private(set) var phase: GatewayPhase = .idle

    // The socket.
    private var socket = 0
    private var socketOpen = false
    private var nextWireId = 1
    private var inFlight: [Int: Purpose] = [:]
    private var attempt = 0
    private var gotReady = false
    private var replaying: Set<String> = []
    /// The `last_seen` each replay asked from.
    private var replayFrom: [String: Int] = [:]
    private var held: [String: [GatewayEventEnvelope]] = [:]
    private var pingOutstanding = false

    // Calls.
    private var queued: [(call: Int, pending: PendingCall)] = []
    private var sentCalls: [Int: Int] = [:]   // app call -> wire id
    private var callDeadlines: Set<Int> = []
    private var queuedAnswers: [String] = []

    // Events and questions.
    private(set) var epoch: String?
    private(set) var watermarks: [String: Int] = [:]
    private(set) var watched: [String: String?] = [:]
    /// Sessions whose watermark is a real position in Hermes's numbering (from the app, a live event or a probe).
    private(set) var known: Set<String> = []
    /// Questions shown to the app and not yet settled, with the session each belongs to.
    private var openQuestions: [String: String] = [:]
    /// Questions withdrawn by Hermes or settled while the line was down: never shown again.
    private var settledQuestions: Set<String> = []
    /// The reply sent (or queued) for each question the client answered, newest last.
    private var replies: [String: String] = [:]
    private var replyOrder: [String] = []
    private(set) var questionsHermesMaySend: Set<String> = []
    private var declinesNotShown = false

    // Timers and jitter.
    private var timerGenerations: [GatewayTimer: Int] = [:]
    private var nextGeneration = 0
    private var random: UInt64

    init(configuration: GatewayConfiguration = GatewayConfiguration()) {
        self.configuration = configuration
        random = configuration.seed
    }

    mutating func handle(_ input: Input) -> [Effect] {
        var out: [Effect] = []
        switch input {
        case .start: start(&out)
        case .stop: shutDown(.stopped, &out)
        case .opened(let number):
            if number == socket, case .connecting = phase { opened(&out) } else { out.append(.close(socket: number, code: 1000)) }
        case .openFailed(let number, let error): if number == socket, case .connecting = phase { openFailed(error, &out) }
        case .received(let number, let text): if number == socket, socketOpen { received(text, &out) }
        case .closed(let number, let code): if number == socket, socketOpen { dropped(code: code, &out) }
        case .timerFired(let timer, let generation): if timerGenerations[timer] == generation { fired(timer, &out) }
        case .call(let call, let method, let params, let deadline): enqueue(call, method, params, deadline, &out)
        case .cancel(let call): abandon(call, .cancelled, &out)
        case .answer(let id, let result): settle(id, GatewayFrame.reply(to: id, result: result), &out)
        case .decline(let id, let message):
            // "Not shown here" leaves the question to another window that shows the chat, when Hermes knows it.
            let code = declinesNotShown ? GatewayRPCError.notShown : GatewayRPCError.unknownMethod
            settle(id, GatewayFrame.reply(to: id, error: GatewayRPCError(code: code, message: message)), &out)
        case .watch(let session, let profile, let from):
            watched[session] = profile
            if let from {
                watermarks[session] = max(watermarks[session] ?? 0, from)
                known.insert(session)
            } else if !known.contains(session), phase == .ready, !replaying.contains(session) {
                catchUp(session, probe: true, &out)
                schedule(.replayDeadline, after: configuration.replayDeadline, &out)
            }
        case .unwatch(let session):
            watched[session] = nil
            watermarks[session] = nil
            known.remove(session)
        }
        return out
    }

    // MARK: Connecting

    private mutating func start(_ out: inout [Effect]) {
        switch phase {
        case .idle, .closed:
            attempt = 0
            connect(&out)
        default:
            break
        }
    }

    private mutating func connect(_ out: inout [Effect]) {
        attempt += 1
        socket += 1
        socketOpen = false
        nextWireId = 1
        gotReady = false
        setPhase(.connecting(attempt: attempt), &out)
        out.append(.open(socket: socket))
        schedule(.connectDeadline, after: configuration.connectDeadline, &out)
    }

    private mutating func opened(_ out: inout [Effect]) {
        socketOpen = true
        setPhase(.handshaking(attempt: attempt), &out)
        schedule(.silence, after: configuration.silenceLimit, &out)
    }

    private mutating func openFailed(_ error: GatewayTransportError, _ out: inout [Effect]) {
        if case .refused(let status) = error, status == 401 || status == 403 {
            shutDown(.refused(code: status), &out)
        } else {
            retry(&out)
        }
    }

    // MARK: Frames

    private mutating func received(_ text: String, _ out: inout [Effect]) {
        // Any frame shows the line is alive.
        schedule(.silence, after: configuration.silenceLimit, &out)
        for frame in GatewayFrame.read(text) {
            guard socketOpen else { return }
            switch frame {
            case .event(let event): receivedEvent(event, &out)
            case .answer(let id, let result): answered(id, .success(result), &out)
            case .refusal(let id?, let error): answered(id, .failure(error), &out)
            case .refusal(nil, _), .unreadable: break
            case .question(let question): asked(question, &out)
            }
        }
    }

    private mutating func receivedEvent(_ event: GatewayEventEnvelope, _ out: inout [Effect]) {
        if event.type == GatewayWire.Events.gatewayReady.name, event.sessionId.isEmpty {
            out.append(.event(event))
            if !gotReady { hermesReady(epoch: event.payload?["replay_epoch"]?.stringValue, &out) }
            return
        }
        let session = event.sessionId
        guard let seq = event.seq, !session.isEmpty else { deliver(event, &out); return }
        if replaying.contains(session) {
            held[session, default: []].append(event)
            return
        }
        // A watched session skipped some numbers (Hermes sends a reconnected socket nothing for a session until
        // the app attaches to it again): fetch the gap before going on.
        if phase == .ready, watched[session] != nil, known.contains(session), seq > (watermarks[session] ?? 0) + 1 {
            held[session] = [event]
            catchUp(session, probe: false, &out)
            schedule(.replayDeadline, after: configuration.replayDeadline, &out)
            return
        }
        deliver(event, &out)
        known.insert(session)
    }

    /// Passes a session event on unless the app already has it.
    private mutating func deliver(_ event: GatewayEventEnvelope, _ out: inout [Effect]) {
        if let seq = event.seq, !event.sessionId.isEmpty {
            if seq <= watermarks[event.sessionId] ?? 0 { return }
            watermarks[event.sessionId] = seq
        }
        out.append(.event(event))
        if event.type == GatewayWire.Events.requestCancel.name, let id = event.payload?["id"]?.stringValue {
            forgetQuestion(id, &out)
        }
    }

    /// Hermes no longer waits on this question: take it down and never show or answer it again.
    private mutating func forgetQuestion(_ id: String, _ out: inout [Effect]) {
        settledQuestions.insert(id)
        if replies.removeValue(forKey: id) != nil { replyOrder.removeAll { $0 == id } }
        if openQuestions.removeValue(forKey: id) != nil { out.append(.withdrawn(question: id)) }
    }

    private mutating func asked(_ question: GatewayIncomingQuestion, _ out: inout [Effect]) {
        if let reply = replies[question.id] {
            // Already answered, yet Hermes still waits: the reply was lost with the old socket. Send it again.
            queuedAnswers.removeAll { $0 == reply }
            out.append(.send(socket: socket, reply))
            return
        }
        guard !settledQuestions.contains(question.id), openQuestions[question.id] == nil else { return }
        if configuration.shownQuestions.contains(question.method) {
            openQuestions[question.id] = question.sessionId
            out.append(.question(question))
            return
        }
        let error: GatewayRPCError
        if declinesNotShown, GatewayConfiguration.windowQuestions.contains(question.method) {
            error = GatewayRPCError(code: GatewayRPCError.notShown, message: "No window that shows this chat is open here.")
        } else {
            error = GatewayRPCError(code: GatewayRPCError.unknownMethod, message: "Nollie can't answer \(question.method) here.")
        }
        let reply = GatewayFrame.reply(to: question.id, error: error)
        remember(reply, for: question.id)
        out.append(.send(socket: socket, reply))
    }

    private mutating func remember(_ reply: String, for id: String) {
        if replies.updateValue(reply, forKey: id) == nil { replyOrder.append(id) }
        while replyOrder.count > Self.rememberedReplies { replies[replyOrder.removeFirst()] = nil }
    }

    private mutating func answered(_ id: Int, _ result: Result<GatewayJSON, GatewayRPCError>, _ out: inout [Effect]) {
        guard let purpose = inFlight.removeValue(forKey: id) else { return }
        switch purpose {
        case .app(let call):
            sentCalls[call] = nil
            callDeadlines.remove(call)
            timerGenerations[.callDeadline(call)] = nil
            out.append(.cancelTimer(.callDeadline(call)))
            out.append(.finish(call: call, result.mapError { .refused($0) }))
        case .ping:
            pingOutstanding = false
        case .capabilities:
            out.append(.cancelTimer(.connectDeadline))
            timerGenerations[.connectDeadline] = nil
            if case .success(let answer) = result {
                questionsHermesMaySend = Set(answer["server_requests"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                declinesNotShown = answer["declines_not_shown"]?.boolValue ?? false
            } else {
                // An older Hermes without client.capabilities: keep going, with plain declines.
                questionsHermesMaySend = []
                declinesNotShown = false
            }
            beginReplay(&out)
        case .replay(let session, let probe):
            caughtUp(session, probe: probe, result, &out)
        }
    }

    // MARK: Handshake and replay

    private mutating func hermesReady(epoch newEpoch: String?, _ out: inout [Effect]) {
        gotReady = true
        if let newEpoch, !newEpoch.isEmpty {
            if let epoch, epoch != newEpoch { restarted(&out) }
            epoch = newEpoch
        }
        sendInternal(.capabilities, method: GatewayWire.Calls.clientCapabilities.name,
                     params: (try? GatewayJSON(encoding: GatewayWire.ClientCapabilitiesParams(serverRequests: true))) ?? [:], &out)
    }

    /// Hermes started over: every number the app holds is meaningless, so watched sessions reload and their
    /// numbering is learned again.
    private mutating func restarted(_ out: inout [Effect]) {
        watermarks = watermarks.mapValues { _ in 0 }
        known.removeAll()
        for id in openQuestions.keys.sorted() { out.append(.withdrawn(question: id)) }
        openQuestions.removeAll()
        replies.removeAll()
        replyOrder.removeAll()
        // Answers queued for the old process would land on the new one's questions.
        queuedAnswers.removeAll()
        for session in watched.keys.sorted() { out.append(.reload(session: session, .restarted)) }
    }

    private mutating func beginReplay(_ out: inout [Effect]) {
        // Watched sessions with a known position catch up from it; the rest, and sessions that only own a shown
        // question, get a probe.
        var plan: [String: Bool] = [:]
        for session in watched.keys { plan[session] = !known.contains(session) }
        for owner in openQuestions.values where !owner.isEmpty && plan[owner] == nil { plan[owner] = true }
        guard !plan.isEmpty else { becomeReady(&out); return }
        for session in plan.keys.sorted() { catchUp(session, probe: plan[session] ?? true, &out) }
        schedule(.replayDeadline, after: configuration.replayDeadline, &out)
    }

    private mutating func catchUp(_ session: String, probe: Bool, _ out: inout [Effect]) {
        replaying.insert(session)
        let from = probe ? Self.probeLastSeen : watermarks[session] ?? 0
        replayFrom[session] = from
        var params: [String: GatewayJSON] = ["session_id": .string(session), "last_seen": .integer(from)]
        if let profile = watched[session] ?? nil { params["profile"] = .string(profile) }
        sendInternal(.replay(session: session, probe: probe), method: GatewayWire.Calls.sessionEventsSince.name,
                     params: .object(params), &out)
    }

    private mutating func caughtUp(_ session: String, probe: Bool, _ result: Result<GatewayJSON, GatewayRPCError>,
                                   _ out: inout [Effect]) {
        guard replaying.contains(session) else { return }
        switch result {
        case .success(let answer):
            let latest = answer["latest_seq"]?.intValue ?? 0
            // The position to resume from, kept below any live event held meanwhile so none is lost.
            let resume = min(latest, ((held[session] ?? []).compactMap(\.seq).min() ?? Int.max) - 1)
            let from = replayFrom[session] ?? 0
            if let answerEpoch = answer["epoch"]?.stringValue, let epoch, answerEpoch != epoch {
                watermarks[session] = 0
                known.remove(session)
                out.append(.reload(session: session, .restarted))
            } else if probe {
                watermarks[session] = max(watermarks[session] ?? 0, resume)
                known.insert(session)
            } else if latest < from {
                // Hermes's numbering is behind what the app saw: it restarted before this client met it.
                watermarks[session] = resume
                out.append(.reload(session: session, .restarted))
            } else if answer["truncated"]?.boolValue == true {
                watermarks[session] = max(watermarks[session] ?? 0, resume)
                out.append(.reload(session: session, .truncated))
            } else {
                let events = (answer["events"]?.arrayValue ?? []).compactMap(GatewayEventEnvelope.init)
                for event in events.sorted(by: { ($0.seq ?? 0) < ($1.seq ?? 0) }) { deliver(event, &out) }
            }
            let stillOpen = answer["open_requests"]?.arrayValue ?? []
            let stillOpenIds = Set(stillOpen.compactMap { $0["id"]?.stringValue })
            // A question of this session that Hermes no longer has was settled while the line was down.
            for (id, owner) in openQuestions.sorted(by: { $0.key < $1.key }) where owner == session && !stillOpenIds.contains(id) {
                forgetQuestion(id, &out)
            }
            for entry in stillOpen {
                guard let id = entry["id"]?.stringValue, let method = entry["method"]?.stringValue else { continue }
                asked(GatewayIncomingQuestion(id: id, method: method, params: entry["params"] ?? [:], replayed: true), &out)
            }
        case .failure:
            if !probe { out.append(.reload(session: session, .replayFailed)) }
        }
        finishReplay(session, &out)
    }

    private mutating func finishReplay(_ session: String, _ out: inout [Effect]) {
        replaying.remove(session)
        replayFrom[session] = nil
        // Live events that arrived while catching up go out after the replayed ones, in order, without repeats.
        for event in (held.removeValue(forKey: session) ?? []).sorted(by: { ($0.seq ?? 0) < ($1.seq ?? 0) }) {
            deliver(event, &out)
        }
        guard replaying.isEmpty else { return }
        if timerGenerations.removeValue(forKey: .replayDeadline) != nil { out.append(.cancelTimer(.replayDeadline)) }
        if case .handshaking = phase { becomeReady(&out) }
    }

    private mutating func becomeReady(_ out: inout [Effect]) {
        setPhase(.ready, &out)
        schedule(.heartbeat, after: configuration.heartbeatInterval, &out)
        schedule(.stable, after: configuration.stableAfter, &out)
        let answers = queuedAnswers
        queuedAnswers.removeAll()
        for frame in answers { out.append(.send(socket: socket, frame)) }
        let waiting = queued
        queued.removeAll()
        for (call, pending) in waiting { sendApp(call, pending, &out) }
    }

    // MARK: Calls

    private mutating func enqueue(_ call: Int, _ method: String, _ params: GatewayJSON, _ deadline: Duration?,
                                  _ out: inout [Effect]) {
        if case .closed = phase {
            out.append(.finish(call: call, .failure(.closed)))
            return
        }
        callDeadlines.insert(call)
        schedule(.callDeadline(call), after: deadline ?? configuration.callDeadline, &out)
        let pending = PendingCall(method: method, params: params)
        if phase == .ready {
            sendApp(call, pending, &out)
        } else {
            queued.append((call, pending))
        }
    }

    private mutating func sendApp(_ call: Int, _ pending: PendingCall, _ out: inout [Effect]) {
        let id = sendInternal(.app(call), method: pending.method, params: pending.params, &out)
        sentCalls[call] = id
    }

    @discardableResult
    private mutating func sendInternal(_ purpose: Purpose, method: String, params: GatewayJSON, _ out: inout [Effect]) -> Int {
        let id = nextWireId
        nextWireId += 1
        inFlight[id] = purpose
        out.append(.send(socket: socket, GatewayFrame.call(id: id, method: method, params: params)))
        return id
    }

    private mutating func abandon(_ call: Int, _ failure: GatewayCallFailure, _ out: inout [Effect]) {
        guard callDeadlines.contains(call) else { return }
        callDeadlines.remove(call)
        timerGenerations[.callDeadline(call)] = nil
        out.append(.cancelTimer(.callDeadline(call)))
        queued.removeAll { $0.call == call }
        if let id = sentCalls.removeValue(forKey: call) { inFlight[id] = nil }
        out.append(.finish(call: call, .failure(failure)))
    }

    // MARK: Questions

    private mutating func settle(_ id: String, _ frame: String, _ out: inout [Effect]) {
        guard openQuestions.removeValue(forKey: id) != nil else { return }
        remember(frame, for: id)
        if phase == .ready {
            out.append(.send(socket: socket, frame))
        } else {
            queuedAnswers.append(frame)
        }
    }

    // MARK: Timers

    private mutating func fired(_ timer: GatewayTimer, _ out: inout [Effect]) {
        timerGenerations[timer] = nil
        switch timer {
        case .connectDeadline, .silence:
            retry(&out)
        case .heartbeat:
            guard phase == .ready else { return }
            if !pingOutstanding {
                pingOutstanding = true
                sendInternal(.ping, method: GatewayWire.Calls.ping.name, params: [:], &out)
            }
            schedule(.heartbeat, after: configuration.heartbeatInterval, &out)
        case .retry:
            if case .retrying = phase { connect(&out) }
        case .stable:
            if phase == .ready { attempt = 0 }
        case .replayDeadline:
            for (id, purpose) in inFlight.sorted(by: { $0.key < $1.key }) {
                guard case .replay(let session, let probe) = purpose else { continue }
                inFlight[id] = nil
                if !probe { out.append(.reload(session: session, .replayFailed)) }
                finishReplay(session, &out)
            }
        case .callDeadline(let call):
            abandon(call, .timedOut, &out)
        }
    }

    // MARK: Drops

    private mutating func dropped(code: Int?, _ out: inout [Effect]) {
        socketOpen = false
        if let code, code == 4401 || code == 4403 {
            shutDown(.refused(code: code), &out)
        } else {
            retry(&out)
        }
    }

    /// Forgets the socket: calls on it are lost, events held for a replay are dropped (the next replay brings
    /// them back), and its timers stop.
    private mutating func loseSocket(_ out: inout [Effect]) {
        for (_, purpose) in inFlight.sorted(by: { $0.key < $1.key }) {
            guard case .app(let call) = purpose else { continue }
            sentCalls[call] = nil
            callDeadlines.remove(call)
            timerGenerations[.callDeadline(call)] = nil
            out.append(.cancelTimer(.callDeadline(call)))
            out.append(.finish(call: call, .failure(.connectionLost)))
        }
        inFlight.removeAll()
        replaying.removeAll()
        replayFrom.removeAll()
        held.removeAll()
        pingOutstanding = false
        for timer in [GatewayTimer.connectDeadline, .heartbeat, .silence, .stable, .replayDeadline]
        where timerGenerations.removeValue(forKey: timer) != nil {
            out.append(.cancelTimer(timer))
        }
    }

    private mutating func retry(_ out: inout [Effect]) {
        if socketOpen { out.append(.close(socket: socket, code: Self.silentCloseCode)) }
        socketOpen = false
        loseSocket(&out)
        if let limit = configuration.maxAttempts, attempt >= limit {
            shutDown(.gaveUp, &out)
            return
        }
        let delay = retryDelay(after: attempt)
        setPhase(.retrying(attempt: attempt + 1, delay: delay), &out)
        schedule(.retry, after: delay, &out)
    }

    private mutating func shutDown(_ reason: GatewayCloseReason, _ out: inout [Effect]) {
        if case .closed = phase { return }
        if socketOpen { out.append(.close(socket: socket, code: 1000)) }
        socketOpen = false
        socket += 1
        loseSocket(&out)
        queued.removeAll()
        queuedAnswers.removeAll()
        for call in callDeadlines.sorted() {
            out.append(.cancelTimer(.callDeadline(call)))
            out.append(.finish(call: call, .failure(.closed)))
        }
        callDeadlines.removeAll()
        sentCalls.removeAll()
        if timerGenerations.removeValue(forKey: .retry) != nil { out.append(.cancelTimer(.retry)) }
        timerGenerations.removeAll()
        setPhase(.closed(reason), &out)
    }

    // MARK: Helpers

    private mutating func setPhase(_ next: GatewayPhase, _ out: inout [Effect]) {
        guard next != phase else { return }
        phase = next
        out.append(.phase(next))
    }

    private mutating func schedule(_ timer: GatewayTimer, after: Duration, _ out: inout [Effect]) {
        nextGeneration += 1
        let generation = nextGeneration
        timerGenerations[timer] = generation
        out.append(.schedule(timer, generation: generation, after: after))
    }

    /// Doubles from the base up to the cap, moved by the jitter.
    mutating func retryDelay(after attempt: Int) -> Duration {
        let base = seconds(configuration.retryBase) * pow(2, Double(max(0, attempt - 1)))
        let capped = min(base, seconds(configuration.retryCap))
        let spread = configuration.retryJitter * (nextUnit() * 2 - 1)
        return .milliseconds(Int((capped * (1 + spread) * 1000).rounded()))
    }

    /// A number in 0..<1 from a small seeded generator (SplitMix64).
    private mutating func nextUnit() -> Double {
        random &+= 0x9E37_79B9_7F4A_7C15
        var z = random
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
