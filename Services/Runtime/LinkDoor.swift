#if os(macOS)
import Foundation
import Network
import Security

/// The only way a phone reaches this Mac's assistant. A TLS 1.3 listener inside Nollie Runtime
/// that accepts private-network sources only, checks a device credential on every request,
/// swaps it for the loopback session token and passes allowed routes to the local Hermes API.
/// Hermes itself stays bound to 127.0.0.1.
/// One "Stop Nollie on my Mac" from a linked phone.
struct LinkDoorStop: Equatable, Sendable {
    /// Counts up with each Stop, so the app acts once per press.
    let generation: Int
    let device: String
    let at: Date
}

final class LinkDoor: @unchecked Sendable {
    struct Configuration: Sendable {
        /// The Mac's name, shown on the phone and used for Bonjour.
        var name: String
        /// nil: the saved port, or one chosen once and saved. 0: any free port (tests).
        var port: UInt16?
        /// Listen on 127.0.0.1 only (tests).
        var loopbackOnly = false
        /// Accept loopback sources (tests); never in the helper.
        var acceptLoopback = false
        var advertise = true
        /// One deadline for everything before a credential is accepted, claim body included.
        var unauthenticatedTimeout: TimeInterval = 10
        /// All connections; at most `maximumUnauthenticated` of them may be still unproven,
        /// so strangers can't crowd out linked phones, and at most `perSourceUnauthenticated`
        /// from any one address.
        var maximumSessions = 64
        var maximumUnauthenticated = 16
        var perSourceUnauthenticated = 4
        /// Opens a helper's live picture for `/nollie/live`; nil answers every stream "unavailable".
        var liveProvider: LiveProvider?
    }

    struct Upstream: Sendable, Equatable {
        let port: Int
        let token: String
    }
    typealias UpstreamProvider = @Sendable () async -> Upstream?

    static let serviceType = "_nollie._tcp"
    static let portRange: ClosedRange<UInt16> = 50_000...59_999

    let devices: LinkDoorDevices
    let identity: LinkDoorIdentity
    let configuration: Configuration
    private let upstream: UpstreamProvider
    private let queue = DispatchQueue(label: "com.coreykozarski.nollie.link.door")
    private var listener: NWListener?
    private var listeningPort: UInt16?
    /// Bumped by every stop: a listener that becomes ready for an older generation is cancelled.
    private var generation = 0
    private var pending: NWListener?
    private var starting: (generation: Int, task: Task<UInt16, Error>)?
    private var sessions: [ObjectIdentifier: LinkDoorSession] = [:]
    private var refusedSources = 0
    private var refusedBusy = 0
    /// Listeners that reached ready and have not been cancelled since: one at most.
    private var readyListeners = Set<ObjectIdentifier>()
    private var handshakes = 0

    init(configuration: Configuration, identity: LinkDoorIdentity, devices: LinkDoorDevices, upstream: @escaping UpstreamProvider) {
        self.configuration = configuration
        self.identity = identity
        self.devices = devices
        self.upstream = upstream
    }

    var port: UInt16? { queue.sync { listeningPort } }
    var isListening: Bool { queue.sync { listener != nil } }
    /// Sources turned away before any handshake, and connections whose handshake finished.
    var counts: (refusedSources: Int, handshakes: Int) { queue.sync { (refusedSources, handshakes) } }
    /// Connections turned away because too many unproven ones were open.
    var refusedBusyCount: Int { queue.sync { refusedBusy } }
    var readyListenerCount: Int { queue.sync { readyListeners.count } }
    var unauthenticatedSessions: Int { queue.sync { sessions.values.filter { !$0.authenticated }.count } }
    func liveSessions(for device: UUID) -> Int { queue.sync { sessions.values.filter { $0.deviceID == device }.count } }
    func liveStreams(for device: UUID) -> Int { queue.sync { sessions.values.filter { $0.deviceID == device && $0.isLive }.count } }

    // MARK: Listening

    /// Listens while a device is linked or an offer is open, and not otherwise.
    func refresh() async throws {
        if devices.hasDevices || devices.hasOpenOffer {
            _ = try await start()
        } else {
            stop()
        }
    }

