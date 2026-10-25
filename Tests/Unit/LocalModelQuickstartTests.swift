import Foundation
import Testing
@testable import Nollie
import NollieCore

@MainActor
struct LocalModelQuickstartTests {
    @Test func readingGuidanceNeverStartsAnInstall() async throws {
        let f = LocalModelFixture(), model = f.make()
        model.restore()
        await model.waitForOperation()
        #expect(model.state == .idle)
        #expect(f.requests.isEmpty)
    }

    @Test func explicitInstallPersistsBeforePostAndVerifiesTheActualDefault() async throws {
        let f = LocalModelFixture(), model = f.make()
        model.install(try f.entry())
        await model.waitForOperation()
        #expect(f.persistedBeforeStart)
        #expect(f.requests.filter { $0.method == "POST" }.map(\.path) == ["/api/local-models/quickstart"])
        #expect(f.startBody == ["model_id": "small"])
        #expect(model.state == .selected)
        #expect(model.selectedModel == "small-q4")
        #expect(model.reply == nil)
        #expect(f.replyChecks == 0, "Download success must not imply an inference check")
        model.testReply()
        await model.waitForOperation()
        #expect(model.state == .ready)
        #expect(model.reply == "Hello!")
        #expect(f.replyChecks == 1)
    }

    @Test func quickstartCompletionCannotHideAWrongProviderOrMissingModel() async throws {
        for wrongProvider in [true, false] {
            let f = LocalModelFixture(); f.wrongProvider = wrongProvider; f.downloaded = wrongProvider
            let model = f.make()
            model.install(try f.entry())
            await model.waitForOperation()
            #expect(model.state == .uncertain)
            #expect(model.selectedModel == nil)
            model.testReply()
            #expect(f.replyChecks == 0)
        }
    }

    @Test func lostStartResponseRecoversOneAcceptedJobWithoutPostingAgain() async throws {
        let f = LocalModelFixture(); f.loseStartResponse = true
        let model = f.make()
        model.install(try f.entry())
        await model.waitForOperation()
        #expect(model.state == .uncertain)
        #expect(!model.canBegin)
        model.checkProgress()
        await model.waitForOperation()
        #expect(model.state == .selected)
        #expect(f.requests.filter { $0.method == "POST" }.count == 1)
        #expect(f.saved?.jobID == "job-1")
    }

    @Test func unknownOrMultipleRecoveryJobsNeverStartMoreWork() async throws {
        for count in [0, 2] {
            let f = LocalModelFixture(); f.loseStartResponse = true; f.recoveryCount = count
            let model = f.make()
            model.install(try f.entry()); await model.waitForOperation()
            model.checkProgress(); await model.waitForOperation()
            #expect(model.state == (count == 0 ? .interrupted : .uncertain))
            #expect(f.requests.filter { $0.method == "POST" }.count == 1)
        }
    }

    @Test func clockSkewCannotHideAnAcceptedActiveJob() async throws {
        let f = LocalModelFixture(); f.loseStartResponse = true
        f.status = "paused"; f.serverClockOffset = -3600
        let model = f.make()
        model.install(try f.entry()); await model.waitForOperation()
        model.checkProgress(); await model.waitForOperation()
        #expect(model.state == .paused)
        #expect(!model.canBegin)
        #expect(f.saved?.jobID == "job-1")
        #expect(f.requests.filter { $0.method == "POST" }.count == 1)
    }

    @Test func reopenObservesSavedJobAndServerRestartDoesNotPretendToResume() async throws {
        let f = LocalModelFixture()
        f.saved = .init(scope: f.scope, catalogID: "small", variantID: "small-q4", requestedAt: .now, jobID: "job-1")
        let model = f.make(); model.restore(); await model.waitForOperation()
        #expect(model.state == .selected)
        #expect(!f.requests.contains { $0.method == "POST" })
        f.missingJob = true
        model.checkProgress(); await model.waitForOperation()
        #expect(model.state == .interrupted)
        #expect(model.message?.contains("Existing downloads are kept") == true)
    }

