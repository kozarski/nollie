import Foundation
import Network
import Security

/// What a phone keeps about the Mac it is linked to. Nothing here is secret: the device
/// credential stays in the Keychain with the connection's other secrets.
public struct LinkedMac: Codable, Hashable, Sendable {
    public var macName: String
    public var pin: Data
    public var port: Int
    public var hosts: [String]
    public var installTag: String
    public var deviceID: UUID
    /// What the Mac said last time it was reached: whether away from home is on there, and
    /// whether Tailscale is ready on it ("ready", "stopped" or "missing"). Nil until it says.
    public var away: Bool?
    public var tailscale: String?

    public init(macName: String, pin: Data, port: Int, hosts: [String], installTag: String, deviceID: UUID) {
        self.macName = macName
        self.pin = pin
        self.port = port
        self.hosts = hosts
        self.installTag = installTag
        self.deviceID = deviceID
    }

    /// The Mac's current hosts and away state, from its door after a connection. An empty list
    /// keeps the old one: a Mac always has somewhere to be found.
    public func updating(with reply: NollieLinkHostsReply) -> LinkedMac {
        var next = self
        if !reply.hosts.isEmpty { next.hosts = reply.hosts }
        next.away = reply.away
        next.tailscale = reply.tailscale
        return next
    }

    /// Away from home is on at the Mac and Tailscale is ready there.
    public var awayReady: Bool { away == true && tailscale == "ready" }

    /// `https://<host>:<port>` for this Mac's door.
    public func gateway(host: String) throws -> GatewayURL {
        let shown = host.contains(":") ? "[\(host)]" : host
        return try GatewayURL.normalize("https://\(shown):\(port)")
    }
}

public struct NollieLinkClaim: Sendable, Equatable {
    public let credential: String
    public let deviceID: UUID
    public let macName: String
}

/// The phone's side of Nollie Link: checking a Mac's key, finding it, and pairing once.
public enum NollieLinkClient {
    public static let serviceType = "_nollie._tcp"
    /// The door's own routes for a linked phone: where to find the Mac, and away from home.
    public static let hostsPath = "/nollie/link/hosts"
    public static let awayOnPath = "/nollie/link/away/on"
    public static let awayOffPath = "/nollie/link/away/off"

    // MARK: Pairing

    /// Presents the offer's secret once, to `host`, only after the connection proves it holds
    /// the pinned key. Returns this phone's new device credential.
    public static func claim(_ offer: NollieLinkOffer, host: String, deviceName: String,
                             timeout: TimeInterval = 15) async throws -> NollieLinkClaim {
        let gateway = try LinkedMac(macName: offer.macName, pin: offer.pin, port: offer.port, hosts: offer.hosts,
                                    installTag: offer.installTag, deviceID: UUID()).gateway(host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        let session = pinnedSession(pin: offer.pin, configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: gateway.api("/nollie/link/claim"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let name = NollieLinkOffer.cleanName(deviceName) ?? "iPhone"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["secret": NollieLinkOffer.base64URL(offer.secret), "name": name],
                                                      options: [.sortedKeys])
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .cancelled || error.code == .serverCertificateUntrusted
                    || error.code == .secureConnectionFailed {
            throw Task.isCancelled ? CancellationError() : NollieLinkError.identityMismatch
        }
        guard let http = response as? HTTPURLResponse, data.count <= 4096 else { throw NollieLinkError.invalidResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 410 { throw NollieLinkError.expired }
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw NollieLinkError.refused(detail ?? NollieLinkError.invalidResponse.localizedDescription)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              Set(object.keys) == ["credential", "device", "mac"],
              let credential = object["credential"], credential.utf8.count == 64,
              credential.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let device = object["device"].flatMap(UUID.init(uuidString:)),
              let mac = object["mac"].flatMap(NollieLinkOffer.cleanName) else { throw NollieLinkError.invalidResponse }
        return NollieLinkClaim(credential: credential, deviceID: device, macName: mac)
    }

    /// A session that accepts only the server holding `pin`, and follows no redirects.
    public static func pinnedSession(pin: Data, configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: NollieLinkPinnedDelegate(pin: pin), delegateQueue: nil)
    }

    // MARK: Reaching the Mac

    /// A TLS 1.3 handshake with `endpoint` that succeeds only when the server holds the
    /// pinned key. Returns the address actually reached.
    public static func probe(_ endpoint: NWEndpoint, pin: Data, timeout: TimeInterval = 3) async -> String? {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            complete(NollieLinkPin.matches(sec_trust_copy_ref(trust).takeRetainedValue(), pin: pin))
        }, DispatchQueue.global(qos: .userInitiated))
        let parameters = NWParameters(tls: tls)
        parameters.includePeerToPeer = false
        let connection = NWConnection(to: endpoint, using: parameters)
        let probe = LinkProbe(connection: connection)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                probe.start(continuation, timeout: timeout)
            }
        } onCancel: { probe.finish(nil) }
    }

    public static func probe(host: String, port: Int, pin: Data, timeout: TimeInterval = 3) async -> Bool {
        guard let value = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        return await probe(.hostPort(host: NWEndpoint.Host(host), port: value), pin: pin, timeout: timeout) != nil
    }

    /// Looks for the Mac's Bonjour service by its install tag, then proves it by its key.
    public static func discover(tag: String, pin: Data, timeout: TimeInterval = 3) async -> String? {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: NWParameters())
        let found = LinkBrowse(browser: browser, tag: tag)
        let endpoints = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[NWEndpoint], Never>) in
                found.start(continuation, timeout: timeout)
            }
        } onCancel: { found.finish() }
        for endpoint in endpoints {
            if let host = await probe(endpoint, pin: pin, timeout: timeout), !host.isEmpty { return host }
        }
        return nil
    }
}

