import CryptoKit
import Foundation

/// Support for encrypted notifications from earlier installs. No relay is contacted any more
/// (`url` is nil), but the keys saved back then still open the payloads sent with them.
public enum PushRelay {
    /// What an install keeps to talk to a relay and to open what the gateway seals for it.
    public struct Credentials: Codable, Sendable, Equatable {
        /// Base64 of a 256-bit key; payloads from the gateway are sealed with it.
        public var secret, installID, payloadKey: String

        public init(installID: String, secret: String, payloadKey: String) {
            self.payloadKey = payloadKey
            self.secret = secret
            self.installID = installID
        }
    }

    public enum RelayError: LocalizedError {
        case rejected(String)
        case badPayload
        case invalidInvitation
        case invitationRequired
        case revoked
        case rateLimited
        case unavailable

        public var errorDescription: String? {
            switch self {
            case .rejected(let reason): return "The relay would not register this device: \(reason)"
            case .badPayload: return "This notification's contents could not be unlocked."
            case .invalidInvitation: return "Check the invitation code and try again."
            case .invitationRequired: return "Enter your beta invitation to turn on notifications."
            case .revoked: return "Notifications for this installation have been disabled. Contact the beta organizer."
            case .rateLimited: return "Too many attempts. Give it a minute, then try again."
            case .unavailable: return "Notifications could not connect. Try again in a moment."
            }
        }
    }

    public static let credentialsAccount = "push.relay.credentials"
    private static let invitationAccount = "push.relay.invitation"

    /// No outside relay is used.
    public static var url: URL? { nil }
    public static var isConfigured: Bool { url != nil }

    // MARK: Invitation

    public static func isValidInvitation(_ token: String) -> Bool {
        guard (32...128).contains(token.utf8.count) else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
        return token.utf8.allSatisfy(allowed.contains)
    }

    /// Keeps an invitation just long enough to enroll this install. It never goes to Hermes.
    public static func saveInvitation(_ value: String) throws {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidInvitation(token) else { throw RelayError.invalidInvitation }
        try Keychain.set(Data(token.utf8), account: invitationAccount)
    }

    // MARK: Credentials

    /// The saved credentials, or new ones saved to the Keychain first.
    public static func credentials() -> Credentials {
        if let saved = Keychain.getCodable(Credentials.self, account: credentialsAccount) { return saved }
        let fresh = Credentials(installID: UUID().uuidString.lowercased(),
                                secret: urlSafeSecret(bits: SymmetricKeySize(bitCount: 384)),
                                payloadKey: standardBase64(of: SymmetricKey(size: .bits256)))
        try? Keychain.setCodable(fresh, account: credentialsAccount)
        return fresh
    }

    private static func standardBase64(of key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    /// Random text that is safe in a URL: URL-safe base64 with no padding.
    private static func urlSafeSecret(bits: SymmetricKeySize) -> String {
        var text = standardBase64(of: SymmetricKey(size: bits))
        text = text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// What goes into the device file the gateway's relay reads. Empty while no relay is used.
    public static func deviceFileFields() -> [String: JSONValue] {
        guard let address = url?.absoluteString else { return [:] }
        let mine = credentials()
        let relay: [String: JSONValue] = [
            "url": .string(address),
            "install_id": .string(mine.installID),
            "secret": .string(mine.secret),
        ]
        return ["payload_key": .string(mine.payloadKey), "relay": .object(relay)]
    }

    // MARK: Registering

    private static func registrationRequest(_ method: String, _ url: URL, body: JSONValue) throws -> URLRequest {
        var request = URLRequest(url: url.appending(path: "v1/register"), timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Signs this device up with the relay or renews its entry; calling it on every token change is fine.
    public static func register(deviceToken: String, platform: String, bundleID: String, environment: String) async throws {
        guard let url else { return }
        let creds = credentials()
        var request = try registrationRequest("POST", url, body: .object([
            "install_id": .string(creds.installID),
            "secret": .string(creds.secret),
            "device_token": .string(deviceToken),
            "platform": .string(platform),
            "bundle_id": .string(bundleID),
            "environment": .string(environment),
        ]))
        if let saved = Keychain.get(account: invitationAccount).flatMap({ String(data: $0, encoding: .utf8) }) {
            request.setValue("Bearer " + saved, forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayError.unavailable }
        if let failure = registrationError(status: http.statusCode, data: data) { throw failure }
        Keychain.delete(account: invitationAccount)
    }

    public static func registrationError(status: Int, data: Data) -> RelayError? {
        if (200..<300).contains(status) { return nil }
        let reason = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?.stringValue
        switch (status, reason) {
        case (401, "enrollment_required"): return .invitationRequired
        case (403, "device_revoked"): return .revoked
        case (429, _): return .rateLimited
        default: return .unavailable
        }
    }

    public static func unregister() async {
        guard let url else { return }
        let creds = credentials()
        let body: JSONValue = ["install_id": .string(creds.installID), "secret": .string(creds.secret)]
        guard let request = try? registrationRequest("DELETE", url, body: body) else { return }
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: Opening payloads

    /// Opens a payload the gateway sealed with this install's key. The text is base64 of
    /// nonce, then ciphertext, then tag.
    public static func decrypt(_ encBase64: String, keyBase64: String) throws -> [String: JSONValue] {
        let parts = [keyBase64, encBase64].compactMap { Data(base64Encoded: $0) }
        if parts.count < 2 { throw RelayError.badPayload }
        let key = SymmetricKey(data: parts[0])
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: parts[1]), using: key)
        return try JSONDecoder().decode(JSONValue.self, from: plain).objectValue ?? [:]
    }
}
