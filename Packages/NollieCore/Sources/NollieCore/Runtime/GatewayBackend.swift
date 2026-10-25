import Foundation

/// Where a runtime's answers come from. Normally that is the network. The demo swaps in a
/// gateway that lives inside the app, behind the same two doors: a URL session for the REST calls
/// and a transport for the live socket. Nothing above them knows the difference.
public struct GatewayBackend: Sendable {
    /// The session the REST client uses. Nil makes the usual one.
    public var urlSession: URLSession?
    /// Where the live socket's lines come from. Nil opens real WebSockets.
    public var transport: (any GatewayTransport)?

    public init(urlSession: URLSession? = nil, transport: (any GatewayTransport)? = nil) {
        (self.urlSession, self.transport) = (urlSession, transport)
    }

    public static let network = GatewayBackend()

    /// True when nothing goes over the network: the Board's own live socket stays off then.
    public var isInProcess: Bool { transport != nil || urlSession != nil }
}
