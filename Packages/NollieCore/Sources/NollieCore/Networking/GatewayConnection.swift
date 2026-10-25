import Foundation

/// How the app proves who it is to a gateway.
public enum AuthMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case sessionToken
    case password
    case oauth
}

public extension AuthMode {
    var id: String { rawValue }

    var title: String {
        let words: [AuthMode: String] = [.sessionToken: "Session token", .password: "Username & password", .oauth: "Sign in with browser"]
        return words[self] ?? rawValue
    }

    /// Everything but the session token signs in and carries a bearer token.
    var usesBearer: Bool { self != .sessionToken }
}

/// A Cloudflare Access service token. Its headers go out only when both halves are filled in.
public struct CloudflareAccess: Hashable, Codable, Sendable {
    public init(clientId: String = "", clientSecret: String = "") {
        (self.clientId, self.clientSecret) = (clientId, clientSecret)
    }

    public var clientId: String = ""
    public var clientSecret: String = ""

    public static let clientIdHeader = "CF-Access-Client-Id"
    public static let clientSecretHeader = "CF-Access-Client-Secret"
}

public extension CloudflareAccess {
    var isConfigured: Bool { [clientId, clientSecret].allSatisfy { !$0.isEmpty } }

    /// One half filled in without the other, which would send nothing.
    var isPartiallyConfigured: Bool { [clientId, clientSecret].contains { !$0.isEmpty } && !isConfigured }

    var headers: [String: String] {
        guard isConfigured else { return [:] }
        return Dictionary(uniqueKeysWithValues: [(Self.clientIdHeader, clientId), (Self.clientSecretHeader, clientSecret)])
    }
}

/// One saved gateway, without its secrets (those are `GatewaySecrets`, kept in the Keychain).
public struct GatewayConnection: Codable, Identifiable, Hashable, Sendable {
    public init(id: UUID = .init(), name: String, gateway: GatewayURL, authMode: AuthMode, authProvider: String? = nil, createdAt: Date = .now, lastProfile: String? = nil, hasAccessHeaders: Bool = false, lastVersion: String? = nil, connectionKind: String? = nil, managedInstallationID: UUID? = nil, gatewayIdentity: String? = nil, linkedMac: LinkedMac? = nil) {
        (self.id, self.name, self.createdAt) = (id, name, createdAt)
        (self.gateway, self.authMode, self.authProvider) = (gateway, authMode, authProvider)
        (self.lastProfile, self.lastVersion, self.gatewayIdentity) = (lastProfile, lastVersion, gatewayIdentity)
        (self.hasAccessHeaders, self.connectionKind) = (hasAccessHeaders, connectionKind)
        (self.managedInstallationID, self.linkedMac) = (managedInstallationID, linkedMac)
    }

    public var id: UUID = UUID()
    public var name: String
    public var createdAt: Date = Date()

    public var gateway: GatewayURL
    public var authMode: AuthMode
    public var authProvider: String?
    public var hasAccessHeaders: Bool = false

    public var lastProfile: String?
    public var lastVersion: String?
    /// Which Hermes install this is, learned after signing in.
    public var gatewayIdentity: String?
    /// One of "local", "tailscale", "cloudflare" or "other". Purely cosmetic: the form's help text and
    /// the list label use it, while the URL and headers decide how we connect.
    public var connectionKind: String?
    /// The Mac install this app manages for the person. Never worked out from a URL.
    public var managedInstallationID: UUID?
    /// A Mac reached through its Nollie Link door, at whichever address answered last with the
    /// pinned key.
    public var linkedMac: LinkedMac?
}

public extension GatewayConnection {
    /// The same linked Mac at another of its addresses. Only on the same port and door, with
    /// nothing that would make the new address a different kind of connection.
    func updatingLinkedEndpoint(_ gateway: GatewayURL) -> Self? {
        guard let link = linkedMac else { return nil }
        let sameKind = authMode == .sessionToken && !hasAccessHeaders
        let sameDoor = gateway.isTLS && gateway.port == link.port && gateway.pathPrefix.isEmpty && gateway.base.query == nil
        return sameKind && sameDoor ? moved(to: gateway) : nil
    }

    /// Takes a new local endpoint reported by the helper, for the managed connection that is
    /// active right now and nothing else.
    func updatingManagedEndpoint(_ endpoint: URL, activeConnectionID: UUID?, installationID: UUID?, enabledInstallationID: UUID?) -> Self? {
        guard activeConnectionID == id, let owned = managedInstallationID else { return nil }
        let isTheEnabledInstall = owned == installationID && owned == enabledInstallationID
        let isLocalOnly = authMode == .sessionToken && !hasAccessHeaders
            && Self.isManagedLoopbackEndpoint(gateway.base) && Self.isManagedLoopbackEndpoint(endpoint)
        guard isTheEnabledInstall, isLocalOnly, let target = try? GatewayURL.normalize(endpoint.absoluteString) else { return nil }
        return moved(to: target)
    }

    /// `http://127.0.0.1:<port>` with an unprivileged port and nothing else attached.
    static func isManagedLoopbackEndpoint(_ endpoint: URL) -> Bool {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return false }
        let rightPlace = parts.scheme == "http" && parts.host == "127.0.0.1" && (1024...65535).contains(parts.port ?? 0)
        let nothingElse = [parts.user, parts.password, parts.query, parts.fragment].allSatisfy { $0 == nil }
        return rightPlace && nothingElse && ["", "/"].contains(parts.path)
    }

    private func moved(to gateway: GatewayURL) -> Self {
        var copy = self
        copy.gateway = gateway
        return copy
    }
}

/// Private half of a saved gateway, held in the Keychain keyed by the connection id.
public struct GatewaySecrets: Codable, Hashable, Sendable {
    public init(sessionToken: String? = nil, accessToken: String? = nil, refreshToken: String? = nil, expiresAt: Double? = nil, provider: String? = nil, userId: String? = nil, access: CloudflareAccess = .init(), linkedDevice: Bool? = nil) {
        (self.sessionToken, self.linkedDevice, self.access) = (sessionToken, linkedDevice, access)
        (self.accessToken, self.refreshToken, self.expiresAt) = (accessToken, refreshToken, expiresAt)
        (self.provider, self.userId) = (provider, userId)
    }

    public var sessionToken: String?
    /// The session token is this device's own Nollie Link credential: sent with every request
    /// (the Mac's door checks each one) and never shared with another device.
    public var linkedDevice: Bool?
    public var access: CloudflareAccess = CloudflareAccess()

    public var accessToken: String?
    public var refreshToken: String?
    /// When the access token stops working, in seconds since 1970.
    public var expiresAt: Double?
    public var provider: String?
    public var userId: String?
}

public extension GatewaySecrets {
    var bearer: String? { accessToken.flatMap { $0.isEmpty ? nil : $0 } }

    /// Within a minute of running out (or already out).
    var accessTokenExpiresSoon: Bool {
        expiresAt.map { Date(timeIntervalSince1970: $0).timeIntervalSinceNow < 60 } ?? false
    }
}
