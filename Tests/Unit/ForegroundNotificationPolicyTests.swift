import Foundation
import Testing
import UserNotifications
@testable import Nollie
@testable import NollieCore

@MainActor
@Suite struct ForegroundNotificationPolicyTests {
    /// An alert's target is only kept for a bot that isn't Private, so the list is set here.
    init() { PrivateBots.useForTesting(PrivateBots(names: ["private", "moss"], settled: true)) }

    private let alerts: UNNotificationPresentationOptions = [.banner, .sound, .list]

    private func connection(_ address: String = "https://assistant.example", identity: String? = nil) throws -> GatewayConnection {
        var connection = GatewayConnection(id: UUID(), name: "Fixture", gateway: try GatewayURL.normalize(address), authMode: .sessionToken)
        connection.gatewayIdentity = identity
        return connection
    }

    private func context(_ connection: GatewayConnection, profile: String = "default", sessions: Set<String> = ["open-chat"]) -> ForegroundNotificationPolicy.Context {
        .init(connections: [connection], visible: .init(connection: connection, profile: profile, sessionIDs: sessions))
    }

    private func event(_ connection: GatewayConnection, profile: String = "default", session: String = "open-chat") -> CloudAlertEvent {
        let target = CloudAlertTarget(connectionID: connection.id, gatewayFingerprint: CloudAlertTarget.fingerprint(for: connection.gateway),
                                      profile: profile, sessionID: session, gatewayIdentity: connection.gatewayIdentity)
        return CloudAlertEvent(source: "fixture", key: session, kind: .replyReady, now: Date(), target: target)
    }

    /// A helper that started using the Mac is worth a banner on the iPhone even in the chat it
    /// came from; the Mac it is about only lists it.
    @Test func aHelperStartingOnTheMacShowsABanner() throws {
        let connection = try connection()
        let target = CloudAlertTarget(connectionID: connection.id, gatewayFingerprint: CloudAlertTarget.fingerprint(for: connection.gateway),
                                      profile: "default", sessionID: "open-chat")
        let started = CloudAlertEvent(source: "fixture", key: "computer", kind: .computerStarted, now: Date(), target: target)
        #expect(ForegroundNotificationPolicy.options(event: started, context: context(connection)) == (DeviceWords.isMac ? [.list] : [.banner, .list]))
    }

    @Test func theOpenConversationHasNoBannerSoundOrListEntry() throws {
        let connection = try connection()
        #expect(ForegroundNotificationPolicy.options(event: event(connection), context: context(connection)).isEmpty)
    }

    @Test func aDifferentConversationStillAlerts() throws {
        let connection = try connection()
        #expect(ForegroundNotificationPolicy.options(event: event(connection, session: "other-chat"), context: context(connection)) == alerts)
    }

    @Test func theSameSessionNameOnAnotherBotStillAlerts() throws {
        let connection = try connection()
        #expect(ForegroundNotificationPolicy.options(event: event(connection, profile: "work"), context: context(connection)) == alerts)
    }

    @Test func theSameSessionNameOnAnotherGatewayStillAlerts() throws {
        let first = try connection(), second = try connection("https://other.example")
        var context = context(first)
        context.connections.append(second)
        #expect(ForegroundNotificationPolicy.options(event: event(second), context: context) == alerts)
    }

    @Test func aPairedAddressAliasUsesTheVerifiedGatewayIdentity() throws {
        let identity = String(repeating: "a", count: 64)
        let mac = try connection("http://127.0.0.1:9119", identity: identity)
        let phone = try connection("https://assistant.example", identity: identity)
        #expect(ForegroundNotificationPolicy.options(event: event(mac), context: context(phone)).isEmpty)
    }

    @Test func anUnverifiedOrAmbiguousGatewayStaysQuietWithoutGuessing() throws {
        let first = try connection(), second = try connection()
        let origin = try connection()
        var context = context(first)
        context.connections.append(second)
        let missing = try connection("https://missing.example")
        #expect(ForegroundNotificationPolicy.options(event: event(origin), context: context) == [.list])
        #expect(ForegroundNotificationPolicy.options(event: event(missing), context: context) == [.list])
    }

    @Test func aCompressedConversationRecognizesItsOriginalSession() throws {
        let connection = try connection()
        let context = context(connection, sessions: ["compressed-chat", "open-chat"])
        #expect(ForegroundNotificationPolicy.options(event: event(connection), context: context).isEmpty)
        #expect(ForegroundNotificationPolicy.options(event: event(connection, session: "compressed-chat"), context: context).isEmpty)
    }

    @Test func leavingTheChatDuringLookupDoesNotSuppressItsAlert() throws {
        let connection = try connection()
        let afterNavigation = ForegroundNotificationPolicy.Context(connections: [connection], visible: nil)
        #expect(ForegroundNotificationPolicy.options(event: event(connection), context: afterNavigation) == alerts)
    }

