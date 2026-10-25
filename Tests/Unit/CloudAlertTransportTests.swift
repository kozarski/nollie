import CloudKit
import Foundation
import Testing
import UserNotifications
import NollieCore
@testable import Nollie

@MainActor
struct CloudAlertTransportTests {
    /// These checks keep the bots marked Private (here "private" and "Moss") out of alerts.
    init() { PrivateBots.useForTesting(PrivateBots(names: ["private", "moss"], settled: true)) }

    @Test func freshOffAndDemoNeverAccessCloudKit() async {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        #expect(!transport.isEnabled)
        await transport.refresh()
        await transport.refresh(checkTestVisibility: true)
        await transport.disable()
        #expect(await transport.sendTest() == nil)
        #expect(fixture.store.calls.isEmpty)

        let demo = fixture.make(isDemo: true)
        await demo.enable()
        await demo.refresh()
        await demo.refresh(checkTestVisibility: true)
        #expect(!demo.isEnabled)
        #expect(fixture.store.calls.isEmpty)
        #expect(fixture.permissions.requests == 0)
    }

    @Test func explicitEnableCreatesGenericCreationSubscriptionAndDoesNotReprompt() async {
        let fixture = CloudAlertFixture()
        fixture.permissions.status = .notDetermined
        let transport = fixture.make()
        await transport.enable()
        #expect(transport.isEnabled)
        #expect(transport.state == .ready)
        #expect(fixture.permissions.requests == 1)
        #expect(fixture.permissions.registrations == 1)
        #expect(fixture.store.calls.contains("subscribe"))
        await transport.refresh()
        await transport.refresh()
        #expect(fixture.permissions.requests == 1)
        #expect(fixture.permissions.registrations == 1)
        #expect(fixture.store.calls.filter { $0 == "subscribe" }.count == 1)

        let subscription = CloudKitAlertStore.makeSubscription()
        #expect(subscription.recordType == CloudAlertEvent.recordType)
        #expect(subscription.querySubscriptionOptions == [.firesOnRecordCreation])
        #expect(subscription.notificationInfo?.alertBody == "There’s an update waiting for you in Nollie.")
        #expect(subscription.notificationInfo?.desiredKeys?.isEmpty != false)
        #expect(subscription.notificationInfo?.shouldSendContentAvailable == false)
    }

    @Test func deniedPermissionIsSeparateFromAccountWideEnable() async {
        let fixture = CloudAlertFixture()
        fixture.permissions.status = .denied
        let transport = fixture.make()
        await transport.enable()
        #expect(transport.isEnabled)
        #expect(transport.state == .notificationsDenied)
        #expect(fixture.permissions.requests == 0)
        #expect(fixture.permissions.registrations == 0)
        fixture.permissions.status = .authorized
        await transport.refresh()
        #expect(transport.state == .ready)
        #expect(fixture.permissions.registrations == 1)
    }

    @Test func accountChangeCannotRestoreConsentOrPublishToNewAccount() async {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        await transport.enable()
        fixture.store.account = "different-account-hash"
        #expect(await transport.publish(eventKey: "outcome-1", profile: "default", kind: .replyReady) == nil)
        #expect(!transport.isEnabled)
        #expect(transport.state == .accountChanged)
        #expect(fixture.store.events.isEmpty)
        #expect(fixture.defaults.object(forKey: CloudAlertTransport.accountKey) == nil)
        fixture.store.calls.removeAll()
        await transport.refresh()
        #expect(fixture.store.calls.isEmpty)
        let reopened = fixture.make()
        #expect(!reopened.isEnabled)
    }

    @Test func accountNotificationInvalidatesPendingWorkWithoutCloudReads() async {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        await transport.enable()
        fixture.store.calls.removeAll()
        transport.accountDidChange()
        #expect(!transport.isEnabled)
        #expect(transport.state == .accountChanged)
        #expect(fixture.store.calls.isEmpty)
    }

    @Test func disableDuringEnableDoesNotLeaveSubscriptionEnabled() async {
        let fixture = CloudAlertFixture()
        let gate = CloudAlertTestGate()
        fixture.store.subscribeGate = gate
        let transport = fixture.make()
        let enabling = Task { await transport.enable() }
        await gate.waitForEntry()
        let disabling = Task { await transport.disable() }
        // Let disable invalidate enable before releasing its in-flight subscription request.
        await Task.yield()
        gate.open()
        await enabling.value
        await disabling.value
        #expect(!transport.isEnabled)
        #expect(!fixture.store.remoteEnabled)
        #expect(!fixture.store.subscribed)
        #expect(!fixture.store.calls.contains("enabled:true"))
    }

    @Test func privateProfilesAreRejectedBeforeCloudAccess() async {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        await transport.enable()
        fixture.store.calls.removeAll()
        for profile in ["private", " PRIVATE ", "Moss", ""] {
            #expect(await transport.publish(eventKey: "private-key", profile: profile, kind: .replyReady) == nil)
        }
        #expect(fixture.store.calls.isEmpty)
    }

