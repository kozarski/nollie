import Foundation

public enum HermesAPIError: LocalizedError, Sendable {
    case sessionExpired
    case unauthorized(String)
    case http(status: Int, detail: String)
    case htmlResponse(status: Int)
    case decoding(String)
    case transport(String)
}

extension HermesAPIError {
    private static var notTheAPI: String { String(localized: "That address answered with a web page, not the Hermes dashboard API. Use the `hermes serve` dashboard address, add the Access service-token headers if Cloudflare Access is on, and check that your tunnel passes WebSockets through.", table: "Core") }

    public var errorDescription: String? {
        switch self {
        case .sessionExpired:
            return String(localized: "Your session ran out. Please sign in again.", table: "Core")
        case .htmlResponse:
            return Self.notTheAPI
        case .transport(let message):
            return message
        case .decoding(let message):
            return String(localized: "The gateway sent something unexpected: \(message)", table: "Core")
        case .unauthorized(let detail):
            return detail.isEmpty ? String(localized: "The gateway did not accept those credentials (401).", table: "Core") : detail
        case .http(let status, let detail):
            return detail.isEmpty ? String(localized: "HTTP \(status)", table: "Core", comment: "An HTTP status code")
                : String(localized: "\(detail) (HTTP \(status))", table: "Core", comment: "The gateway's own words, then an HTTP status code")
        }
    }

    /// The credentials were refused, or are known to have run out.
    public var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return if case .sessionExpired = self { true } else { false }
    }
}

public struct EmptyBody: Encodable, Sendable { public init() {} }

/// Talks to one gateway over HTTP. Adds the sign-in and Access headers and `?profile=`, renews
/// a bearer sign-in once when the gateway says 401, and notices when an HTML page answers
/// instead of the API.
public actor HermesAPI {
    /// The query items of a request.
    public typealias Query = [URLQueryItem]
    /// A request body and its content type.
    public typealias Body = (Data, String)

    private let urlSession: URLSession
    private var renewal: Task<RequestSigner, Error>?

    public private(set) var signer: RequestSigner
    public private(set) var gateway: GatewayURL
    /// Asked for a fresh signer after a 401 on a bearer sign-in.
    public var refresher: (@Sendable () async throws -> RequestSigner)?

    public init(gateway: GatewayURL, signer: RequestSigner, urlSession: URLSession = HermesAPI.makeSession()) {
        (self.gateway, self.signer, self.urlSession) = (gateway, signer, urlSession)
    }

    public static func makeSession() -> URLSession {
        URLSession(configuration: sessionConfiguration(), delegate: GatewayTrust.shared, delegateQueue: nil)
    }

    public static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 5 * 60
        return config
    }

    public func updateSigner(_ s: RequestSigner) { signer = s }
    public func updateGateway(_ gateway: GatewayURL) { self.gateway = gateway }
    public func setRefresher(_ r: (@Sendable () async throws -> RequestSigner)?) { refresher = r }
}

// MARK: Typed calls

