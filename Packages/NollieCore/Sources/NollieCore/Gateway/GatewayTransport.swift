import Foundation

/// Where and how to open the gateway socket: the `/api/ws` URL with any ticket or token the caller minted, extra
/// headers (for example Cloudflare Access) and WebSocket subprotocols. It carries credentials, so its
/// description never shows them.
public struct GatewayEndpoint: Sendable, CustomStringConvertible {
    public var url: URL
    public var headers: [String: String]
    public var subprotocols: [String]

    public init(url: URL, headers: [String: String] = [:], subprotocols: [String] = []) {
        self.url = url
        self.headers = headers
        self.subprotocols = subprotocols
    }

    public var description: String {
        let host = url.host() ?? "?"
        return "GatewayEndpoint(\(url.scheme ?? "?")://\(host)\(url.port.map { ":\($0)" } ?? "")\(url.path()))"
    }
}

/// What happens on an open socket, in order. `closed` is always last.
public enum GatewayChannelEvent: Hashable, Sendable {
    case text(String)
    /// The socket closed. `code` is the WebSocket close code when there was one.
    case closed(code: Int?, reason: String?)
}

/// Why a socket could not be opened.
public enum GatewayTransportError: Error, Hashable, Sendable {
    /// The server answered the upgrade with this HTTP status (401 and 403 mean the credentials or the origin
    /// were refused).
    case refused(status: Int)
    case unreachable(String)
}

/// One open socket.
public protocol GatewayChannel: AnyObject, Sendable {
    /// Every message and then the close. Finishes after `closed`.
    var incoming: AsyncStream<GatewayChannelEvent> { get }
    /// Queues one text message. Messages go out in the order they were queued; a failure shows up as `closed`.
    func send(_ text: String)
    /// Closes the socket from this side. `incoming` still ends with `closed`.
    func close(code: Int)
}

/// Opens gateway sockets.
public protocol GatewayTransport: Sendable {
    func open(_ endpoint: GatewayEndpoint) async throws -> any GatewayChannel
}
