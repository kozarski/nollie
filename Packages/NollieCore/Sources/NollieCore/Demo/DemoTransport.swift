import Foundation

/// Finds the demo gateway a request is for. Each demo has its own made-up host, so a request
/// that reaches the URL protocol is matched by name and never goes anywhere else.
enum DemoGateways {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: DemoGateway] = [:]

    static func register(_ gateway: DemoGateway) {
        lock.withLock { known[gateway.host] = gateway }
    }

    static func unregister(_ host: String) {
        lock.withLock { known[host] = nil }
    }

    static func gateway(for host: String?) -> DemoGateway? {
        guard let host else { return nil }
        return lock.withLock { known[host] }
    }

    /// A URL session whose every request is answered by `DemoURLProtocol`.
    static func session() -> URLSession {
        let config = HermesAPI.sessionConfiguration()
        config.protocolClasses = [DemoURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// Answers REST calls for the demo gateway, from memory. A request for any other host gets a
/// failure, not a connection.
final class DemoURLProtocol: URLProtocol, @unchecked Sendable {
    private var work: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let gateway = DemoGateways.gateway(for: url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        var target = url.path
        if let query = url.query { target += "?" + query }
        // The loading system calls back on any thread, which is what it expects of a protocol.
        nonisolated(unsafe) let me = self
        work = Task {
            let (status, data) = await gateway.rest(method, target, body: body)
            guard !Task.isCancelled else { return }
            let reply = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])
            if let reply { me.client?.urlProtocol(me, didReceive: reply, cacheStoragePolicy: .notAllowed) }
            me.client?.urlProtocol(me, didLoad: data)
            me.client?.urlProtocolDidFinishLoading(me)
        }
    }

    override func stopLoading() {
        work?.cancel()
    }

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Opens sockets to the demo gateway. Nothing is sent over the network: each channel is a pair
/// of queues, with the gateway on the other end.
public struct DemoTransport: GatewayTransport {
    let gateway: DemoGateway

    public func open(_ endpoint: GatewayEndpoint) async throws -> any GatewayChannel {
        guard endpoint.url.host == gateway.host else { throw GatewayTransportError.unreachable("not the demo") }
        let channel = DemoChannel()
        await gateway.attach(channel)
        let gateway = gateway
        // Messages from the app are handled one at a time, in the order they were sent.
        Task { [weak channel] in
            guard let channel else { return }
            for await text in channel.inbound {
                await gateway.receive(text, from: channel)
            }
            await gateway.detach(channel)
        }
        return channel
    }
}

/// One socket to the demo gateway.
final class DemoChannel: GatewayChannel, @unchecked Sendable {
    let incoming: AsyncStream<GatewayChannelEvent>
    let inbound: AsyncStream<String>
    private let feed: AsyncStream<GatewayChannelEvent>.Continuation
    private let toGateway: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var ended = false

    init() {
        (incoming, feed) = AsyncStream.makeStream(of: GatewayChannelEvent.self)
        (inbound, toGateway) = AsyncStream.makeStream(of: String.self)
    }

    func send(_ text: String) {
        toGateway.yield(text)
    }

    /// A message from the gateway to the app.
    func push(_ text: String) {
        feed.yield(.text(text))
    }

    func close(code: Int) {
        let first = lock.withLock { () -> Bool in
            defer { ended = true }
            return !ended
        }
        guard first else { return }
        feed.yield(.closed(code: code, reason: nil))
        feed.finish()
        toGateway.finish()
    }
}
