import Foundation

// Keeping the session alive, and the credentials that sockets are opened with.

extension GatewayRuntime {

    /// Renews the session just as a mid-request 401 would. Meant for callers told "session expired"
    /// by an action who want a single retry before the person is asked to sign in.
    public func refreshSession() async throws {
        await api.updateSigner(try await refreshSigner())
    }

    /// Takes a new session (the person signed in) and opens the socket with it.
    public func replaceSecrets(_ fresh: GatewaySecrets) async {
        keep(fresh)
        await api.updateSigner(RequestSigner(authMode: connection.authMode, secrets: fresh))
        guard socketEnabled else { return }
        await socket.connect()
    }

    /// Remembers a session that works: it is held here and saved, and the refusal is forgotten.
    private func keep(_ working: GatewaySecrets) {
        refreshRefused = false
        secrets = working
        store.saveSecrets(working, for: connection.id)
    }

    /// Requests fresh tokens from the gateway. When it rejects the refresh token, the remembered
    /// sign-in (if one was saved) is tried before we give up on the session.
    func refreshSigner() async throws -> RequestSigner {
        if !connection.authMode.usesBearer { throw HermesAPIError.unauthorized("") }
        let renewal = try await renewedSecrets()
        keep(renewal.secrets)
        let signer = RequestSigner(authMode: connection.authMode, secrets: renewal.secrets)
        if renewal.byRememberedSignIn { await reopenRefusedSocket(with: signer) }
        return signer
    }

    /// Secrets from a refresh, or from the remembered sign-in if the refresh was turned down.
    private func renewedSecrets() async throws -> (secrets: GatewaySecrets, byRememberedSignIn: Bool) {
        do {
            return (try await NativeAuthClient.refresh(gateway: connection.gateway, secrets: secrets), false)
        } catch HermesAPIError.sessionExpired {
            if let signInAgain, var again = await signInAgain(connection, secrets) {
                again.access = secrets.access
                return (again, true)
            }
            refreshRefused = true
            throw HermesAPIError.sessionExpired
        }
    }

    /// When a remembered sign-in works, open the socket again if it is still refused. That can
    /// happen if a REST call met the expired session first, or if the socket was turned away again
    /// with nobody around to ask. Nothing else would retry: on return, sign-in happens only while
    /// `refreshRefused` holds, and this one cleared it. Skipping this leaves the socket closed and the
    /// banner asking for a login the person already completed.
    private func reopenRefusedSocket(with signer: RequestSigner) async {
        guard socketEnabled else { return }
        // Our own view of the socket may be behind, so its latest word counts too.
        var views = [socketState]
        views.append(await socket.state)
        let standsRefused = views.contains { state in
            if case .authRejected = state { return true }
            return false
        }
        if !standsRefused { return }
        // Ask for the ticket under the new session, not the rejected one.
        await api.updateSigner(signer)
        await socket.connect()
    }

    // MARK: Socket credentials

    /// What it takes to sign a socket address, copied out so it can travel between actors.
    struct SocketGrant: Sendable {
        let gateway: GatewayURL
        let usesBearer: Bool
        let sessionToken: String?
        let headers: [String: String]
    }

    func currentGrant() -> SocketGrant {
        SocketGrant(gateway: connection.gateway, usesBearer: connection.authMode.usesBearer,
                    sessionToken: secrets.sessionToken, headers: secrets.access.headers)
    }

    /// A one-time ticket for opening a socket. Only gateways that sign in with a bearer token
    /// hand them out.
    nonisolated func ticket(for grant: SocketGrant) async throws -> String? {
        guard grant.usesBearer else { return nil }
        let reply: [String: JSONValue] = try await api.send("POST", "/api/auth/ws-ticket", body: EmptyBody())
        return reply["ticket"]?.stringValue
    }

    /// The main socket's address and headers, signed with a fresh ticket when the gateway wants one.
    private nonisolated func signedSocketTarget() async throws -> (url: URL, headers: [String: String]) {
        let grant = await currentGrant()
        let once = try await ticket(for: grant)
        let url = RequestSigner.websocketURL(gateway: grant.gateway, token: grant.sessionToken, ticket: once)
        return (url, grant.headers)
    }

    /// Where and how the main socket opens. The managed and linked addresses are settled first.
    nonisolated func websocketURL() async throws -> (URL, [String: String]) {
        try await resolveManagedEndpoint()
        try await resolveLinkedEndpoint()
        let target = try await signedSocketTarget()
        return (target.url, target.headers)
    }

    /// Where a second client of the gateway (the new conversation screen's) opens its own socket,
    /// with the main socket's credentials. Asked for before every attempt, so the ticket is fresh.
    public func gatewayEndpoint() async throws -> GatewayEndpoint {
        let target = try await signedSocketTarget()
        return GatewayEndpoint(url: target.url, headers: target.headers)
    }

    /// Builds the socket request for a plugin's endpoint (kanban events). Gateways using bearer auth
    /// sign with a ticket; all others add the session token as `?token=`.
    nonisolated func pluginSocketRequest(path: String, query: [URLQueryItem]) async throws -> URLRequest {
        let grant = await currentGrant()
        let (key, secret): (String, String?) = grant.usesBearer
            ? ("ticket", try await ticket(for: grant))
            : ("token", grant.sessionToken)
        var items = query
        if let secret, !secret.isEmpty { items.append(URLQueryItem(name: key, value: secret)) }
        var request = URLRequest(url: grant.gateway.websocket(path, query: items))
        grant.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return request
    }

    /// Where a chat's live picture opens: where the main socket does (a linked Mac's door is
    /// found first), with the session token and, for a linked Mac, its pin. Nil for a gateway
    /// signed in another way, which keeps showing snapshots.
    public func liveTarget(profile: String, sessionID: String) async throws -> LiveStreamClient.Target? {
        guard connection.authMode == .sessionToken, let token = secrets.sessionToken, !token.isEmpty else { return nil }
        try await resolveLinkedEndpoint()
        let grant = currentGrant()
        return LiveStreamClient.Target(gateway: grant.gateway, profile: profile, sessionID: sessionID, token: token,
                                       pin: connection.linkedMac?.pin, headers: grant.headers)
    }
}