    @Test func stableOpaqueEventIDIsIdempotentAndContainsNoSourceNames() async throws {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        await transport.enable()
        let first = try #require(await transport.publish(eventKey: "session-secret/outcome-42", profile: "forager", kind: .replyReady))
        let second = await transport.publish(eventKey: "session-secret/outcome-42", profile: "forager", kind: .replyReady)
        #expect(first == second)
        #expect(CloudAlertEvent.isValidID(first))
        #expect(!first.contains("session-secret"))
        #expect(fixture.store.events.count == 1)
        #expect(fixture.store.creations == 1)
        #expect(fixture.store.cleanups.count == 1)
        let event = try #require(fixture.store.events[first])
        #expect(event.expiresAt.timeIntervalSince(event.createdAt) == 7 * 24 * 3600)
        #expect(event.source == CloudAlertEvent.digest(fixture.source))
    }

    /// "Scout started using your Mac": routed to the task's chat, with a short preview and no
    /// secret in its id; a private bot never gets one.
    @Test func computerStartedCarriesItsChatAndAShortPreview() async throws {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        await transport.enable()
        var connection = GatewayConnection(id: UUID(), name: "Mac", gateway: try GatewayURL.normalize("http://127.0.0.1:9119"), authMode: .sessionToken)
        connection.gatewayIdentity = String(repeating: "a", count: 64)
        let started = Date(timeIntervalSince1970: 1_792_000_000)
        // As Nollie Computer names the task's chat.
        await transport.publishComputerStarted(profile: "career", botName: "Scout", sessionID: "career/20261021_101500_abc",
                                               startedAt: started, connection: connection)
        let event = try #require(fixture.store.events.values.first)
        #expect(event.kind == .computerStarted)
        #expect(event.preview == CloudAlertPreview(title: "Scout", body: "Scout started using your Mac."))
        #expect(event.target?.profile == "career")
        #expect(event.target?.sessionID == "20261021_101500_abc")
        #expect(event.target?.connectionID == connection.id)
        #expect(event.target?.isValid == true)
        #expect(!event.id.contains("career"))
        await transport.publishComputerStarted(profile: "private", botName: "Moss", sessionID: "20261021_101500_def",
                                               startedAt: started, connection: connection)
        #expect(fixture.store.events.count == 1)
    }

    @Test func remoteDisableStopsPublisherWithoutRecreatingSubscription() async {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        await transport.enable()
        fixture.store.remoteEnabled = false
        fixture.store.calls.removeAll()
        #expect(await transport.publish(eventKey: "new", profile: "default", kind: .needsAttention) == nil)
        #expect(!transport.isEnabled)
        #expect(transport.state == .off)
        #expect(!fixture.store.calls.contains("subscribe"))
        #expect(fixture.store.events.isEmpty)
    }

    @Test func testStorageDoesNotClaimReceiptAndOwnDeviceCannotAcknowledge() async throws {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        await transport.enable()
        let id = try #require(await transport.sendTest())
        let stored = try #require(await transport.checkTest(id))
        #expect(stored.stored)
        #expect(stored.receivedAt == nil)
        #expect(stored.openedAt == nil)
        #expect(stored.message.contains("not confirmed"))
        await transport.recordReceipt(eventID: id, opened: true)
        #expect(fixture.store.receipts.isEmpty)

        let other = CloudAlertFixture(store: fixture.store)
        let receiver = other.make()
        await receiver.enable()
        await receiver.recordReceipt(eventID: id, opened: false)
        let received = try #require(await transport.checkTest(id))
        #expect(received.receivedAt != nil)
        #expect(received.openedAt == nil)
        await receiver.recordReceipt(eventID: id, opened: true)
        #expect(await transport.checkTest(id)?.openedAt != nil)
    }

