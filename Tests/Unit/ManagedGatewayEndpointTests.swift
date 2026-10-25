import Foundation
import Testing
@testable import NollieCore

struct ManagedGatewayEndpointTests {
    private let installationID = UUID()
    private let newURL = URL(string: "http://127.0.0.1:49312")!

    private func connection(managed: Bool = true) throws -> GatewayConnection {
        GatewayConnection(name: "My assistant", gateway: try GatewayURL.normalize("http://127.0.0.1:49100"),
                          authMode: .sessionToken, lastProfile: "default", connectionKind: "local",
                          managedInstallationID: managed ? installationID : nil)
    }

    @Test func oldSavedConnectionDecodesWithoutManagedIdentity() throws {
        let old = try connection(managed: false)
        let data = try JSONEncoder().encode(old)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["managedInstallationID"] == nil)
        let decoded = try JSONDecoder().decode(GatewayConnection.self, from: data)
        #expect(decoded == old)
        #expect(decoded.managedInstallationID == nil)
    }

    @Test func managedIdentityRoundTripsAndOnlyEndpointChanges() throws {
        let original = try connection()
        let decoded = try JSONDecoder().decode(GatewayConnection.self, from: JSONEncoder().encode(original))
        #expect(decoded.managedInstallationID == installationID)
        let updated = try #require(decoded.updatingManagedEndpoint(newURL, activeConnectionID: original.id,
            installationID: installationID, enabledInstallationID: installationID))
        var expected = original
        expected.gateway = try GatewayURL.normalize(newURL.absoluteString)
        #expect(updated == expected)
    }

    @Test func untaggedLocalConnectionIsNeverRewritten() throws {
        let original = try connection(managed: false)
        #expect(original.updatingManagedEndpoint(newURL, activeConnectionID: original.id,
            installationID: installationID, enabledInstallationID: installationID) == nil)
    }

    @Test func differentConnectionOrInstallationIsNeverRewritten() throws {
        let original = try connection()
        #expect(original.updatingManagedEndpoint(newURL, activeConnectionID: UUID(),
            installationID: installationID, enabledInstallationID: installationID) == nil)
        #expect(original.updatingManagedEndpoint(newURL, activeConnectionID: original.id,
            installationID: UUID(), enabledInstallationID: installationID) == nil)
        #expect(original.updatingManagedEndpoint(newURL, activeConnectionID: original.id,
            installationID: installationID, enabledInstallationID: UUID()) == nil)
        #expect(original.updatingManagedEndpoint(newURL, activeConnectionID: original.id,
            installationID: installationID, enabledInstallationID: nil) == nil)
    }

    @Test func remoteAndEditedConnectionsAreNotRetargeted() throws {
        var original = try connection()
        original.gateway = try GatewayURL.normalize("https://assistant.example.com")
        #expect(original.updatingManagedEndpoint(newURL, activeConnectionID: original.id,
            installationID: installationID, enabledInstallationID: installationID) == nil)
        original = try connection()
        original.authMode = .password
        #expect(original.updatingManagedEndpoint(newURL, activeConnectionID: original.id,
            installationID: installationID, enabledInstallationID: installationID) == nil)
        original = try connection()
        original.hasAccessHeaders = true
        #expect(original.updatingManagedEndpoint(newURL, activeConnectionID: original.id,
            installationID: installationID, enabledInstallationID: installationID) == nil)
    }

    @Test func existingRESTClientUsesUpdatedEndpoint() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ManagedEndpointURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let original = try connection()
        let api = HermesAPI(gateway: original.gateway, signer: .init(authMode: .sessionToken, secrets: .init()), urlSession: session)
        let before: [String: Int] = try await api.get("/fixture")
        #expect(before["port"] == 49100)
        await api.updateGateway(try GatewayURL.normalize(newURL.absoluteString))
        let after: [String: Int] = try await api.get("/fixture")
        #expect(after["port"] == 49312)
    }

    @Test(arguments: ["http://localhost:49312", "https://127.0.0.1:49312", "http://127.0.0.1:80",
                      "http://127.0.0.1:49312/api", "http://127.0.0.1:49312?token=x",
                      "http://127.0.0.1:49312#x", "http://user:pass@127.0.0.1:49312",
                      "http://100.64.1.2:49312"])
    func malformedHelperEndpointIsRejected(_ text: String) throws {
        let original = try connection()
        #expect(original.updatingManagedEndpoint(try #require(URL(string: text)), activeConnectionID: original.id,
            installationID: installationID, enabledInstallationID: installationID) == nil)
    }
}

private final class ManagedEndpointURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.path == "/fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"port\":\(url.port ?? 0)}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