    @Test func aSheetOverTheSameConversationAllowsItsAlertUntilDismissed() throws {
        let connection = try connection()
        let update = event(connection)
        var context = context(connection)
        #expect(ForegroundNotificationPolicy.options(event: update, context: context).isEmpty)
        #expect(ForegroundNotificationPolicy.isReading(connectionID: connection.id, profile: "default", sessionID: "open-chat", context: context))
        context.isConversationObscured = true
        #expect(ForegroundNotificationPolicy.options(event: update, context: context) == alerts)
        #expect(!ForegroundNotificationPolicy.isReading(connectionID: connection.id, profile: "default", sessionID: "open-chat", context: context),
                "A reply received behind a sheet must not be cleared from Notification Center")
        let legacy = PendingRoute(connectionID: connection.id, storedSessionID: "open-chat", profile: "default")
        #expect(ForegroundNotificationPolicy.options(route: legacy, context: context) == alerts)
        context.isConversationObscured = false
        #expect(ForegroundNotificationPolicy.options(event: update, context: context).isEmpty)
        context.visible = nil
        #expect(ForegroundNotificationPolicy.options(event: update, context: context) == alerts,
                "Dismissing a sheet must not suppress notifications when the app or conversation is out of sight")
        #expect(!ForegroundNotificationPolicy.isReading(connectionID: connection.id, profile: "default", sessionID: "open-chat", context: context))
    }

    @Test func aSheetOpenedDuringTheCloudLookupUsesTheCurrentVisibility() async throws {
        let connection = try connection()
        let gate = LookupGate()
        var current = context(connection)
        let task = Task {
            let event = await ForegroundNotificationLookup.resolve(load: { await gate.load() })
            return ForegroundNotificationPolicy.options(event: event, context: current)
        }
        await gate.started()
        current.isConversationObscured = true
        gate.finish(event(connection))
        #expect(await task.value == alerts)
    }

    @Test func anUnresolvedGenericCloudUpdateDoesNotInterrupt() throws {
        let connection = try connection()
        #expect(ForegroundNotificationPolicy.options(event: nil, context: context(connection)) == [.list])
        let old = CloudAlertEvent(source: "fixture", key: "old", kind: .replyReady, now: Date())
        #expect(ForegroundNotificationPolicy.options(event: old, context: context(connection)) == [.list])
    }

    @Test func explicitNotificationTestsRemainVisible() throws {
        let connection = try connection()
        let test = CloudAlertEvent(source: "fixture", key: "test", kind: .test, now: Date())
        #expect(ForegroundNotificationPolicy.options(event: test, context: context(connection)) == alerts)
        #expect(ForegroundNotificationPolicy.options(route: nil, isTest: true, context: context(connection)) == alerts)
    }

    @Test func legacyLocalAndCompanionPayloadsUseTheSameConversationRule() throws {
        let connection = try connection()
        let payload: [AnyHashable: Any] = ["hermes": ["connection_id": connection.id.uuidString,
                                                     "session_id": "open-chat", "profile": "default"]]
        let route = try #require(PendingRoute(notification: payload))
        #expect(ForegroundNotificationPolicy.options(route: route, context: context(connection)).isEmpty)
        var other = route
        other.storedSessionID = "other-chat"
        #expect(ForegroundNotificationPolicy.options(route: other, context: context(connection)) == alerts)
    }

    @Test func aTimelyLookupReturnsTheExactEvent() async throws {
        let connection = try connection()
        let expected = event(connection)
        let result = await ForegroundNotificationLookup.resolve(load: { expected })
        #expect(result == expected)
    }

    @Test func aSlowLookupReturnsQuietlyWithoutWaitingForCloudKit() async throws {
        let connection = try connection()
        let gate = LookupGate()
        let result = await ForegroundNotificationLookup.resolve(load: { await gate.load() }, waitForTimeout: {
            await gate.started()
        })
        #expect(result == nil)
        #expect(ForegroundNotificationPolicy.options(event: result, context: context(connection)) == [.list])
        gate.finish(event(connection))
        await Task.yield()
    }

    @Test func cancellationReturnsEvenWhenTheReadIgnoresCancellation() async throws {
        let connection = try connection()
        let gate = LookupGate()
        let task = Task { await ForegroundNotificationLookup.resolve(load: { await gate.load() }) }
        await gate.started()
        task.cancel()
        let result = await task.value
        #expect(result == nil)
        gate.finish(event(connection))
        await Task.yield()
    }

    @MainActor
    private final class LookupGate {
        private var read: CheckedContinuation<CloudAlertEvent?, Never>?
        private var waiting: CheckedContinuation<Void, Never>?

        func load() async -> CloudAlertEvent? {
            await withCheckedContinuation { continuation in
                read = continuation
                waiting?.resume(); waiting = nil
            }
        }

        func started() async {
            if read != nil { return }
            await withCheckedContinuation { waiting = $0 }
        }

        func finish(_ event: CloudAlertEvent) {
            read?.resume(returning: event); read = nil
        }
    }
}
