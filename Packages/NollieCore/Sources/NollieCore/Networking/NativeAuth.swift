import AuthenticationServices
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Signs in to a gateway the way a native app should (RFC 8252): the system browser plus the
/// gateway's `/auth/native/*` routes, or a username and password, and later token renewal.
@MainActor
public final class NativeAuthClient: NSObject {
    typealias Callback = (code: String, state: String)
    typealias Finish = @Sendable (Result<Callback, Error>) -> Void

    private var webSession: ASWebAuthenticationSession?

    public static func providers(gateway: GatewayURL, access: CloudflareAccess) async throws -> [AuthProvider] {
        let reply: AuthProvidersResponse = try await api(gateway, access).get("/api/auth/providers", authenticated: false)
        return reply.providers
    }

    // MARK: Browser sign-in

    public func signInWithBrowser(gateway: GatewayURL, provider: String? = nil, access: CloudflareAccess = CloudflareAccess()) async throws -> GatewaySecrets {
        let nonce = UUID().uuidString
        let proof = PKCE.init()
        defer { webSession = nil }
        try await Self.checkNativeSignIn(gateway: gateway, access: access)

        let catcher = try LoopbackCallbackServer()
        let port = try await catcher.start()
        let chosen = (provider ?? "").isEmpty ? [] : [URLQueryItem(name: "provider", value: provider)]
        let trip = chosen + Self.authorizeItems(proof, nonce, returnTo: "http://127.0.0.1:\(port)/callback")
        let arrived = try await runBrowser(at: gateway.api("/auth/native/authorize", query: trip), catcher: catcher)

        if arrived.state != nonce { throw NativeAuthError.stateMismatch }
        return try await Self.redeem(arrived.code, proof.verifier, gateway, access)
    }

