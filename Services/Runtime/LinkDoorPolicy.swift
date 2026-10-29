#if os(macOS)
import Foundation
import Network

/// Who may knock, and which Hermes routes a linked device may reach.
enum LinkDoorPolicy {
    // MARK: Source addresses

    /// Private and local networks only: RFC 1918, link-local, CGNAT (Tailscale), IPv6 ULA and
    /// link-local. Loopback only when the door is run inside a test. Everything else is refused
    /// before the TLS handshake starts.
    static func allowsSource(_ endpoint: NWEndpoint, allowLoopback: Bool) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return allowsIPv4(Array(address.rawValue), allowLoopback: allowLoopback)
        case .ipv6(let address): return allowsIPv6(Array(address.rawValue), allowLoopback: allowLoopback)
        default: return false
        }
    }

    static func allowsIPv4(_ bytes: [UInt8], allowLoopback: Bool) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        case (100, 64...127): return true
        case (127, _): return allowLoopback
        default: return false
        }
    }

    static func allowsIPv6(_ bytes: [UInt8], allowLoopback: Bool) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return allowsIPv4(Array(bytes[12..<16]), allowLoopback: allowLoopback)
        }
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return allowLoopback }
        if bytes[0] & 0xFE == 0xFC { return true }                     // fc00::/7
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }   // fe80::/10
        return false
    }

    // MARK: Routes

    enum Route: Equatable, Sendable {
        /// The one route a phone may use without a device credential, with an offer's secret.
        case claim
        /// "Stop Nollie on my Mac" from a linked phone: answered by the door itself, never Hermes.
        case stop
        /// The live picture of a helper's computer, as a socket the door answers itself, never Hermes.
        case live
        case hermes
        case refused
        /// Where to find this Mac next time, and away from home: answered by the door itself.
        case hosts
        case awayOn
        case awayOff
        /// Away through iCloud: the phone's away key in, the Mac's out. Answered by the door itself.
        case seal
    }

    static let claimPath = "/nollie/link/claim"
    static let stopPath = "/nollie/stop"
    static let livePath = "/nollie/live"
    static let sealPath = "/nollie/link/seal"

    /// One allowed route: methods and a path pattern, where `*` is one segment that is not a
    /// reserved word and `**` is any further segments (kanban only). Sockets list no methods.
    private struct Rule {
        let methods: Set<String>
        let pattern: [Substring]
        let socket: Bool
        init(_ methods: Set<String>, _ pattern: String, socket: Bool = false) {
            self.methods = methods
            self.pattern = pattern.split(separator: "/")
            self.socket = socket
        }
    }

    /// Segments a `*` never matches, so `/api/sessions/*` can't reach bulk or maintenance routes.
    private static let reserved: Set<Substring> = [
        "empty", "bulk-delete", "import", "export", "owner-backfill", "prune", "search", "stats", "active",
        "sessions", "open-terminal", "setup-command", "desktop-overlay", "reset-state", "rescan", "attachments",
    ]

    /// Exactly what the app uses for everyday chat, and no more. Not listed, so refused:
    /// keys and secrets (`/api/env`, credentials, providers), all configuration (`/api/config`
    /// returns secrets from config.yaml), plugin and MCP management, updates, restarts and ops,
    /// sign-in, local model downloads, files (Hermes's file routes are not confined to a folder
    /// the door can enforce), the raw file system and git, logs, Hermes's own memory routes (reset and provider), webhooks, creating or
    /// changing scheduled tasks (their scripts can't be inspected here), deleting bots, bulk
    /// session routes, and every page or asset outside `/api`.
    private static let rules: [Rule] = [
        Rule(["GET"], "/api/status"), Rule(["GET"], "/api/health"),
        Rule([], "/api/ws", socket: true),
        Rule(["GET"], "/api/sessions"), Rule(["GET"], "/api/sessions/search"),
        Rule(["GET", "PATCH", "DELETE"], "/api/sessions/*"), Rule(["GET"], "/api/sessions/*/messages"),
        Rule(["GET", "POST"], "/api/profiles"), Rule(["GET", "POST"], "/api/profiles/active"),
        Rule(["GET"], "/api/profiles/sessions"), Rule(["PATCH"], "/api/profiles/*"),
        Rule(["GET", "PUT"], "/api/profiles/*/soul"), Rule(["PUT"], "/api/profiles/*/description"),
        Rule(["PUT"], "/api/profiles/*/model"),
        Rule(["GET"], "/api/model/options"),
        Rule(["GET"], "/api/config/schema"),
        Rule(["GET"], "/api/media"), Rule(["GET"], "/api/media/proxy"),
        Rule(["GET"], "/api/cron/jobs"), Rule(["GET", "DELETE"], "/api/cron/jobs/*"),
        Rule(["POST"], "/api/cron/jobs/*/pause"), Rule(["POST"], "/api/cron/jobs/*/resume"),
        Rule(["POST"], "/api/cron/jobs/*/trigger"),
        Rule(["GET"], "/api/analytics/usage"), Rule(["GET"], "/api/skills"), Rule(["GET"], "/api/tools/toolsets"),
        Rule(["GET", "POST", "PATCH", "DELETE"], "/api/plugins/kanban/**"), Rule([], "/api/plugins/kanban/events", socket: true),
        Rule(["GET"], "/api/plugins/nollie-workflow/private-bots"), Rule(["GET"], "/api/plugins/nollie-workflow/attention"),
        Rule(["GET"], "/api/plugins/nollie-workflow/papertrail"),
        // The weekly note: one bot's week as counts and names, and one tap to turn a connected app or the web tools
        // off or on again. The add-on refuses private bots and never removes anything; the door allows nothing but
        // `?bot=` on the read (see `allowsQuery`).
        Rule(["GET"], "/api/plugins/nollie-workflow/week"), Rule(["PUT"], "/api/plugins/nollie-workflow/week/switch"),
        // Remove asks first on the phone; the add-on removes through Hermes's own config code and records it.
        Rule(["POST"], "/api/plugins/nollie-workflow/week/remove-app"),
        // Each helper's mute and the note's day, the same on every device. Only the Mac's own alert helper says
        // it sends the note itself (`weekly-note/live`), so a phone never reaches that.
        Rule(["GET"], "/api/plugins/nollie-workflow/mutes"), Rule(["PUT"], "/api/plugins/nollie-workflow/mutes/*"),
        Rule(["GET", "PUT"], "/api/plugins/nollie-workflow/weekly-note"),
        // Each bot's character and colour, so a look picked on the phone is the Mac's too. The add-on
        // refuses a private bot's.
        Rule(["GET"], "/api/plugins/nollie-workflow/bot-looks"), Rule(["PUT"], "/api/plugins/nollie-workflow/bot-looks/*"),
        // The main chat's cards: read them, and Turn on or Keep off a rehearsed schedule, as resuming one is.
        Rule(["GET"], "/api/plugins/nollie-workflow/posts"),
        Rule(["POST"], "/api/plugins/nollie-workflow/rehearsals/*/turn-on"),
        Rule(["POST"], "/api/plugins/nollie-workflow/rehearsals/*/keep-off"),
        // When the Mac slept, for a schedule that ran late: times and a kind only.
        Rule(["GET"], "/api/plugins/nollie-workflow/sleep"),
        Rule(["GET"], "/api/plugins/nollie-computer/preview"),
        Rule(["GET", "PUT"], "/api/plugins/nollie-computer/ask-first"),
        // A saved sign-in card: the phone may only say it is the one answering. Sites, the
        // requests list, the Mac's start and result, and the history stay on the Mac.
        Rule(["POST"], "/api/plugins/nollie-workflow/sign-ins/requests/*/claim"),
        // A helper's Calendar, Reminders and Contacts switches. The requests and their answers stay on the Mac.
        Rule(["GET", "PUT"], "/api/plugins/nollie-workflow/apple-data/bots"),
        // Saved cards: the labels ("Visa ending 4242") and a helper's "Can pay" switch. The requests,
        // their answers and the history stay on the Mac, which alone fills a card in.
        Rule(["GET"], "/api/plugins/nollie-workflow/payments/cards"),
        Rule(["GET", "PUT"], "/api/plugins/nollie-workflow/payments/bots"),
        // Watch: Take over and Hand back, after Face ID on the phone. The add-on still refuses
        // private bots; the door allows nothing but `?profile=` on these (see `allowsQuery`).
        Rule(["POST"], "/api/plugins/nollie-computer/take-over"),
        Rule(["POST"], "/api/plugins/nollie-computer/hand-back"),
        // What a helper remembers: read it, add, edit or forget one entry, and its one switch. The add-on
        // refuses Moss and every private bot from here; the door allows nothing but `?bot=` (see `allowsQuery`).
        Rule(["GET"], "/api/plugins/nollie-workflow/memory"),
        Rule(["POST", "PUT", "DELETE"], "/api/plugins/nollie-workflow/memory/notes"),
        Rule(["PUT"], "/api/plugins/nollie-workflow/memory/switch"),
        // Ready-made helpers: the gallery's roster, its Add and the Undo that takes one back. The crew add-on
        // keeps an added helper on the local model, with no schedule and only tools of Nollie's own that need no
        // further yes, archives rather than deletes on Undo, and only answers for Nollie's profile. A suggestion's
        // Add can bring a schedule, so `suggestions/*` stays on the Mac.
        Rule(["GET"], "/api/plugins/nollie-crew/crew"),
        Rule(["POST"], "/api/plugins/nollie-crew/members"),
        Rule(["POST"], "/api/plugins/nollie-crew/undo"),
    ]

    private static func matches(_ pattern: [Substring], _ path: [Substring]) -> Bool {
        for (index, part) in pattern.enumerated() {
            if part == "**" { return path.count > index && !path[index...].contains(where: reserved.contains) }
            guard index < path.count else { return false }
            if part == "*" { if reserved.contains(path[index]) { return false } }
            else if part != path[index] { return false }
        }
        return path.count == pattern.count
    }

    static func route(method: String, path: String, websocket: Bool) -> Route {
        if path == claimPath { return method == "POST" && !websocket ? .claim : .refused }
        if path == stopPath { return method == "POST" && !websocket ? .stop : .refused }
        if path == livePath { return method == "GET" && websocket ? .live : .refused }
        if path == sealPath { return method == "POST" && !websocket ? .seal : .refused }
        if let own = awayRoutes[path] { return method == (own == .hosts ? "GET" : "POST") && !websocket ? own : .refused }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map { $0 }
        guard !segments.contains(where: \.isEmpty) else { return .refused }
        for rule in rules where rule.socket == websocket && (websocket ? method == "GET" : rule.methods.contains(method)) {
            if matches(rule.pattern, segments) { return .hermes }
        }
        return .refused
    }

    /// What may travel from the phone on each kind of socket.
    enum SocketKind: Equatable, Sendable { case rpc, events }
    static func socketKind(_ path: String) -> SocketKind {
        path == "/api/ws" ? .rpc : .events
    }

    // MARK: Away from home

    static let awayRoutes: [String: Route] = ["/nollie/link/hosts": .hosts, "/nollie/link/away/on": .awayOn, "/nollie/link/away/off": .awayOff]

    /// Paths whose query is held to one `profile` and nothing else.
    static let profileOnlyPaths: Set<String> = ["/api/plugins/nollie-computer/take-over", "/api/plugins/nollie-computer/hand-back",
                                               "/api/plugins/nollie-computer/ask-first"]

    /// Paths whose query is held to one `bot` and nothing else: a helper's memory. So a phone can't say
    /// `on_this_mac`, which only Nollie on the Mac that runs Hermes sends for a private bot.
    static let botOnlyPaths: Set<String> = ["/api/plugins/nollie-workflow/memory", "/api/plugins/nollie-workflow/memory/notes",
                                           "/api/plugins/nollie-workflow/memory/switch", "/api/plugins/nollie-workflow/week"]

    /// Every other path passes its query on as before; these take exactly one profile name.
    static func allowsQuery(path: String, query: String?) -> Bool {
        if profileOnlyPaths.contains(path) { return onlyOneName("profile", in: query) }
        if botOnlyPaths.contains(path) { return onlyOneName("bot", in: query) }
        return true
    }

    private static func onlyOneName(_ key: Substring, in query: String?) -> Bool {
        guard let query, !query.isEmpty else { return false }
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        guard pairs.count == 1 else { return false }
        let parts = pairs[0].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == key, let value = parts[1].removingPercentEncoding,
              (1...64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    /// Tailscale's address blocks: 100.64.0.0/10 and fd7a:115c:a1e0::/48. With away from home off
    /// the door turns these away before the handshake, as it does the internet.
    static func isTailnetSource(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return isTailnetIPv4(Array(address.rawValue))
        case .ipv6(let address):
            let bytes = Array(address.rawValue)
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF { return isTailnetIPv4(Array(bytes[12..<16])) }
            return bytes.count == 16 && Array(bytes.prefix(6)) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
        default: return false
        }
    }

    static func isTailnetIPv4(_ bytes: [UInt8]) -> Bool { bytes.count == 4 && bytes[0] == 100 && (64...127).contains(bytes[1]) }

    /// A host the door would hand a phone that only works through Tailscale: a `.ts.net` name or
    /// an address in Tailscale's blocks.
    static func isTailnetHost(_ host: String) -> Bool {
        if host.lowercased().hasSuffix(".ts.net") { return true }
        if let v4 = IPv4Address(host) { return isTailnetIPv4(Array(v4.rawValue)) }
        if let v6 = IPv6Address(host) { return isTailnetSource(.hostPort(host: .ipv6(v6), port: 1)) }
        return false
    }

    // MARK: Credentials and forwarding

    static let deviceHeader = "X-Hermes-Session-Token"

    /// Header names never passed to Hermes. Incoming credentials are removed and replaced;
    /// hop-by-hop and forwarding headers are the door's own business.
    static let strippedHeaders: Set<String> = [
        "host", "connection", "keep-alive", "proxy-connection", "proxy-authorization", "proxy-authenticate",
        "te", "trailer", "transfer-encoding", "upgrade", "content-length",
        "x-hermes-session-token", "authorization", "cookie", "cf-access-client-id", "cf-access-client-secret",
        "cf-access-jwt-assertion", "forwarded", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto",
        "x-forwarded-port", "x-real-ip", "origin", "referer",
        // No compression on sockets: the door reads every frame the phone sends.
        "sec-websocket-extensions",
    ]
    static let strippedQuery: Set<String> = ["token", "ticket"]

    /// The device credential, from the session header or, for a socket, the `token` query.
    /// Two different values are no credential at all.
    static func presentedCredential(_ request: LinkDoorHTTP.Request) -> String? {
        let headers = request.values(deviceHeader)
        let queries = request.isWebSocketUpgrade ? request.queryItems.filter { $0.name == "token" }.compactMap(\.value) : []
        let all = Set(headers + queries)
        guard headers.count <= 1, queries.count <= 1, all.count == 1 else { return nil }
        return all.first
    }

    /// The request head Hermes receives: the loopback host, the door's own session token in
    /// place of any credential, and `Connection: close` (or the socket upgrade).
    static func upstreamHead(_ request: LinkDoorHTTP.Request, port: Int, token: String) -> Data {
        let named = LinkDoorHTTP.tokens(request.values("connection"))
        var headers = [LinkDoorHTTP.Header(name: "Host", value: "127.0.0.1:\(port)")]
        headers += request.headers.filter { !strippedHeaders.contains($0.key) && !named.contains($0.key) }
        var target = request.path.isEmpty ? "/" : request.target.split(separator: "?", maxSplits: 1)[0].description
        var query = request.query?.split(separator: "&", omittingEmptySubsequences: true).filter { pair in
            let name = String(pair.split(separator: "=", maxSplits: 1)[0])
            return !strippedQuery.contains(name.removingPercentEncoding ?? name)
        }.map(String.init) ?? []
        if request.isWebSocketUpgrade {
            query.append("token=" + token)
            headers.append(.init(name: "Connection", value: "Upgrade"))
            headers.append(.init(name: "Upgrade", value: "websocket"))
        } else {
            headers.append(.init(name: deviceHeader, value: token))
            headers.append(.init(name: "Connection", value: "close"))
            if request.contentLength > 0 || ["POST", "PUT", "PATCH"].contains(request.method) {
                headers.append(.init(name: "Content-Length", value: String(request.contentLength)))
            }
        }
        if !query.isEmpty { target += "?" + query.joined(separator: "&") }
        return LinkDoorHTTP.serializeRequest(method: request.method, target: target, headers: headers)
    }

    /// The response head the phone receives. A socket upgrade passes unchanged; anything else
    /// is told the connection closes after it.
    static func downstreamHead(_ response: LinkDoorHTTP.Response) -> Data {
        guard response.status != 101 else {
            return LinkDoorHTTP.serializeResponse(status: 101, reason: response.reason, headers: response.headers)
        }
        let named = LinkDoorHTTP.tokens(response.headers.filter { $0.key == "connection" }.map(\.value))
        let hop: Set<String> = ["connection", "keep-alive", "proxy-connection", "upgrade", "set-cookie"]
        var headers = response.headers.filter { !hop.contains($0.key) && !named.contains($0.key) }
        headers.append(.init(name: "Connection", value: "close"))
        return LinkDoorHTTP.serializeResponse(status: response.status, reason: response.reason, headers: headers)
    }
}
#endif
