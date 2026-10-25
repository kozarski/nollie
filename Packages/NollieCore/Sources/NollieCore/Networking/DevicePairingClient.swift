import CryptoKit
import Foundation
import Security

public struct DevicePairingCapability: Decodable, Sendable {
    public let supported: Bool
    public let reason: String?
    public init(supported: Bool, reason: String? = nil) { self.supported = supported; self.reason = reason }
}

public struct DevicePairingStatus: Decodable, Sendable {
    public enum State: String, Decodable, Sendable { case pending, paired, expired, cancelled }
    public let state: State
}

public actor DevicePairingClient {
    public static let provider = "nollie-pairing"
    private static let path = "/api/plugins/nollie-pairing"
    private let api: HermesAPI

    public init(api: HermesAPI) { self.api = api }

    public func capability() async throws -> DevicePairingCapability {
        do { try DevicePairingInvitation.validateGateway(await api.gateway.base.absoluteString) }
        catch { return .init(supported: false, reason: "secure_address_required") }
        do {
            return try await api.get(Self.path + "/capabilities")
        } catch let error as HermesAPIError {
            if case .http(let status, _) = error, status == 404 || status == 405 { return .init(supported: false, reason: "companion_required") }
            if case .htmlResponse = error { return .init(supported: false, reason: "companion_required") }
            throw error
        }
    }

    public func create(deviceName: String = "iPhone", displayName: String = "Nollie") async throws -> DevicePairingInvitation {
        let gateway = await api.gateway
        try DevicePairingInvitation.validateGateway(gateway.base.absoluteString)
        guard try await capability().supported else { throw DevicePairingError.setupRequired }
        struct Body: Encodable, Sendable { let device_name: String }
        struct Created: Decodable { let id: String; let grant: String; let expiresAt: Double }
        let response: Created = try await api.send("POST", Self.path + "/invitations", body: Body(device_name: deviceName))
        guard await api.gateway == gateway else { throw DevicePairingError.invalidResponse }
        return try DevicePairingInvitation(gateway: gateway, id: response.id, grant: response.grant,
                                          displayName: displayName, expiresAt: Date(timeIntervalSince1970: response.expiresAt))
    }

    public func status(_ invitation: DevicePairingInvitation) async throws -> DevicePairingStatus {
        guard await api.gateway == invitation.gateway else { throw DevicePairingError.invalidInvitation }
        return try await api.get(Self.path + "/invitations/" + invitation.id)
    }

    public func cancel(_ invitation: DevicePairingInvitation) async throws {
        guard await api.gateway == invitation.gateway else { throw DevicePairingError.invalidInvitation }
        let _: EmptyResponse = try await api.send("DELETE", Self.path + "/invitations/" + invitation.id, body: EmptyBody())
    }

    @MainActor public static func redeem(_ invitation: DevicePairingInvitation) async throws -> GatewaySecrets {
        try await redeem(invitation, configuration: .ephemeral)
    }

    /// Best-effort cleanup for a cancelled phone flow that already received credentials.
    @MainActor public static func discard(_ invitation: DevicePairingInvitation, secrets: GatewaySecrets) async throws {
        try await discard(invitation, secrets: secrets, configuration: .ephemeral)
    }

    @MainActor static func discard(_ invitation: DevicePairingInvitation, secrets: GatewaySecrets, configuration: URLSessionConfiguration) async throws {
        try DevicePairingInvitation.validateGateway(invitation.gateway.base.absoluteString)
        guard secrets.provider == provider, secrets.userId == "nollie-device:" + invitation.id,
              let token = secrets.accessToken, validCredential(token) else { throw DevicePairingError.invalidResponse }
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: PairingRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: invitation.gateway.api(Self.path + "/device"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DevicePairingError.invalidResponse }
    }

    @MainActor static func redeem(_ invitation: DevicePairingInvitation, configuration: URLSessionConfiguration) async throws -> GatewaySecrets {
        guard invitation.expiresAt > Date() else { throw DevicePairingError.expired }
        try DevicePairingInvitation.validateGateway(invitation.gateway.base.absoluteString)
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: PairingRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw DevicePairingError.invalidResponse }
        let verifier = Data(random).base64URLEncodedString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = UUID().uuidString
        let gateway = invitation.gateway
        let authorize = URLRequest(url: gateway.api("/auth/native/authorize", query: [
            .init(name: "provider", value: provider), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "redirect_uri", value: "http://127.0.0.1:1/callback"),
            .init(name: "state", value: state)]))
        let (_, authorizeResponse) = try await session.data(for: authorize)
        guard let authorizeHTTP = authorizeResponse as? HTTPURLResponse,
              [200, 302, 303].contains(authorizeHTTP.statusCode) else { throw DevicePairingError.invalidResponse }
        // The authorize redirect only sets the PKCE cookie. No redirected URL is opened.
        struct Login: Encodable { let provider: String; let username: String; let password: String }
        let loginData = try await pairingPost(session: session, url: gateway.api("/auth/password-login"),
            body: Login(provider: provider, username: invitation.id, password: invitation.grant))
        struct LoggedIn: Decodable { let ok: Bool; let next: String }
        guard let loggedIn = try? JSONDecoder().decode(LoggedIn.self, from: loginData), loggedIn.ok,
              let callback = URLComponents(string: loggedIn.next), callback.scheme == "http", callback.host == "127.0.0.1",
              callback.port == 1, callback.path == "/callback", callback.user == nil, callback.password == nil,
              callback.fragment == nil, callback.queryItems?.count == 2,
              callback.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let code = callback.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.count <= 256 else {
            throw DevicePairingError.invalidResponse
        }
        struct Exchange: Encodable { let code: String; let code_verifier: String }
        let tokenData = try await pairingPost(session: session, url: gateway.api("/auth/native/token"),
            body: Exchange(code: code, code_verifier: verifier))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let result = try? decoder.decode(NativeTokenResponse.self, from: tokenData), result.provider == provider,
              result.userId == "nollie-device:" + invitation.id, validCredential(result.accessToken),
              let refresh = result.refreshToken, validCredential(refresh),
              let expires = result.expiresAt, expires > Date().timeIntervalSince1970,
              expires <= Date().timeIntervalSince1970 + 915 else { throw DevicePairingError.invalidResponse }
        return GatewaySecrets(accessToken: result.accessToken, refreshToken: refresh, expiresAt: result.expiresAt,
                              provider: result.provider, userId: result.userId)
    }

    private static func pairingPost<B: Encodable>(session: URLSession, url: URL, body: B) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 16_384 else { throw DevicePairingError.invalidResponse }
        return data
    }

    private struct EmptyResponse: Decodable {}

    private static func validCredential(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

private final class PairingRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