    @Test func unrelatedNotificationAndMalformedIDsAreIgnored() async {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        await transport.enable()
        fixture.store.calls.removeAll()
        #expect(CloudAlertTransport.eventID(from: ["hermes": ["kind": "reply"]]) == nil)
        #expect(await transport.checkTest("some-other-record") == nil)
        await transport.recordReceipt(eventID: "oa1_../../data", opened: true)
        #expect(fixture.store.calls.isEmpty)
        let id = CloudAlertEvent(source: "source", key: "test", kind: .test, now: .now).id
        #expect(CloudAlertTransport.recognizedEventID(container: CloudKitAlertStore.containerIdentifier,
            subscription: CloudKitAlertStore.subscriptionID, scope: .private, recordID: id) == id)
        #expect(CloudAlertTransport.recognizedEventID(container: "iCloud.unrelated",
            subscription: CloudKitAlertStore.subscriptionID, scope: .private, recordID: id) == nil)
        #expect(CloudAlertTransport.recognizedEventID(container: CloudKitAlertStore.containerIdentifier,
            subscription: CloudKitAlertStore.subscriptionID, scope: .public, recordID: id) == nil)
        #expect(CloudAlertTransport.recognizedEventID(container: CloudKitAlertStore.containerIdentifier,
            subscription: "unrelated-subscription", scope: .private, recordID: id) == nil)
    }

    @Test func failedRemoteRegistrationCanRetryOnActivationWithoutPrompting() async {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        await transport.enable()
        transport.remoteRegistrationFailed()
        #expect(transport.state == .failed)
        await transport.refresh()
        #expect(transport.state == .ready)
        #expect(fixture.permissions.registrations == 2)
        #expect(fixture.permissions.requests == 0)
    }

    @Test func permissionAndSavedSubscriptionDoNotClaimAPNsSuccess() async {
        let fixture = CloudAlertFixture()
        fixture.permissions.autoConfirm = false
        let transport = fixture.make()
        await transport.enable()
        #expect(transport.isEnabled)
        #expect(transport.state == .registering)
        #expect(transport.registrationState == .waiting)
        #expect(transport.subscriptionState == .valid)
        await transport.refresh()
        #expect(fixture.permissions.registrations == 1)
        #expect(transport.state == .registering)
        transport.remoteRegistrationSucceeded()
        #expect(transport.registrationState == .registered)
        #expect(transport.state == .ready)
    }

    @Test func priorSystemRegistrationIsRecognizedWithoutAnotherRequest() async {
        let fixture = CloudAlertFixture()
        fixture.permissions.systemRegistered = true
        let transport = fixture.make()
        await transport.enable()
        #expect(transport.state == .ready)
        #expect(transport.registrationState == .registered)
        #expect(fixture.permissions.registrations == 0)
    }

    @Test func refreshDetectsDeletedOrChangedSubscriptionWithoutSilentRecreation() async {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        await transport.enable()
        fixture.store.subscribed = false
        await transport.refresh()
        #expect(transport.state == .failed)
        #expect(transport.subscriptionState == .missing)
        #expect(transport.issue?.contains("missing") == true)
        #expect(fixture.store.calls.filter { $0 == "subscribe" }.count == 1)
        transport.remoteRegistrationSucceeded()
        #expect(transport.state == .failed)
        fixture.store.subscribed = true
        fixture.store.subscriptionValid = false
        await transport.refresh()
        #expect(transport.subscriptionState == .invalid)
        #expect(transport.state == .failed)
    }

    @Test func registrationCallbackCannotRestoreDisabledOrChangedAccount() async {
        let fixture = CloudAlertFixture()
        fixture.permissions.autoConfirm = false
        let transport = fixture.make()
        await transport.enable()
        await transport.disable()
        transport.remoteRegistrationSucceeded()
        #expect(transport.state == .off)
        #expect(!transport.isEnabled)
        #expect(transport.accountComparison == nil)
        await transport.enable()
        transport.accountDidChange()
        transport.remoteRegistrationSucceeded()
        #expect(transport.state == .accountChanged)
        #expect(!transport.isEnabled)
    }

    @Test func fetchedSubscriptionMustHaveExactGenericVisibleAlertContract() {
        #expect(CloudKitAlertStore.subscriptionState(nil) == .missing)
        #expect(CloudKitAlertStore.subscriptionState(CloudKitAlertStore.makeSubscription()) == .valid)
        let changed = CloudKitAlertStore.makeSubscription()
        changed.notificationInfo?.alertBody = nil
        #expect(CloudKitAlertStore.subscriptionState(changed) == .invalid)
        let silent = CloudKitAlertStore.makeSubscription()
        silent.notificationInfo?.shouldSendContentAvailable = true
        #expect(CloudKitAlertStore.subscriptionState(silent) == .invalid)
        let unrelated = CKQuerySubscription(recordType: "Other", predicate: NSPredicate(value: true),
            subscriptionID: CloudKitAlertStore.subscriptionID, options: [.firesOnRecordCreation])
        unrelated.notificationInfo = CloudKitAlertStore.makeSubscription().notificationInfo
        #expect(CloudKitAlertStore.subscriptionState(unrelated) == .invalid)
    }

    @Test func failedDisableIsHonestAndDoesNotResumeLocalPublishing() async {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        await transport.enable()
        fixture.store.failWrites = true
        await transport.disable()
        #expect(!transport.isEnabled)
        #expect(transport.issue?.contains("other devices") == true)
        #expect(await transport.sendTest() == nil)
    }

    @Test func explicitVisibilityCheckReadsOtherDeviceTestWithoutAcknowledgingOrResubscribing() async throws {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        await transport.enable()
        let test = CloudAlertEvent(source: "other-device", key: "test", kind: .test,
                                   now: Date(timeIntervalSince1970: 1_800_000_000))
        fixture.store.events[test.id] = test
        fixture.store.calls = []
        await transport.refresh()
        #expect(!fixture.store.calls.contains("latest-test"))
        await transport.refresh(checkTestVisibility: true)
        let visible = try #require(transport.visibleTest)
        #expect(visible.shortID == String(test.id.dropFirst(4).prefix(12)))
        #expect(visible.createdAt == test.createdAt)
        #expect(!visible.isThisDevice)
        #expect(transport.visibilityCheckedAt != nil)
        #expect(fixture.store.receipts.isEmpty)
        #expect(!fixture.store.calls.contains("acknowledge"))
        #expect(!fixture.store.calls.contains("subscribe"))
        #expect(transport.callbackDiagnostics.callbacks.isEmpty)
    }

    @Test func latestVisibleTestFiltersExpiredAndNonTestEventsAndReportsBoundedLookup() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let older = CloudAlertEvent(source: "a", key: "older", kind: .test, now: now.addingTimeInterval(-50))
        let newest = CloudAlertEvent(source: "b", key: "newest", kind: .test, now: now.addingTimeInterval(-10))
        let reply = CloudAlertEvent(source: "c", key: "reply", kind: .replyReady, now: now)
        let expired = CloudAlertEvent(id: older.id, source: older.source, kind: .test,
                                      createdAt: now, expiresAt: now)
        let lookup = CloudAlertTestLookup.select(from: [older, reply, expired, newest], at: now, isLimited: true)
        #expect(lookup.latest == newest)
        #expect(lookup.isLimited)
        #expect(CloudAlertTestLookup.select(from: [expired, reply], at: now, isLimited: false).latest == nil)
        #expect(CloudAlertVisibleTest(event: newest, source: "b").isThisDevice)
    }

    @Test func visibilityFailureDoesNotPretendNoRecordsOrBreakReadyPushState() async {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        await transport.enable()
        fixture.store.failLatestTest = true
        await transport.refresh(checkTestVisibility: true)
        #expect(transport.visibleTest == nil)
        #expect(transport.visibilityCheckedAt == nil)
        #expect(transport.visibilityIssue != nil)
        #expect(transport.state == .ready)
        #expect(fixture.store.receipts.isEmpty)
    }

    @Test func disablingDuringVisibilityReadDiscardsItsResult() async {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        await transport.enable()
        let test = CloudAlertEvent(source: "other", key: "test", kind: .test,
                                   now: Date(timeIntervalSince1970: 1_800_000_000))
        fixture.store.events[test.id] = test
        let gate = CloudAlertTestGate()
        fixture.store.latestTestGate = gate
        let refresh = Task { await transport.refresh(checkTestVisibility: true) }
        await gate.waitForEntry()
        let disable = Task { await transport.disable() }
        // The disable invalidates the read before its queued cloud work begins.
        while transport.isEnabled { await Task.yield() }
        gate.open()
        await refresh.value
        await disable.value
        #expect(transport.visibleTest == nil)
        #expect(transport.visibilityCheckedAt == nil)
        #expect(transport.state == .off)
    }

    @Test func parserDiagnosticsKeepEveryRoutingGuard() {
        let id = CloudAlertEvent(source: "source", key: "test", kind: .test, now: .now).id
        let container = CloudKitAlertStore.containerIdentifier
        let subscription = CloudKitAlertStore.subscriptionID
        #expect(CloudAlertTransport.inspectPayload(["hermes": ["kind": "test"]]).result == .notCloudKit)
        let accepted = CloudAlertTransport.inspectFields(container: container, subscription: subscription,
                                                         scope: .private, recordID: id)
        #expect(accepted == .init(result: .accepted, eventID: id))
        let rejected: [CloudAlertPayloadInspection] = [
            CloudAlertTransport.inspectFields(container: nil, subscription: subscription, scope: .private, recordID: id),
            CloudAlertTransport.inspectFields(container: container, subscription: nil, scope: .private, recordID: id),
            CloudAlertTransport.inspectFields(container: container, subscription: subscription, scope: .public, recordID: id),
            CloudAlertTransport.inspectFields(container: container, subscription: subscription, scope: .private, recordID: "invalid")
        ]
        #expect(rejected.map(\.result) == [.containerMismatch, .subscriptionMismatch, .scopeMismatch, .invalidRecord])
        #expect(rejected.allSatisfy { $0.eventID == nil })
    }

    @Test func callbackCountersStayLocalAndResetWhenConsentEnds() async {
        let fixture = CloudAlertFixture()
        let transport = fixture.make()
        transport.recordCallback(.foreground, result: .accepted)
        #expect(transport.callbackDiagnostics.callbacks.isEmpty)
        await transport.enable()
        fixture.store.calls = []
        transport.recordCallback(.foreground, result: .containerMismatch)
        transport.recordCallback(.remote, result: .accepted)
        #expect(transport.callbackDiagnostics.callbacks[.foreground] == 1)
        #expect(transport.callbackDiagnostics.results[.containerMismatch] == 1)
        #expect(transport.callbackDiagnostics.lastResult == .accepted)
        #expect(fixture.store.calls.isEmpty)
        transport.accountDidChange()
        #expect(transport.callbackDiagnostics.callbacks.isEmpty)
        #expect(transport.visibleTest == nil)
    }

    @Test func previewsAreBoundedAndTargetsRejectPrivateOrMalformedRoutes() throws {
        let preview = CloudAlertPreview(title: "  Nollie\n", body: "\u{0000}  " + String(repeating: "A", count: 500) + "\n")
        #expect(preview.title == "Nollie")
        #expect(preview.body.count == 240)
        #expect(preview.body.hasSuffix("…"))
        #expect(preview.isValid)
        let combined = CloudAlertPreview(body: "A" + String(repeating: "\u{0301}", count: 10_000))
        #expect(combined.body.utf8.count <= 960)
        #expect(combined.isValid)
        let gateway = try GatewayURL.normalize("https://Example.invalid:443/hermes/")
        let fingerprint = CloudAlertTarget.fingerprint(for: gateway)
        #expect(fingerprint == CloudAlertTarget.fingerprint(for: try .normalize("https://example.invalid/hermes")))
        #expect(!fingerprint.contains("example"))
        for profile in ["private", "Moss", "all", "../default"] {
            #expect(!CloudAlertTarget(connectionID: UUID(), gatewayFingerprint: fingerprint, profile: profile,
                                     sessionID: "chat-1", messageRowID: 4).isValid)
        }
        #expect(!CloudAlertTarget(connectionID: UUID(), gatewayFingerprint: fingerprint, profile: "default",
                                 sessionID: "chat/other", messageRowID: 4).isValid)
        #expect(!CloudAlertTarget(connectionID: UUID(), gatewayFingerprint: fingerprint, profile: "default",
                                 sessionID: "chat-1", messageRowID: -1).isValid)
    }

    @Test func installationIdentityIsOpaqueValidatedAndBackwardCompatible() throws {
        let raw = String(repeating: "a", count: 32)
        let fingerprint = try #require(GatewayIdentity.fingerprint(installID: raw))
        #expect(GatewayIdentity.isValid(fingerprint))
        #expect(fingerprint != raw)
        #expect(fingerprint == GatewayIdentity.fingerprint(installID: raw))
        for invalid in ["", raw + "a", raw.uppercased(), "https://example.invalid", String(repeating: "g", count: 32)] {
            #expect(GatewayIdentity.fingerprint(installID: invalid) == nil)
        }
        let old = Data(#"{"connectionID":"00000000-0000-0000-0000-000000000001","gatewayFingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","profile":"default","sessionID":"fixture"}"#.utf8)
        let decoded = try JSONDecoder().decode(CloudAlertTarget.self, from: old)
        #expect(decoded.gatewayIdentity == nil && decoded.isValid)
        var malformed = decoded; malformed.gatewayIdentity = "unverified"
        #expect(!malformed.isValid)
        malformed.gatewayIdentity = fingerprint
        #expect(malformed.isValid)
        let roundTrip = try JSONDecoder().decode(CloudAlertTarget.self, from: JSONEncoder().encode(malformed))
        #expect(roundTrip == malformed)
    }

    @Test func oldRecordsRemainReadableAndExactTargetRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CloudAlertEvent(source: "fixture", key: "reply", kind: .replyReady, now: now)
        let record = CKRecord(recordType: CloudAlertEvent.recordType, recordID: .init(recordName: event.id))
        record["version"] = 1; record["source"] = event.source; record["kind"] = event.kind.rawValue
        record["createdAt"] = event.createdAt; record["expiresAt"] = event.expiresAt
        #expect(try CloudKitAlertStore.decodeEvent(record).target == nil)
        let target = CloudAlertTarget(connectionID: UUID(), gatewayFingerprint: String(repeating: "a", count: 64),
                                      profile: "default", sessionID: "compressed-child", messageRowID: 17)
        record["target"] = String(decoding: try JSONEncoder().encode(target), as: UTF8.self)
        record["previewTitle"] = "Nollie"; record["previewBody"] = "The saved reply."
        let decoded = try CloudKitAlertStore.decodeEvent(record)
        #expect(decoded.target == target)
        #expect(decoded.preview?.body == "The saved reply.")
        record["target"] = "{}"
        #expect(throws: CloudAlertFailure.self) { try CloudKitAlertStore.decodeEvent(record) }
    }

    @Test func openedTargetUsesOnlyTheReferencedSavedRowAndExpires() async throws {
        let fixture = CloudAlertFixture()
        let transport = fixture.make(); await transport.enable()
        let target = CloudAlertTarget(connectionID: UUID(), gatewayFingerprint: String(repeating: "a", count: 64),
                                      profile: "default", sessionID: "chat-1", messageRowID: 17)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CloudAlertEvent(source: "other", key: "old-reply", kind: .replyReady, now: now, target: target)
        fixture.store.events[event.id] = event
        #expect(await transport.openedTarget(eventID: event.id) == target)
        #expect(fixture.store.receipts[event.id]?.openedAt != nil)
        let expired = CloudAlertEvent(source: "other", key: "expired", kind: .replyReady,
                                      now: now.addingTimeInterval(-CloudAlertEvent.retention - 1), target: target)
        fixture.store.events[expired.id] = expired
        #expect(await transport.openedTarget(eventID: expired.id) == nil)
        await transport.disable()
        fixture.store.calls.removeAll()
        #expect(await transport.openedTarget(eventID: event.id) == nil)
        #expect(fixture.store.calls.isEmpty)
    }

    @Test func extensionPrivacyFailsClosedBeforeCloudAccess() async {
        let store = CloudAlertTestStore()
        let id = CloudAlertEvent(source: "other", key: "reply", kind: .replyReady, now: .now).id
        let policies: [NotificationPreviewPolicy?] = [nil,
            .init(showPreviews: false, appLockEnabled: false, cloudAlertsEnabled: true, cloudAccountFingerprint: nil),
            .init(showPreviews: true, appLockEnabled: true, cloudAlertsEnabled: true, cloudAccountFingerprint: nil),
            .init(showPreviews: true, appLockEnabled: false, cloudAlertsEnabled: false, cloudAccountFingerprint: nil),
            .init(showPreviews: true, appLockEnabled: false, cloudAlertsEnabled: true, cloudAccountFingerprint: nil)]
        for policy in policies {
            let resolver = CloudAlertNotificationResolver(store: store, policy: { policy })
            #expect(await resolver.event(id) == nil)
        }
        #expect(store.calls.isEmpty)
    }

    @Test func extensionChecksAccountAndPrivacyAgainAfterFetching() async throws {
        let store = CloudAlertTestStore(); store.account = String(repeating: "a", count: 64); store.remoteEnabled = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let target = CloudAlertTarget(connectionID: UUID(), gatewayFingerprint: String(repeating: "b", count: 64),
                                      profile: "default", sessionID: "chat-1", messageRowID: 17)
        let event = CloudAlertEvent(source: "other", key: "reply", kind: .replyReady, now: now,
                                   target: target, preview: .init(body: "Exact final reply"))
        store.events[event.id] = event
        var policy = NotificationPreviewPolicy(showPreviews: true, appLockEnabled: false, cloudAlertsEnabled: true,
                                               cloudAccountFingerprint: store.account)
        let resolver = CloudAlertNotificationResolver(store: store, policy: { policy }, now: { now })
        #expect(await resolver.event(event.id)?.preview?.body == "Exact final reply")
        store.afterEvent = {
            policy = .init(showPreviews: false, appLockEnabled: false, cloudAlertsEnabled: true,
                           cloudAccountFingerprint: store.account)
        }
        #expect(await resolver.event(event.id) == nil)
        store.afterEvent = nil
        policy = .init(showPreviews: true, appLockEnabled: false, cloudAlertsEnabled: true,
                       cloudAccountFingerprint: String(repeating: "c", count: 64))
        store.calls.removeAll()
        #expect(await resolver.event(event.id) == nil)
        #expect(!store.calls.contains("event"))
    }

    @Test func oldGenericSubscriptionUpgradesInPlaceOnlyWhileEnabled() async {
        let fixture = CloudAlertFixture(); let transport = fixture.make()
        await transport.enable()
        fixture.store.legacySubscription = true
        fixture.store.calls.removeAll()
        await transport.refresh()
        #expect(transport.subscriptionState == .valid)
        #expect(fixture.store.calls.filter { $0 == "subscribe" }.count == 1)
        #expect(!fixture.store.calls.contains("enabled:true"))
        let legacy = CloudKitAlertStore.makeSubscription()
        legacy.notificationInfo?.shouldSendMutableContent = false
        #expect(CloudKitAlertStore.subscriptionState(legacy) == .legacy)
    }

    @Test func notificationExpiryAndLateSuccessCompleteOnlyOnceWithGenericFallback() {
        let fallback = UNMutableNotificationContent(); fallback.title = "Nollie"; fallback.body = "Generic"
        let result = DeliveryResultProbe()
        var destination: String?
        let gate = NotificationDeliveryGate(fallback: fallback) {
            result.record($0.body)
            destination = ($0.userInfo["hermes"] as? [String: String])?["session_id"]
        }
        gate.updateRouting(["hermes": ["session_id": "exact-chat"]])
        gate.finish()
        let detailed = UNMutableNotificationContent(); detailed.body = "Private preview"
        DispatchQueue.concurrentPerform(iterations: 20) { _ in gate.finish() }
        gate.finish(detailed)
        #expect(result.bodies == ["Generic"])
        #expect(destination == "exact-chat")
    }

    @Test func cloudStylingRejectsAccountOrConsentChangesEvenWhilePreviewsRemainOn() {
        let original = NotificationPreviewPolicy(showPreviews: true, appLockEnabled: false, cloudAlertsEnabled: true,
                                                cloudAccountFingerprint: String(repeating: "a", count: 64))
        let changedAccount = NotificationPreviewPolicy(showPreviews: true, appLockEnabled: false, cloudAlertsEnabled: true,
                                                      cloudAccountFingerprint: String(repeating: "b", count: 64))
        let disabled = NotificationPreviewPolicy(showPreviews: true, appLockEnabled: false, cloudAlertsEnabled: false,
                                                cloudAccountFingerprint: original.cloudAccountFingerprint)
        #expect(original.allowsPreview(matching: original))
        #expect(changedAccount.allowsPreview && !changedAccount.allowsPreview(matching: original))
        #expect(disabled.allowsPreview && !disabled.allowsPreview(matching: original))
    }

    @Test func consentChangesMirrorPrivacyWithoutAVisibleSettingsView() async {
        let fixture = CloudAlertFixture()
        fixture.store.account = String(repeating: "a", count: 64)
        fixture.defaults.set(false, forKey: NotificationPreviewPolicy.preferenceKey)
        let transport = fixture.make()
        await transport.enable()
        #expect(fixture.mirroredPolicies.last?.cloudAlertsEnabled == true)
        #expect(fixture.mirroredPolicies.last?.cloudAccountFingerprint == fixture.store.account)
        #expect(fixture.mirroredPolicies.allSatisfy { !$0.showPreviews })
        transport.accountDidChange()
        #expect(fixture.mirroredPolicies.last?.cloudAlertsEnabled == false)
        #expect(fixture.mirroredPolicies.last?.cloudAccountFingerprint == nil)
        #expect(fixture.mirroredPolicies.last?.showPreviews == false)
    }

    @Test func disablingMirrorsPrivacyBeforeItsRemoteWriteCompletes() async {
        let fixture = CloudAlertFixture(); let transport = fixture.make()
        await transport.enable()
        fixture.store.failWrites = true
        await transport.disable()
        #expect(!transport.isEnabled)
        #expect(fixture.mirroredPolicies.last?.cloudAlertsEnabled == false)
    }

    @Test func foregroundLookupReadsTheExactEventWithoutAcknowledgingIt() async {
        let fixture = CloudAlertFixture(); let transport = fixture.make()
        await transport.enable()
        let event = CloudAlertEvent(source: "other", key: "explicit-test", kind: .test,
                                    now: Date(timeIntervalSince1970: 1_800_000_000))
        fixture.store.events[event.id] = event
        fixture.store.calls.removeAll()
        #expect(await transport.foregroundEvent(eventID: event.id) == event)
        #expect(fixture.store.calls.filter { $0 == "event" }.count == 1)
        #expect(!fixture.store.calls.contains("acknowledge"))
        #expect(fixture.store.receipts.isEmpty)
        await transport.disable()
        fixture.store.calls.removeAll()
        #expect(await transport.foregroundEvent(eventID: event.id) == nil)
        #expect(fixture.store.calls.isEmpty)
    }

    @Test func foregroundLookupRejectsChangedConsentAndExpiredOrPrivateTargets() async {
        let fixture = CloudAlertFixture(); let transport = fixture.make()
        await transport.enable()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = CloudAlertEvent(source: "other", key: "expired", kind: .replyReady,
                                      now: now.addingTimeInterval(-CloudAlertEvent.retention - 1))
        fixture.store.events[expired.id] = expired
        #expect(await transport.foregroundEvent(eventID: expired.id) == nil)
        let target = CloudAlertTarget(connectionID: UUID(), gatewayFingerprint: String(repeating: "a", count: 64),
                                      profile: "private", sessionID: "chat", messageRowID: 1)
        let invalid = CloudAlertEvent(id: expired.id, source: expired.source, kind: .replyReady,
                                      createdAt: now, expiresAt: now.addingTimeInterval(60), target: target)
        fixture.store.events[invalid.id] = invalid
        #expect(await transport.foregroundEvent(eventID: invalid.id) == nil)
        let valid = CloudAlertEvent(source: "other", key: "valid", kind: .test, now: now)
        fixture.store.events[valid.id] = valid
        fixture.store.afterEvent = { transport.accountDidChange() }
        #expect(await transport.foregroundEvent(eventID: valid.id) == nil)
        #expect(fixture.store.receipts.isEmpty)
    }

    @Test func previewDiagnosticsSeparateLegacyEventsFromReadyDetailsAndPrivacyChanges() async {
        let store = CloudAlertTestStore(); store.account = String(repeating: "a", count: 64); store.remoteEnabled = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = CloudAlertEvent(source: "other", key: "old-helper", kind: .replyReady, now: now)
        let target = CloudAlertTarget(connectionID: UUID(), gatewayFingerprint: String(repeating: "b", count: 64),
                                      profile: "default", sessionID: "chat", messageRowID: 1)
        let detailed = CloudAlertEvent(source: "other", key: "new-helper", kind: .replyReady, now: now,
                                       target: target, preview: .init(body: "Three options are ready to compare."))
        store.events[legacy.id] = legacy; store.events[detailed.id] = detailed
        var policy = NotificationPreviewPolicy(showPreviews: true, appLockEnabled: false, cloudAlertsEnabled: true,
                                               cloudAccountFingerprint: store.account)
        let resolver = CloudAlertNotificationResolver(store: store, policy: { policy }, now: { now })
        #expect(await resolver.resolve(legacy.id).outcome == .detailsUnavailable)
        let ready = await resolver.resolve(detailed.id)
        #expect(ready.outcome == .detailsReady)
        #expect(ready.event?.preview?.body == "Three options are ready to compare.")
        store.afterEvent = {
            policy = .init(showPreviews: false, appLockEnabled: false, cloudAlertsEnabled: true,
                           cloudAccountFingerprint: store.account)
        }
        #expect(await resolver.resolve(detailed.id).outcome == .privacyChanged)
        store.calls.removeAll()
        #expect(await resolver.resolve(detailed.id).outcome == .detailsHidden)
        #expect(store.calls.isEmpty)
    }
}

