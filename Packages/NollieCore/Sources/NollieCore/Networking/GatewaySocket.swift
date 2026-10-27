import Foundation
import OSLog

public enum SocketState: Sendable, Equatable {
    case failed(String)
    case authRejected(String)
    case reconnecting(attempt: Int, delay: Double)
    case open
    case connecting
    case idle
}

public extension SocketState {
    var isOpen: Bool { self == .open }

    var label: String {
        switch self {
        case .open: String(localized: "Connected", table: "Core", comment: "The gateway connection's state")
        case .idle: String(localized: "Offline", table: "Core", comment: "The gateway connection's state")
        case .authRejected: String(localized: "Sign in required", table: "Core", comment: "The gateway connection's state")
        case .failed: String(localized: "Connection failed", table: "Core", comment: "The gateway connection's state")
        case .connecting: String(localized: "Connecting…", table: "Core", comment: "The gateway connection's state")
        case .reconnecting(let tries, _): String(localized: "Reconnecting (\(tries))…", table: "Core", comment: "The gateway connection's state, with the attempt number")
        }
    }
}

public enum SocketError: LocalizedError, Sendable {
    case cancelled
    case closed(code: Int, reason: String)
    case timeout(String)
    case notConnected
}

public extension SocketError {
    var errorDescription: String? {
        switch self {
        case .cancelled: return String(localized: "Cancelled.", table: "Core")
        case .notConnected: return String(localized: "Not connected to the gateway.", table: "Core")
        case .timeout(let what): return String(localized: "Timed out waiting for \(what).", table: "Core", comment: "The value is a gateway method name, such as gateway.ready")
        case .closed(let code, let reason):
            return reason.isEmpty ? String(localized: "WebSocket closed (\(String(code)))", table: "Core", comment: "The value is a close code")
                : String(localized: "WebSocket closed (\(String(code))): \(reason)", table: "Core", comment: "A close code, then why")
        }
    }
}

/// The app's live line to a gateway: JSON-RPC over `/api/ws`. It connects, keeps the line
/// alive, and reconnects with a growing pause when the line drops. Every attempt asks
/// `urlProvider` for a fresh address, because sign-in tickets work once.
public actor GatewaySocket {
    /// Pairs a caller with the timer that ends their wait. An earlier version raced a sleep against the
    /// reply inside a task group, but a group holds back its rethrow until all children end, and a reply's
    /// continuation cannot be cancelled, so calls never timed out. If the socket died quietly while
    /// the app slept (nothing closes it; the radio just lost track), the heartbeat ping hung for good, the
    /// socket was never judged lost, and each resume and send stalled behind it.
    private struct Waiter<Value: Sendable> {
        var continuation: CheckedContinuation<Value, Error>
        var clock: Task<Void, Never>

        func settle(_ result: Result<Value, Error>) {
            clock.cancel()
            continuation.resume(with: result)
        }
    }

    private enum Attempt {
        case connected
        case rejected(String)
        case failed
    }

    public private(set) var state: SocketState = .idle

    private let urlProvider: URLProvider
    private let sendBatch: EventBatchSink
    private let answerRequest: RequestHandler
    private let afterReconnect: ReconnectHook
    private let report: StateSink
    private let log = Logger(subsystem: NollieLog.subsystem, category: "connection")

    // The line itself, and the tasks that tend it.
    private var line: (any SocketLine)?
    /// Where lines come from when they are not the network's: the in-process demo gateway.
    private let transport: (any GatewayTransport)?
    private var reader: Task<Void, Never>?
    private var pulse: Task<Void, Never>?
    private var connector: Task<Void, Never>?

    // Who is waiting for what.
    private var calls: [Int: Waiter<JSONValue>] = [:]
    private var readyWaiters: [Int: Waiter<Void>] = [:]
    private var callCounter = 0
    private var waiterCounter = 0
    /// The batch currently collecting events, until the app claims it or a reply seals it.
    private var filling: GatewayEventBatch?

    // Whether the line should be up, and how the climb back is going.
    private var climb = Climb()

    /// Where the reconnect loop stands.
    private struct Climb {
        var wanted = false
        var wasOpen = false
        var tries = 0
    }

    /// Batched delivery. The sink hears about each batch only when it opens, and whoever picks the
    /// batch up afterwards gets everything that piled in since.
    public init(urlProvider: @escaping URLProvider, transport: (any GatewayTransport)? = nil,
                onEvents: @escaping EventBatchSink, onState: @escaping StateSink,
                onServerRequest: @escaping RequestHandler, onReconnected: @escaping ReconnectHook = {}) {
        self.transport = transport
        self.urlProvider = urlProvider
        self.sendBatch = onEvents
        self.report = onState
        self.answerRequest = onServerRequest
        self.afterReconnect = onReconnected
    }

    /// Delivers events individually, in arrival order.
    public init(urlProvider: @escaping URLProvider, onEvent: @escaping EventSink, onState: @escaping StateSink,
                onServerRequest: @escaping RequestHandler, onReconnected: @escaping ReconnectHook) {
        let perBatch: EventBatchSink = { batch in
            for event in batch.take() { onEvent(event) }
        }
        self.init(urlProvider: urlProvider, onEvents: perBatch, onState: onState,
                  onServerRequest: onServerRequest, onReconnected: onReconnected)
    }
}

