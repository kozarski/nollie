#if os(macOS)
import Darwin
import Foundation
import Network
import Security

/// Papertrail's door: the way out for Hermes and every program it starts. Hermes's processes get
/// `HTTP_PROXY`, `HTTPS_PROXY` and `ALL_PROXY` pointing here (loopback stays direct through
/// `NO_PROXY`), with a label naming the bot and the kind of program as the proxy user and this
/// run's secret as the password. The door listens on 127.0.0.1 only, answers `CONNECT host:port`
/// and plain `http://` requests, notes each connection in that bot's Papertrail (host, port, time,
/// kind) and passes the bytes through unread. A request without the secret is turned away.
///
/// It only sees programs that use a proxy when told to. The rest is the network filter's job.
final class PapertrailDoor: @unchecked Sendable {
    struct Configuration: Sendable {
        /// Request, name lookup and connect.
        var setupTimeout: TimeInterval = 20
        var connectTimeout: TimeInterval = 15
        /// No bytes either way for this long and the connection is closed. Long, for streamed replies.
        var idleTimeout: TimeInterval = 900
        var maximumConnections = 512
        /// With the network filter refusing what goes around the door, the door refuses what it can't
        /// place with a bot too, so nothing leaves without a line.
        var refuseUnplaced = false
    }

    struct Counts: Equatable, Sendable {
        var open = 0
        var passed = 0
        var refusedSecret = 0
        var refusedUnplaced = 0
        var malformed = 0
        var upstreamFailures = 0
    }

    let configuration: Configuration
    /// This run's secret, 64 hex characters. Only Hermes's environment carries it.
    let secret: String
    private let book: PapertrailDoorBook?
    private let queue = DispatchQueue(label: "com.coreykozarski.nollie.papertrail-door")
    private var listener: NWListener?
    private var listeningPort: UInt16?
    private var sessions: [ObjectIdentifier: PapertrailDoorSession] = [:]
    private var tally = Counts()
    private var sweep: DispatchSourceTimer?
    /// Starts as the configuration says; the network filter's switch can change it while Hermes runs.
    private var refusing: Bool

    init(configuration: Configuration = .init(), book: PapertrailDoorBook?, secret: String = PapertrailDoor.newSecret()) {
        self.configuration = configuration
        self.refusing = configuration.refuseUnplaced
        self.book = book
        self.secret = secret
    }

    static func newSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    var port: UInt16? { queue.sync { listeningPort } }
    var refusesUnplaced: Bool { queue.sync { refusing } }

    /// With the network filter refusing, programs the door can't place with a bot are refused too.
    func setRefuseUnplaced(_ refuse: Bool) { queue.sync { refusing = refuse } }
    var counts: Counts { queue.sync { var counts = tally; counts.open = sessions.count; return counts } }

    /// The proxy address for one label, as Hermes's environment carries it.
    func proxyURL(bot: String, kind: String) -> String? {
        guard let port else { return nil }
        return "http://\(bot).\(kind):\(secret)@127.0.0.1:\(port)"
    }

    // MARK: Listening

    @discardableResult
    func start() async throws -> UInt16 {
        if let port = queue.sync(execute: { listener != nil ? listeningPort : nil }) { return port }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.includePeerToPeer = false
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let made = try NWListener(using: parameters)
        made.newConnectionHandler = { [weak self, weak made] connection in
            guard let self, let made, self.listener === made else { connection.forceCancel(); return }
            self.accept(connection)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = PapertrailDoorOnce(continuation)
            queue.async { [self] in
                listener = made
                made.stateUpdateHandler = { [weak self] state in
                    guard let self else { made.cancel(); return }
                    switch state {
                    case .ready:
                        guard self.listener === made, let port = made.port?.rawValue else {
                            made.cancel(); once.resume(.failure(NWError.posix(.ECANCELED))); return
                        }
                        self.listeningPort = port
                        self.startSweep()
                        once.resume(.success(port))
                    case .failed(let error), .waiting(let error):
                        made.cancel()
                        if self.listener === made { self.listener = nil; self.listeningPort = nil }
                        once.resume(.failure(error))
                    case .cancelled:
                        made.stateUpdateHandler = nil
                        made.newConnectionHandler = nil
                        if self.listener === made { self.listener = nil; self.listeningPort = nil }
                        once.resume(.failure(NWError.posix(.ECANCELED)))
                    default: break
                    }
                }
                made.start(queue: queue)
            }
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            listeningPort = nil
            sweep?.cancel()
            sweep = nil
            for session in sessions.values { session.close() }
            sessions = [:]
        }
        book?.flush()
    }

