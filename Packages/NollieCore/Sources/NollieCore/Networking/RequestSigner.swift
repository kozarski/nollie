import Foundation

/// Works out which headers a request to the gateway carries, and how the WebSocket upgrade
/// proves who is asking.
public struct RequestSigner: Hashable, Sendable {
    public var access: CloudflareAccess
    public var authMode: AuthMode
    public var bearer: String?
    public var sessionToken: String?
    /// A linked Mac's door wants a credential on every request, public routes too.
    public var credentialOnEveryRequest = false

    public static let sessionTokenHeader = "X-Hermes-Session-Token"

    public init(authMode: AuthMode, sessionToken: String? = .none, bearer: String? = .none, access: CloudflareAccess = .init()) {
        self.authMode = authMode
        self.access = access
        self.bearer = bearer
        self.sessionToken = sessionToken
    }

    public init(authMode: AuthMode, secrets: GatewaySecrets) {
        self.init(authMode: authMode, sessionToken: secrets.sessionToken, bearer: secrets.bearer, access: secrets.access)
        if authMode == .sessionToken, secrets.linkedDevice == true { credentialOnEveryRequest = true }
    }
}

public extension RequestSigner {
    /// Everything a normal request and the WebSocket handshake carry.
    var headers: [String: String] { access.headers.merging(credential) { _, new in new } }

    /// For routes that need no sign-in: Cloudflare Access still applies, and so does a linked
    /// Mac's own credential.
    var publicHeaders: [String: String] { credentialOnEveryRequest ? headers : access.headers }

    func apply(to request: inout URLRequest, includeCredential: Bool = true) {
        let carried = includeCredential ? headers : publicHeaders
        for (name, value) in carried { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    /// The `token` query item a session-token gateway reads on the upgrade. Gateways with a
    /// sign-in gate take a one-use ticket instead.
    var websocketTokenQuery: URLQueryItem? {
        guard authMode == .sessionToken else { return nil }
        return Self.queryItem("token", sessionToken)
    }

    static func websocketURL(gateway: GatewayURL, token: String?, ticket: String?) -> URL {
        let proof = queryItem("ticket", ticket) ?? queryItem("token", token)
        return gateway.websocket("/api/ws", query: Array(proof.map { [$0] } ?? []))
    }

    private static func queryItem(_ name: String, _ value: String?) -> URLQueryItem? {
        guard let value, !value.isEmpty else { return nil }
        return URLQueryItem(name: name, value: value)
    }

    /// The one header that proves who is asking, if there is anything to prove it with.
    private var credential: [String: String] {
        let (name, secret, prefix) = authMode == .sessionToken
            ? (Self.sessionTokenHeader, sessionToken, "")
            : ("Authorization", bearer, "Bearer ")
        guard let secret, !secret.isEmpty else { return [:] }
        return [name: prefix + secret]
    }
}