@MainActor
private final class CloudAlertFixture {
    let defaults: UserDefaults
    let source = UUID().uuidString
    let store: CloudAlertTestStore
    let permissions = CloudAlertPermissionProbe()
    var mirroredPolicies: [NotificationPreviewPolicy] = []
    private let suite = "CloudAlertTransportTests." + UUID().uuidString
    init(store: CloudAlertTestStore? = nil) {
        self.store = store ?? CloudAlertTestStore()
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(source, forKey: CloudAlertTransport.sourceKey)
    }
    func make(isDemo: Bool = false) -> CloudAlertTransport {
        let transport = CloudAlertTransport(store: store, defaults: defaults, permission: permissions.client, isDemo: isDemo,
                                           now: { Date(timeIntervalSince1970: 1_800_000_000) },
                                           privacyChanged: { [weak self] defaults in
                                               self?.mirroredPolicies.append(NotificationPreviewPreferences.policy(defaults: defaults))
                                           })
        permissions.confirm = { [weak transport] in transport?.remoteRegistrationSucceeded() }
        return transport
    }
}

@MainActor
private final class CloudAlertPermissionProbe {
    var status: UNAuthorizationStatus = .authorized
    var requests = 0
    var registrations = 0
    var autoConfirm = true
    var systemRegistered = false
    var confirm: (() -> Void)?
    var client: CloudAlertPermissionClient {
        .init(status: { self.status }, request: { self.requests += 1; self.status = .authorized },
              register: { self.registrations += 1; if self.autoConfirm { self.confirm?() } },
              isRegistered: { self.systemRegistered })
    }
}

