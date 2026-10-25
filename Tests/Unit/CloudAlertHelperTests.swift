import Foundation
import Testing
import NollieCore
@testable import Nollie
#if os(macOS)
import ServiceManagement
#endif

@MainActor
struct CloudAlertHelperTests {
    /// These checks keep the bots marked Private (here "private" and "Moss") out of alerts.
    init() { PrivateBots.useForTesting(PrivateBots(names: ["private", "moss"], settled: true)) }

    @Test func helperConsentRejectsPrivateAndBroadProfileScopes() {
        for name in ["private", "Moss", "all", "default,private", "../private", "", "default/private"] {
            #expect(!CloudAlertHelperConfiguration.permitsProfile(name))
        }
        #expect(CloudAlertHelperConfiguration.permitsProfile("default"))
        #expect(CloudAlertHelperConfiguration.permitsProfile("my-bot"))
        for id in ["", "../private", "Bot Chat", "id/private", "id?profile=private", String(repeating: "a", count: 256)] {
            #expect(!CloudAlertHelperConfiguration.permitsSessionID(id))
        }
        #expect(CloudAlertHelperConfiguration.permitsSessionID("20261016_132700_fixture"))
    }

    @Test func oldConsentWithoutCanonicalIDDecodesWithoutResettingItsBaseline() throws {
        let original = HelperFixture().config
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "canonicalSessions")
        let decoded = try JSONDecoder().decode(CloudAlertHelperConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.isValid)
        #expect(decoded.canonicalSessions == nil)
        #expect(decoded.consentID == original.consentID)
        #expect(decoded.enabledAt == original.enabledAt)
        var invalid = original
        invalid.canonicalSessions = ["private": "private-chat"]
        #expect(!invalid.isValid)
    }

    @Test func onlyExplicitTerminalRowsBecomeOutcomes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let since = now.addingTimeInterval(-60)
        func row(_ reason: String?, tools: Bool = false) -> TranscriptMessage {
            .init(role: "assistant", text: "A result", timestamp: now.timeIntervalSince1970,
                  rowId: 2, finishReason: reason, hasToolCalls: tools)
        }
        #expect(CloudAlertOutcomePolicy.latest(in: [row(nil)], since: since, now: now) == nil)
        #expect(CloudAlertOutcomePolicy.latest(in: [row("tool_calls", tools: true)], since: since, now: now) == nil)
        #expect(CloudAlertOutcomePolicy.latest(in: [row("stop")], since: since, now: now)?.kind == .replyReady)
        #expect(CloudAlertOutcomePolicy.latest(in: [row("error")], since: since, now: now)?.kind == .needsAttention)
        #expect(CloudAlertOutcomePolicy.latest(in: [row("length")], since: since, now: now) == nil)
        let failed = TranscriptMessage(role: "assistant", text: "This turn did not complete.", timestamp: now.timeIntervalSince1970,
                                       rowId: 3, displayKind: "failed_turn")
        #expect(CloudAlertOutcomePolicy.latest(in: [failed], since: since, now: now)?.kind == .needsAttention)
        #expect(CloudAlertOutcomePolicy.latest(in: [row("stop")], since: now.addingTimeInterval(1), now: now) == nil)
        #expect(CloudAlertOutcomePolicy.latest(in: [row("stop"), .init(role: "user", text: "Another question")], since: since, now: now) == nil)
    }

    @Test func installedDashboardWireShapeDecodesIntoTerminalOutcome() throws {
        let session = try JSONCoding.decoder.decode(CloudAlertObservedSession.self, from: Data(#"{"id":"fixture","profile":"default","last_active":1800000000.0,"message_count":2}"#.utf8))
        #expect(session.lastActive == 1_800_000_000)
        #expect(session.messageCount == 2)
        let page = try JSONCoding.decoder.decode(CloudAlertObservedMessages.self, from: Data(#"{"profile":"default","messages":[{"id":7,"role":"assistant","content":"A verified result","timestamp":1800000000.0,"finish_reason":"stop","tool_calls":null}],"pagination":{"limit":12}}"#.utf8))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CloudAlertOutcomePolicy.latest(in: page.messages, since: now, now: now)?.rowID == 7)
    }

    @Test func canonicalMessageRequestPreservesUnderscoresAndHyphensAndAuthenticatesExactProfile() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HelperMessagesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = HermesAPI(gateway: try GatewayURL.normalize("https://fixture.invalid/hermes"),
                            signer: RequestSigner(authMode: .sessionToken, sessionToken: "fixture-token"),
                            urlSession: session)
        let source = HermesCloudAlertOutcomeSource(api: api)
        let page = try await source.messages(sessionID: "20261016_132700_fixture-a", profile: "default")
        #expect(page.profile == "default")
        #expect(page.messages.count == 1)
        #expect(page.messages.first?.rowId == 19)
        #expect(page.messages.first?.text == "Verified result")
        #expect(page.messages.first?.finishReason == "stop")
        let identity = try await source.gatewayIdentity()
        #expect(identity == GatewayIdentity.fingerprint(installID: String(repeating: "a", count: 32)))
        await #expect(throws: CloudAlertHelperFailure.invalidConsent) {
            _ = try await source.messages(sessionID: "20261016_132700_fixture-a", profile: "private")
        }
    }

    @Test func helperFailureClassificationNeverRetainsErrorPayloads() {
        let sensitive = "fixture credential or response body"
        let cases: [(Error, CloudAlertHelperIssue)] = [
            (HermesAPIError.unauthorized(sensitive), .signInRequired),
            (HermesAPIError.sessionExpired, .signInRequired),
            (HermesAPIError.http(status: 404, detail: sensitive), .sessionNotFound),
            (HermesAPIError.http(status: 503, detail: sensitive), .serverRejected),
            (HermesAPIError.decoding(sensitive), .responseInvalid),
            (HermesAPIError.htmlResponse(status: 200), .responseInvalid),
            (HermesAPIError.transport(sensitive), .gatewayUnavailable),
            (CloudAlertHelperFailure.journalDamaged, .journalDamaged),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                     userInfo: [NSLocalizedDescriptionKey: sensitive]), .localStorageUnavailable),
            (NSError(domain: "CKErrorDomain", code: 4, userInfo: [NSLocalizedDescriptionKey: sensitive]), .iCloudUnavailable),
            (CloudAlertHelperFailure.unavailable, .retrying)
        ]
        for (error, expected) in cases {
            let issue = CloudAlertHelperIssue.classify(error)
            #expect(issue == expected)
            #expect(!issue.rawValue.contains(sensitive))
            #expect(issue.rawValue.count < 32)
        }
    }

    @Test func quietAutomationIsSuppressedButHumanLiteralIsNot() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reply = TranscriptMessage(role: "assistant", text: "NO_REPLY", timestamp: now.timeIntervalSince1970,
                                      rowId: 2, finishReason: "stop")
        #expect(CloudAlertOutcomePolicy.latest(in: [.init(role: "user", text: "Say NO_REPLY"), reply], since: now, now: now) != nil)
        let machine = TranscriptMessage(role: "user", text: "Check", displayKind: "internal_notification")
        #expect(CloudAlertOutcomePolicy.latest(in: [machine, reply], since: now, now: now) == nil)
    }

    @Test func promotedRESTAnswerWithEmptyContentQualifiesWithoutChangingRawHistory() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let page = try JSONCoding.decoder.decode(CloudAlertObservedMessages.self, from: Data(#"{"profile":"default","messages":[{"id":9,"role":"assistant","content":"","api_content":"Your verified report is ready.","timestamp":1800000000.0,"finish_reason":"stop","tool_calls":null}]}"#.utf8))
        let outcome = try #require(CloudAlertOutcomePolicy.latest(in: page.messages, since: now, now: now))
        #expect(outcome.rowID == 9)
        #expect(outcome.kind == .replyReady)
        #expect(page.messages[0].text == "")
        #expect(page.messages[0].apiContent == "Your verified report is ready.")
    }

    @Test func promotedAnswerStillRequiresTerminalDurableRowAndNeverPromotesReasoning() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reply = TranscriptMessage(role: "assistant", text: " \n", timestamp: now.timeIntervalSince1970,
                                      rowId: 10, apiContent: "Ready", finishReason: "stop")
        #expect(CloudAlertOutcomePolicy.latest(in: [reply], since: now, now: now)?.kind == .replyReady)
        for reason in [nil, "length", "tool_calls", "interrupted"] as [String?] {
            var unfinished = reply; unfinished.finishReason = reason
            #expect(CloudAlertOutcomePolicy.latest(in: [unfinished], since: now, now: now) == nil)
        }
        var tool = reply; tool.hasToolCalls = true
        #expect(CloudAlertOutcomePolicy.latest(in: [tool], since: now, now: now) == nil)
        var undurable = reply; undurable.rowId = nil
        #expect(CloudAlertOutcomePolicy.latest(in: [undurable], since: now, now: now) == nil)
        var reasoning = reply; reasoning.apiContent = nil; reasoning.reasoning = "Private reasoning"
        #expect(CloudAlertOutcomePolicy.latest(in: [reasoning], since: now, now: now) == nil)
    }

    @Test func promotedQuietResultIsFilteredBeforeEligibilityButHumanLiteralRemains() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for marker in ["[SILENT]", "NO_REPLY"] {
            let reply = TranscriptMessage(role: "assistant", text: "", timestamp: now.timeIntervalSince1970,
                                          rowId: 11, apiContent: marker, finishReason: "stop")
            let machine = TranscriptMessage(role: "user", text: "Check", displayKind: "internal_notification")
            #expect(CloudAlertOutcomePolicy.latest(in: [machine, reply], since: now, now: now) == nil)
            let human = TranscriptMessage(role: "user", text: "Repeat the marker")
            #expect(CloudAlertOutcomePolicy.latest(in: [human, reply], since: now, now: now)?.kind == .replyReady)
        }
    }

    @Test func baselineIgnoresOldHistoryButIncludesOutcomeAfterEnableBeforeFirstPoll() async throws {
        let fixture = HelperFixture()
        fixture.source.rows = [.init(id: "old", profile: "default", lastActive: fixture.now.timeIntervalSince1970 - 300, messageCount: 2), fixture.session]
        _ = try await fixture.observer().tick(fixture.config)
        #expect(fixture.source.messageReads == ["new"])
        #expect(fixture.cloud.created.count == 1)
        #expect(fixture.persistence.savedBeforeCloud)
    }

    @Test func hiddenCanonicalChatIsPolledEvenWhenAbsentFromOrdinarySessionList() async throws {
        let fixture = HelperFixture()
        fixture.source.rows = []
        // The REST route follows a canonical root through compression and stamps the exact owner.
        fixture.source.page = try JSONCoding.decoder.decode(CloudAlertObservedMessages.self, from: Data(#"{"session_id":"compressed-child","profile":"default","messages":[{"id":44,"role":"assistant","content":"The report is ready.","timestamp":1800000000.0,"finish_reason":"stop","tool_calls":null}]}"#.utf8))
        _ = try await fixture.observer().tick(fixture.config)
        #expect(fixture.source.messageReads == ["new"])
        #expect(fixture.cloud.created.count == 1)
        #expect(fixture.persistence.savedBeforeCloud)
        #expect(fixture.cloud.created.first?.target?.sessionID == "compressed-child")
        #expect(fixture.cloud.created.first?.target?.messageRowID == 44)
        #expect(fixture.cloud.created.first?.target?.connectionID == fixture.config.connectionID)
        #expect(fixture.cloud.created.first?.target?.gatewayIdentity == fixture.source.identity)
        #expect(fixture.cloud.created.first?.preview?.body == "The report is ready.")
        _ = try await fixture.observer().tick(fixture.config)
        #expect(fixture.cloud.created.count == 1)
    }

    @Test func missingInstallationIdentityKeepsLegacyAddressScope() async throws {
        let fixture = HelperFixture()
        fixture.source.identity = nil
        _ = try await fixture.observer().tick(fixture.config)
        #expect(fixture.cloud.created.first?.target?.gatewayIdentity == nil)
        #expect(fixture.cloud.created.first?.target?.gatewayFingerprint == String(repeating: "b", count: 64))
    }

    @Test func visibleCanonicalDuplicateIsReadOnlyOnceAndOtherProfilesAreNotRead() async throws {
        let fixture = HelperFixture()
        fixture.source.rows = [fixture.session, fixture.session,
            .init(id: "private-chat", profile: "private", lastActive: fixture.now.timeIntervalSince1970, messageCount: 2)]
        _ = try await fixture.observer().tick(fixture.config)
        #expect(fixture.source.messageReads == ["new"])
        #expect(fixture.cloud.created.count == 1)
    }

    @Test func canonicalChatWithoutActivityMetadataUsesDurableTimestampAndQuietPolicy() async throws {
        let fixture = HelperFixture()
        fixture.source.rows = []
        fixture.source.page = .init(profile: "default", messages: [
            .init(role: "assistant", text: "Old result", timestamp: fixture.config.enabledAt.timeIntervalSince1970 - 1,
                  rowId: 51, finishReason: "stop")])
        _ = try await fixture.observer().tick(fixture.config)
        #expect(fixture.cloud.created.isEmpty)
        fixture.source.page = .init(profile: "default", messages: [
            .init(role: "user", text: "Check", displayKind: "internal_notification"),
            .init(role: "assistant", text: "NO_REPLY", timestamp: fixture.now.timeIntervalSince1970,
                  rowId: 52, finishReason: "stop")])
        _ = try await fixture.observer().tick(fixture.config)
        #expect(fixture.cloud.created.isEmpty)
        fixture.source.page = .init(profile: "private", messages: [])
        await #expect(throws: CloudAlertHelperFailure.invalidConsent) { _ = try await fixture.observer().tick(fixture.config) }
        #expect(fixture.cloud.created.isEmpty)
    }

    @Test func missingCanonicalIDDoesNotClaimMainAssistantCoverageOrReadOtherChats() async throws {
        let fixture = HelperFixture()
        fixture.config.canonicalSessions = nil
        fixture.consent = fixture.config
        await #expect(throws: CloudAlertHelperFailure.mainChatUnknown) { _ = try await fixture.observer().tick(fixture.config) }
        #expect(fixture.source.listReads == 0)
        #expect(fixture.source.messageReads.isEmpty)
        #expect(fixture.cloud.created.isEmpty)
    }

    @Test func changedCanonicalIDStopsStaleReadButPreservesTheExistingConsent() async throws {
        let fixture = HelperFixture()
        fixture.source.afterRead = { fixture.consent?.canonicalSessions = ["default": "replacement-chat"] }
        await #expect(throws: CloudAlertHelperFailure.configurationChanged) { _ = try await fixture.observer().tick(fixture.config) }
        #expect(fixture.cloud.created.isEmpty)
        #expect(fixture.consent?.consentID == fixture.config.consentID)
        #expect(fixture.consent?.enabledAt == fixture.config.enabledAt)
        fixture.source.afterRead = nil
        fixture.config = try #require(fixture.consent)
        fixture.source.rows = []
        _ = try await fixture.observer().tick(fixture.config)
        #expect(fixture.source.messageReads.last == "replacement-chat")
        #expect(fixture.cloud.created.count == 1)
    }

    @Test func restartDoesNotDuplicateAnAlreadyDeliveredOutcome() async throws {
        let fixture = HelperFixture()
        _ = try await fixture.observer().tick(fixture.config)
        _ = try await fixture.observer().tick(fixture.config)
        #expect(fixture.cloud.created.count == 1)
        #expect(fixture.source.messageReads.count == 2)
        #expect(fixture.persistence.journal?.pending.isEmpty == true)
    }

    @Test func durableOutboxRetriesWithSameIDAfterCloudFailureAndHermesOutage() async throws {
        let fixture = HelperFixture()
        fixture.cloud.failCreate = true
        await #expect(throws: CloudAlertHelperFailure.self) { _ = try await fixture.observer().tick(fixture.config) }
        let pending = try #require(fixture.persistence.journal?.pending.values.first)
        #expect(pending.attempts == 1)
        #expect(pending.nextAttempt == fixture.now.addingTimeInterval(20))
        fixture.cloud.failCreate = false
        fixture.source.fail = true
        fixture.now = fixture.now.addingTimeInterval(21)
        await #expect(throws: CloudAlertHelperFailure.self) { _ = try await fixture.observer().tick(fixture.config) }
        #expect(fixture.cloud.created.map(\.id) == [pending.id])
        #expect(fixture.persistence.journal?.pending.isEmpty == true)
        #expect(fixture.persistence.journal?.seen[pending.id] != nil)
    }

    @Test func revokingConsentDuringAReadPreventsPublication() async throws {
        let fixture = HelperFixture()
        fixture.source.afterRead = { fixture.consent = nil }
        await #expect(throws: CloudAlertHelperFailure.self) { _ = try await fixture.observer().tick(fixture.config) }
        #expect(fixture.cloud.created.isEmpty)
    }

    @Test func changedICloudAccountOrRemoteOffDoesNotReadHermes() async throws {
        let fixture = HelperFixture()
        fixture.cloud.fingerprint = String(repeating: "b", count: 64)
        await #expect(throws: CloudAlertHelperFailure.self) { _ = try await fixture.observer().tick(fixture.config) }
        #expect(fixture.source.listReads == 0)
        fixture.cloud.fingerprint = fixture.config.accountFingerprint
        fixture.cloud.isEnabled = false
        await #expect(throws: CloudAlertHelperFailure.self) { _ = try await fixture.observer().tick(fixture.config) }
        #expect(fixture.source.listReads == 0)
    }

    @Test func pendingEventsExpireAndBackoffIsBounded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CloudAlertEvent(source: "source", key: "event", kind: .replyReady, now: now.addingTimeInterval(-86_401))
        var journal = CloudAlertHelperJournal(consentID: UUID())
        journal.pending[event.id] = CloudAlertHelperPending(event)
        journal.prune(now: now)
        #expect(journal.pending.isEmpty)
        #expect(CloudAlertOutcomePolicy.retryDelay(attempt: 1) == 20)
        #expect(CloudAlertOutcomePolicy.retryDelay(attempt: 100) == 900)
    }

    @Test func durableFileJournalIsScopedAndContainsNoMessageBody() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NollieHelperTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCloudAlertHelperPersistence(directory: directory)
        let consent = UUID()
        var journal = CloudAlertHelperJournal(consentID: consent)
        let event = CloudAlertEvent(source: "source", key: "secret-session-and-text", kind: .replyReady, now: .now)
        journal.pending[event.id] = CloudAlertHelperPending(event)
        try store.save(journal)
        #expect(try store.load(consentID: consent).pending[event.id] == journal.pending[event.id])
        #expect(try store.load(consentID: UUID()).pending.isEmpty)
        let data = try Data(contentsOf: directory.appendingPathComponent("alert-outbox-v1.json"))
        #expect(!String(decoding: data, as: UTF8.self).contains("secret-session-and-text"))
    }

    #if os(macOS)
    @Test func mainChatHandoffUpgradesOldConsentWithoutReregisteringOrResettingHistory() async throws {
        let probe = HelperLoginProbe()
        let controller = probe.controller()
        let connection = UUID()
        await controller.enable(connectionID: connection)
        let original = try #require(probe.config)
        #expect(controller.state == .needsMainChat)
        probe.now = probe.now.addingTimeInterval(3600)
        controller.updateCanonicalSession(connectionID: UUID(), sessionID: "wrong-connection")
        controller.updateCanonicalSession(connectionID: connection, profile: "private", sessionID: "private-chat")
        controller.updateCanonicalSession(connectionID: connection, sessionID: "../private")
        #expect(probe.config == original)
        controller.updateCanonicalSession(connectionID: connection, sessionID: "canonical-main")
        let updated = try #require(probe.config)
        #expect(updated.canonicalSessions == ["default": "canonical-main"])
        #expect(updated.consentID == original.consentID)
        #expect(updated.enabledAt == original.enabledAt)
        #expect(probe.registerCalls == 1)
        #expect(probe.unregisterCalls == 0)
        await controller.retry()
        #expect(probe.config == updated)
        #expect(probe.registerCalls == 2)
        #expect(probe.unregisterCalls == 1)
    }

    @Test func loginRegistrationRequiresExplicitConsentAndDisableRevokesBeforeUnregister() async {
        let probe = HelperLoginProbe()
        let controller = probe.controller()
        #expect(probe.registerCalls == 0)
        controller.refresh()
        #expect(probe.registerCalls == 0)
        await controller.enable(connectionID: UUID(), canonicalSessionID: "canonical-main")
        #expect(probe.registerCalls == 1)
        #expect(probe.config?.enabled == true)
        #expect(controller.state == .starting)
        await controller.disable()
        #expect(probe.unregisterCalls == 1)
        #expect(probe.consentWasOffBeforeUnregister)
        #expect(!controller.isEnabled)
    }

    @Test func storeEditionAndDemoCannotRegisterHelper() async {
        for demo in [false, true] {
            let probe = HelperLoginProbe()
            let controller = probe.controller(isDemo: demo, isAvailable: false)
            await controller.enable(connectionID: UUID(), canonicalSessionID: "canonical-main")
            #expect(probe.registerCalls == 0)
            #expect(probe.config == nil)
        }
    }

    @Test func registrationAloneDoesNotClaimAHealthyHelper() async throws {
        let probe = HelperLoginProbe()
        let controller = probe.controller()
        await controller.enable(connectionID: UUID(), canonicalSessionID: "canonical-main")
        let config = try #require(probe.config)
        probe.health = .init(consentID: UUID(), checkedAt: probe.now, phase: "ready", pending: 0)
        probe.now = probe.now.addingTimeInterval(61)
        controller.refresh()
        #expect(controller.state == .stopped)
        probe.health = .init(consentID: config.consentID, checkedAt: probe.now, phase: "ready", pending: 0)
        controller.refresh()
        #expect(controller.state == .enabled)
        probe.now = probe.now.addingTimeInterval(361)
        controller.refresh()
        #expect(controller.state == .stopped)
        #expect(probe.registerCalls == 1)
    }

    @Test func healthMakesSignInAndAccountChangeVisibleWithoutAutomaticRestart() async throws {
        let probe = HelperLoginProbe()
        let controller = probe.controller()
        await controller.enable(connectionID: UUID(), canonicalSessionID: "canonical-main")
        let config = try #require(probe.config)
        for (phase, state) in [("signInRequired", CloudAlertHelperController.State.signInRequired),
                               ("retrying", .retrying), ("accountChanged", .stopped), ("off", .stopped),
                               ("sessionNotFound", .needsMainChat), ("responseInvalid", .retrying),
                               ("serverRejected", .retrying), ("gatewayUnavailable", .retrying),
                               ("iCloudUnavailable", .retrying), ("journalDamaged", .failed),
                               ("localStorageUnavailable", .failed)] {
            probe.health = .init(consentID: config.consentID, checkedAt: probe.now, phase: phase, pending: 0)
            controller.refresh()
            #expect(controller.state == state)
        }
        #expect(probe.registerCalls == 1)
        #expect(probe.unregisterCalls == 0)
    }

    @Test func explicitRetryRestartsRegistrationAndPreservesDurableConsent() async throws {
        let probe = HelperLoginProbe()
        let controller = probe.controller()
        await controller.enable(connectionID: UUID(), canonicalSessionID: "canonical-main")
        let original = try #require(probe.config)
        await controller.retry()
        #expect(probe.registerCalls == 2)
        #expect(probe.unregisterCalls == 1)
        #expect(probe.consentWasOffBeforeUnregister)
        #expect(probe.config == original)
        probe.defaults.set(String(repeating: "b", count: 64), forKey: CloudAlertTransport.accountKey)
        await controller.retry()
        #expect(probe.registerCalls == 2)
    }

    @Test func retryAfterRegistrationWasRemovedDoesNotUnregisterAMissingJob() async throws {
        let probe = HelperLoginProbe()
        let controller = probe.controller()
        await controller.enable(connectionID: UUID(), canonicalSessionID: "canonical-main")
        let original = try #require(probe.config)
        probe.status = .notRegistered
        probe.rejectMissingUnregister = true
        controller.refresh()
        #expect(controller.state == .stopped)
        await controller.retry()
        #expect(probe.unregisterCalls == 0)
        #expect(probe.registerCalls == 2)
        #expect(probe.config == original)
        #expect(controller.state == .starting)
    }

    @Test func visibleSettingsRefreshesHealthWrittenAfterRegistration() async throws {
        let probe = HelperLoginProbe()
        let controller = probe.controller()
        await controller.enable(connectionID: UUID(), canonicalSessionID: "canonical-main")
        let config = try #require(probe.config)
        var reads = 0
        await controller.monitorStatus {
            reads += 1
            if reads == 1 {
                #expect(controller.state == .starting)
                probe.health = .init(consentID: config.consentID, checkedAt: probe.now, phase: "ready", pending: 0)
            } else {
                #expect(controller.state == .enabled)
                throw CancellationError()
            }
        }
        #expect(reads == 2)
        #expect(probe.registerCalls == 1)
    }

    @Test func closingSettingsCancelsHealthMonitoring() async {
        let probe = HelperLoginProbe()
        let controller = probe.controller()
        var enteredWait = false
        let task = Task { await controller.monitorStatus {
            enteredWait = true
            try await Task.sleep(for: .seconds(30))
        } }
        while !enteredWait { await Task.yield() }
        task.cancel()
        await task.value
        #expect(probe.registerCalls == 0)
    }
    #endif
}