    /// Starts listening once; callers that arrive while it starts share the same attempt.
    @discardableResult
    func start() async throws -> UInt16 {
        let (ready, attempt): (UInt16?, Task<UInt16, Error>?) = queue.sync {
            if listener != nil, let port = listeningPort { return (port, nil) }
            if let starting, starting.generation == generation { return (nil, starting.task) }
            let current = generation
            let task = Task { try await self.open(generation: current) }
            starting = (current, task)
            return (nil, task)
        }
        if let ready { return ready }
        return try await attempt!.value
    }

    private func open(generation: Int) async throws -> UInt16 {
        defer { queue.sync { if starting?.generation == generation { starting = nil } } }
        if let fixed = configuration.port { return try await listen(on: fixed, generation: generation) }
        if let saved = devices.port, let port = UInt16(exactly: saved) { return try await listen(on: port, generation: generation) }
        var lastError: Error = NWError.posix(.EADDRINUSE)
        for _ in 0..<8 {
            let candidate = UInt16.random(in: Self.portRange)
            do {
                let port = try await listen(on: candidate, generation: generation)
                try devices.savePort(Int(port))
                return port
            } catch {
                lastError = error
                if case NWError.posix(.ECANCELED) = error { throw error }
            }
        }
        throw lastError
    }

    /// Stops listening and closes every connection, including a listener still starting.
    func stop() {
        queue.sync {
            generation += 1
            starting = nil
            pending.map(retire)
            pending = nil
            listener.map(retire)
            listener = nil
            listeningPort = nil
            for session in sessions.values { session.close(force: true) }
            sessions = [:]
        }
    }

    /// Cancels a listener and stops counting it as up, at once (on the door's queue).
    private func retire(_ listener: NWListener) {
        readyListeners.remove(ObjectIdentifier(listener))
        listener.cancel()
    }

