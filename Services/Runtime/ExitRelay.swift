#if os(macOS)
import Darwin
import Foundation
import Network

/// A small HTTP and SOCKS5 relay inside Nollie Runtime for helpers' computers. It listens on the
/// Mac's address on Apple's VM network only, takes connections from VMs on that network only,
/// resolves each name on the Mac and refuses it when any address is private, loopback,
/// link-local, Tailscale, multicast or this Mac's own, then connects to the vetted address itself
/// (never the name again). Bytes pass through unread. Nothing is logged: only counts are kept,
/// in memory.
final class ExitRelay: @unchecked Sendable {
    struct Configuration: Sendable {
        var network: ExitRelayPolicy.Network
        /// 0: any free port (tests).
        var port: UInt16 = ExitRelayPolicy.port
        /// Everything before the upstream connection is made: request, name lookup, connect.
        var setupTimeout: TimeInterval = 15
        var resolveTimeout: TimeInterval = 5
        var connectTimeout: TimeInterval = 10
        /// No bytes either way for this long and the connection is closed.
        var idleTimeout: TimeInterval = 300
        var maximumConnections = 128
        var maximumPerSource = 96
        #if DEBUG
        /// Tests only, and absent from release builds: lets loopback clients in, and lets one exact
        /// loopback address and port through the destination rules, for a fake upstream.
        var testLoopbackClients = false
        var testUpstream: (address: [UInt8], port: UInt16)?
        #endif
    }

    /// What the relay has done since it started, without a single host, address or byte.
    struct Counts: Equatable, Sendable {
        var open = 0
        var served = 0
        var refusedSources = 0
        var refusedBusy = 0
        var refusedDestinations = 0
        var malformed = 0
        var upstreamFailures = 0
    }

    typealias Resolver = @Sendable (_ name: String, _ timeout: TimeInterval) async -> [[UInt8]]?
    typealias OwnAddresses = @Sendable () -> [[UInt8]]

    let configuration: Configuration
    private let resolver: Resolver
    private let ownAddresses: OwnAddresses
    private let queue = DispatchQueue(label: "com.coreykozarski.nollie.exit-relay")
    private var listener: NWListener?
    private var listeningPort: UInt16?
    private var sessions: [ObjectIdentifier: ExitRelaySession] = [:]
    private var tally = Counts()
    /// Upstream connections that failed in a row; any success clears it.
    private var failuresInARow = 0
    private var sweep: DispatchSourceTimer?

    init(configuration: Configuration, resolver: @escaping Resolver = ExitRelayResolver.resolve,
         ownAddresses: @escaping OwnAddresses = ExitRelayResolver.ownAddresses) {
        self.configuration = configuration
        self.resolver = resolver
        self.ownAddresses = ownAddresses
    }

    var port: UInt16? { queue.sync { listeningPort } }
    var isListening: Bool { queue.sync { listener != nil && listeningPort != nil } }
    var counts: Counts { queue.sync { var counts = tally; counts.open = sessions.count; return counts } }
    /// Three upstream connections failed in a row with none getting through since: the relay is up
    /// but can't reach the internet (the exit node may be offline).
    var cannotConnect: Bool { queue.sync { failuresInARow >= 3 } }

    // MARK: Listening

