import Foundation
import Testing
@testable import NollieCore

/// What a shared diagnostics file may never hold.
@Suite struct LogRedactorTests {
    private func hides(_ secret: String, in text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let result = LogRedactor.redact(text)
        #expect(!result.contains(secret), "\(result)", sourceLocation: sourceLocation)
    }

    @Test func bearerTokens() {
        hides("abcDEF123456789xyz", in: "Authorization: Bearer abcDEF123456789xyz")
        hides("abcDEF123456789xyz", in: "sent header bearer abcDEF123456789xyz to gateway")
        #expect(LogRedactor.redact("Bearer abcDEF123456789xyz") == "Bearer <redacted>")
    }

    @Test func namedSecrets() {
        hides("hunter2hunter2", in: "login failed password=hunter2hunter2 for user")
        hides("s3cretValue99", in: "GET /api?token=s3cretValue99&x=1")
        hides("abc123def456", in: #"{"access_token": "abc123def456", "ok": true}"#)
        hides("deadbeefcafe", in: "HERMES_DASHBOARD_SESSION_TOKEN=deadbeefcafe")
        hides("topsecretvalue", in: "api_key: topsecretvalue")
        hides("cookieValue77", in: "cookie=cookieValue77; path=/")
        // The words around a secret stay readable.
        #expect(LogRedactor.redact("GET /api?token=s3cret&x=1").contains("x=1"))
    }

    @Test func signInCallbacks() {
        hides("one-time-code-8812", in: "callback nollie://signin?code=one-time-code-8812&state=statevalue99")
        hides("statevalue99", in: "callback nollie://signin?code=one-time-code-8812&state=statevalue99")
    }

    @Test func knownKeyShapes() {
        hides("sk-ant-api03-AbCdEfGhIjKlMnOpQrSt", in: "key sk-ant-api03-AbCdEfGhIjKlMnOpQrSt used")
        hides("sk-1234567890abcdefghij", in: "using sk-1234567890abcdefghij now")
        hides("ghp_1234567890abcdefghijklmnopqrstuvwxyz", in: "remote ghp_1234567890abcdefghijklmnopqrstuvwxyz")
        hides("github_pat_11ABCDEFG0abcdefghijkl_mnop", in: "github_pat_11ABCDEFG0abcdefghijkl_mnop")
        hides("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdef", in: "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdef")
    }

    @Test func longHexAndBase64() {
        let hex = String(repeating: "a1b2c3d4", count: 8)
        hides(hex, in: "token was \(hex) at start")
        let base64 = "Zm9vYmFyQmF6UXV4MTIzNDU2Nzg5MEFCQ0RFRkdISUo="
        hides(base64, in: "blob \(base64) end")
    }

    @Test func emailAddresses() {
        hides("corey@example.com", in: "signed in as corey@example.com today")
        hides("first.last+tag@mail.example.co.uk", in: "from first.last+tag@mail.example.co.uk")
    }

    @Test func ordinaryTextAndPathsAreLeftAlone() {
        let lines = [
            "2026-10-22T10:11:12.345+02:00 notice chat: Reply arrived in 412 ms",
            "Connected to gateway, 3 bots, tokens=128",
            "/Users/sam/Library/Application Support/Nollie/Setups/Packages/NollieCore/Sources/Logging",
            "D6A1B2C3-0000-4000-8000-ABCDEF123456 is a chat id",
        ]
        for line in lines { #expect(LogRedactor.redact(line) == line) }
    }

    @Test func redactingTwiceChangesNothing() {
        let once = LogRedactor.redact("password=abc12345 and corey@example.com")
        #expect(LogRedactor.redact(once) == once)
    }
}