    /// Opens the browser sheet and returns whichever happens first: the code reaching the
    /// loopback server, or the sheet closing without one.
    private func runBrowser(at url: URL, catcher: LoopbackCallbackServer) async throws -> Callback {
        let teardown: @MainActor (LoopbackCallbackServer) -> Void = { [weak self] server in
            server.stop()
            self?.webSession?.cancel()
            self?.webSession = nil
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Callback, Error>) in
                let gate = LockedFlag()
                let finish: Finish = { outcome in
                    guard gate.claim() else { return }
                    Task { @MainActor in
                        teardown(catcher)
                        continuation.resume(with: outcome)
                    }
                }
                catcher.onCallback = { code, state in finish(.success((code, state))) }

                let sheet = ASWebAuthenticationSession(
                    url: url,
                    callback: .customScheme("hermesremote"),
                    completionHandler: Self.browserClosed(finish)
                )
                sheet.presentationContextProvider = self
                sheet.prefersEphemeralWebBrowserSession = false
                webSession = sheet
                let opened = sheet.start()
                if !opened { finish(.failure(NativeAuthError.browserWouldNotOpen)) }
            }
        } onCancel: {
            Task { @MainActor in teardown(catcher) }
        }
    }

    /// Completion handler for when the browser sheet closes. The system calls it on its own thread, so
    /// it must not be tied to the main actor; creating it inline once crashed the Mac app. A sheet that
    /// closes without an error means the code never made it to the loopback server.
    nonisolated static func sessionEnded(_ finish: @escaping Finish) -> ASWebAuthenticationSession.CompletionHandler {
        browserClosed(finish)
    }

    nonisolated private static func browserClosed(_ finish: @escaping Finish) -> ASWebAuthenticationSession.CompletionHandler {
        { @Sendable _, problem in
            switch problem {
            case nil:
                finish(.failure(NativeAuthError.noCallback))
            case let closed as ASWebAuthenticationSessionError where closed.code == .canceledLogin:
                finish(.failure(NativeAuthError.cancelled))
            case let other?:
                finish(.failure(other))
            }
        }
    }

    /// Asks whether the gateway supports the native sign-in route, before a browser opens. On older
    /// Hermes this gives 404, and the browser flow would end at the dashboard sign-in with no way back
    /// into the app. When the route exists, the reply is 400 because parameters are missing. Other
    /// outcomes (a proxy page, a network blip, a login wall the browser could still cross) do not count
    /// against the gateway.
    public static func checkNativeSignIn(gateway: GatewayURL, access: CloudflareAccess) async throws {
        var request = URLRequest(url: gateway.api("/auth/native/authorize"), timeoutInterval: 15)
        for (name, value) in access.headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return }

        let page = String(decoding: data, as: UTF8.self)
        if let complaint = routeComplaint(status: status, proxyPage: page.localizedCaseInsensitiveContains("nginx")) {
            throw NativeAuthError.invalidResponse(complaint)
        }
    }

    private static func routeComplaint(status: Int, proxyPage: Bool) -> String? {
        if status == 404 {
            return "This gateway's Hermes cannot do native sign-in yet (its /auth/native/authorize route is missing). The browser would sign in to the dashboard and never hand anything to the app. Update Hermes on the gateway, or use a session token from the dashboard."
        }
        if status == 403 && proxyPage {
            return "The proxy in front of the gateway turned the sign-in request away (403). With Nginx Proxy Manager and Block Common Exploits, this build already encodes the request so the rule should not match; otherwise let /auth/ through the proxy."
        }
        return nil
    }

    // MARK: Username and password

    /// Signs in with a dashboard password provider and no browser. It opens a broker
    /// authorization (which leaves a cookie in this session), logs in under that cookie, and
    /// trades the code the gateway returns for tokens.
    public static func signInWithPassword(gateway: GatewayURL, provider: String, username: String, password: String, access: CloudflareAccess = CloudflareAccess()) async throws -> GatewaySecrets {
        let nonce = UUID().uuidString
        let proof = PKCE.init()
        let desk = CookieDesk(access: access)

        let opening = authorizeItems(proof, nonce, returnTo: "http://127.0.0.1:1/callback")
        try await desk.touch(gateway.api("/auth/native/authorize", query: [URLQueryItem(name: "provider", value: provider)] + opening))
        let answer = try await desk.postJSON(
            ["provider": provider, "username": username, "password": password],
            to: gateway.api("/auth/password-login")
        )

        guard let back = redirectItems(in: answer), let code = back["code"] else {
            throw NativeAuthError.invalidResponse("The gateway sent no sign-in code. Turn on a password provider in the dashboard (HERMES_DASHBOARD_BASIC_AUTH_*).")
        }
        if back["state"] != nonce { throw NativeAuthError.stateMismatch }
        return try await redeem(code, proof.verifier, gateway, access)
    }

    /// The query values of the `next` link in a password-login reply.
    private static func redirectItems(in reply: Data) -> [String: String]? {
        guard let next = (try? JSONDecoder().decode(JSONValue.self, from: reply))?["next"]?.stringValue,
              let items = URLComponents(string: next)?.queryItems else { return nil }
        var table: [String: String] = [:]
        for item in items where table[item.name] == nil {
            table[item.name] = item.value
        }
        return table
    }

    /// A URLSession that keeps cookies, for the password sign-in's two calls.
    private struct CookieDesk {
        let access: CloudflareAccess
        let session: URLSession

        init(access: CloudflareAccess) {
            let setup = URLSessionConfiguration.ephemeral
            setup.httpCookieAcceptPolicy = .always
            setup.httpShouldSetCookies = true
            setup.timeoutIntervalForRequest = 30
            self.access = access
            self.session = URLSession(configuration: setup)
        }

        /// Loads a page just to pick up the cookie it sets.
        func touch(_ url: URL) async throws {
            _ = try await run(URLRequest(url: url))
        }

        func postJSON(_ fields: [String: String], to url: URL) async throws -> Data {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(fields)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return try await run(request)
        }

        private func run(_ original: URLRequest) async throws -> Data {
            var request = original
            access.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await session.data(for: request)
            switch response as? HTTPURLResponse {
            case nil:
                throw HermesAPIError.transport("The gateway sent no HTTP answer")
            case let bad? where bad.statusCode >= 400:
                throw HermesAPI.error(for: bad, data: data)
            default:
                return data
            }
        }
    }

    // MARK: Tokens

    public static func exchange(gateway: GatewayURL, code: String, verifier: String, access: CloudflareAccess = CloudflareAccess()) async throws -> GatewaySecrets {
        try await redeem(code, verifier, gateway, access)
    }

    /// Trades a sign-in code and its verifier for the first set of tokens.
    private static func redeem(_ code: String, _ verifier: String, _ gateway: GatewayURL, _ access: CloudflareAccess) async throws -> GatewaySecrets {
        let granted: NativeTokenResponse = try await api(gateway, access)
            .send("POST", "/auth/native/token", body: ["code": code, "code_verifier": verifier])
        return GatewaySecrets(access: access).with {
            $0.accessToken = granted.accessToken
            $0.refreshToken = granted.refreshToken
            $0.expiresAt = granted.expiresAt
            $0.provider = granted.provider
            $0.userId = granted.userId
        }
    }

    /// Fresh tokens from the refresh token. Whatever the gateway leaves out keeps its old
    /// value. A refusal means the person has to sign in again.
    public static func refresh(gateway: GatewayURL, secrets: GatewaySecrets) async throws -> GatewaySecrets {
        let oldRefresh = secrets.refreshToken ?? ""
        if oldRefresh.isEmpty { throw HermesAPIError.sessionExpired }
        let granted: NativeTokenResponse
        do {
            granted = try await api(gateway, secrets.access)
                .send("POST", "/auth/native/refresh", body: ["refresh_token": oldRefresh, "provider": secrets.provider ?? ""])
        } catch let refused as HermesAPIError where refused.isUnauthorized {
            throw HermesAPIError.sessionExpired
        }
        var updated = secrets
        updated.accessToken = granted.accessToken
        updated.expiresAt = granted.expiresAt
        updated.refreshToken = granted.refreshToken ?? oldRefresh
        updated.provider = granted.provider ?? secrets.provider
        updated.userId = granted.userId ?? secrets.userId
        return updated
    }

    // MARK: Shared pieces

    private static func api(_ gateway: GatewayURL, _ access: CloudflareAccess) -> HermesAPI {
        HermesAPI(gateway: gateway, signer: RequestSigner(authMode: .oauth, access: access))
    }

    private static func authorizeItems(_ proof: PKCE, _ nonce: String, returnTo: String) -> [URLQueryItem] {
        [
            ("code_challenge", proof.challenge),
            ("code_challenge_method", "S256"),
            ("redirect_uri", returnTo),
            ("state", nonce),
        ].map { URLQueryItem(name: $0.0, value: $0.1) }
    }
}

extension NativeAuthClient: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .lazy.compactMap(\.keyWindow).first
        return window ?? ASPresentationAnchor()
        #endif
    }
}

private extension GatewaySecrets {
    /// A copy with the changes made inside `edit`.
    func with(_ edit: (inout GatewaySecrets) -> Void) -> GatewaySecrets {
        var copy = self
        edit(&copy)
        return copy
    }
}