    private func parameters(port: UInt16) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(security, sec_identity_create(identity.identity)!)
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // Never share the port with another listener.
        parameters.allowLocalEndpointReuse = false
        parameters.includePeerToPeer = false
        if configuration.loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        }
        return parameters
    }

    private func listen(on port: UInt16, generation expected: Int) async throws -> UInt16 {
        let parameters = parameters(port: port)
        let made: NWListener
        if configuration.loopbackOnly {
            made = try NWListener(using: parameters)
        } else {
            guard let value = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
            made = try NWListener(using: parameters, on: value)
        }
        if configuration.advertise && !configuration.loopbackOnly {
            made.service = NWListener.Service(name: configuration.name, type: Self.serviceType, domain: nil,
                                              txtRecord: NWTXTRecord(["tag": devices.installTag, "v": "1"]))
        }
        made.newConnectionHandler = { [weak self, weak made] connection in
            guard let self, let made, self.listener === made else { connection.forceCancel(); return }
            self.accept(connection)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = LinkDoorOnce(continuation)
            queue.async { [self] in
                guard generation == expected else {
                    once.resume(.failure(NWError.posix(.ECANCELED)))
                    return
                }
                pending = made
                // Holds the listener until it is cancelled, when the handlers are let go.
                made.stateUpdateHandler = { [weak self] state in
                    guard let self else { made.stateUpdateHandler = nil; return }
                    switch state {
                    case .ready:
                        self.readyListeners.insert(ObjectIdentifier(made))
                        if self.pending === made { self.pending = nil }
                        // Stopped, or another start won, while this one was coming up.
                        guard self.generation == expected, self.listener == nil else {
                            self.retire(made)
                            once.resume(.failure(NWError.posix(.ECANCELED)))
                            return
                        }
                        let bound = made.port?.rawValue ?? port
                        self.listener = made
                        self.listeningPort = bound
                        once.resume(.success(bound))
                    case .failed(let error):
                        self.retire(made)
                        if self.pending === made { self.pending = nil }
                        if self.listener === made { self.listener = nil; self.listeningPort = nil }
                        once.resume(.failure(error))
                    case .cancelled:
                        self.readyListeners.remove(ObjectIdentifier(made))
                        made.stateUpdateHandler = nil
                        made.newConnectionHandler = nil
                        if self.pending === made { self.pending = nil }
                        if self.listener === made { self.listener = nil; self.listeningPort = nil }
                        once.resume(.failure(NWError.posix(.ECANCELED)))
                    default: break
                    }
                }
                made.start(queue: queue)
            }
        }
    }

    // MARK: Devices

    /// Unlinks a device and closes everything it has open, at once.
    @discardableResult
    func remove(_ device: UUID) throws -> Bool {
        let removed = try devices.remove(device)
        cut(device)
        return removed
    }

    func cut(_ device: UUID) {
        queue.sync {
            for (key, session) in sessions where session.deviceID == device {
                session.close(force: true)
                sessions[key] = nil
            }
        }
    }

    // MARK: Connections (on the door's queue)

    private func accept(_ connection: NWConnection) {
        guard LinkDoorPolicy.allowsSource(connection.endpoint, allowLoopback: configuration.acceptLoopback) else {
            refusedSources += 1
            connection.forceCancel()
            return
        }
        // Away from home off: Tailscale's addresses are turned away like the internet's.
        let tailnet = LinkDoorPolicy.isTailnetSource(connection.endpoint)
        guard !tailnet || devices.away else {
            refusedSources += 1
            connection.forceCancel()
            return
        }
        let source = Self.sourceKey(connection.endpoint)
        let unproven = sessions.values.filter { !$0.authenticated }
        guard sessions.count < configuration.maximumSessions,
              unproven.count < configuration.maximumUnauthenticated,
              unproven.filter({ $0.source == source }).count < configuration.perSourceUnauthenticated else {
            refusedBusy += 1
            connection.forceCancel()
            return
        }
        let session = LinkDoorSession(client: connection, source: source, door: self, queue: queue)
        session.tailnet = tailnet
        let key = ObjectIdentifier(session)
        sessions[key] = session
        connection.stateUpdateHandler = { [weak self, weak session] state in
            guard let self, let session else { return }
            switch state {
            case .ready:
                self.handshakes += 1
                session.readHead()
            case .failed, .cancelled:
                session.close(force: true)
                self.sessions[key] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        // Handshake, head and any claim body share one deadline.
        queue.asyncAfter(deadline: .now() + configuration.unauthenticatedTimeout) { [weak session] in
            guard let session, !session.authenticated else { return }
            session.close(force: true)
        }
    }

    private static func sourceKey(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "?" }
        switch host {
        case .ipv4(let address): return Data(address.rawValue).base64EncodedString()
        case .ipv6(let address): return Data(address.rawValue).base64EncodedString()
        default: return "\(host)"
        }
    }

    fileprivate func finished(_ session: LinkDoorSession) { sessions[ObjectIdentifier(session)] = nil }

    /// One live stream per device: a newer one closes any other still open.
    fileprivate func replaceLive(for device: UUID, with session: LinkDoorSession) {
        for (key, other) in sessions where other !== session && other.deviceID == device && other.isLive {
            other.close(force: true)
            sessions[key] = nil
        }
    }

    fileprivate func provideUpstream(_ done: @escaping @Sendable (Upstream?) -> Void) {
        let upstream = self.upstream
        Task { done(await upstream()) }
    }

    /// The latest Stop from a linked phone. The signed app reads it from the helper's link status
    /// and ends whatever runs on the Mac; the door itself only records it.
    private let stopLock = NSLock()
    private var lastStopValue: LinkDoorStop?
    var lastStop: LinkDoorStop? { stopLock.withLock { lastStopValue } }

    func requestStop(from device: UUID, now: Date = Date()) -> Data {
        let name = devices.devices.first { $0.id == device }?.name ?? "your iPhone"
        stopLock.withLock {
            lastStopValue = LinkDoorStop(generation: (lastStopValue?.generation ?? 0) + 1, device: name, at: now)
        }
        let body = Data(#"{"stopped":true}"#.utf8)
        var head = LinkDoorHTTP.serializeResponse(status: 200, reason: "OK", headers: [
            .init(name: "Content-Type", value: "application/json"),
            .init(name: "Content-Length", value: String(body.count)),
            .init(name: "Cache-Control", value: "no-store"),
            .init(name: "Connection", value: "close"),
        ])
        head.append(body)
        return head
    }

    // MARK: Away from home

    /// This Mac's hosts for a linked phone and Tailscale's state ("ready", "stopped", "missing").
    /// Set once by the helper before the door listens.
    var hostsProvider: @Sendable () async -> (hosts: [String], tailscale: String) {
        get { awayLock.withLock { provider } }
        set { awayLock.withLock { provider = newValue } }
    }
    private let awayLock = NSLock()
    private var provider: @Sendable () async -> (hosts: [String], tailscale: String) = { ([], "missing") }

    /// Answers `/nollie/link/hosts` and `/nollie/link/away/on|off` for a linked phone. Turning
    /// away from home off also closes every connection that came in through Tailscale.
    fileprivate func answerAway(_ route: LinkDoorPolicy.Route, _ done: @escaping @Sendable (Data) -> Void) {
        if route != .hosts {
            do { try devices.setAway(route == .awayOn) } catch {
                done(LinkDoorHTTP.reply(503, "Your Mac couldn't save that. Try again.")); return
            }
            if route == .awayOff { cutTailnet() }
        }
        let provider = hostsProvider
        let devices = devices
        Task {
            let found = await provider()
            let away = devices.away
            let tailnet = Set(found.hosts.filter { LinkDoorPolicy.isTailnetHost($0) })
            let hosts = away ? found.hosts : found.hosts.filter { !tailnet.contains($0) }
            let object: [String: Any] = ["hosts": hosts, "away": away, "tailscale": found.tailscale]
            let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            var head = LinkDoorHTTP.serializeResponse(status: 200, reason: "OK", headers: [
                .init(name: "Content-Type", value: "application/json"),
                .init(name: "Content-Length", value: String(body.count)),
                .init(name: "Cache-Control", value: "no-store"),
                .init(name: "Connection", value: "close"),
            ])
            head.append(body)
            done(head)
        }
    }

    /// Closes every connection from a Tailscale address, at once, apart from a reply still going out.
    func cutTailnet() {
        queue.async { [self] in
            for (key, session) in sessions where session.tailnet && !session.answeringAway {
                session.close(force: true)
                sessions[key] = nil
            }
        }
    }

    fileprivate func claim(_ body: Data) -> Data {
        struct Claim: Decodable { let secret: String; let name: String }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(object.keys) == ["secret", "name"],
              let claim = try? JSONDecoder().decode(Claim.self, from: body),
              let secret = LinkDoorBase64URL.decode(claim.secret) else {
            return LinkDoorHTTP.reply(400, "That pairing code could not be read.")
        }
        do {
            let (device, credential) = try devices.claim(secret: secret, name: claim.name)
            let reply: [String: String] = ["credential": credential, "device": device.id.uuidString.lowercased(), "mac": configuration.name]
            let body = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
            var head = LinkDoorHTTP.serializeResponse(status: 200, reason: "OK", headers: [
                .init(name: "Content-Type", value: "application/json"),
                .init(name: "Content-Length", value: String(body.count)),
                .init(name: "Cache-Control", value: "no-store"),
                .init(name: "Connection", value: "close"),
            ])
            head.append(body)
            return head
        } catch {
            switch error {
            case .noOffer, .expired: return LinkDoorHTTP.reply(410, "This code has expired. Show a new one on your Mac.")
            case .mismatch: return LinkDoorHTTP.reply(403, "That code is not the one on your Mac.")
            case .invalidName: return LinkDoorHTTP.reply(400, "That device name can't be used.")
            case .full: return LinkDoorHTTP.reply(403, "Too many devices are linked. Remove one on your Mac.")
            case .unsaved: return LinkDoorHTTP.reply(503, "Your Mac couldn't save the link. Try again.")
            }
        }
    }
}

/// Resumes a continuation the first time only; listener states keep arriving afterwards.
private final class LinkDoorOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    @discardableResult
    func resume(_ result: Result<UInt16, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}

enum LinkDoorBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ text: String) -> Data? {
        guard text.utf8.count <= 4096, text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// One phone connection: a request head, then either the door's own reply or a pump to
/// Hermes for exactly one request (or one socket). All work happens on the door's queue.
private final class LinkDoorSession: @unchecked Sendable {
    let client: NWConnection
    let source: String
    private weak var door: LinkDoor?
    private let queue: DispatchQueue
    private var upstream: NWConnection?
    private var buffer = Data()
    /// Set once a device credential has been accepted; until then the door's deadline runs.
    private(set) var authenticated = false
    private(set) var deviceID: UUID?
    /// Came in through Tailscale; closed when away from home is turned off.
    var tailnet = false
    /// Sending the answer to an away request: the switch-off leaves it to finish.
    private(set) var answeringAway = false
    private var closed = false
    private var socketKind: LinkDoorPolicy.SocketKind?
    private var reader = LinkDoorWebSocket.ClientReader(maximumMessage: 32 * 1024 * 1024)
    private var tracker = LinkDoorWebSocket.ServerTracker()
    private var injections: [Data] = []
    /// Set when this connection became a live stream the door serves itself.
    private var live: LinkDoorLiveSession?
    var isLive: Bool { live != nil }
    private static let chunk = 64 * 1024
    private static let claimBodyLimit = 4096

