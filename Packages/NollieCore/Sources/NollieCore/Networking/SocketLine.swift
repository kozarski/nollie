import Foundation

/// One open line to a gateway, as `GatewaySocket` uses it: text out, text in, and a close. The
/// network's line is a `URLSessionWebSocketTask`. The in-process demo gateway supplies another
/// through `GatewayTransport`, so everything above the line runs the same way for both.
protocol SocketLine: AnyObject, Sendable {
    func send(_ text: String) async throws
    /// The next message. Throws when the line has closed.
    func receive() async throws -> String
    /// Lets go of the line from this side.
    func close()
    /// What the other side said on closing, once `receive` has thrown.
    var closing: (code: Int, reason: String) { get }
}

/// The network's line: a WebSocket on its own session, so closing it also ends the session.
final class URLSessionLine: SocketLine, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(url: URL, headers: [String: String]) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config, delegate: GatewayTrust.shared, delegateQueue: nil)

        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let bytes): return String(decoding: bytes, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    var closing: (code: Int, reason: String) {
        (task.closeCode.rawValue, task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }
}

/// A line made from a `GatewayChannel`: what a `GatewayTransport` hands back.
final class ChannelLine: SocketLine, @unchecked Sendable {
    private let channel: any GatewayChannel
    private let lock = NSLock()
    private var messages: AsyncStream<GatewayChannelEvent>.Iterator
    private var ended: (code: Int, reason: String) = (0, "")

    init(_ channel: any GatewayChannel) {
        self.channel = channel
        messages = channel.incoming.makeAsyncIterator()
    }

    func send(_ text: String) async throws {
        channel.send(text)
    }

    func receive() async throws -> String {
        switch await messages.next() {
        case .text(let text)?:
            return text
        case .closed(let code, let reason)?:
            lock.withLock { ended = (code ?? 0, reason ?? "") }
            throw SocketError.closed(code: code ?? 0, reason: reason ?? "")
        case nil:
            throw SocketError.notConnected
        }
    }

    func close() {
        channel.close(code: 1001)
    }

    var closing: (code: Int, reason: String) { lock.withLock { ended } }
}
