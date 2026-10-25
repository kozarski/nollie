import Foundation

public struct ConnectionTestStep: Identifiable, Hashable, Sendable {
    public init(id: String, title: String, status: Status = .pending) {
        (self.id, self.title, self.status) = (id, title, status)
    }

    public var id: String
    public var title: String
    public var status: Status = .pending
}

public extension ConnectionTestStep {
    /// Where one leg of the test stands; the text of a finished leg says what was found.
    enum Status: Hashable, Sendable {
        case pending
        case running
        case passed(String)
        case failed(String)
    }
}

public struct ConnectionTestOutcome: Sendable {
    public init(steps: [ConnectionTestStep], version: String? = nil, authRequired: Bool? = nil) {
        (self.steps, self.version, self.authRequired) = (steps, version, authRequired)
    }

    public var steps: [ConnectionTestStep]
    public var version: String?
    public var authRequired: Bool?
}

public extension ConnectionTestOutcome {
    /// Every leg passed.
    var succeeded: Bool {
        let passed = steps.filter { step in
            guard case .passed = step.status else { return false }
            return true
        }
        return passed.count == steps.count
    }
}

/// The "Test connection" check: does the gateway answer with JSON, accept the credentials, and
/// open a live WebSocket that says it is ready. It stops at the first leg that fails, and each
/// leg reports as it goes.
public enum ConnectionTester {
    /// A leg that failed for a reason of its own, in words for the person.
    private struct Verdict: Error { var text: String }

    /// What the legs share while they run.
    private final class Probe {
        let connection: GatewayConnection
        let signer: RequestSigner
        let pin: Data?
        let api: HermesAPI
        var version: String?
        var authRequired: Bool?

        init(connection: GatewayConnection, secrets: GatewaySecrets) {
            self.connection = connection
            signer = RequestSigner(authMode: connection.authMode, secrets: secrets)
            // A linked Mac is checked against its own pinned key before anything about it is saved.
            pin = connection.linkedMac?.pin
            let session = pin.map { NollieLinkClient.pinnedSession(pin: $0, configuration: HermesAPI.sessionConfiguration()) }
                ?? HermesAPI.makeSession()
            api = HermesAPI(gateway: connection.gateway, signer: signer, urlSession: session)
        }

        var usesBearer: Bool { connection.authMode.usesBearer }

        /// The gateway is there and speaks JSON.
        func checkStatus() async throws -> String {
            let status: GatewayStatusResponse = try await api.get("/api/status", authenticated: false)
            (version, authRequired) = (status.version, status.authRequired)
            let providers = status.authProviders?.joined(separator: ", ") ?? "-"
            return "Hermes \(status.version ?? "?"), " + (status.authRequired == true ? "auth gate on (\(providers))" : "no auth gate")
        }

        /// The credentials suit the gateway's kind of sign-in, and work.
        func checkCredentials() async throws -> String {
            if authRequired == true {
                if !usesBearer {
                    throw Verdict(text: "This gateway requires a sign-in (its auth gate is on, non-loopback bind). Choose “Sign in with browser” or “Username & password” rather than a session token.")
                }
                let me: AuthMeResponse = try await api.get("/api/auth/me")
                return "Signed in as \(me.displayName ?? me.email ?? me.userId ?? "user") via \(me.provider ?? "provider")"
            }
            if usesBearer {
                throw Verdict(text: "This gateway has no auth gate and wants the dashboard session token (HERMES_DASHBOARD_SESSION_TOKEN). Change the auth mode to “Session token”.")
            }
            let profiles: ProfilesResponse = try await api.get("/api/profiles")
            return "Session token works: \(profiles.profiles.count) profile(s) found"
        }

        private func oneUseTicket() async throws -> String? {
            let reply: [String: JSONValue] = try await api.send("POST", "/api/auth/ws-ticket", body: EmptyBody())
            return reply["ticket"]?.stringValue
        }

        /// The WebSocket upgrades and the gateway says it is ready.
        func checkSocket() async throws -> String {
            let ticket = try await usesBearer ? oneUseTicket() : nil
            let address = RequestSigner.websocketURL(gateway: connection.gateway, token: signer.sessionToken, ticket: ticket)
            do {
                return try await probeWebSocket(url: address, headers: signer.publicHeaders, pin: pin)
            } catch {
                let hint = " The HTTP checks passed but the WebSocket did not. Make sure your reverse proxy or Cloudflare tunnel passes Upgrade requests through to /api/ws, that Access (if used) gets the same service-token headers, and that the gateway's dashboard.public_url matches this host."
                throw Verdict(text: error.localizedDescription + hint)
            }
        }
    }

