import Foundation

/// A pretend Hermes for tests and offline demos. It plays a script, one entry per socket the client opens: refuse
/// the open, or accept it and run steps in order. Steps push frames to the client, wait for the client to send
/// a call or an answer (and reply to it), or drop the socket. A test reads like the conversation it expects.
///
/// Anything the client sends that the script did not expect is kept in `problems`; tests check it is empty.
public final class ScriptedGatewayTransport: GatewayTransport, @unchecked Sendable {
    public enum Dial: Sendable {
        case refuse(GatewayTransportError)
        case accept([Step])
    }

    public enum Step: Sendable {
        /// Hermes sends this frame.
        case push(String)
        /// Hermes sends an event.
        case event(type: String, session: String = "", seq: Int? = nil, payload: GatewayJSON? = nil)
        /// The client must call `method`; Hermes answers with `reply` using the call's id.
        case expectCall(String, params: GatewayJSON? = nil, reply: Reply = .result([:]))
        /// The client must answer the question with this id (with a result or an error).
        case expectAnswer(id: String, result: GatewayJSON? = nil, errorCode: Int? = nil)
        /// Hermes closes the socket.
        case drop(code: Int?)
    }

    public enum Reply: Sendable {
        case result(GatewayJSON)
        case error(code: Int, message: String)
        /// Never answer (the call stays in flight).
        case silence
    }

    private let lock = NSLock()
    private var dials: [Dial]
    private var sentFrames: [String] = []
    private var problemList: [String] = []
    private var opens = 0
    private var live: ScriptedGatewayChannel?

    public init(_ dials: [Dial]) {
        self.dials = dials
    }

    /// Every frame the client sent, across all sockets, in order.
    public var sent: [String] { lock.withLock { sentFrames } }
    /// Sends the script did not expect, and opens it had no entry for.
    public var problems: [String] { lock.withLock { problemList } }
    public var openCount: Int { lock.withLock { opens } }
    /// True when every entry has been used and every step of the last socket has run.
    public var finished: Bool { lock.withLock { dials.isEmpty && (live?.remainingSteps ?? 0) == 0 } }

    /// The usual start of a connection: Hermes says it is ready, then answers the client's capabilities call.
    public static func handshake(epoch: String, declinesNotShown: Bool = true) -> [Step] {
        let ready: GatewayJSON = ["type": "gateway.ready", "payload": [
            "skin": ["name": "default"], "change_events": true, "heartbeat": true, "replay_epoch": .string(epoch),
        ]]
        let capabilities: GatewayJSON = ["server_requests": .array(GatewayWire.Questions.all.map(GatewayJSON.string)),
                                         "declines_not_shown": .bool(declinesNotShown)]
        return [.push(Self.text(["jsonrpc": "2.0", "method": "event", "params": ready])),
                .expectCall("client.capabilities", params: ["server_requests": true], reply: .result(capabilities))]
    }

    public func open(_ endpoint: GatewayEndpoint) async throws -> any GatewayChannel {
        let dial = lock.withLock { () -> Dial? in
            opens += 1
            live?.retire()
            return dials.isEmpty ? nil : dials.removeFirst()
        }
        switch dial {
        case nil:
            note("open \(openCount) has no script")
            throw GatewayTransportError.unreachable("no script")
        case .refuse(let error):
            throw error
        case .accept(let steps):
            let channel = ScriptedGatewayChannel(steps: steps, owner: self)
            lock.withLock { live = channel }
            channel.run()
            return channel
        }
    }

    func record(_ text: String) { lock.withLock { sentFrames.append(text) } }
    func note(_ problem: String) { lock.withLock { problemList.append(problem) } }

    static func text(_ json: GatewayJSON) -> String {
        String(decoding: (try? json.encoded()) ?? Data(), as: UTF8.self)
    }
}

final class ScriptedGatewayChannel: GatewayChannel, @unchecked Sendable {
    let incoming: AsyncStream<GatewayChannelEvent>
    private let feed: AsyncStream<GatewayChannelEvent>.Continuation
    private let lock = NSLock()
    private var steps: [ScriptedGatewayTransport.Step]
    private var closed = false
    private weak var owner: ScriptedGatewayTransport?

    init(steps: [ScriptedGatewayTransport.Step], owner: ScriptedGatewayTransport) {
        self.steps = steps
        self.owner = owner
        (incoming, feed) = AsyncStream.makeStream(of: GatewayChannelEvent.self)
    }

    var remainingSteps: Int { lock.withLock { steps.count } }

    /// Runs steps up to the next one that waits for the client.
    func run() {
        while true {
            let step = lock.withLock { () -> ScriptedGatewayTransport.Step? in
                guard !closed, let next = steps.first else { return nil }
                switch next {
                case .expectCall, .expectAnswer: return nil
                default: steps.removeFirst(); return next
                }
            }
            switch step {
            case nil: return
            case .push(let text): feed.yield(.text(text))
            case .event(let type, let session, let seq, let payload):
                var params: [String: GatewayJSON] = ["type": .string(type), "session_id": .string(session)]
                if let seq { params["seq"] = .integer(seq) }
                if let payload { params["payload"] = payload }
                feed.yield(.text(ScriptedGatewayTransport.text(["jsonrpc": "2.0", "method": "event", "params": .object(params)])))
            case .drop(let code): end(code: code)
            case .expectCall, .expectAnswer: return
            }
        }
    }

    func send(_ text: String) {
        guard let owner else { return }
        guard lock.withLock({ !closed }) else { owner.note("sent after the socket closed: \(text)"); return }
        owner.record(text)
        guard let frame = try? GatewayJSON.parse(Data(text.utf8)) else { owner.note("unreadable send: \(text)"); return }
        let expected = lock.withLock { steps.first }
        switch expected {
        case .expectCall(let method, let params, let reply) where frame["method"]?.stringValue == method:
            if let params, frame["params"] != params {
                owner.note("\(method) sent with params \(frame["params"].map(String.init(describing:)) ?? "none")")
            }
            lock.withLock { _ = steps.removeFirst() }
            let id = frame["id"] ?? .null
            switch reply {
            case .result(let result): feed.yield(.text(ScriptedGatewayTransport.text(["jsonrpc": "2.0", "id": id, "result": result])))
            case .error(let code, let message):
                feed.yield(.text(ScriptedGatewayTransport.text(["jsonrpc": "2.0", "id": id,
                                                                "error": ["code": .integer(code), "message": .string(message)]])))
            case .silence: break
            }
        case .expectAnswer(let id, let result, let errorCode) where frame["method"] == nil && frame["id"]?.stringValue == id:
            if let result, frame["result"] != result { owner.note("answer to \(id) was \(text)") }
            if let errorCode, frame["error"]?["code"]?.intValue != errorCode { owner.note("answer to \(id) was \(text)") }
            lock.withLock { _ = steps.removeFirst() }
        default:
            owner.note("unexpected send: \(text)")
            return
        }
        run()
    }

    func close(code: Int) {
        noteLeftovers("closed by the client")
        end(code: code)
    }

    /// A newer socket replaced this one.
    func retire() {
        noteLeftovers("replaced by a new socket")
        end(code: nil)
    }

    /// Steps the client never reached mean it skipped something the script expected.
    private func noteLeftovers(_ how: String) {
        let left = lock.withLock { closed ? [] : steps }
        if !left.isEmpty { owner?.note("socket \(how) with \(left.count) step(s) unused: \(left)") }
    }

    private func end(code: Int?) {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        feed.yield(.closed(code: code, reason: nil))
        feed.finish()
    }
}