    @Test func pauseAndResumeUseTheSameJobAndUnknownProgressIsNotZero() async throws {
        let f = LocalModelFixture(); f.status = "paused"
        let model = f.make(); model.install(try f.entry()); await model.waitForOperation()
        #expect(model.state == .paused)
        #expect(model.job?.fractionCompleted == nil)
        f.status = "done"
        model.resume(); await model.waitForOperation()
        #expect(f.requests.filter { $0.path.hasSuffix("/resume") }.count == 1)
        #expect(model.state == .selected)
    }

    @Test func failedReplyDoesNotBecomeReadinessAndChangedSelectionDoesNotRun() async throws {
        let f = LocalModelFixture(), model = f.make()
        model.install(try f.entry()); await model.waitForOperation()
        f.failReply = true
        model.testReply(); await model.waitForOperation()
        #expect(model.state == .selected)
        #expect(model.reply == nil)
        f.wrongProvider = true
        model.testReply(); await model.waitForOperation()
        #expect(f.replyChecks == 1)
    }

    @Test func lockOrConnectionChangeBeforeDispatchPreventsStart() async throws {
        let f = LocalModelFixture(), model = f.make()
        model.install(try f.entry())
        f.current = false
        await model.waitForOperation()
        #expect(f.requests.isEmpty)
        #expect(model.selectedModel == nil)
    }

    @Test func cancelledPollingDoesNotPublishLaterReadiness() async throws {
        let f = LocalModelFixture(); f.status = "running"
        let model = f.make(wait: { throw CancellationError() })
        model.install(try f.entry()); await model.waitForOperation()
        model.stopObserving()
        #expect(model.selectedModel == nil)
        #expect(model.reply == nil)
        #expect(f.saved?.jobID == "job-1")
    }

    @Test func unsafeOrUnpricedModelsCannotStart() async throws {
        let f = LocalModelFixture(), model = f.make()
        for mutation in ["fits", "size", "spilled", "engine"] {
            var entry = try f.entry()
            switch mutation {
            case "fits": entry.fits = false
            case "size": entry.sizeBytes = nil
            case "spilled": entry.spilled = true
            default: entry.needsEngine = true
            }
            model.install(entry)
        }
        await model.waitForOperation()
        #expect(f.requests.isEmpty)
    }

    @Test func unmanagedRemoteDemoAndPrivateScopesNeverOfferInstallation() throws {
        var connection = GatewayConnection(name: "Fixture", gateway: try .normalize("http://127.0.0.1:1234"),
            authMode: .sessionToken, connectionKind: "local", managedInstallationID: UUID())
        #expect(LocalModelInstallScope.managed(connection, profile: "default", isDemo: false) != nil)
        #expect(LocalModelInstallScope.managed(connection, profile: "private", isDemo: false) == nil)
        #expect(LocalModelInstallScope.managed(connection, profile: "default", isDemo: true) == nil)
        connection.managedInstallationID = nil
        #expect(LocalModelInstallScope.managed(connection, profile: "default", isDemo: false) == nil)
        connection.managedInstallationID = UUID(); connection.gateway = try .normalize("https://example.invalid")
        #expect(LocalModelInstallScope.managed(connection, profile: "default", isDemo: false) == nil)
    }

    @Test func replyEvidenceRequiresTheExactLocalModelAndBoundedNonemptyText() throws {
        for (provider, model, text, accepted) in [
            ("llamacpp", "small-q4", "Hello", true),
            ("online", "small-q4", "Hello", false),
            ("llamacpp", "different", "Hello", false),
            ("llamacpp", "small-q4", " ", false),
            ("llamacpp", "small-q4", String(repeating: "x", count: 4097), false)
        ] {
            let raw = try JSONSerialization.data(withJSONObject: ["provider": provider, "model": model, "text": text])
            let result = try JSONDecoder().decode(LocalModelReplyResult.self, from: raw)
            if accepted { #expect(try LocalModelReplyEvidence.completedReply(result, expectedModel: "small-q4") == "Hello") }
            else {
                #expect(throws: LocalModelCheckFailure.self) {
                    _ = try LocalModelReplyEvidence.completedReply(result, expectedModel: "small-q4")
                }
            }
        }
    }

