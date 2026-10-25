import Foundation

public enum GatewayURLError: LocalizedError, Equatable {
    case empty
    case unsupportedScheme(String)
    case missingHost
    case containsQuery
    case invalid
}

public extension GatewayURLError {
    var errorDescription: String? {
        switch self {
        case .invalid: return "That doesn't look like a web address."
        case .missingHost: return "The URL has no host."
        case .empty: return "Enter your Hermes dashboard address (the one from `hermes serve`)."
        case .containsQuery: return "Leave off everything after the question mark. The dashboard's base address is enough."
        case .unsupportedScheme(let name): return "“\(name)” isn't supported here. Start the address with https:// or http://."
        }
    }
}

/// The address of a gateway, tidied: scheme, host, optional port and path prefix, nothing
/// else and no trailing slash.
public struct GatewayURL: CustomStringConvertible, Codable, Hashable, Sendable {
    public let base: URL

    private init(base: URL) {
        self.base = base
    }

    /// Routes people paste along with the address; they are cut off again.
    private static let pastedRoutes = ["/api/ws", "/api/status", "/api/health", "/chat", "/login", "/api"]

    /// Cleans up what someone typed into a base address. Handles `https://host` (path optional),
    /// `http://host:9119`, and a bare `host:9119`; the bare form takes `defaultScheme`, which is https,
    /// or http for home and tailnet addresses that lack a certificate. `ws://` and `wss://` become http
    /// and https. If a dashboard route was pasted, it is trimmed, and `pathPrefix` gets appended once.
    public static func normalize(_ raw: String, pathPrefix: String? = nil, defaultScheme: String = "https") throws(GatewayURLError) -> GatewayURL {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { throw .empty }

        var text = typed
        if !typed.contains("://") { text = "\(defaultScheme)://\(typed)" }
        // "ws://host" has the separator too; "ws:host" reaches here as a bare address.
        guard var parts = URLComponents(string: text) else { throw .invalid }

        let given = (parts.scheme ?? "").lowercased()
        switch given {
        case "http", "https": parts.scheme = given
        case "ws": parts.scheme = "http"
        case "wss": parts.scheme = "https"
        default: throw .unsupportedScheme(given)
        }

        guard let host = parts.host, !host.isEmpty else { throw .missingHost }
        if let query = parts.query, !query.isEmpty { throw .containsQuery }
        parts.host = host.lowercased()
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil

        var path = pastedRoutes.reduce(parts.path) { $0.hasSuffix($1) ? String($0.dropLast($1.count)) : $0 }
        if let extra = prefixed(pathPrefix), !path.hasSuffix(extra) { path += extra }
        while path.hasSuffix("/") { path.removeLast() }
        parts.path = path

        guard let url = parts.url else { throw .invalid }
        return GatewayURL(base: url)
    }

    /// A path prefix with one leading slash and none trailing; nil when there is none.
    private static func prefixed(_ prefix: String?) -> String? {
        guard var p = prefix?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
        if !p.hasPrefix("/") { p.insert("/", at: p.startIndex) }
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public var description: String { base.absoluteString }
    public var pathPrefix: String { base.path }
    public var port: Int? { base.port }
    public var host: String { base.host ?? "" }
    public var isTLS: Bool { base.scheme?.lowercased() == "https" }

    /// Tailscale hosts: MagicDNS names ending in `.ts.net`, or carrier-grade NAT addresses (100.64.x.x up to 100.127.x.x).
    public var isTailscaleHost: Bool {
        guard let o = Self.octets(host) else { return host.hasSuffix(".ts.net") }
        return o[0] == 100 && o[1] >= 64 && o[1] <= 127
    }

    /// True for private-network hosts: loopback, link-local, RFC 1918, `.local`, or a bare name
    /// without dots.
    public var isPrivateHost: Bool {
        let named = host == "localhost" || host.hasSuffix(".local") || !host.contains(".")
        let v6 = host == "::1" || ["fd", "fe80"].contains { host.hasPrefix($0) }
        guard let o = Self.octets(host) else { return named || v6 }
        let privateRange: Bool
        switch o[0] {
        case 10, 127: privateRange = true
        case 172: privateRange = (16...31).contains(o[1])
        case 192: privateRange = o[1] == 168
        case 169: privateRange = o[1] == 254
        default: privateRange = false
        }
        return named || privateRange || v6
    }

    /// The four numbers of a dotted address, or nil for anything else.
    private static func octets(_ host: String) -> [Int]? {
        let numbers = host.split(separator: ".").compactMap { Int($0) }
        return numbers.count == 4 ? numbers : nil
    }

    /// The URL for `path` (starting with `/`) under this gateway, with `query` if any.
    public func api(_ path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.path = pathPrefix + Self.slashed(path)
        // Foundation leaves ":" and "/" as they are inside a query, which is allowed. Some proxies run a
        // rule against "common exploits" that trips on "=http://" in the sign-in redirect and returns 403,
        // so each value gets full escaping. Servers decode either form identically.
        parts.percentEncodedQuery = query.isEmpty ? nil : Self.encodedQuery(query)
        return parts.url!
    }

    /// Joins `name=value` pairs with `&`, escaping everything outside the RFC 3986 unreserved set.
    public static func encodedQuery(_ items: [URLQueryItem]) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        func escape(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text }
        var pairs: [String] = []
        for item in items {
            let name = escape(item.name)
            pairs.append(item.value.map { name + "=" + escape($0) } ?? name)
        }
        return pairs.joined(separator: "&")
    }

    /// The `ws://` or `wss://` form of `path` under this gateway.
    public func websocket(_ path: String, query: Array<URLQueryItem> = Array()) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.scheme = isTLS ? "wss" : "ws"
        parts.path = pathPrefix + Self.slashed(path)
        parts.queryItems = query.isEmpty ? nil : query
        return parts.url!
    }

    private static func slashed(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/" + path
    }
}