    public static func run(connection: GatewayConnection, secrets: GatewaySecrets, progress: @escaping @Sendable ([ConnectionTestStep]) -> Void) async -> ConnectionTestOutcome {
        let titles = [
            ("status", "GET /api/status returns JSON"),
            ("auth", "Credentials accepted"),
            ("ws", "WebSocket /api/ws connects and gateway.ready comes back"),
        ]
        var steps = titles.map { ConnectionTestStep(id: $0.0, title: $0.1) }
        let probe = Probe(connection: connection, secrets: secrets)
        let legs: [() async throws -> String] = [probe.checkStatus, probe.checkCredentials, probe.checkSocket]

        for (position, leg) in legs.enumerated() {
            steps[position].status = .running
            progress(steps)
            do {
                steps[position].status = .passed(try await leg())
            } catch let verdict as Verdict {
                steps[position].status = .failed(verdict.text)
            } catch {
                steps[position].status = .failed(error.localizedDescription)
            }
            progress(steps)
            if case .failed = steps[position].status {
                // A gateway that never answered has told us nothing about itself.
                if position == 0 { (probe.version, probe.authRequired) = (nil, nil) }
                break
            }
        }
        return ConnectionTestOutcome(steps: steps, version: probe.version, authRequired: probe.authRequired)
    }

    /// Opens a socket and waits for the gateway to say it is ready.
    public static func probeWebSocket(url: URL, headers: [String: String], pin: Data? = nil, timeout: Double = 12) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let session = pin.map { NollieLinkClient.pinnedSession(pin: $0, configuration: config) }
            ?? URLSession(configuration: config, delegate: GatewayTrust.shared, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 65_536
        socket.resume()

        return try await awaitGatewayReady(timeout: timeout, receive: {
            do {
                switch try await socket.receive() {
                case .string(let text): return text
                case .data(let bytes): return String(decoding: bytes, as: UTF8.self)
                @unknown default: return ""
                }
            } catch {
                try Task.checkCancellation()
                throw closeError(code: socket.closeCode.rawValue,
                                 reason: socket.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "",
                                 underlying: error)
            }
        }, cancel: { socket.cancel(with: .goingAway, reason: nil) })
    }

    /// What a socket that closed before it was ready means, in words for the person.
    private static func closeError(code: Int, reason: String, underlying: Error) -> Error {
        switch code {
        case 4401: SocketError.closed(code: code, reason: "credential rejected (\(reason))")
        case 4403: SocketError.closed(code: code, reason: "blocked by the host/origin guard (\(reason)); set dashboard.public_url to this URL")
        case 4408: SocketError.closed(code: code, reason: "this address is not allowed (the gateway accepts loopback only)")
        case 1...: SocketError.closed(code: code, reason: reason)
        default: HermesAPIError.transport(underlying.localizedDescription)
        }
    }

    /// Reads frames from `receive` until the gateway reports `gateway.ready`. Gives up when the
    /// gateway reports an error or an error answer, after 128 frames, or after `timeout`
    /// seconds; always calls `cancel` on the way out. Split out so tests can feed it frames.
    static func awaitGatewayReady(timeout: Double, receive: @escaping @Sendable () async throws -> String,
                                  cancel: @escaping @Sendable () -> Void) async throws -> String {
        guard timeout.isFinite, timeout > 0 else { throw SocketError.timeout("gateway.ready") }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Bool.self) { race in
                defer {
                    cancel()
                    race.cancelAll()
                }
                race.addTask {
                    for _ in 0..<128 {
                        try Task.checkCancellation()
                        switch InboundFrame.parse(try await receive()) {
                        case .event(let event) where event.type == "gateway.ready":
                            return true
                        case .event(let event) where event.type == "gateway.error":
                            throw HermesAPIError.transport("The gateway reported an error before it was ready.")
                        case .response(_, _, let failure?):
                            throw failure
                        default:
                            continue
                        }
                    }
                    throw HermesAPIError.transport("The gateway sent too many messages without becoming ready.")
                }
                race.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    return false
                }
                guard try await race.next() == true else { throw SocketError.timeout("gateway.ready") }
                try Task.checkCancellation()
                return "gateway.ready received"
            }
        } onCancel: { cancel() }
    }
}
