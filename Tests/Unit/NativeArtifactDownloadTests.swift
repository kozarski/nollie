#if os(macOS) && NOLLIE_DIRECT
import Foundation
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
}
#endif