    /// Listens on the VM network's address. Throws when that address can't be used.
    @discardableResult
    func start() async throws -> UInt16 {
        if let port = queue.sync(execute: { listener != nil ? listeningPort : nil }) { return port }
        let parameters = NWParameters.tcp
        // Never share the port, never on another interface, never peer-to-peer.
        parameters.allowLocalEndpointReuse = false
        parameters.includePeerToPeer = false
        let bytes = configuration.network.address
        guard bytes.count == 4, let address = IPv4Address(Data(bytes)) else { throw NWError.posix(.EADDRNOTAVAIL) }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: NWEndpoint.Port(rawValue: configuration.port) ?? .any)
        let made = try NWListener(using: parameters)
        made.newConnectionHandler = { [weak self, weak made] connection in
            guard let self, let made, self.listener === made else { connection.forceCancel(); return }
            self.accept(connection)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = ExitRelayOnce(continuation)
            queue.async { [self] in
                listener = made
                made.stateUpdateHandler = { [weak self] state in
                    guard let self else { made.cancel(); return }
                    switch state {
                    case .ready:
                        guard self.listener === made else { made.cancel(); once.resume(.failure(NWError.posix(.ECANCELED))); return }
                        self.listeningPort = made.port?.rawValue ?? self.configuration.port
                        self.startSweep()
                        once.resume(.success(self.listeningPort!))
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

    /// Stops listening and closes every connection.
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
    }

    /// Closes connections that have been quiet too long, or still have no upstream after the
    /// setup deadline.
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

    // MARK: Connections (on the relay's queue)

    private func accept(_ connection: NWConnection) {
        guard allowsSource(connection.endpoint) else {
            tally.refusedSources += 1
            connection.forceCancel()
            return
        }
        let source = Self.sourceKey(connection.endpoint)
        guard sessions.count < configuration.maximumConnections,
              sessions.values.filter({ $0.source == source }).count < configuration.maximumPerSource else {
            tally.refusedBusy += 1
            connection.forceCancel()
            return
        }
        let session = ExitRelaySession(client: connection, source: source, relay: self, queue: queue)
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

    private func allowsSource(_ endpoint: NWEndpoint) -> Bool {
        #if DEBUG
        if configuration.testLoopbackClients, case .hostPort(.ipv4(let address), _) = endpoint, address == .loopback { return true }
        #endif
        return ExitRelayPolicy.allowsSource(endpoint, network: configuration.network)
    }

    private static func sourceKey(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "?" }
        return "\(host)"
    }

    fileprivate func finished(_ session: ExitRelaySession) { sessions[ObjectIdentifier(session)] = nil }
    fileprivate func countMalformed() { tally.malformed += 1 }
    fileprivate func countRefusedDestination() { tally.refusedDestinations += 1 }
    fileprivate func countUpstream(_ ok: Bool) {
        if ok { tally.served += 1; failuresInARow = 0 } else { tally.upstreamFailures += 1; failuresInARow += 1 }
    }

    /// The addresses a target may be reached at, all of them vetted, or why not.
    fileprivate func vet(_ target: ExitRelayTarget) async -> Result<[[UInt8]], ExitRelayPolicy.Refusal> {
        #if DEBUG
        if let allowed = configuration.testUpstream, target.port == allowed.port {
            var literal: [[UInt8]]?
            if case .address(let bytes) = target.host { literal = [bytes] }
            else { literal = await resolver(Self.name(target), configuration.resolveTimeout) }
            if let literal, !literal.isEmpty, literal.allSatisfy({ $0 == allowed.address }) { return .success(literal) }
        }
        #endif
        guard ExitRelayPolicy.allowsPort(target.port) else { return .failure(.port) }
        let addresses: [[UInt8]]
        switch target.host {
        case .address(let bytes): addresses = [bytes]
        case .name(let name):
            guard let found = await resolver(name, configuration.resolveTimeout) else { return .failure(.address) }
            addresses = found
        }
        if let refusal = ExitRelayPolicy.vet(addresses, own: ownAddresses(), network: configuration.network) {
            return .failure(refusal)
        }
        return .success(addresses)
    }

    private static func name(_ target: ExitRelayTarget) -> String {
        if case .name(let name) = target.host { return name }
        return ""
    }
}

/// Name lookups and this Mac's own addresses.
enum ExitRelayResolver {
    /// `getaddrinfo` on the Mac's own resolver, on a background thread, with a deadline. Nil when
    /// the name doesn't resolve in time. Every address it gives is returned, once each.
    static func resolve(_ name: String, timeout: TimeInterval) async -> [[UInt8]]? {
        let gate = ExitRelayGate<[[UInt8]]?>()
        return await withCheckedContinuation { continuation in
            gate.set(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                gate.resume(lookup(name))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.resume(nil) }
        }
    }

    private static func lookup(_ name: String) -> [[UInt8]]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }
        var result: [[UInt8]] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ai_next }
            guard let address = entry.pointee.ai_addr else { continue }
            let bytes: [UInt8]
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin_addr) { Array($0) }
                }
            case AF_INET6:
                bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                }
            default: continue
            }
            if !result.contains(bytes) { result.append(bytes) }
        }
        return result
    }

    /// Every address on this Mac's interfaces, loopback included.
    static func ownAddresses() -> [[UInt8]] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [[UInt8]] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                result.append(address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin_addr) { Array($0) }
                })
            case AF_INET6:
                result.append(address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                })
            default: continue
            }
        }
        return result
    }
}

