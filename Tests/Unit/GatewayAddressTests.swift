import Foundation
import Testing
@testable import NollieCore

/// What a person types for a gateway, and what the app turns it into.
@Suite struct GatewayAddressTests {
    static let tidied: [(typed: String, kept: String)] = [
        ("https://bots.example.org", "https://bots.example.org"),
        ("https://bots.example.org/", "https://bots.example.org"),
        ("https://bots.example.org/hermes/", "https://bots.example.org/hermes"),
        ("http://relay.example.org:9119", "http://relay.example.org:9119"),
        ("relay.example.org:9119", "https://relay.example.org:9119"),
        ("HTTPS://Bots.Example.org", "https://bots.example.org"),
        ("https://b.example.org/hermes/api/status", "https://b.example.org/hermes"),
    ]

    @Test(arguments: Self.tidied)
    func typedAddressesAreTidied(typed: String, kept: String) throws {
        #expect(try GatewayURL.normalize(typed).description == kept)
    }

    @Test(arguments: [
        ("https://b.example.org", "hermes"),
        ("https://b.example.org/hermes", "/hermes/"),
    ])
    func aPathPrefixIsAppliedOnce(typed: String, prefix: String) throws {
        #expect(try GatewayURL.normalize(typed, pathPrefix: prefix).description == "https://b.example.org/hermes")
    }

    @Test func routesAreBuiltUnderTheGatewayPath() throws {
        let secure = try GatewayURL.normalize("https://b.example.org/hermes")
        let configURL = secure.api("/api/config", query: [URLQueryItem(name: "profile", value: "work")])
        #expect(secure.api("/api/status").absoluteString == "https://b.example.org/hermes/api/status")
        #expect(configURL.absoluteString == "https://b.example.org/hermes/api/config?profile=work")
        #expect(secure.websocket("/api/ws").absoluteString == "wss://b.example.org/hermes/api/ws")
        let local = try GatewayURL.normalize("http://10.0.0.5:9119")
        #expect(local.websocket("/api/ws").absoluteString == "ws://10.0.0.5:9119/api/ws")
        #expect([local.isPrivateHost, secure.isPrivateHost] == [true, false])
    }

    static let refused: [(typed: String, reason: GatewayURLError)] = [
        (" \t ", .empty),
        ("ftp://files.example.com", .unsupportedScheme("ftp")),
        ("https://z.example.org/?key=abc", .containsQuery),
    ]

    @Test(arguments: Self.refused)
    func unusableAddressesAreRefusedWithAReason(typed: String, reason: GatewayURLError) {
        #expect(throws: reason) { try GatewayURL.normalize(typed) }
    }
}

/// Which headers go out with a request, and how a socket proves who it is.
@Suite struct RequestSigningTests {
    @Test func tokenModeSendsOnlyTheTokenWhenAccessIsUnset() {
        let signer = RequestSigner(authMode: .sessionToken, sessionToken: "tok", access: CloudflareAccess())
        #expect(signer.headers == [RequestSigner.sessionTokenHeader: "tok"])
    }

    @Test func accessHeadersNeedBothHalves() {
        let half = CloudflareAccess(clientId: "id", clientSecret: "")
        #expect(half.headers.isEmpty)
        #expect(half.isPartiallyConfigured)
        let whole = CloudflareAccess(clientId: "id", clientSecret: "secret")
        #expect(whole.headers == [CloudflareAccess.clientIdHeader: "id", CloudflareAccess.clientSecretHeader: "secret"])
    }

    @Test func bearerModeLeavesOutTheTokenHeaderAndHidesTheBearerFromPublicHeaders() {
        let whole = CloudflareAccess(clientId: "id", clientSecret: "secret")
        let signer = RequestSigner(authMode: .oauth, bearer: "at", access: whole)
        #expect(signer.headers["Authorization"] == "Bearer at")
        #expect(signer.headers[RequestSigner.sessionTokenHeader] == nil)
        #expect(signer.headers[CloudflareAccess.clientIdHeader] == "id")
        #expect(signer.headers[CloudflareAccess.clientSecretHeader] == "secret")
        #expect(signer.publicHeaders["Authorization"] == nil)
        #expect(signer.publicHeaders[CloudflareAccess.clientIdHeader] == "id")
    }

    @Test func aSocketPresentsATicketInPreferenceToTheToken() throws {
        let gateway = try GatewayURL.normalize("https://b.example.org/hermes")
        let base = "wss://b.example.org/hermes/api/ws"
        #expect(RequestSigner.websocketURL(gateway: gateway, token: "tok", ticket: nil).absoluteString == base + "?token=tok")
        #expect(RequestSigner.websocketURL(gateway: gateway, token: "tok", ticket: "tkt").absoluteString == base + "?ticket=tkt")
        let viaBearer = RequestSigner(authMode: .oauth, bearer: "x")
        let viaToken = RequestSigner(authMode: .sessionToken, sessionToken: "t")
        #expect(viaBearer.websocketTokenQuery == nil)
        #expect(viaToken.websocketTokenQuery?.value == "t")
    }
}
