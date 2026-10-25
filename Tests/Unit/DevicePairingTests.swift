import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NollieCore

@Suite(.serialized)
struct DevicePairingTests {
    private let secret = String(repeating: "a", count: 64)

    private func invitation(gateway: String = "https://mac.example.test", expires: Date = Date().addingTimeInterval(120)) throws -> DevicePairingInvitation {
        try .init(gateway: GatewayURL.normalize(gateway), id: UUID().uuidString.lowercased(), grant: secret,
                  displayName: "Studio", expiresAt: expires)
    }

    @Test func roundTripCarriesOnlyShortLivedGrantAndSafeDisplayInformation() throws {
        let original = try invitation()
        let parsed = try DevicePairingInvitation.parse(original.qrString)
        #expect(parsed.id == original.id && parsed.gateway == original.gateway && parsed.displayName == "Studio")
        #expect(parsed.grant == secret)
        #expect(!String(describing: original).contains(secret))
        #expect(!String(reflecting: original).contains(secret))
        #expect(!original.qrString.contains("sessionToken"))
    }

    @Test func malformedOrUnsupportedCodesAreRejected() throws {
        let good = try invitation().qrString
        for raw in ["https://mac.example.test", good + "?extra=yes", good.replacingOccurrences(of: "nollie://pair", with: "nollie://pair/path"),
                    good.replacingOccurrences(of: "nollie://pair", with: "nollie://user@pair"), String(repeating: "x", count: 4097)] {
            #expect(throws: DevicePairingError.self) { try DevicePairingInvitation.parse(raw) }
        }
    }

    @Test func expiryIsEnforcedAndCannotClaimLongLivedValidity() throws {
        let now = Date()
        let item = try invitation(expires: now.addingTimeInterval(120))
        #expect(throws: DevicePairingError.expired) { try DevicePairingInvitation.parse(item.qrString, now: now.addingTimeInterval(120)) }
        #expect(throws: DevicePairingError.self) { try invitation(expires: now.addingTimeInterval(600)) }
    }

    @Test func insecureLoopbackAndAmbiguousAddressesAreRejected() throws {
        for address in ["http://mac.example.test", "https://127.0.0.1", "https://localhost", "https://x.localhost",
                        "https://[::1]", "https://[0:0:0:0:0:0:0:1]", "https://[::ffff:127.0.0.1]",
                        "https://0.0.0.0", "https://2130706433", "https://127.1", "https://0177.0.0.1",
                        "https://0x7f.0.0.1", "https://user:pass@mac.example.test", "https://mac.example.test/?token=x",
                        "https://mac.example.test/#x", "https://mac.example.test/%2e%2e"] {
            #expect(throws: DevicePairingError.self) { try DevicePairingInvitation.validateGateway(address) }
        }
        for address in ["https://mac.example.test", "https://studio.local:8443", "https://192.168.1.2:8443", "https://studio.example.test/hermes"] {
            try DevicePairingInvitation.validateGateway(address)
        }
    }