    @Test func replyRequestDoesNotSendAPromptModelOrCredentialToAnotherTarget() async throws {
        let api = LocalModelAPI { method, path, data in
            #expect(method == "POST")
            #expect(path == "/api/nollie/local-model/reply-check")
            let body = try data.map { try JSONDecoder().decode([String: String].self, from: $0) }
            #expect(body == [:])
            return Data(#"{"provider":"llamacpp","model":"small-q4","text":"Hello"}"#.utf8)
        }
        #expect(try await LocalModelReplyCheck.run(api: api, model: "small-q4", isCurrent: { true }) == "Hello")
        await #expect(throws: CancellationError.self) {
            try await LocalModelReplyCheck.run(api: api, model: "small-q4", isCurrent: { false })
        }
    }

    @Test func preferencesAreScopedAndContainNoCredentialOrReply() throws {
        let suite = "local-model-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let f = LocalModelFixture(), store = LocalModelInstallPersistence.preferences(defaults, scope: f.scope)
        let receipt = LocalModelInstallReceipt(scope: f.scope, catalogID: "small", variantID: "small-q4", requestedAt: .now, jobID: "job-1")
        try store.save(receipt)
        #expect(try store.load() == receipt)
        let other = LocalModelInstallScope(installationID: UUID(), connectionID: UUID(), profile: "default")
        #expect(try LocalModelInstallPersistence.preferences(defaults, scope: other).load() == nil)
        let data = try #require(defaults.data(forKey: f.scope.storageKey))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["scope", "catalogID", "variantID", "requestedAt", "jobID"])
    }

    @Test func nativeRequestsUseThePinnedRoutesAuthAndProfile() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalModelURLProtocol.self]
        let api = HermesAPI(gateway: try .normalize("https://local-model.invalid/hermes"),
            signer: .init(authMode: .sessionToken, sessionToken: "fixture-only"), urlSession: URLSession(configuration: config))
        let client = LocalModelAPI(api: api, profile: "default")
        let start = try await client.quickstart(catalogID: "small_model-q4")
        #expect(start.modelId == "small_model-q4")
        let job = try await client.job(id: "job_1-a")
        #expect(job.jobId == "job_1-a")
        #expect(job.fractionCompleted == 0.25)
        #expect(try await client.firstReply().text == "Hello")
    }

    @Test func invalidJobPathsAreRejectedBeforeTransport() async {
        let client = LocalModelAPI { _, _, _ in Issue.record("Invalid ID reached the transport"); throw LocalModelCheckFailure.incomplete }
        for id in ["../other", "job?profile=private", "job#fragment", "", "space id"] {
            await #expect(throws: HermesAPIError.self) { _ = try await client.job(id: id) }
        }
    }
}