    private func startSweep() {
        sweep?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let every = max(0.05, min(configuration.idleTimeout, configuration.setupTimeout) / 4)
        timer.schedule(deadline: .now() + every, repeating: every)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for session in self.sessions.values where session.expired(now: now, setup: self.configuration.setupTimeout,
                                                                        idle: self.configuration.idleTimeout) {
                session.close()
            }
        }
        timer.resume()
        sweep = timer
    }

    // MARK: Connections (on the door's queue)

    private func accept(_ connection: NWConnection) {
        // Loopback only: the listener is bound there, and anything else is dropped unread.
        guard case .hostPort(let host, _) = connection.endpoint, Self.isLoopback(host),
              sessions.count < configuration.maximumConnections else {
            connection.forceCancel()
            return
        }
        let session = PapertrailDoorSession(client: connection, door: self, queue: queue)
        sessions[ObjectIdentifier(session)] = session
        connection.stateUpdateHandler = { [weak session] state in
            guard let session else { return }
            switch state {
            case .ready: session.readRequest()
            case .failed, .cancelled: session.close()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): return address.rawValue.first == 127
        case .ipv6(let address): return address == .loopback || address.asIPv4.map { $0.rawValue.first == 127 } == true
        default: return false
        }
    }

    fileprivate func finished(_ session: PapertrailDoorSession) { sessions[ObjectIdentifier(session)] = nil }
    fileprivate func countMalformed() { tally.malformed += 1 }
    fileprivate func countRefusedSecret() { tally.refusedSecret += 1 }
    fileprivate func countRefusedUnplaced() { tally.refusedUnplaced += 1 }
    /// On the door's queue, where sessions run.
    fileprivate var refusingNow: Bool { refusing }
    fileprivate func countUpstream(_ ok: Bool) { if ok { tally.passed += 1 } else { tally.upstreamFailures += 1 } }

    /// The label behind a request, when its secret is this run's. Constant time over the secret.
    fileprivate func admit(_ authorization: String?) -> (bot: String, kind: String)? {
        guard let credentials = PapertrailDoorRequest.basic(authorization),
              Self.same(credentials.password, secret) else { return nil }
        // The right secret with no bot to name: passed on, without a line.
        return PapertrailDoorBook.label(credentials.user) ?? ("", "program")
    }

    fileprivate func note(_ label: (bot: String, kind: String), _ target: ExitRelayTarget) {
        guard !label.bot.isEmpty else { return }
        book?.record(bot: label.bot, kind: label.kind, host: target.recordedHost, port: target.port)
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

extension ExitRelayTarget {
    /// The host as Papertrail keeps it: the name, or the address written out.
    var recordedHost: String {
        switch host {
        case .name(let name): return name
        case .address(let bytes) where bytes.count == 4: return bytes.map(String.init).joined(separator: ".")
        case .address(let bytes): return IPv6Address(Data(bytes)).map { "\($0)" } ?? ""
        }
    }
}

/// What the door reads from a request: the usual CONNECT or `http://` request (parsed as the exit
/// relay parses it) and the proxy credentials it carries.
enum PapertrailDoorRequest {
    static func authorization(_ data: Data) throws(LinkDoorHTTP.Failure) -> String? {
        let (lines, _) = try LinkDoorHTTP.headLines(data, limits: ExitRelayHTTP.limits)
        let headers = try LinkDoorHTTP.parseHeaders(lines.dropFirst(), limits: ExitRelayHTTP.limits)
        return headers.first { $0.key == "proxy-authorization" }?.value
    }

    /// `Basic base64(user:password)`, or nil.
    static func basic(_ value: String?) -> (user: String, password: String)? {
        guard let value else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "basic",
              let decoded = Data(base64Encoded: String(parts[1]).trimmingCharacters(in: .whitespaces)),
              let text = String(data: decoded, encoding: .utf8),
              let colon = text.firstIndex(of: ":") else { return nil }
        return (String(text[..<colon]).removingPercentEncoding ?? String(text[..<colon]), String(text[text.index(after: colon)...]))
    }

    static let established = ExitRelayHTTP.established

    static func refusal(_ status: Int) -> Data {
        var headers = [LinkDoorHTTP.Header(name: "Content-Type", value: "text/plain; charset=utf-8"),
                       LinkDoorHTTP.Header(name: "Connection", value: "close")]
        let message: String
        switch status {
        case 407:
            headers.append(.init(name: "Proxy-Authenticate", value: "Basic realm=\"Nollie\""))
            message = "Nollie's door needs the address Nollie gave this program.\n"
        case 403: message = "Nollie's door only lets out what Papertrail can name.\n"
        case 502: message = "Nollie's door couldn't reach that address.\n"
        case 503: message = "Nollie's door is busy. Try again in a moment.\n"
        default: message = "Nollie's door couldn't read that request.\n"
        }
        let body = Data(message.utf8)
        headers.append(.init(name: "Content-Length", value: String(body.count)))
        return LinkDoorHTTP.serializeResponse(status: status, reason: LinkDoorHTTP.reason(status), headers: headers) + body
    }
}

private final class PapertrailDoorOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func resume(_ result: Result<UInt16, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// One connection from a program Hermes started: its request, the secret, a line in Papertrail,
/// then bytes both ways until either side is done. All work happens on the door's queue.
private final class PapertrailDoorSession: @unchecked Sendable {
    let client: NWConnection
    private weak var door: PapertrailDoor?
    private let queue: DispatchQueue
    private var upstream: NWConnection?
    private var buffer = Data()
    private var closed = false
    private var connected = false
    private let opened = Date()
    private var lastActivity = Date()
    private var clientDone = false
    private var upstreamDone = false
    private static let chunk = 64 * 1024

    init(client: NWConnection, door: PapertrailDoor, queue: DispatchQueue) {
        self.client = client
        self.door = door
        self.queue = queue
    }

    func expired(now: Date, setup: TimeInterval, idle: TimeInterval) -> Bool {
        connected ? now.timeIntervalSince(lastActivity) > idle : now.timeIntervalSince(opened) > setup
    }

    func close() {
        guard !closed else { return }
        closed = true
        upstream?.forceCancel()
        upstream = nil
        client.forceCancel()
        door?.finished(self)
    }

    private func answer(_ data: Data) {
        guard !closed else { return }
        client.send(content: data, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func readRequest() {
        guard !closed else { return }
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            self.lastActivity = Date()
            if !self.buffer.isEmpty { self.http(complete: complete || error != nil) }
            else if complete || error != nil { self.close() }
            else { self.readRequest() }
        }
    }

    private func http(complete: Bool) {
        guard let door else { close(); return }
        do throws(LinkDoorHTTP.Failure) {
            let request = try ExitRelayHTTP.parse(buffer)
            guard let label = door.admit(try PapertrailDoorRequest.authorization(buffer)) else {
                door.countRefusedSecret()
                answer(PapertrailDoorRequest.refusal(407))
                return
            }
            if label.bot.isEmpty, door.refusingNow {
                door.countRefusedUnplaced()
                answer(PapertrailDoorRequest.refusal(403))
                return
            }
            let early = Data(buffer.dropFirst(request.headLength))
            buffer = Data()
            // Noted before it is tried: a name looked up and a connection attempted already left.
            door.note(label, request.target)
            connect(request.target) { [weak self] ok in
                guard let self else { return }
                guard ok else { self.answer(PapertrailDoorRequest.refusal(502)); return }
                switch request.kind {
                case .connect:
                    self.client.send(content: PapertrailDoorRequest.established, completion: .contentProcessed { [weak self] error in
                        guard let self, error == nil else { self?.close(); return }
                        self.pipe(early)
                    })
                case .forward(let head):
                    self.pipe(head + early)
                }
            }
        } catch .incomplete {
            if complete { close() } else { readRequest() }
        } catch {
            door.countMalformed()
            answer(PapertrailDoorRequest.refusal(400))
        }
    }

    private func connect(_ target: ExitRelayTarget, then: @escaping @Sendable (Bool) -> Void) {
        guard let door else { close(); return }
        let host: NWEndpoint.Host
        switch target.host {
        case .name(let name): host = .init(name)
        case .address(let bytes) where bytes.count == 4: host = IPv4Address(Data(bytes)).map { .ipv4($0) } ?? .init(target.recordedHost)
        case .address(let bytes): host = IPv6Address(Data(bytes)).map { .ipv6($0) } ?? .init(target.recordedHost)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(door.configuration.connectTimeout.rounded(.up))
        tcp.noDelay = true
        let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: target.port) ?? .https,
                                      using: NWParameters(tls: nil, tcp: tcp))
        upstream = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed, self.upstream === connection, !self.connected else { return }
            switch state {
            case .ready:
                self.connected = true
                self.lastActivity = Date()
                door.countUpstream(true)
                then(true)
            case .failed, .waiting:
                connection.forceCancel()
                self.upstream = nil
                door.countUpstream(false)
                then(false)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func pipe(_ first: Data) {
        guard let upstream, !closed else { return }
        let start: @Sendable () -> Void = { [weak self] in
            guard let self, !self.closed else { return }
            self.pumpUp()
            self.pumpDown()
        }
        if first.isEmpty { start(); return }
        upstream.send(content: first, completion: .contentProcessed { [weak self] error in
            guard error == nil else { self?.close(); return }
            start()
        })
    }

    private func pumpUp() {
        guard let upstream, !closed else { return }
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            self.lastActivity = Date()
            if error != nil { self.close(); return }
            let payload = data ?? Data()
            if payload.isEmpty && !complete { self.pumpUp(); return }
            upstream.send(content: payload.isEmpty ? nil : payload, isComplete: complete, completion: .contentProcessed { [weak self] sendError in
                guard let self, !self.closed else { return }
                if sendError != nil { self.close(); return }
                if complete { self.clientDone = true; self.closeIfDone() } else { self.pumpUp() }
            })
        }
    }

    private func pumpDown() {
        guard let upstream, !closed else { return }
        upstream.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            self.lastActivity = Date()
            if error != nil { self.close(); return }
            let payload = data ?? Data()
            if payload.isEmpty && !complete { self.pumpDown(); return }
            self.client.send(content: payload.isEmpty ? nil : payload, isComplete: complete, completion: .contentProcessed { [weak self] sendError in
                guard let self, !self.closed else { return }
                if sendError != nil { self.close(); return }
                if complete { self.upstreamDone = true; self.closeIfDone() } else { self.pumpDown() }
            })
        }
    }

    private func closeIfDone() {
        if clientDone && upstreamDone { close() }
    }
}
#endif