/// An exact server fixture: a double-encoded ID, missing auth or a changed profile returns 404.
private final class HelperMessagesURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let matches = request.httpMethod == "GET"
            && components.percentEncodedPath == "/hermes/api/sessions/20261016_132700_fixture-a/messages"
            && query == ["profile": "default", "order": "latest", "limit": "12", "inline_images": "false"]
            && request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "fixture-token"
        let identityMatches = request.httpMethod == "GET"
            && components.percentEncodedPath == "/hermes/api/status" && query == ["profile": "default"]
            && request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "fixture-token"
        let body = identityMatches ? #"{"install_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"# : matches
            ? #"{"session_id":"20261016_132700_fixture-a","profile":"default","messages":[{"id":19,"role":"assistant","content":"Verified result","timestamp":1800000000.0,"finish_reason":"stop","tool_calls":null}],"pagination":{"limit":12,"offset":0,"order":"latest","returned":1}}"#
            : #"{"detail":"Fixture route not found"}"#
        let response = HTTPURLResponse(url: url, statusCode: matches || identityMatches ? 200 : 404, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class HelperFixture {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var config: CloudAlertHelperConfiguration
    var consent: CloudAlertHelperConfiguration?
    let source = HelperSourceProbe()
    let cloud = HelperCloudProbe()
    let persistence = HelperPersistenceProbe()
    var session: CloudAlertObservedSession { .init(id: "new", profile: "default", lastActive: now.timeIntervalSince1970, messageCount: 2) }
    init() {
        config = .init(enabled: true, consentID: UUID(), enabledAt: now.addingTimeInterval(-60), connectionID: UUID(),
                       profiles: ["default"], accountFingerprint: String(repeating: "a", count: 64), source: "test-source",
                       canonicalSessions: ["default": "new"])
        consent = config
        source.rows = [session]
        source.page = .init(profile: "default", messages: [
            .init(role: "assistant", text: "Verified result", timestamp: now.timeIntervalSince1970, rowId: 7, finishReason: "stop")])
        cloud.beforeCreate = { self.persistence.savedBeforeCloud = self.persistence.journal?.pending.isEmpty == false }
    }
    func observer() -> CloudAlertHelperObserver {
        .init(source: source, cloud: cloud, persistence: persistence, consent: { self.consent }, now: { self.now }, gatewayFingerprint: String(repeating: "b", count: 64))
    }
}

@MainActor private final class HelperSourceProbe: CloudAlertOutcomeSource {
    var rows: [CloudAlertObservedSession] = []
    var page = CloudAlertObservedMessages(profile: "default", messages: [])
    var identity: String? = String(repeating: "c", count: 64)
    func gatewayIdentity() async throws -> String? { identity }
    var listReads = 0
    var messageReads: [String] = []
    var afterRead: (() -> Void)?
    var fail = false
    func sessions(profile: String) async throws -> [CloudAlertObservedSession] {
        listReads += 1
        if fail { throw CloudAlertHelperFailure.unavailable }
        return rows
    }
    func messages(sessionID: String, profile: String) async throws -> CloudAlertObservedMessages {
        messageReads.append(sessionID); afterRead?(); return page
    }
}

@MainActor private final class HelperPersistenceProbe: CloudAlertHelperPersistence {
    var journal: CloudAlertHelperJournal?
    var savedBeforeCloud = false
    func load(consentID: UUID) throws -> CloudAlertHelperJournal {
        journal?.consentID == consentID ? journal! : .init(consentID: consentID)
    }
    func save(_ journal: CloudAlertHelperJournal) throws { self.journal = journal }
}

@MainActor private final class HelperCloudProbe: CloudAlertStore {
    var fingerprint = String(repeating: "a", count: 64)
    var isEnabled = true
    var created: [CloudAlertEvent] = []
    var failCreate = false
    var beforeCreate: (() -> Void)?
    func accountFingerprint() async throws -> String { fingerprint }
    func enabled() async throws -> Bool { isEnabled }
    func setEnabled(_ enabled: Bool) async throws { isEnabled = enabled }
    func installSubscription() async throws { }
    func subscriptionState() async throws -> CloudAlertSubscriptionState { .valid }
    func removeSubscription() async throws { }
    func create(_ event: CloudAlertEvent) async throws {
        beforeCreate?()
        if failCreate { throw CloudAlertHelperFailure.unavailable }
        if !created.contains(where: { $0.id == event.id }) { created.append(event) }
    }
    func event(_ id: String) async throws -> CloudAlertEvent? { nil }
    func latestUnexpiredTest(at date: Date) async throws -> CloudAlertTestLookup { .init() }
    func receipt(_ id: String) async throws -> CloudAlertTestStatus? { nil }
    func acknowledge(_ event: CloudAlertEvent, opened: Bool, at: Date) async throws { }
    func cleanExpired(source: String, before: Date) async throws { }
}

#if os(macOS)
@MainActor private final class HelperLoginProbe {
    var config: CloudAlertHelperConfiguration?
    var health: CloudAlertHelperHealth?
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var status: SMAppService.Status = .notRegistered
    var registerCalls = 0
    var unregisterCalls = 0
    var consentWasOffBeforeUnregister = false
    var rejectMissingUnregister = false
    let defaults = UserDefaults(suiteName: "HelperLoginProbe." + UUID().uuidString)!
    func controller(isDemo: Bool = false, isAvailable: Bool = true) -> CloudAlertHelperController {
        defaults.set(true, forKey: CloudAlertTransport.enabledKey)
        defaults.set(String(repeating: "a", count: 64), forKey: CloudAlertTransport.accountKey)
        defaults.set("source", forKey: CloudAlertTransport.sourceKey)
        return .init(loginItem: .init(status: { self.status }, register: {
            self.registerCalls += 1; self.status = .enabled
        }, unregister: {
            if self.rejectMissingUnregister && self.status == .notRegistered { throw CloudAlertHelperFailure.unavailable }
            self.unregisterCalls += 1; self.consentWasOffBeforeUnregister = self.config?.enabled == false; self.status = .notRegistered
        }), read: { self.config }, write: { self.config = $0 }, readHealth: { self.health }, now: { self.now },
                     defaults: defaults, isDemo: isDemo, isAvailable: isAvailable)
    }
}
#endif