/// Finds a linked Mac. At home: the address that worked last time, then Bonjour. When the last
/// address was a Tailscale one, or Bonjour finds nothing (away, or behind an exit node), the
/// Tailscale name and addresses go first and the rest race behind them. Every candidate must
/// prove the pinned key before it is used, on every path.
public struct NollieLinkResolver: Sendable {
    public var probe: @Sendable (_ host: String, _ port: Int, _ pin: Data) async -> Bool
    public var discover: @Sendable (_ tag: String, _ pin: Data) async -> String?

    public init(probe: @escaping @Sendable (String, Int, Data) async -> Bool = { await NollieLinkClient.probe(host: $0, port: $1, pin: $2) },
                discover: @escaping @Sendable (String, Data) async -> String? = { await NollieLinkClient.discover(tag: $0, pin: $1) }) {
        self.probe = probe
        self.discover = discover
    }

    public func resolve(_ link: LinkedMac, lastGood: String?) async -> String? {
        let tailnet = link.hosts.filter(NollieTailnet.isTailnetHost)
        let home = link.hosts.filter { !NollieTailnet.isTailnetHost($0) }
        if let lastGood, NollieTailnet.isTailnetHost(lastGood) {
            // Away last time: straight to the tailnet, and only then look for home.
            if let found = await race([lastGood] + tailnet.filter { $0 != lastGood }, link) { return found }
            if Task.isCancelled { return nil }
            if let found = await discover(link.installTag, link.pin), NollieLinkResolver.usable(found) { return found }
            if Task.isCancelled { return nil }
            return await race(home, link)
        }
        if let lastGood, await probe(lastGood, link.port, link.pin) { return lastGood }
        if Task.isCancelled { return nil }
        if let found = await discover(link.installTag, link.pin), NollieLinkResolver.usable(found) { return found }
        if Task.isCancelled { return nil }
        // No Bonjour answer: not at home, most likely. The tailnet first, then the code's addresses.
        return await race((tailnet + home).filter { $0 != lastGood }, link)
    }

    /// Tries every host at once; the earliest in the list that proves the pin wins, as soon as
    /// every host before it has failed, so a slow home address can't hold up a tailnet one.
    func race(_ hosts: [String], _ link: LinkedMac) async -> String? {
        guard !hosts.isEmpty else { return nil }
        let probe = self.probe
        return await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, host) in hosts.enumerated() {
                group.addTask { (index, await probe(host, link.port, link.pin)) }
            }
            var answers: [Int: Bool] = [:]
            for await (index, ok) in group {
                answers[index] = ok
                if let best = hosts.indices.first(where: { answers[$0] != false }), answers[best] == true {
                    group.cancelAll()
                    return hosts[best]
                }
            }
            return nil
        }
    }

    /// A Bonjour answer may be an IPv6 link-local address that a URL can't carry.
    static func usable(_ host: String) -> Bool { !host.contains("%") && !host.lowercased().hasPrefix("fe80") }
}

// MARK: Network helpers

private final class LinkProbe: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(connection: NWConnection) { self.connection = connection }

    func start(_ continuation: CheckedContinuation<String?, Never>, timeout: TimeInterval) {
        lock.lock(); self.continuation = continuation; lock.unlock()
        let queue = DispatchQueue(label: "com.coreykozarski.nollie.link.probe")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                var host: String?
                if case .hostPort(let reached, _)? = self.connection.currentPath?.remoteEndpoint {
                    switch reached {
                    case .ipv4(let address): host = "\(address)"
                    case .ipv6(let address): host = "\(address)"
                    case .name(let name, _): host = name
                    @unknown default: host = nil
                    }
                }
                self.finish(host.map { $0.split(separator: "%").first.map(String.init) ?? $0 } ?? "")
            case .failed, .cancelled, .waiting: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
    }

    func finish(_ result: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        connection.cancel()
        pending?.resume(returning: result)
    }
}

private final class LinkBrowse: @unchecked Sendable {
    private let browser: NWBrowser
    private let tag: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[NWEndpoint], Never>?
    private var found: [NWEndpoint] = []

    init(browser: NWBrowser, tag: String) { self.browser = browser; self.tag = tag }

    func start(_ continuation: CheckedContinuation<[NWEndpoint], Never>, timeout: TimeInterval) {
        lock.lock(); self.continuation = continuation; lock.unlock()
        let queue = DispatchQueue(label: "com.coreykozarski.nollie.link.browse")
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let matches = results.filter {
                if case .bonjour(let record) = $0.metadata { return record["tag"] == self.tag }
                return false
            }.map(\.endpoint)
            guard !matches.isEmpty else { return }
            self.lock.lock(); self.found = matches; self.lock.unlock()
            self.finish()
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish() }
    }

    func finish() {
        lock.lock()
        let pending = continuation
        continuation = nil
        let result = found
        lock.unlock()
        browser.cancel()
        pending?.resume(returning: result)
    }
}