extension HermesAPI {
    /// Fetches a file into a temporary folder of its own and returns where it landed. The caller
    /// moves it or deletes it. The file keeps the last component of the `path` query item.
    public func download(_ path: String, query: Query = []) async throws -> URL {
        let source = gateway.api(path, query: query)
        var request = URLRequest(url: source)
        signer.apply(to: &request)
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (temporary, response) = try await urlSession.download(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw Self.error(for: http, data: (try? Data(contentsOf: temporary)) ?? Data())
        }
        guard response is HTTPURLResponse else { throw HermesAPIError.transport(String(localized: "No HTTP response", table: "Core")) }

        // The caller gets a folder to itself, so a name that was already taken cannot clash.
        let asked = URLComponents(url: source, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
        let leaf = (asked as NSString?)?.lastPathComponent ?? ""
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: leaf.isEmpty ? "download" : leaf, directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    public func sendMultipart<T: Decodable>(_ path: String, query: Query = [], profile: String? = nil, fields: [String: String] = [:], fileField: String, filename: String, fileData: Data, mimeType: String = "application/octet-stream") async throws -> T {
        let edge = "Nollie-" + UUID().uuidString
        func part(_ headers: [String]) -> Data { Data((["--" + edge] + headers + ["", ""]).joined(separator: "\r\n").utf8) }

        var form = Data()
        for (name, value) in fields {
            form += part(["Content-Disposition: form-data; name=\"\(name)\""]) + Data((value + "\r\n").utf8)
        }
        form += part([
            "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"",
            "Content-Type: \(mimeType)",
        ])
        form += fileData
        form += Data("\r\n--\(edge)--\r\n".utf8)
        return try await answer(Ask(method: "POST", path: path, query: query, profile: profile,
                                    body: (form, "multipart/form-data; boundary=" + edge)))
    }

    public func send<T: Decodable>(_ method: String, _ path: String, query: Query = [], profile: String? = nil, json: JSONValue) async throws -> T {
        try await answer(.init(method: method, path: path, query: query, profile: profile, body: (JSONEncoder().encode(json), "application/json")))
    }

    public func get<T: Decodable>(_ path: String, query: Query = [], profile: String? = nil, authenticated: Bool = true) async throws -> T {
        try await answer(.init(method: "GET", path: path, query: query, profile: profile, authenticated: authenticated))
    }

    public func send<T: Decodable, B>(_ method: String, _ path: String, query: Query = [], profile: String? = nil, body: B) async throws -> T where B: Encodable & Sendable {
        let encoded = try JSONEncoder().encode(body)
        return try await answer(Ask(method: method, path: path, query: query, profile: profile, body: (encoded, "application/json")))
    }

    /// What the typed calls ask for, before it becomes a URL request.
    private struct Ask {
        var method: String
        var path: String
        var query: Query
        var profile: String?
        var body: Body?
        var authenticated = true
    }

    private func answer<T: Decodable>(_ ask: Ask) async throws -> T {
        let reply = try await raw(ask.method, ask.path, query: ask.query, profile: ask.profile, body: ask.body, authenticated: ask.authenticated)
        do {
            return try JSONCoding.decoder.decode(T.self, from: reply.0)
        } catch {
            throw HermesAPIError.decoding(String(String(describing: error).prefix(200)))
        }
    }
}

// MARK: One request

extension HermesAPI {
    /// One request. `timeout` replaces the session's wait when given. `answers` lists error
    /// statuses whose body is the answer the caller wants (a 409 carrying the current state),
    /// so they are returned, not thrown.
    public func raw(_ method: String, _ path: String, query: Query = [], profile: String? = nil, body: Body?, authenticated: Bool, timeout: TimeInterval? = nil, answers: Set<Int> = []) async throws -> (Data, HTTPURLResponse) {
        let wantsProfile = profile.map { !$0.isEmpty } == true && !query.contains { $0.name == "profile" }
        let items = wantsProfile ? query + [URLQueryItem(name: "profile", value: profile)] : query

        // Built fresh for each try, since a renewal changes what the headers say.
        let build = { [self] in
            makeRequest(method, gateway.api(path, query: items), body: body, timeout: timeout, authenticated: authenticated)
        }

        var reply = try await fetch(build())
        let canRenew = authenticated && signer.authMode.usesBearer
        let renewed = reply.1.statusCode == 401 && canRenew && refresher != nil
        if renewed, let refresher {
            signer = try await sharedRenewal(refresher)
            reply = try await fetch(build())
        }

        let status = reply.1.statusCode
        if status >= 400 && !answers.contains(status) { throw Self.error(for: reply.1, data: reply.0) }
        // Right after a renewal, only the retry's status counts.
        let pageInsteadOfData = !renewed && Self.looksLikeHTML(http: reply.1, data: reply.0)
        if pageInsteadOfData { throw HermesAPIError.htmlResponse(status: status) }
        return reply
    }

    private func makeRequest(_ method: String, _ url: URL, body: Body?, timeout: TimeInterval?, authenticated: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        signer.apply(to: &request, includeCredential: authenticated)
        if let body {
            request.httpBody = body.0
            request.setValue(body.1, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Calls arriving together on a 401 share one renewal.
    private func sharedRenewal(_ refresher: @escaping @Sendable () async throws -> RequestSigner) async throws -> RequestSigner {
        let task = renewal ?? Task { try await refresher() }
        renewal = task
        defer { renewal = nil }
        return try await task.value
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse { return (data, http) }
        } catch let known as HermesAPIError {
            throw known
        } catch {
            throw HermesAPIError.transport(error.localizedDescription)
        }
        throw HermesAPIError.transport(String(localized: "No HTTP response", table: "Core"))
    }
}

// MARK: Reading answers

extension HermesAPI {
    /// Whether an answer is a web page rather than API output (a login page, a proxy's page).
    public nonisolated static func looksLikeHTML(http: HTTPURLResponse, data: Data) -> Bool {
        let declared = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        switch (declared.contains("text/html"), declared.contains("application/json")) {
        case (true, _): return true
        case (_, true): return false
        default:
            let opening = String(decoding: data.prefix(64), as: UTF8.self)
            let lead = opening.drop { $0.isWhitespace || $0.isNewline }.lowercased()
            return lead.hasPrefix("<!doctype") || lead.hasPrefix("<html")
        }
    }

    /// The error an unsuccessful answer stands for, with the gateway's own words when it gave any.
    public nonisolated static func error(for http: HTTPURLResponse, data: Data) -> HermesAPIError {
        let status = http.statusCode
        guard !looksLikeHTML(http: http, data: data) else { return .htmlResponse(status: status) }
        switch explanation(in: data) {
        case (_, true): return .sessionExpired
        case (let detail, false) where status == 401: return .unauthorized(detail)
        case (let detail, false): return .http(status: status, detail: detail)
        }
    }

    /// The gateway's own words in an error body, and whether they say the session ran out.
    private nonisolated static func explanation(in data: Data) -> (String, Bool) {
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            return (text.count < 300 ? text : "", false)
        }
        let reason = body["error"]?.stringValue
        let words = body["detail"].map { $0.stringValue ?? $0.displayText } ?? reason ?? ""
        return (words, reason == "session_expired")
    }
}