public extension GatewaySocket {
    typealias URLProvider = @Sendable () async throws -> (URL, [String: String])
    typealias EventSink = @Sendable (GatewayEvent) -> Void
    /// Receives each batch once, as its first event comes in (see `GatewayEventBatch`).
    typealias EventBatchSink = @Sendable (GatewayEventBatch) -> Void
    typealias StateSink = @Sendable (SocketState) -> Void
    typealias RequestHandler = @Sendable (ServerRequest) async -> JSONValue?
    typealias ReconnectHook = @Sendable () async -> Void
}

// MARK: Starting and stopping

extension GatewaySocket {
    public func connect() {
        climb.wanted = true
        guard connector == nil, line == nil else { return }
        climb.tries = 0
        startConnector()
    }

    public func disconnect() {
        climb.wanted = false
        dropLine()
        connector?.cancel()
        connector = nil
        setState(.idle)
    }

    /// Returns once the gateway has said `gateway.ready`; throws if that takes longer than
    /// `timeout` seconds or the line goes away first.
    public func waitUntilReady(timeout: Double = 20) async throws {
        guard state != .open else { return }
        waiterCounter += 1
        let key = waiterCounter
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard state != .open else { return continuation.resume() }
                let clock = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    if !Task.isCancelled { await self?.failReadyWaiter(key, SocketError.timeout("gateway.ready")) }
                }
                readyWaiters[key] = Waiter(continuation: continuation, clock: clock)
            }
        } onCancel: {
            Task { await self.failReadyWaiter(key, SocketError.timeout("gateway.ready (cancelled)")) }
        }
    }

    /// Probes the line for life right now, and counts a missing answer as a dropped connection. A
    /// socket can die while the app is suspended; if we waited for the next heartbeat, each resume and
    /// send would pile up on it and then fail in one go.
    public func checkAlive(timeout: Double = 5) async {
        guard line != nil, state == .open else { return }
        if (try? await self.call("ping", params: [:], timeout: timeout)) == nil {
            lineLost("ping went unanswered on return")
        }
    }

    private func setState(_ new: SocketState) {
        state = new
        report(new)
    }

    private func startConnector() {
        connector = Task { await self.keepConnecting() }
    }
}

// MARK: Calls

extension GatewaySocket {
    public func call(_ method: String, params: JSONValue = [:], timeout: Double = 120) async throws -> JSONValue {
        guard let line else { throw SocketError.notConnected }
        callCounter += 1
        let key = callCounter
        let frame = RPCFrames.request(id: key, method: method, params: params)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                let clock = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    if !Task.isCancelled { await self?.failCall(key, SocketError.timeout(method)) }
                }
                calls[key] = Waiter(continuation: continuation, clock: clock)
                Task { [weak self] in
                    do {
                        try await line.send(frame)
                    } catch {
                        // The line can close mid-send, and closing already failed every call, this one too. Resuming
                        // twice traps, so only a call that is still waiting gets failed here.
                        await self?.failCall(key, SocketError.notConnected)
                    }
                }
            }
        } onCancel: {
            Task { await self.failCall(key, SocketError.timeout("\(method) (cancelled)")) }
        }
    }

    /// Answers a question from the gateway that reached the app some other way (a replayed
    /// `open_requests` entry, say).
    public func respond(to id: String, result: JSONValue) async {
        await write(RPCFrames.response(id: id, result: result))
    }

    private func write(_ text: String) async {
        try? await line?.send(text)
    }

    /// Fails a single call unless a reply or a teardown already settled it.
    private func failCall(_ key: Int, _ error: Error) {
        calls.removeValue(forKey: key)?.settle(.failure(error))
    }

    private func failReadyWaiter(_ key: Int, _ error: Error) {
        readyWaiters.removeValue(forKey: key)?.settle(.failure(error))
    }

    private func settleReadyWaiters(_ outcome: Result<Void, Error>) {
        let waiting = readyWaiters.values
        readyWaiters.removeAll()
        for waiter in waiting { waiter.settle(outcome) }
    }
}

