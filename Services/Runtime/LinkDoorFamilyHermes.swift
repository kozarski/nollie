#if os(macOS)
import Foundation

/// The door's own calls to Hermes on loopback, with Hermes's token: the Private list, the helpers and
/// chat rows it answers a member with itself, and the owner's answer to a member's ask. Nothing here
/// is reachable from a phone except through those answers.
final class LinkDoorFamilyHermes: @unchecked Sendable {
    private let upstream: LinkDoor.UpstreamProvider
    private let session: URLSession
    private let lock = NSLock()
    private var privateCache: (names: Set<String>, at: Date)?
    private var refreshing = false
    /// How long a read Private list is used before it is read again, and how old it may get (while a
    /// read is failing) before members are refused.
    static let privateFresh: TimeInterval = 5
    static let privateStale: TimeInterval = 30

    init(upstream: @escaping LinkDoor.UpstreamProvider) {
        self.upstream = upstream
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: Plain requests

    /// A GET to Hermes. Nil when Hermes isn't there or didn't answer.
    func get(_ path: String, query: [URLQueryItem] = []) async -> (status: Int, body: Data)? {
        await send("GET", path, query: query, json: nil)
    }

    /// One request to Hermes, with a JSON body when given. Nil when Hermes isn't there or didn't answer.
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any?) async -> (status: Int, body: Data)? {
        guard let target = await upstream(), (1024...65535).contains(target.port) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = target.port
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(target.token, forHTTPHeaderField: LinkDoorPolicy.deviceHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            guard let body = try? JSONSerialization.data(withJSONObject: json) else { return nil }
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse,
              data.count <= 4 * 1024 * 1024 else { return nil }
        return (http.statusCode, data)
    }

    // MARK: The Private list

    /// The Private list as the add-on keeps it, read at most every five seconds. Nil when it can't be
    /// read and the last good read is over thirty seconds old: members are then refused.
    func privateNames(now: Date = Date()) async -> Set<String>? {
        if let cached = lock.withLock({ privateCache }), now.timeIntervalSince(cached.at) < Self.privateFresh { return cached.names }
        if let names = await readPrivate() {
            lock.withLock { privateCache = (names, now) }
            return names
        }
        guard let cached = lock.withLock({ privateCache }), now.timeIntervalSince(cached.at) < Self.privateStale else { return nil }
        return cached.names
    }

    /// The last list read, for decisions on a socket that can't wait; it is read again in the background.
    func cachedPrivateNames(now: Date = Date()) -> Set<String>? {
        let cached = lock.withLock { privateCache }
        if cached.map({ now.timeIntervalSince($0.at) >= Self.privateFresh }) ?? true { refreshInBackground() }
        guard let cached, now.timeIntervalSince(cached.at) < Self.privateStale else { return nil }
        return cached.names
    }

    private func refreshInBackground() {
        let start = lock.withLock { () -> Bool in
            guard !refreshing else { return false }
            refreshing = true
            return true
        }
        guard start else { return }
        Task {
            _ = await self.privateNames()
            self.lock.withLock { self.refreshing = false }
        }
    }

    private func readPrivate() async -> Set<String>? {
        guard let reply = await get("/api/plugins/nollie-workflow/private-bots"), reply.status == 200,
              let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
              let names = object["profiles"] as? [String] else { return nil }
        return Set(names.map { $0.lowercased() }).union(LinkDoorFamily.alwaysPrivate)
    }

    // MARK: Household copies

    /// Makes a household copy with Hermes's own profile copy: config, instructions, skills and identity,
    /// none of the memory or chats. True when it was made, or was already there.
    func makeCopy(_ copy: String, of helper: String, person: String) async -> Bool {
        let body: [String: Any] = ["name": copy, "clone_from": helper, "description": "For \(person)"]
        guard let reply = await send("POST", "/api/profiles", json: body) else { return false }
        return (200..<300).contains(reply.status) || reply.status == 409
    }

    /// Writes the copy's own `agent.disabled_toolsets` so it can't read this Mac's files, run code, reach
    /// other helpers or use the owner's accounts, keeping whatever the copy already had off. Read back to
    /// prove it took.
    func lockDown(_ copy: String) async -> Bool {
        let scope = [URLQueryItem(name: "profile", value: copy)]
        let raw = [URLQueryItem(name: "profile", value: copy), URLQueryItem(name: "include_defaults", value: "false")]
        guard let before = await get("/api/config", query: raw), before.status == 200,
              let config = try? JSONSerialization.jsonObject(with: before.body) as? [String: Any],
              let toolsets = await get("/api/tools/toolsets", query: scope), toolsets.status == 200,
              let rows = try? JSONSerialization.jsonObject(with: toolsets.body) as? [[String: Any]] else { return false }
        let servers = ((config["mcp_servers"] as? [String: Any]) ?? [:]).keys.sorted()
        let required = LinkDoorFamily.requiredDrops(listed: rows.compactMap { $0["name"] as? String }, mcpServers: servers)
        let wanted = LinkDoorFamily.lockedToolsets(existing: (config["agent"] as? [String: Any])?["disabled_toolsets"], required: required)
        guard let saved = await send("PUT", "/api/config", query: scope, json: ["config": ["agent": ["disabled_toolsets": wanted]]]),
              (200..<300).contains(saved.status),
              let after = await get("/api/config", query: raw), after.status == 200,
              let read = try? JSONSerialization.jsonObject(with: after.body) as? [String: Any] else { return false }
        return LinkDoorFamily.isLockedDown((read["agent"] as? [String: Any])?["disabled_toolsets"], required: required)
    }

    // MARK: Asking Hermes something on its socket

    /// One JSON-RPC call on a socket of the door's own. True when Hermes answered without an error.
    func call(_ method: String, params: [String: Any], timeout: TimeInterval = 10) async -> Bool {
        guard let target = await upstream(), (1024...65535).contains(target.port) else { return false }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = target.port
        components.path = "/api/ws"
        components.queryItems = [URLQueryItem(name: "token", value: target.token)]
        guard let url = components.url else { return false }
        let id = "nollie-door-" + UUID().uuidString.lowercased()
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let text = (try? JSONSerialization.data(withJSONObject: message)).flatMap({ String(data: $0, encoding: .utf8) }) else { return false }
        let task = session.webSocketTask(with: url)
        task.resume()
        // Closing the socket at the deadline ends a receive that is still waiting.
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timer.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }
        do { try await task.send(.string(text)) } catch { return false }
        while true {
            guard let next = try? await task.receive() else { return false }
            guard case .string(let reply) = next, let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
                  object["id"] as? String == id else { continue }
            return object["error"] == nil
        }
    }
}
#endif