    init(client: NWConnection, source: String, door: LinkDoor, queue: DispatchQueue) {
        self.client = client
        self.source = source
        self.door = door
        self.queue = queue
    }

    func close(force: Bool) {
        guard !closed else { return }
        closed = true
        live?.stop()
        upstream?.forceCancel()
        upstream = nil
        if force { client.forceCancel() } else { client.cancel() }
        door?.finished(self)
    }

    private func respond(_ data: Data) {
        guard !closed else { return }
        client.send(content: data, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close(force: false)
        })
    }

    // MARK: Head

    func readHead() {
        guard !closed else { return }
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, complete, receiveError in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            do throws(LinkDoorHTTP.Failure) {
                let request = try LinkDoorHTTP.parseRequest(self.buffer)
                self.handle(request)
            } catch .incomplete {
                if receiveError != nil || complete { self.close(force: true) } else { self.readHead() }
            } catch {
                self.respond(LinkDoorHTTP.reply(error.status, "The request was refused."))
            }
        }
    }

    private func handle(_ request: LinkDoorHTTP.Request) {
        guard let door else { close(force: true); return }
        let extra = buffer.dropFirst(request.headLength)
        buffer = Data()
        // One request per connection: anything past the body is pipelining, refused.
        guard extra.count <= request.contentLength else {
            respond(LinkDoorHTTP.reply(400, "One request at a time, please."))
            return
        }
        let route = LinkDoorPolicy.route(method: request.method, path: request.path, websocket: request.isWebSocketUpgrade)
        if route == .claim {
            guard request.contentLength > 0, request.contentLength <= Self.claimBodyLimit else {
                respond(LinkDoorHTTP.reply(413, "The request was refused."))
                return
            }
            readBody(Data(extra), until: request.contentLength) { [weak self] body in
                guard let self, let door = self.door else { return }
                self.respond(door.claim(body))
            }
            return
        }
        guard let credential = LinkDoorPolicy.presentedCredential(request), let device = door.devices.authenticate(credential) else {
            respond(LinkDoorHTTP.reply(401, "This device isn't linked to this Mac."))
            return
        }
        authenticated = true
        deviceID = device
        door.devices.touch(device)
        if route == .stop {
            guard request.contentLength == 0, extra.isEmpty else {
                respond(LinkDoorHTTP.reply(413, "The request was refused."))
                return
            }
            respond(door.requestStop(from: device))
            return
        }
        if route == .live {
            startLive(request, device: device)
            return
        }
        if route == .hosts || route == .awayOn || route == .awayOff {
            guard request.contentLength == 0, extra.isEmpty else {
                respond(LinkDoorHTTP.reply(413, "The request was refused."))
                return
            }
            answeringAway = true
            let queue = self.queue
            door.answerAway(route) { [weak self] reply in
                queue.async { [weak self] in self?.respond(reply) }
            }
            return
        }
        guard route == .hermes else {
            respond(LinkDoorHTTP.reply(403, "This can only be changed on your Mac."))
            return
        }
        guard LinkDoorPolicy.allowsQuery(path: request.path, query: request.query) else {
            respond(LinkDoorHTTP.reply(403, "This can only be changed on your Mac."))
            return
        }
        if request.isWebSocketUpgrade { socketKind = LinkDoorPolicy.socketKind(request.path) }
        door.provideUpstream { [weak self] upstream in
            guard let self else { return }
            self.queue.async {
                guard !self.closed, let door = self.door, door.devices.contains(device) else { self.close(force: true); return }
                guard let upstream, (1024...65535).contains(upstream.port) else {
                    self.respond(LinkDoorHTTP.reply(503, "Your assistant is starting on your Mac. Try again in a moment."))
                    return
                }
                self.forward(request, body: Data(extra), to: upstream)
            }
        }
    }

    private func startLive(_ request: LinkDoorHTTP.Request, device: UUID) {
        guard let door else { close(force: true); return }
        switch LinkDoorLive.upgrade(request, device: device) {
        case .refuse(let reply):
            respond(reply)
        case .accept(let head, let wanted):
            door.replaceLive(for: device, with: self)
            let stream = LinkDoorLiveSession(client: client, queue: queue, request: wanted, provider: door.configuration.liveProvider) { [weak self] in
                self?.close(force: false)
            }
            live = stream
            stream.start(head)
        }
    }

    private func readBody(_ start: Data, until length: Int, then: @escaping @Sendable (Data) -> Void) {
        if start.count == length { then(start); return }
        client.receive(minimumIncompleteLength: 1, maximumLength: min(Self.chunk, length - start.count)) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, !data.isEmpty else { self.close(force: true); return }
            let next = start + data
            if next.count > length { self.respond(LinkDoorHTTP.reply(400, "The request was refused.")); return }
            if complete && next.count < length { self.close(force: true); return }
            self.readBody(next, until: length, then: then)
        }
    }

    // MARK: Forwarding

    private func forward(_ request: LinkDoorHTTP.Request, body: Data, to target: LinkDoor.Upstream) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(target.port)) else { close(force: true); return }
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        upstream = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                var head = LinkDoorPolicy.upstreamHead(request, port: target.port, token: target.token)
                head.append(body)
                connection.send(content: head, completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil else { self?.close(force: true); return }
                    let remaining = request.contentLength - body.count
                    if !request.isWebSocketUpgrade { self.pumpBody(remaining: remaining) }
                    self.readResponseHead(Data(), websocket: request.isWebSocketUpgrade)
                })
            case .failed, .waiting:
                if self.upstream === connection {
                    self.upstream = nil
                    connection.forceCancel()
                    self.respond(LinkDoorHTTP.reply(502, "Your assistant on this Mac didn't answer."))
                }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// Whatever is left of the request body, passed through byte for byte. After that the client is
    /// only watched for a close; any extra data counts as a second request and ends the connection.
    private func pumpBody(remaining: Int) {
        client.receive(minimumIncompleteLength: 1, maximumLength: remaining > 0 ? min(Self.chunk, remaining) : 1) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if remaining == 0 {
                if data?.isEmpty == false || error != nil || complete { self.close(force: true) }
                return
            }
            guard error == nil, let data, !data.isEmpty, data.count <= remaining else { self.close(force: true); return }
            self.upstream?.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { self?.close(force: true); return }
                self.pumpBody(remaining: remaining - data.count)
            })
        }
    }

    private func readResponseHead(_ start: Data, websocket: Bool) {
        guard let upstream else { return }
        upstream.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, complete, receiveError in
            guard let self, !self.closed else { return }
            var received = start
            if let data { received.append(data) }
            do throws(LinkDoorHTTP.Failure) {
                let response = try LinkDoorHTTP.parseResponse(received)
                let upgraded = websocket && response.status == 101
                // The phone's frames are read in the clear: no compression may be agreed.
                if upgraded, response.headers.contains(where: { $0.key == "sec-websocket-extensions" }) {
                    self.respond(LinkDoorHTTP.reply(502, "Your assistant on this Mac didn't answer."))
                    return
                }
                let rest = Data(received.dropFirst(response.headLength))
                var head = LinkDoorPolicy.downstreamHead(response)
                head.append(rest)
                if upgraded { self.tracker.consume(rest) }
                self.client.send(content: head, completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil else { self?.close(force: true); return }
                    if upgraded {
                        self.pumpSocketDown()
                        self.pumpSocketUp()
                    } else {
                        self.pumpResponse()
                    }
                })
            } catch .incomplete {
                if receiveError != nil || complete { self.respond(LinkDoorHTTP.reply(502, "Your assistant on this Mac didn't answer.")) }
                else { self.readResponseHead(received, websocket: websocket) }
            } catch {
                self.respond(LinkDoorHTTP.reply(502, "Your assistant on this Mac didn't answer."))
            }
        }
    }

    /// Hermes to phone, until Hermes closes.
    private func pumpResponse() {
        guard let upstream else { return }
        upstream.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            let finish = complete || error != nil
            guard let data, !data.isEmpty else {
                if finish { self.close(force: false) } else { self.pumpResponse() }
                return
            }
            self.client.send(content: data, completion: .contentProcessed { [weak self] sendError in
                guard let self, sendError == nil else { self?.close(force: true); return }
                if finish { self.close(force: false) } else { self.pumpResponse() }
            })
        }
    }

    // MARK: Sockets

    /// Hermes to phone: bytes pass as they come; the door only notes where frames end, so its
    /// own replies never land inside one of Hermes's messages.
    private func pumpSocketDown() {
        guard let upstream else { return }
        upstream.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            let finish = complete || error != nil
            guard let data, !data.isEmpty else {
                if finish { self.close(force: false) } else { self.pumpSocketDown() }
                return
            }
            self.tracker.consume(data)
            self.client.send(content: data, completion: .contentProcessed { [weak self] sendError in
                guard let self, sendError == nil else { self?.close(force: true); return }
                if finish { self.close(force: false) } else { self.pumpSocketDown() }
            })
            self.flushInjections()
        }
    }

    /// A frame of the door's own for the phone, sent as soon as Hermes is between messages.
    private func inject(_ frame: Data) {
        injections.append(frame)
        flushInjections()
    }

    private func flushInjections() {
        guard tracker.atBoundary, !tracker.closed, !injections.isEmpty else { return }
        let frames = injections
        injections = []
        for frame in frames { client.send(content: frame, completion: .contentProcessed { _ in }) }
    }

    /// Phone to Hermes: every frame read, unmasked and checked. On `/api/ws` each message must be
    /// a JSON-RPC call the app makes, or an answer to Hermes's own request; anything else gets
    /// the door's error reply and goes no further.
    private func pumpSocketUp() {
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            let messages: [LinkDoorWebSocket.Message]
            do throws(LinkDoorWebSocket.Failure) {
                messages = try self.reader.feed(data ?? Data())
            } catch {
                self.endSocket(error.closeCode)
                return
            }
            var outgoing = Data()
            for message in messages {
                switch message {
                case .text(let text):
                    switch self.socketKind {
                    case .rpc?:
                        switch LinkDoorRPC.decide(text) {
                        case .forward: outgoing.append(LinkDoorWebSocket.message(.text(text), masked: true))
                        case .refuse(let reply): self.inject(LinkDoorWebSocket.message(.text(reply), masked: false))
                        }
                    default:
                        self.endSocket(1008); return
                    }
                case .binary:
                    self.endSocket(1003); return
                case .ping, .pong, .close:
                    // After a close, the phone is still read until it goes, so its leaving is noticed.
                    outgoing.append(LinkDoorWebSocket.message(message, masked: true))
                }
            }
            let finish = complete || error != nil
            let next: @Sendable () -> Void = { [weak self] in
                guard let self, !self.closed else { return }
                if finish { self.close(force: false) } else { self.pumpSocketUp() }
            }
            guard !outgoing.isEmpty, let upstream = self.upstream else { next(); return }
            upstream.send(content: outgoing, completion: .contentProcessed { [weak self] sendError in
                guard sendError == nil else { self?.close(force: true); return }
                next()
            })
        }
    }

    /// Ends a socket the phone broke: a close frame when one fits between Hermes's messages.
    private func endSocket(_ code: UInt16) {
        upstream?.forceCancel()
        upstream = nil
        guard tracker.atBoundary, !tracker.closed else { close(force: true); return }
        client.send(content: LinkDoorWebSocket.message(.close(LinkDoorWebSocket.closePayload(code)), masked: false),
                    completion: .contentProcessed { [weak self] _ in self?.close(force: false) })
    }
}
#endif