    @Test func displayNameCannotSpoofTheConfirmation() throws {
        for name in ["", " Studio", "Studio\nOther Mac", "Studio\u{202E}moc.elpmaxe", String(repeating: "x", count: 65)] {
            #expect(throws: DevicePairingError.self) {
                try DevicePairingInvitation(gateway: GatewayURL.normalize("https://mac.example.test"), id: UUID().uuidString.lowercased(),
                    grant: secret, displayName: name, expiresAt: Date().addingTimeInterval(120))
            }
        }
    }

    @Test func unsupportedCapabilityDoesNotMintAnInvitation() async throws {
        let fixture = PairingHTTPFixture()
        fixture.reply = { request in
            #expect(request.url?.path == "/api/plugins/nollie-pairing/capabilities")
            return (404, [:], Data("{}".utf8))
        }
        let client = DevicePairingClient(api: fixture.api())
        #expect(try await client.capability().supported == false)
        await #expect(throws: DevicePairingError.setupRequired) { try await client.create() }
        #expect(fixture.count == 2)
    }

    @Test func loopbackCapabilityDoesNotMakeANetworkRequest() async throws {
        let api = HermesAPI(gateway: try .normalize("http://127.0.0.1:9119"), signer: .init(authMode: .sessionToken))
        #expect(try await DevicePairingClient(api: api).capability().supported == false)
    }

    @Test func createStatusAndCancelUseTheAuthenticatedMacConnection() async throws {
        let fixture = PairingHTTPFixture()
        let id = UUID().uuidString.lowercased(), grant = secret
        fixture.reply = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-mac")
            switch (request.httpMethod, request.url!.path) {
            case (_, "/api/plugins/nollie-pairing/capabilities"):
                return (200, [:], Data(#"{"supported":true,"reason":null}"#.utf8))
            case ("POST", "/api/plugins/nollie-pairing/invitations"):
                return (200, [:], try JSONSerialization.data(withJSONObject: ["id": id, "grant": grant, "expires_at": Int(Date().timeIntervalSince1970) + 120]))
            case ("GET", "/api/plugins/nollie-pairing/invitations/" + id):
                return (200, [:], Data(#"{"state":"paired"}"#.utf8))
            case ("DELETE", "/api/plugins/nollie-pairing/invitations/" + id):
                return (200, [:], Data(#"{"ok":true}"#.utf8))
            default:
                Issue.record("Unexpected pairing route")
                return (500, [:], Data())
            }
        }
        let client = DevicePairingClient(api: fixture.api())
        let item = try await client.create(displayName: "Studio")
        #expect(item.id == id && item.displayName == "Studio")
        #expect(try await client.status(item).state == .paired)
        try await client.cancel(item)
    }

    @MainActor @Test func redemptionUsesPKCEWithoutMacCredentials() async throws {
        let fixture = PairingHTTPFixture()
        let values = Mutex<[String: String]>([:])
        fixture.reply = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: RequestSigner.sessionTokenHeader) == nil)
            switch request.url!.path {
            case "/auth/native/authorize":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                values.withLock { store in
                    store["state"] = query.first { $0.name == "state" }!.value!
                    store["challenge"] = query.first { $0.name == "code_challenge" }!.value!
                }
                return (302, ["Location": "/login"], Data())
            case "/auth/password-login":
                let body = try JSONSerialization.jsonObject(with: fixture.body(request)) as! [String: String]
                #expect(body["provider"] == "nollie-pairing" && body["password"]?.count == 64)
                values.withLock { $0["id"] = body["username"] }
                let state = values.withLock { $0["state"]! }
                return (200, [:], try JSONSerialization.data(withJSONObject: ["ok": true, "next": "http://127.0.0.1:1/callback?code=fixture-code&state=" + state]))
            case "/auth/native/token":
                let body = try JSONSerialization.jsonObject(with: fixture.body(request)) as! [String: String]
                let challenge = Data(SHA256.hash(data: Data(body["code_verifier"]!.utf8))).base64URLEncodedString()
                #expect(challenge == values.withLock { $0["challenge"] })
                return (200, [:], try JSONSerialization.data(withJSONObject: [
                    "access_token": String(repeating: "b", count: 64), "refresh_token": String(repeating: "c", count: 64),
                    "provider": "nollie-pairing", "user_id": "nollie-device:" + values.withLock { $0["id"]! },
                    "expires_at": Int(Date().timeIntervalSince1970) + 900]))
            default:
                Issue.record("Unexpected redirected request")
                return (500, [:], Data())
            }
        }
        let item = try invitation(gateway: fixture.url.absoluteString)
        let secrets = try await DevicePairingClient.redeem(item, configuration: fixture.configuration())
        #expect(secrets.provider == "nollie-pairing" && secrets.sessionToken == nil)
        #expect(secrets.accessToken == String(repeating: "b", count: 64))
        #expect(fixture.count == 3)
    }

    @MainActor @Test func exchangeRejectsRedirectAndNeverSavesCredentials() async throws {
        let fixture = PairingHTTPFixture()
        fixture.reply = { request in
            if request.url!.path == "/auth/native/authorize" { return (302, ["Location": "/login"], Data()) }
            return (307, ["Location": "https://other.example.test/collect"], Data())
        }
        let item = try invitation(gateway: fixture.url.absoluteString)
        await #expect(throws: DevicePairingError.invalidResponse) {
            try await DevicePairingClient.redeem(item, configuration: fixture.configuration())
        }
        #expect(fixture.count == 2)
    }

    @MainActor @Test func cancelledSetupRevokesOnlyTheExactNewDevice() async throws {
        let fixture = PairingHTTPFixture()
        let item = try invitation(gateway: fixture.url.absoluteString)
        let token = String(repeating: "b", count: 64)
        fixture.reply = { request in
            #expect(request.httpMethod == "DELETE" && request.url?.path == "/api/plugins/nollie-pairing/device")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
            #expect(request.url?.query == nil)
            return (200, [:], Data(#"{"ok":true}"#.utf8))
        }
        let secrets = GatewaySecrets(accessToken: token, provider: "nollie-pairing", userId: "nollie-device:" + item.id)
        try await DevicePairingClient.discard(item, secrets: secrets, configuration: fixture.configuration())
        #expect(fixture.count == 1)
        await #expect(throws: DevicePairingError.invalidResponse) {
            try await DevicePairingClient.discard(item, secrets: GatewaySecrets(accessToken: token, provider: "other", userId: "other"), configuration: fixture.configuration())
        }
        #expect(fixture.count == 1)
    }
}

private final class PairingHTTPFixture: @unchecked Sendable {
    typealias Reply = @Sendable (URLRequest) throws -> (Int, [String: String], Data)
    let url = URL(string: "https://fixture-" + UUID().uuidString.lowercased() + ".example.test")!
    private let storage = Mutex<(Reply?, Int)>((nil, 0))
    var reply: Reply? { get { storage.withLock { $0.0 } } set { storage.withLock { $0.0 = newValue } } }
    var count: Int { storage.withLock { $0.1 } }
    init() { PairingURLProtocol.fixtures.withLock { $0[url.host!] = self } }
    func configuration() -> URLSessionConfiguration {
        let result = URLSessionConfiguration.ephemeral
        result.protocolClasses = [PairingURLProtocol.self]
        return result
    }
    func api() -> HermesAPI {
        HermesAPI(gateway: try! GatewayURL.normalize(url.absoluteString), signer: .init(authMode: .oauth, bearer: "fixture-mac"),
                  urlSession: URLSession(configuration: configuration()))
    }
    func response(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        let handler = storage.withLock { $0.1 += 1; return $0.0! }
        return try handler(request)
    }
    func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class PairingURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = Mutex<[String: PairingHTTPFixture]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let fixture = Self.fixtures.withLock({ $0[request.url!.host!] }) else { throw URLError(.unsupportedURL) }
            let (status, headers, data) = try fixture.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