/// Resumes a continuation once; later answers are dropped.
final class ExitRelayGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var early: Value?
    private var done = false

    func set(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if done, let early {
            lock.unlock()
            continuation.resume(returning: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Value) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let pending = continuation
        continuation = nil
        if pending == nil { early = value }
        lock.unlock()
        pending?.resume(returning: value)
    }
}

private final class ExitRelayOnce: @unchecked Sendable {
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

/// One connection from a helper's computer: a request, the relay's checks, then bytes both ways
/// until either side is done. All work happens on the relay's queue.
private final class ExitRelaySession: @unchecked Sendable {
    let client: NWConnection
    let source: String
    private weak var relay: ExitRelay?
    private let queue: DispatchQueue
    private var upstream: NWConnection?
    private var buffer = Data()
    private var closed = false
    private var connected = false
    private let opened = Date()
    private var lastActivity = Date()
    private var socksGreeted = false
    /// Each direction ends on its own; the connection closes when both have.
    private var clientDone = false
    private var upstreamDone = false
    private static let chunk = 64 * 1024

    init(client: NWConnection, source: String, relay: ExitRelay, queue: DispatchQueue) {
        self.client = client
        self.source = source
        self.relay = relay
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
        relay?.finished(self)
    }

    /// A last answer from the relay itself, then the end.
    private func answer(_ data: Data) {
        guard !closed else { return }
        client.send(content: data, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    // MARK: Request

    func readRequest() {
        guard !closed else { return }
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            self.lastActivity = Date()
            if self.buffer.first == ExitRelaySOCKS.version { self.socks(complete: complete || error != nil) }
            else if !self.buffer.isEmpty { self.http(complete: complete || error != nil) }
            else if complete || error != nil { self.close() }
            else { self.readRequest() }
        }
    }

    private func http(complete: Bool) {
        do throws(LinkDoorHTTP.Failure) {
            let request = try ExitRelayHTTP.parse(buffer)
            let early = Data(buffer.dropFirst(request.headLength))
            buffer = Data()
            open(request.target) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .refused: self.answer(ExitRelayHTTP.refusal(403))
                case .unreachable: self.answer(ExitRelayHTTP.refusal(502))
                case .connected:
                    switch request.kind {
                    case .connect:
                        self.client.send(content: ExitRelayHTTP.established, completion: .contentProcessed { [weak self] error in
                            guard let self, error == nil else { self?.close(); return }
                            self.pipe(early)
                        })
                    case .forward(let head):
                        self.pipe(head + early)
                    }
                }
            }
        } catch .incomplete {
            if complete { close() } else { readRequest() }
        } catch {
            relay?.countMalformed()
            answer(ExitRelayHTTP.refusal(error.status))
        }
    }