// MARK: Connecting

extension GatewaySocket {
    private func keepConnecting() async {
        defer { connector = nil }
        while climb.wanted && !Task.isCancelled {
            climb.tries += 1
            let comingBack = climb.tries > 1 || climb.wasOpen
            setState(comingBack ? .reconnecting(attempt: climb.tries, delay: 0) : .connecting)

            switch await tryOnce() {
            case .rejected(let why):
                setState(.authRejected(why))
                return
            case .connected:
                let wasReturn = climb.wasOpen
                climb = Climb(wanted: climb.wanted, wasOpen: true, tries: 0)
                if wasReturn { await afterReconnect() }
                return
            case .failed:
                if !climb.wanted { return }
                if await pauseBeforeRetry() == false { return }
            }
        }
    }

    /// One go: get an address, open the line, wait for ready.
    private func tryOnce() async -> Attempt {
        do {
            let (url, headers) = try await urlProvider()
            try await openLine(url: url, headers: headers)
            try await waitUntilReady(timeout: 20)
            return .connected
        } catch GatewayTransportError.refused(let status) where status == 401 || status == 403 {
            dropLine()
            return .rejected(String(localized: "The gateway turned down the WebSocket credential (\(status)).", table: "Core", comment: "The value is an HTTP status"))
        } catch let refused as HermesAPIError where refused.isUnauthorized {
            dropLine()
            return .rejected(refused.localizedDescription)
        } catch SocketError.closed(let code, let reason) where code == 4401 {
            dropLine()
            return .rejected(reason.isEmpty ? String(localized: "The gateway turned down the WebSocket credential (4401).", table: "Core") : reason)
        } catch {
            dropLine()
            log.warning("connect failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    /// Waits before the next attempt. Returns false if the loop should stop instead.
    private func pauseBeforeRetry() async -> Bool {
        let network = NetworkWatch.shared
        guard network.isUsable else {
            // No route at all: waiting longer each time would not help (#305). Wait for the
            // network path to change, which is what a route coming up looks like.
            setState(.reconnecting(attempt: climb.tries, delay: 0))
            await network.waitForChange(since: network.mark, upTo: 30)
            return !Task.isCancelled
        }
        let pause = Self.retryDelay(attempt: climb.tries) * Double.random(in: 0.8...1.2)
        setState(.reconnecting(attempt: climb.tries, delay: pause))
        return await sleepUnlessPathChanges(for: pause, watching: network)
    }

    /// Sleeps in short steps so that a network change (the route came up) ends the wait early.
    /// False means the task was cancelled while waiting.
    private func sleepUnlessPathChanges(for seconds: Double, watching network: NetworkWatch) async -> Bool {
        let marker = network.mark
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline && network.mark == marker {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return false }
        }
        return !Task.isCancelled
    }

    /// The pause after failed attempt number `attempt`: a second for the first three, then
    /// doubling from two seconds up to half a minute.
    nonisolated static func retryDelay(attempt: Int) -> Double {
        let ladder: [Double] = [1, 1, 1, 2, 4, 8, 16, 30]
        return ladder[min(max(attempt, 1), ladder.count) - 1]
    }

    private func openLine(url: URL, headers: [String: String]) async throws {
        let opened: any SocketLine
        if let transport {
            opened = ChannelLine(try await transport.open(GatewayEndpoint(url: url, headers: headers)))
        } else {
            opened = URLSessionLine(url: url, headers: headers)
        }
        line = opened
        reader = Task { await self.readLoop(opened) }
    }

    /// Lets go of the line and fails everyone waiting on it.
    private func dropLine() {
        for task in [pulse, reader] { task?.cancel() }
        (pulse, reader, filling) = (nil, nil, nil)
        line?.close()
        line = nil

        settleReadyWaiters(.failure(SocketError.notConnected))
        let waiting = calls.values
        calls.removeAll()
        for waiter in waiting { waiter.settle(.failure(SocketError.notConnected)) }
    }

    private func lineLost(_ why: String) {
        guard line != nil else { return }
        log.warning("connection lost: \(why, privacy: .public)")
        dropLine()
        // The state turns non-open at this very moment, not when the connect loop gets going. Otherwise a
        // call made in between would see `.open`, skip waiting for readiness, and fail against a connection
        // that was already gone.
        guard climb.wanted else { return setState(.idle) }
        setState(.reconnecting(attempt: climb.tries + 1, delay: 0))
        if connector == nil { startConnector() }
    }

    private func becomeOpen() {
        if state == .open { return }
        setState(.open)
        settleReadyWaiters(.success(()))
        pulse?.cancel()
        pulse = Task { [weak self] in await self?.beat() }
    }

    /// Every 15 seconds, ask for proof of life; silence is treated as a dropped line.
    private func beat() async {
        while (try? await Task.sleep(for: .seconds(15))) != nil {
            do {
                _ = try await self.call("ping", params: [:], timeout: 20)
            } catch {
                return lineLost("heartbeat timeout")
            }
        }
    }
}

// MARK: Reading

extension GatewaySocket {
    private func readLoop(_ task: any SocketLine) async {
        while !Task.isCancelled, line === task {
            switch await nextText(from: task) {
            case .success(let text):
                for piece in text.split(separator: "\n") { route(InboundFrame.parse(String(piece))) }
            case .failure(let error):
                if line === task { readFailed(on: task, error) }
                return
            }
        }
    }

    private func nextText(from task: any SocketLine) async -> Result<String, Error> {
        do {
            return .success(try await task.receive())
        } catch {
            return .failure(error)
        }
    }

    private func readFailed(on task: any SocketLine, _ error: Error) {
        if state == .open { return lineLost("receive error: \(error.localizedDescription)") }
        // Closed before ready: the connect loop hears why through the waiters.
        let (code, said) = task.closing
        let rejected = code == 4401 || code == 4403
        let reason = rejected || !said.isEmpty ? said : error.localizedDescription
        settleReadyWaiters(.failure(SocketError.closed(code: code, reason: reason)))
        dropLine()
    }

    private func route(_ frame: InboundFrame) {
        switch frame {
        case .unknown:
            return
        case .event(let event):
            if event.type == "gateway.ready" { becomeOpen() }
            hand(event)
        case .response(let id, let result, let failure):
            // Anything arriving after a reply belongs to a later batch (see `GatewayEventBatch`).
            filling = nil
            guard let key = id.intValue, let waiter = calls.removeValue(forKey: key) else { return }
            if let failure { waiter.settle(.failure(failure)) } else { waiter.settle(.success(result ?? .null)) }
        case .serverRequest(let request):
            filling = nil
            Task { await self.reply(to: request) }
        }
    }

    /// Appends to the open batch if the app has not claimed it yet, otherwise starts a fresh one.
    private func hand(_ event: GatewayEvent) {
        if let batch = filling, batch.add(event) { return }
        let fresh = GatewayEventBatch()
        _ = fresh.add(event)
        filling = fresh
        sendBatch(fresh)
    }

    private func reply(to request: ServerRequest) async {
        guard let result = await answerRequest(request) else {
            // The gateway closes a request out as soon as any client replies, so an error from us here
            // would pull the approval away from every device and leave the turn to time out. When this app has no way to
            // show the request (a chat it never opened, or a method it cannot draw) it stays quiet instead.
            // The request remains in the gateway's open_requests, returns after the next resume, and a different
            // client can still answer it.
            log.warning("request \(request.method, privacy: .public) from \(request.sessionID, privacy: .public) was left open")
            return
        }
        await write(RPCFrames.response(id: request.id, result: result))
    }
}
