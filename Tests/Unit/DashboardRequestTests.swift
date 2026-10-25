import Foundation
import Testing
@testable import NollieCore

/// A URL protocol that answers from a closure and remembers what it was asked.
final class CannedURLProtocol: URLProtocol {
    struct Canned: Sendable {
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var body = Data()
        static func json(_ text: String, status: Int = 200) -> Canned { Canned(status: status, body: Data(text.utf8)) }
    }

    nonisolated(unsafe) static var answer: (@Sendable (URLRequest) -> Canned)?
    nonisolated(unsafe) static var asked: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        var tidy = request
        tidy.cachePolicy = .reloadIgnoringLocalCacheData
        return tidy
    }

    override func startLoading() {
        var seen = request
        if seen.httpBody == nil, let stream = seen.httpBodyStream { seen.httpBody = Self.drain(stream) }
        Self.asked.append(seen)
        let canned = Self.answer?(seen) ?? Canned()
        let head = HTTPURLResponse(url: seen.url!, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: canned.headers)!
        guard let client else { return }
        client.urlProtocol(self, didReceive: head, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: canned.body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 2048)
        stream.open()
        defer { stream.close() }
        while stream.hasBytesAvailable {
            let got = stream.read(&chunk, maxLength: chunk.count)
            guard got > 0 else { break }
            collected.append(chunk, count: got)
        }
        return collected
    }
}

/// The dashboard API client against a pretend server.
@Suite(.serialized) struct DashboardRequestTests {
    private func client(_ mode: AuthMode = .sessionToken, canned: @escaping @Sendable (URLRequest) -> CannedURLProtocol.Canned) throws -> HermesAPI {
        CannedURLProtocol.asked = []
        CannedURLProtocol.answer = canned
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedURLProtocol.self]
        let access = CloudflareAccess(clientId: "cid", clientSecret: "csec")
        let bearer: String? = mode.usesBearer ? "at" : nil
        let signer = RequestSigner(authMode: mode, sessionToken: "tok", bearer: bearer, access: access)
        let gateway = try GatewayURL.normalize("https://h.example.com/hermes")
        return HermesAPI(gateway: gateway, signer: signer, urlSession: URLSession(configuration: configuration))
    }

    @Test func readingConfigNamesTheBotAndCarriesEveryCredential() async throws {
        let api = try client { _ in .json(#"{"config":{"approvals":{"mode":"manual"}}}"#) }
        let config: JSONValue = try await api.get("/api/config", profile: "scout")
        #expect(config["config"]?["approvals"]?["mode"]?.stringValue == "manual")
        let request = try #require(CannedURLProtocol.asked.first)
        #expect(request.url?.absoluteString == "https://h.example.com/hermes/api/config?profile=scout")
        let sent = ["X-Hermes-Session-Token", "CF-Access-Client-Id", "CF-Access-Client-Secret"].map { request.value(forHTTPHeaderField: $0) }
        #expect(sent == ["tok", "cid", "csec"])
    }

    @Test func savingConfigPutsTheNewValuesWithABearer() async throws {
        let api = try client(.oauth) { _ in .json(#"{"ok":true}"#) }
        let change: JSONValue = ["config": ["approvals": ["mode": "manual"]]]
        let reply: JSONValue = try await api.send("PUT", "/api/config", profile: "scout", json: change)
        #expect(reply["ok"]?.boolValue == true)
        let request = try #require(CannedURLProtocol.asked.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer at")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
        let sentMode = body["config"]?["approvals"]?["mode"]
        #expect(sentMode == .string("manual"))
    }

    @Test func aLoginPageInPlaceOfJSONIsNamedForWhatItIs() async throws {
        let api = try client { _ in
            .init(headers: ["Content-Type": "text/html"], body: Data("<!DOCTYPE html><html><body>Please log in</body></html>".utf8))
        }
        await #expect {
            let _: JSONValue = try await api.get("/api/status", authenticated: false)
        } throws: { error in
            guard case .htmlResponse? = error as? HermesAPIError else { return false }
            return error.localizedDescription.contains("not the Hermes dashboard API")
        }
    }

    @Test func theServersReasonSurvivesAnUnprocessableRequest() async throws {
        let api = try client { _ in .json(#"{"detail":"timeout has to be above zero"}"#, status: 422) }
        let empty: JSONValue = ["config": [:]]
        await #expect {
            let _: JSONValue = try await api.send("PUT", "/api/config", json: empty)
        } throws: { error in
            guard case .http(let status, let detail)? = error as? HermesAPIError else { return false }
            return status == 422 && detail == "timeout has to be above zero"
        }
    }
}
