import Foundation
import Testing
import NollieCore

struct PushRelayEnrollmentTests {
    @Test(arguments: ["", "short", String(repeating: "a", count: 129), String(repeating: "a", count: 32) + "\nInjected: true", String(repeating: "é", count: 32)])
    func rejectsMalformedInvitation(_ value: String) {
        #expect(!PushRelay.isValidInvitation(value))
    }

    @Test func acceptsURLSafeInvitation() {
        #expect(PushRelay.isValidInvitation(String(repeating: "aB09_-", count: 8)))
    }

    @Test func enrollmentFailureHasAnActionableMessage() throws {
        let data = Data(#"{"error":"enrollment_required"}"#.utf8)
        let error = try #require(PushRelay.registrationError(status: 401, data: data))
        if case .invitationRequired = error {} else { Issue.record("Missing invitation must ask for enrollment.") }
    }

    @Test func serverMessagesCannotLeakIntoTheInterface() throws {
        let data = Data(#"{"error":"untrusted secret and implementation details"}"#.utf8)
        let error = try #require(PushRelay.registrationError(status: 500, data: data))
        #expect(error.localizedDescription == "Notifications could not connect. Try again in a moment.")
        #expect(PushRelay.registrationError(status: 200, data: Data()) == nil)
    }
}
