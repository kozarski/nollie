import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

@MainActor
@Suite struct NotificationNavigationTests {
    /// The preview check keeps the bots marked Private (here "private" and "Moss") out of previews.
    init() { PrivateBots.useForTesting(PrivateBots(names: ["private", "moss"], settled: true)) }

    private func connection(_ address: String, id: UUID = UUID()) throws -> GatewayConnection {
        GatewayConnection(id: id, name: "Test", gateway: try GatewayURL.normalize(address), authMode: .sessionToken)
    }

    @Test func aPairedDeviceFindsItsOwnSavedConnectionByFingerprint() throws {
        let phone = try connection("https://assistant.example")
        let unrelated = try connection("https://other.example")
        let route = PendingRoute(connectionID: UUID(), gatewayFingerprint: CloudAlertTarget.fingerprint(for: phone.gateway),
                                 storedSessionID: "reply-session", profile: "default", messageRowID: 42)
        #expect(NotificationNavigation.connection(for: route, among: [unrelated, phone])?.id == phone.id)
    }

    @Test func aReusedConnectionIDCannotOpenADifferentGateway() throws {
        let saved = try connection("https://other.example")
        let original = try connection("https://assistant.example", id: saved.id)
        let route = PendingRoute(connectionID: saved.id, gatewayFingerprint: CloudAlertTarget.fingerprint(for: original.gateway),
                                 storedSessionID: "reply-session", profile: "default")
        #expect(NotificationNavigation.connection(for: route, among: [saved]) == nil)
        let legacy = PendingRoute(connectionID: saved.id, gateway: original.gateway.description, storedSessionID: "reply-session")
        #expect(NotificationNavigation.connection(for: legacy, among: [saved]) == nil)
    }

    @Test func anAmbiguousOrRemovedGatewayNeverFallsBackToTheActiveOne() throws {
        let first = try connection("https://assistant.example")
        let second = try connection("https://assistant.example")
        let route = PendingRoute(connectionID: UUID(), gatewayFingerprint: CloudAlertTarget.fingerprint(for: first.gateway),
                                 storedSessionID: "reply-session", profile: "default")
        #expect(NotificationNavigation.connection(for: route, among: [first, second]) == nil)
        #expect(NotificationNavigation.connection(for: PendingRoute(connectionID: UUID(), storedSessionID: "same"), among: [first]) == nil)
        #expect(NotificationNavigation.connection(for: PendingRoute(storedSessionID: "same"), among: [first, second]) == nil)
        #expect(NotificationNavigation.connection(for: PendingRoute(storedSessionID: "same"), among: [first])?.id == first.id)
    }

    @Test func matchingChatIDsOnOtherBotsAndGatewaysAreDifferentDestinations() {
        let id = UUID()
        let route = PendingRoute(connectionID: id, storedSessionID: "same", profile: "work")
        #expect(NotificationNavigation.matches(route, connectionID: id, profile: "work", sessionID: "same"))
        #expect(!NotificationNavigation.matches(route, connectionID: UUID(), profile: "work", sessionID: "same"))
        #expect(!NotificationNavigation.matches(route, connectionID: id, profile: "default", sessionID: "same"))
        #expect(!NotificationNavigation.matches(route, connectionID: id, profile: "work", sessionID: "newer"))
    }

    @Test func malformedAddressesAreNotTreatedAsMissingLegacyMetadata() {
        #expect(PendingRoute(notification: ["hermes": ["session_id": "ok", "connection_id": "bad"]]) == nil)
        #expect(PendingRoute(notification: ["hermes": ["session_id": "../other"]]) == nil)
        #expect(PendingRoute(notification: ["hermes": ["session_id": "ok", "profile": "all"]]) == nil)
    }

    @Test func eachTapHasItsOwnFocusAndCannotTurnIntoAReply() throws {
        let payload: [AnyHashable: Any] = ["hermes": ["session_id": "same", "profile": "work", "message_row_id": 42]]
        let first = try #require(PendingRoute(notification: payload))
        let second = try #require(PendingRoute(notification: payload))
        #expect(first.token != second.token)
        #expect(first.messageFocus?.rowID == 42)
        #expect(first.replyText == nil && first.action == nil)
    }