@MainActor
private final class CloudAlertTestStore: CloudAlertStore {
    var account = "account-hash"
    var remoteEnabled = false
    var subscribed = false
    var subscriptionValid = true
    var legacySubscription = false
    var afterEvent: (() -> Void)?
    var calls: [String] = []
    var events: [String: CloudAlertEvent] = [:]
    var receipts: [String: CloudAlertTestStatus] = [:]
    var creations = 0
    var cleanups: [(String, Date)] = []
    var subscribeGate: CloudAlertTestGate?
    var latestTestGate: CloudAlertTestGate?
    var failLatestTest = false
    var failWrites = false
    func accountFingerprint() async throws -> String { calls.append("account"); return account }
    func enabled() async throws -> Bool { calls.append("enabled"); return remoteEnabled }
    func setEnabled(_ value: Bool) async throws {
        calls.append("enabled:\(value)")
        if failWrites { throw CloudAlertFailure.unavailable }
        remoteEnabled = value
    }
    func installSubscription() async throws {
        calls.append("subscribe")
        if let subscribeGate { await subscribeGate.wait() }
        subscribed = true; legacySubscription = false
    }
    func subscriptionState() async throws -> CloudAlertSubscriptionState {
        calls.append("subscription:check")
        return subscribed ? (legacySubscription ? .legacy : (subscriptionValid ? .valid : .invalid)) : .missing
    }
    func removeSubscription() async throws { calls.append("unsubscribe"); subscribed = false }
    func create(_ event: CloudAlertEvent) async throws {
        calls.append("create")
        if events[event.id] == nil { events[event.id] = event; creations += 1 }
    }
    func event(_ id: String) async throws -> CloudAlertEvent? { calls.append("event"); afterEvent?(); return events[id] }
    func latestUnexpiredTest(at date: Date) async throws -> CloudAlertTestLookup {
        calls.append("latest-test")
        if let latestTestGate { await latestTestGate.wait() }
        if failLatestTest { throw CloudAlertFailure.unavailable }
        return .select(from: Array(events.values), at: date, isLimited: false)
    }
    func receipt(_ id: String) async throws -> CloudAlertTestStatus? { calls.append("receipt"); return receipts[id] }
    func acknowledge(_ event: CloudAlertEvent, opened: Bool, at: Date) async throws {
        calls.append("acknowledge")
        var receipt = receipts[event.id] ?? CloudAlertTestStatus(stored: true)
        receipt.receivedAt = at
        if opened { receipt.openedAt = at }
        receipts[event.id] = receipt
    }
    func cleanExpired(source: String, before: Date) async throws { cleanups.append((source, before)) }
}

@MainActor
private final class CloudAlertTestGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var entry: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true; entry?.resume(); entry = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}

private final class DeliveryResultProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var bodies: [String] { lock.withLock { values } }
    func record(_ value: String) { lock.withLock { values.append(value) } }
}
