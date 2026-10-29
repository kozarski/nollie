import Foundation

/// What the connection tells the app, in order.
public enum GatewayNotice: Hashable, Sendable {
    case phase(GatewayPhase)
    case event(GatewayEventEnvelope)
    /// A question the app said it can show (see `GatewayConfiguration.shownQuestions`). Answer it with
    /// `answer(_:id:with:)` or `decline(id:)`.
    case question(GatewayIncomingQuestion)
    /// A question already shown is no longer waiting; take its card down.
    case questionWithdrawn(id: String)
    /// Reload this session from stored history: some of its events cannot be recovered.
    case reload(session: String, GatewayReloadReason)
}

/// One live connection to a Hermes gateway's `/api/ws`. It runs `GatewayMachine` against a transport: opens
/// sockets, runs timers, matches answers to calls and passes everything else on as `notices`.
/// See `Docs/specs/gateway-client.md`.
public actor GatewayClient {
    /// Gives the endpoint for each attempt, so a short-lived ticket can be minted fresh every time.
    public typealias EndpointSource = @Sendable () async throws -> GatewayEndpoint

    public nonisolated let notices: AsyncStream<GatewayNotice>
    private let noticeFeed: AsyncStream<GatewayNotice>.Continuation
    private let transport: any GatewayTransport
    private let endpoint: EndpointSource
    private var machine: GatewayMachine
    private var channels: [Int: any GatewayChannel] = [:]
    private var timers: [GatewayTimer: Task<Void, Never>] = [:]
    private var waiting: [Int: CheckedContinuation<GatewayJSON, any Error>] = [:]
    private var nextCall = 1

    public init(transport: any GatewayTransport, configuration: GatewayConfiguration = GatewayConfiguration(),
                endpoint: @escaping EndpointSource) {
        self.transport = transport
        self.endpoint = endpoint
        machine = GatewayMachine(configuration: configuration)
        (notices, noticeFeed) = AsyncStream.makeStream(of: GatewayNotice.self)
    }

    public var phase: GatewayPhase { machine.phase }

    public func start() { feed(.start) }

    /// Closes the connection until `start()`. Calls not yet sent fail with `closed`; calls already sent fail with
    /// `connectionLost`, because Hermes may have acted on them.
    public func stop() { feed(.stop) }

    /// Calls a method and waits for its result.
    public func call<Params, Result>(_ method: GatewayCall<Params, Result>, _ params: Params,
                                     timeout: Duration? = nil) async throws -> Result {
        let answer = try await callRaw(method.name, try GatewayJSON(encoding: params), timeout: timeout)
        return try answer.decode(Result.self)
    }

    /// Calls a method by name with plain JSON params.
    public func callRaw(_ method: String, _ params: GatewayJSON, timeout: Duration? = nil) async throws -> GatewayJSON {
        let call = nextCall
        nextCall += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting[call] = continuation
                feed(.call(call, method: method, params: params, deadline: timeout))
            }
        } onCancel: {
            Task { await self.feed(.cancel(call: call)) }
        }
    }

    public func answer<Params, Answer>(_ question: GatewayQuestion<Params, Answer>, id: String, with answer: Answer) throws {
        feed(.answer(question: id, result: try GatewayJSON(encoding: answer)))
    }

    /// Sets a shown question aside on this device without answering it, so a window elsewhere that shows the
    /// chat can still answer. When the person says no, answer instead (for an approval, its deny choice). The message
    /// goes to the gateway, so it stays in English.
    public func decline(id: String, message: String = "Not answered on this device.") {
        feed(.decline(question: id, message: message))
    }

    /// Keeps a session's events in order and catches up on them after a drop. `from` is the last seq the app
    /// already has, if it knows it.
    public func watch(session: String, profile: String? = nil, from seq: Int? = nil) {
        feed(.watch(session: session, profile: profile, from: seq))
    }

    public func unwatch(session: String) { feed(.unwatch(session: session)) }

    // MARK: Running the machine

    private func feed(_ input: GatewayMachine.Input) {
        for effect in machine.handle(input) { perform(effect) }
    }

    private func perform(_ effect: GatewayMachine.Effect) {
        switch effect {
        case .open(let socket):
            Task { await self.open(socket) }
        case .send(let socket, let text):
            channels[socket]?.send(text)
        case .close(let socket, let code):
            channels.removeValue(forKey: socket)?.close(code: code)
        case .schedule(let timer, let generation, let delay):
            timers[timer]?.cancel()
            timers[timer] = Task {
                guard (try? await Task.sleep(for: delay)) != nil else { return }
                self.timerFired(timer, generation)
            }
        case .cancelTimer(let timer):
            timers.removeValue(forKey: timer)?.cancel()
        case .phase(let phase):
            noticeFeed.yield(.phase(phase))
            if case .closed = phase { closeAllChannels() }
        case .finish(let call, let result):
            guard let continuation = waiting.removeValue(forKey: call) else { return }
            continuation.resume(with: result.mapError { $0 as any Error })
        case .event(let event):
            noticeFeed.yield(.event(event))
        case .question(let question):
            noticeFeed.yield(.question(question))
        case .withdrawn(let id):
            noticeFeed.yield(.questionWithdrawn(id: id))
        case .reload(let session, let reason):
            noticeFeed.yield(.reload(session: session, reason))
        }
    }

    private func timerFired(_ timer: GatewayTimer, _ generation: Int) {
        feed(.timerFired(timer, generation: generation))
    }

    private func open(_ socket: Int) async {
        let channel: any GatewayChannel
        do {
            channel = try await transport.open(try await endpoint())
        } catch let error as GatewayTransportError {
            feed(.openFailed(socket: socket, error))
            return
        } catch {
            feed(.openFailed(socket: socket, .unreachable(String(describing: type(of: error)))))
            return
        }
        channels[socket] = channel
        feed(.opened(socket: socket))
        guard channels[socket] != nil else { return }
        Task { await self.read(channel, socket) }
    }

    private func read(_ channel: any GatewayChannel, _ socket: Int) async {
        for await message in channel.incoming {
            switch message {
            case .text(let text): feed(.received(socket: socket, text))
            case .closed(let code, _):
                channels[socket] = nil
                feed(.closed(socket: socket, code: code))
            }
        }
    }

    private func closeAllChannels() {
        for (_, channel) in channels { channel.close(code: 1000) }
        channels.removeAll()
    }
}