    private func socks(complete: Bool) {
        do throws(ExitRelaySOCKS.Failure) {
            if !socksGreeted {
                guard let greeting = try ExitRelaySOCKS.greeting(buffer) else {
                    if complete { close() } else { readRequest() }
                    return
                }
                guard greeting.noAuthentication else {
                    relay?.countMalformed()
                    answer(ExitRelaySOCKS.noAcceptableMethod)
                    return
                }
                socksGreeted = true
                buffer.removeFirst(greeting.length)
                client.send(content: ExitRelaySOCKS.chooseNoAuthentication, completion: .contentProcessed { _ in })
            }
            guard let request = try ExitRelaySOCKS.request(buffer) else {
                if complete { close() } else { readRequest() }
                return
            }
            let early = Data(buffer.dropFirst(request.length))
            buffer = Data()
            open(request.target) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .refused: self.answer(ExitRelaySOCKS.reply(.notAllowed))
                case .unreachable: self.answer(ExitRelaySOCKS.reply(.hostUnreachable))
                case .connected:
                    self.client.send(content: ExitRelaySOCKS.reply(.succeeded), completion: .contentProcessed { [weak self] error in
                        guard let self, error == nil else { self?.close(); return }
                        self.pipe(early)
                    })
                }
            }
        } catch .command {
            relay?.countMalformed()
            answer(ExitRelaySOCKS.reply(.commandNotSupported))
        } catch .addressType {
            relay?.countMalformed()
            answer(ExitRelaySOCKS.reply(.addressTypeNotSupported))
        } catch {
            relay?.countMalformed()
            answer(socksGreeted ? ExitRelaySOCKS.reply(.generalFailure) : ExitRelaySOCKS.noAcceptableMethod)
        }
    }

    // MARK: Upstream

    private enum Outcome { case connected, refused, unreachable }

    /// Vets the target, then connects to its first address that answers, by address.
    private func open(_ target: ExitRelayTarget, then: @escaping @Sendable (Outcome) -> Void) {
        guard let relay else { close(); return }
        Task { [weak self] in
            let vetted = await relay.vet(target)
            self?.queue.async { [weak self] in
                guard let self, !self.closed else { return }
                switch vetted {
                case .failure:
                    relay.countRefusedDestination()
                    then(.refused)
                case .success(let addresses):
                    self.connect(Array(addresses.prefix(4)), port: target.port, then: then)
                }
            }
        }
    }

    private func connect(_ addresses: [[UInt8]], port: UInt16, then: @escaping @Sendable (Outcome) -> Void) {
        guard let first = addresses.first, let relay else {
            self.relay?.countUpstream(false)
            then(.unreachable)
            return
        }
        let host: NWEndpoint.Host
        if first.count == 4, let v4 = IPv4Address(Data(first)) { host = .ipv4(v4) }
        else if first.count == 16, let v6 = IPv6Address(Data(first)) { host = .ipv6(v6) }
        else { connect(Array(addresses.dropFirst()), port: port, then: then); return }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(relay.configuration.connectTimeout.rounded(.up))
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.prohibitedInterfaceTypes = [.loopback]
        #if DEBUG
        if relay.configuration.testUpstream != nil { parameters.prohibitedInterfaceTypes = [] }
        #endif
        let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port) ?? .https, using: parameters)
        upstream = connection
        connection.stateUpdateHandler = { [weak self] state in
            // Once connected, the pumps see any later failure.
            guard let self, !self.closed, self.upstream === connection, !self.connected else { return }
            switch state {
            case .ready:
                self.connected = true
                self.lastActivity = Date()
                relay.countUpstream(true)
                then(.connected)
            case .failed, .waiting:
                connection.forceCancel()
                self.upstream = nil
                if addresses.count > 1 {
                    self.connect(Array(addresses.dropFirst()), port: port, then: then)
                } else {
                    relay.countUpstream(false)
                    then(.unreachable)
                }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: Both ways

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

    /// Helper's computer to the internet.
    private func pumpUp() {
        guard let upstream, !closed else { return }
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            self.lastActivity = Date()
            if error != nil { self.close(); return }
            let finish = complete
            let payload = data ?? Data()
            if payload.isEmpty && !finish { self.pumpUp(); return }
            upstream.send(content: payload.isEmpty ? nil : payload, isComplete: finish, completion: .contentProcessed { [weak self] sendError in
                guard let self, !self.closed else { return }
                if sendError != nil { self.close(); return }
                if finish { self.clientDone = true; self.closeIfDone() } else { self.pumpUp() }
            })
        }
    }

    /// The internet to the helper's computer.
    private func pumpDown() {
        guard let upstream, !closed else { return }
        upstream.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            self.lastActivity = Date()
            if error != nil { self.close(); return }
            let finish = complete
            let payload = data ?? Data()
            if payload.isEmpty && !finish { self.pumpDown(); return }
            self.client.send(content: payload.isEmpty ? nil : payload, isComplete: finish, completion: .contentProcessed { [weak self] sendError in
                guard let self, !self.closed else { return }
                if sendError != nil { self.close(); return }
                if finish { self.upstreamDone = true; self.closeIfDone() } else { self.pumpDown() }
            })
        }
    }

    private func closeIfDone() {
        if clientDone && upstreamDone { close() }
    }
}
#endif