    @Test func historicalFocusUsesPersistedIdentityNotIdenticalReplyText() {
        let items = [TranscriptItem(id: "old-live-id", kind: .assistant(text: "Done", reasoning: nil, streaming: false), rowID: 41),
                     TranscriptItem(id: "new-live-id", kind: .assistant(text: "Done", reasoning: nil, streaming: false), rowID: 42)]
        let rows = TranscriptRowModel.build(items)
        let focus = NotificationMessageFocus(token: UUID(), rowID: 41, itemID: "new-live-id")
        #expect(focus.anchor(in: rows) == "old-live-id")
        #expect(NotificationMessageFocus(token: UUID(), rowID: 999, itemID: "old-live-id").anchor(in: rows) == nil)
    }

    @Test func sameDeviceLiveFallbackDoesNotGuessAnotherMessage() {
        let item = TranscriptItem(id: "live", kind: .assistant(text: "Done", reasoning: nil, streaming: false))
        let rows = TranscriptRowModel.build([item])
        #expect(NotificationMessageFocus(token: UUID(), rowID: nil, itemID: "live").anchor(in: rows) == "live")
        #expect(NotificationMessageFocus(token: UUID(), rowID: nil, itemID: "gone").anchor(in: rows) == nil)
    }
    @Test func aLiveCompletionCarriesOnlyAVerifiedPersistedRow() {
        let valid: JSONValue = ["status": "complete", "persisted_turn": ["complete": true, "row_ids": [12, 13], "final_assistant_row_id": 13]]
        #expect(ChatSession.completedAssistantRowID(valid) == 13)
        #expect(ChatSession.completedAssistantRowID(["status": "complete", "persisted_turn": ["complete": false, "row_ids": [13], "final_assistant_row_id": 13]]) == nil)
        #expect(ChatSession.completedAssistantRowID(["status": "complete", "persisted_turn": ["complete": true, "row_ids": [12], "final_assistant_row_id": 13]]) == nil)
        #expect(ChatSession.completedAssistantRowID(["status": "error", "persisted_turn": ["complete": true, "row_ids": [13], "final_assistant_row_id": 13]]) == nil)
    }

    @Test func localPreviewsRespectTheHideSwitchLockAndPrivateProfiles() {
        let visible = NotificationPreviewPolicy(showPreviews: true, appLockEnabled: false, cloudAlertsEnabled: true, cloudAccountFingerprint: nil)
        let hidden = NotificationPreviewPolicy(showPreviews: false, appLockEnabled: false, cloudAlertsEnabled: true, cloudAccountFingerprint: nil)
        let locked = NotificationPreviewPolicy(showPreviews: true, appLockEnabled: true, cloudAlertsEnabled: true, cloudAccountFingerprint: nil)
        #expect(LocalNotifier.showsPreview(policy: visible, profile: "default"))
        #expect(!LocalNotifier.showsPreview(policy: hidden, profile: "default"))
        #expect(!LocalNotifier.showsPreview(policy: locked, profile: "default"))
        #expect(!LocalNotifier.showsPreview(policy: nil, profile: "default"))
        #expect(!LocalNotifier.showsPreview(policy: visible, profile: " Private "))
        #expect(!LocalNotifier.showsPreview(policy: visible, profile: "Moss"))
        #expect(!LocalNotifier.showsPreview(policy: visible, profile: nil))
    }

    @Test func metadataMustNameTheExactSessionAndBotBeforeResume() {
        let route = PendingRoute(storedSessionID: "session-1", profile: "work")
        #expect(NotificationNavigation.sessionMatches(["id": "session-1", "profile": "work"], route: route))
        #expect(!NotificationNavigation.sessionMatches(["id": "session-1", "profile": "default"], route: route))
        #expect(!NotificationNavigation.sessionMatches(["id": "session-10", "profile": "work"], route: route))
        #expect(!NotificationNavigation.sessionMatches(["id": "session-1"], route: route))
    }

