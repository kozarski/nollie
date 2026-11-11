#if os(macOS) && NOLLIE_DIRECT
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Nollie

struct NativeArtifactDownloadTests {
    @Test func pinnedDownloadsAndApprovedReleaseRedirectsAreAllowed() {
        #expect(NativeArtifactDownloadPolicy.allows(NativeSetupPlan.hermes.url))
        #expect(NativeArtifactDownloadPolicy.allows(NativeSetupPlan.uv.url))
        #expect(NativeArtifactDownloadPolicy.allows(URL(string: "https://release-assets.githubusercontent.com/asset?fixture=value")!))
        #expect(NativeArtifactDownloadPolicy.allows(URL(string: "https://objects.githubusercontent.com/asset")!))
    }

    @Test(arguments: ["http://codeload.github.com/archive", "https://codeload.github.com.evil.example/archive",
                      "https://example.com/archive", "https://user:password@github.com/archive",
                      "https://github.com:8443/archive", "file:///tmp/archive"])
    func otherHostsAndCredentialBearingRedirectsAreRejected(_ text: String) {
        #expect(!NativeArtifactDownloadPolicy.allows(URL(string: text)!))
    }

    @Test func httpErrorsCarryTheActualStatusWithoutResponseContent() {
        #expect(NativeArtifactDownloadPolicy.httpFailure(403).contains("HTTP 403"))
        #expect(NativeArtifactDownloadPolicy.httpFailure(503).contains("HTTP 503"))
        #expect(!NativeArtifactDownloadPolicy.httpFailure(nil).contains("HTTP 0"))
    }

    @Test func transportErrorsDoNotRevealTheirURLOrDescription() {
        let fixture = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                              userInfo: [NSLocalizedDescriptionKey: "private fixture", NSURLErrorFailingURLErrorKey: "https://example.com/?secret=fixture"])
        let message = NativeArtifactDownloadPolicy.transportFailure(fixture)
        #expect(message.contains("-1001"))
        #expect(!message.contains("private") && !message.contains("secret") && !message.contains("example.com"))
        #expect(!NativeArtifactDownloadPolicy.transportFailure(NSError(domain: "private fixture", code: 7)).contains("private"))
    }

    private static func artifact(_ body: Data, path: String) -> NativeSetupPlan.Artifact {
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return NativeSetupPlan.Artifact(id: "fixture", version: "1", url: URL(string: "https://github.com/fixture/" + path)!,
                                        sha256: hash, bytes: body.count)
    }

    /// The first download of Hermes once hung for 12 minutes. A download with no bytes for the stall
    /// limit now ends with the plain network error, so Try again shows.
    @Test func aDownloadThatStopsMovingEndsAfterTheStallLimit() async {
        let body = Data(repeating: 7, count: 4_096)
        let started = Date()
        do {
            _ = try await NativeArtifactDownload.fetch(Self.artifact(body, path: "stall-" + UUID().uuidString),
                                                       stallLimit: 0.6, protocolClasses: [StalledRelease.self])
            Issue.record("A stalled download must not finish")
        } catch let failure as ConfigurationBackup.Failure {
            #expect(failure.message.contains("-1001"))
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aSlowDownloadThatKeepsMovingIsNotCutOff() async throws {
        // Twelve pieces a quarter of a second apart: three seconds in all, five times the stall limit.
        let body = Data((0..<12_288).map { UInt8($0 % 251) })
        let path = "trickle-" + UUID().uuidString
        TrickleRelease.bodies.withLock { $0[path] = body }
        let data = try await NativeArtifactDownload.fetch(Self.artifact(body, path: path),
                                                          stallLimit: 0.6, protocolClasses: [TrickleRelease.self])
        #expect(data == body)
    }
}

/// Sends headers and the first bytes, then nothing more.
private final class StalledRelease: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "4096"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 512))
    }
    override func stopLoading() {}
}

/// Sends the body in small pieces, a quarter of a second apart.
private final class TrickleRelease: URLProtocol, @unchecked Sendable {
    static let bodies = Mutex<[String: Data]>([:])
    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let body = Self.bodies.withLock { $0[url.lastPathComponent] } ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let pieces = stride(from: 0, to: body.count, by: 1_024).map { body[$0..<min($0 + 1_024, body.count)] }
        for (index, piece) in pieces.enumerated() {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25 * Double(index + 1)) { [self] in
                guard !stopped.withLock({ $0 }) else { return }
                client?.urlProtocol(self, didLoad: Data(piece))
                if index == pieces.count - 1 { client?.urlProtocolDidFinishLoading(self) }
            }
        }
    }
    override func stopLoading() { stopped.withLock { $0 = true } }
}
#endif