private final class LocalModelURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var matches = request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "fixture-only"
            && parts.queryItems == [URLQueryItem(name: "profile", value: "default")]
        let payload: String
        if request.httpMethod == "POST", parts.percentEncodedPath == "/hermes/api/local-models/quickstart" {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(buffer, count: count)
                }
            }
            matches = matches && (try? JSONDecoder().decode([String: String].self, from: data)) == ["model_id": "small_model-q4"]
            payload = #"{"job_id":"job_1-a","model_id":"small_model-q4","display_name":"Small","needs_runtime":true,"needs_download":true,"download_bytes":400}"#
        } else if parts.percentEncodedPath == "/hermes/api/nollie/local-model/reply-check" {
            matches = matches && request.httpMethod == "POST" && request.timeoutInterval == 190
            payload = #"{"provider":"llamacpp","model":"small_model-q4","text":"Hello"}"#
        } else {
            matches = matches && request.httpMethod == "GET" && parts.percentEncodedPath == "/hermes/api/local-models/jobs/job_1-a"
            payload = #"{"job_id":"job_1-a","kind":"quickstart","target":"Small","model_id":"small_model-q4","status":"running","phase":"downloading","total_bytes":400,"done_bytes":100,"started_at":1800000000,"can_pause":true}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: matches ? 200 : 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((matches ? payload : #"{"detail":"Fixture route mismatch"}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class LocalModelFixture {
    struct Request { var method: String; var path: String }
    let scope = LocalModelInstallScope(installationID: UUID(), connectionID: UUID(), profile: "default")
    var saved: LocalModelInstallReceipt?
    var requests: [Request] = []
    var persistedBeforeStart = false
    var startBody: [String: String]?
    var current = true
    var loseStartResponse = false
    var recoveryCount = 1
    var serverClockOffset: TimeInterval = 0
    var missingJob = false
    var status = "done"
    var wrongProvider = false
    var downloaded = true
    var replyChecks = 0
    var failReply = false

    func entry() throws -> LocalModelCatalogEntry {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(LocalModelCatalogEntry.self, from: Data(#"{"id":"small","display_name":"Small model","model_id":"small-q4","downloaded_model_id":"small-q4","size_bytes":3500000000,"start_window":65536,"recommended":true,"fits":true,"spilled":false,"needs_engine":false,"downloaded":true}"#.utf8))
    }

    func make(wait: @escaping @Sendable () async throws -> Void = {}) -> LocalModelQuickstart {
        LocalModelQuickstart(api: .init { method, path, body in try await self.respond(method, path, body) }, scope: scope,
            persistence: .init(load: { self.saved }, save: { self.saved = $0 }),
            inspect: {
                try await MainActor.run {
                    var entry = try self.entry(); entry.downloaded = self.downloaded
                    return LocalModelSetupSnapshot(models: [entry])
                }
            }, isCurrent: { self.current }, checkReply: { _ in
                self.replyChecks += 1
                if self.failReply { throw LocalModelCheckFailure.incomplete }
                return "Hello!"
            }, wait: wait)
    }

    func respond(_ method: String, _ path: String, _ body: Data?) throws -> Data {
        requests.append(.init(method: method, path: path))
        if path.hasSuffix("/quickstart") {
            persistedBeforeStart = saved != nil
            startBody = try body.map { try JSONDecoder().decode([String: String].self, from: $0) }
            if loseStartResponse { throw URLError(.networkConnectionLost) }
            return Data(#"{"job_id":"job-1","model_id":"small","display_name":"Small model","needs_runtime":true,"needs_download":true,"download_bytes":3500000000}"#.utf8)
        }
        let job: [String: Any] = ["job_id": "job-1", "kind": "quickstart", "target": "Small model", "model_id": "small",
            "status": status, "phase": status == "done" ? "done" : "downloading", "done_bytes": 50,
            "started_at": Date().timeIntervalSince1970 + serverClockOffset, "can_pause": status == "running", "can_resume": status == "paused"]
        if path.hasSuffix("/jobs") { return try JSONSerialization.data(withJSONObject: ["jobs": Array(repeating: job, count: recoveryCount)]) }
        if path.contains("/jobs/") {
            if missingJob { throw HermesAPIError.http(status: 404, detail: "not found") }
            return try JSONSerialization.data(withJSONObject: job)
        }
        if path.hasSuffix("/options") {
            return try JSONSerialization.data(withJSONObject: ["providers": [], "provider": wrongProvider ? "online" : "llamacpp", "model": "small-q4"])
        }
        return Data(#"{"ok":true}"#.utf8)
    }
}