    @Test func outOfRangeAndFractionalReceiptIDsCannotBecomeAddresses() {
        #expect(ChatSession.completedAssistantRowID(["status": "complete", "persisted_turn": ["complete": true, "row_ids": [1.5], "final_assistant_row_id": 1.5]]) == nil)
        #expect(ChatSession.completedAssistantRowID(["status": "complete", "persisted_turn": ["complete": true, "row_ids": [1e100], "final_assistant_row_id": 1e100]]) == nil)
    }

    @Test func aResumeContinuationKeepsTheExactRequestedMessageRoute() {
        let id = UUID()
        let route = PendingRoute(connectionID: id, storedSessionID: "parent", profile: "work", messageRowID: 42)
        #expect(NotificationNavigation.matches(route, connectionID: id, profile: "work", sessionID: "child", requestedSessionID: "parent"))
        #expect(!NotificationNavigation.matches(route, connectionID: id, profile: "work", sessionID: "child"))
        #expect(!NotificationNavigation.matches(route, connectionID: id, profile: "work", sessionID: "child", requestedSessionID: "unrelated"))
    }

    @Test func aRequestedSessionAliasCannotCrossGatewayOrBot() {
        let id = UUID()
        let route = PendingRoute(connectionID: id, storedSessionID: "parent", profile: "work", messageRowID: 42)
        #expect(!NotificationNavigation.matches(route, connectionID: UUID(), profile: "work", sessionID: "child", requestedSessionID: "parent"))
        #expect(!NotificationNavigation.matches(route, connectionID: id, profile: "default", sessionID: "child", requestedSessionID: "parent"))
    }

    @Test func authenticatedInstallationIdentityMatchesDifferentAddressAliases() throws {
        var phone = try connection("https://studio.example:8443")
        phone.gatewayIdentity = try #require(GatewayIdentity.fingerprint(installID: String(repeating: "a", count: 32)))
        let local = try connection("http://127.0.0.1:9119")
        let route = PendingRoute(connectionID: local.id, gatewayFingerprint: CloudAlertTarget.fingerprint(for: local.gateway),
                                 gatewayIdentity: phone.gatewayIdentity, storedSessionID: "session", profile: "default")
        #expect(NotificationNavigation.connection(for: route, among: [phone])?.id == phone.id)
    }

    @Test func aConflictingKnownInstallationCannotFallBackToTheSameURLOrUUID() throws {
        var saved = try connection("https://studio.example")
        saved.gatewayIdentity = GatewayIdentity.fingerprint(installID: String(repeating: "b", count: 32))
        let expected = try #require(GatewayIdentity.fingerprint(installID: String(repeating: "a", count: 32)))
        let route = PendingRoute(connectionID: saved.id, gatewayFingerprint: CloudAlertTarget.fingerprint(for: saved.gateway),
                                 gatewayIdentity: expected, storedSessionID: "session", profile: "default")
        #expect(NotificationNavigation.connection(for: route, among: [saved]) == nil)
        saved.gatewayIdentity = nil
        #expect(NotificationNavigation.connection(for: route, among: [saved]) == nil)
    }

    @Test func duplicateInstallationAliasesNeedAnExactLocalConnectionID() throws {
        var first = try connection("http://127.0.0.1:9119")
        var second = try connection("https://studio.example")
        let identity = try #require(GatewayIdentity.fingerprint(installID: String(repeating: "c", count: 32)))
        first.gatewayIdentity = identity; second.gatewayIdentity = identity
        var route = PendingRoute(connectionID: UUID(), gatewayIdentity: identity, storedSessionID: "session", profile: "default")
        #expect(NotificationNavigation.connection(for: route, among: [first, second]) == nil)
        route.connectionID = second.id
        #expect(NotificationNavigation.connection(for: route, among: [first, second])?.id == second.id)
    }

    @Test func anInvalidInstallationIdentityNeverFallsBackToURLMatching() throws {
        let saved = try connection("https://studio.example")
        let route = PendingRoute(connectionID: saved.id, gatewayFingerprint: CloudAlertTarget.fingerprint(for: saved.gateway),
                                 gatewayIdentity: "invalid", storedSessionID: "session", profile: "default")
        #expect(NotificationNavigation.connection(for: route, among: [saved]) == nil)
    }

}
