import Foundation
import Testing
@testable import Nollie
import NollieCore

/// The setup step after a real quick start, against what Hermes 0.23.1 answered on this Mac
/// (11 Nov 2026, isolated rehearsal, build/real-local-model/run2): the model it chose, the catalog row
/// with its downloaded flag, the job as it moved from the model's files to its optional draft.
@MainActor
struct LocalModelRealShapesTests {
    // GET /api/model/options after POST /api/local-models/quickstart finished.
    nonisolated static let optionsAfter = #"{"providers":[{"slug":"llamacpp","name":"llama.cpp","authenticated":true,"is_current":true}],"model":"gemma-3-4b-it-Q4_K_M","provider":"llamacpp"}"#
    // The quick start's row of GET /api/local-models/catalog, after the download (size counts the optional draft).
    static let rowAfter = #"{"id":"scratch-gemma3-4b","display_name":"Gemma 3 4B (scratch test)","recommended":false,"downloaded":true,"downloaded_model_id":"gemma-3-4b-it-Q4_K_M","needs_engine":false,"fits":true,"model_id":"gemma-3-4b-it-Q4_K_M","quant":"Q4_K_M","size_bytes":3594260768,"size_label":"3.3 GB","start_window":131072,"spilled":false}"#
    // Two GET /api/local-models/jobs/<id> views: the model's own files, then the optional draft.
    static let mainPhase = #"{"job_id":"d93eb7781a51","kind":"quickstart","target":"Gemma 3 4B (scratch test)","model_id":"scratch-gemma3-4b","status":"running","phase":"downloading","detail":"Downloading Gemma 3 4B (scratch test)","total_bytes":3341145344,"done_bytes":1027604480,"started_at":1794413313.851289,"error":null,"bytes_per_sec":72593110.26922044,"eta_seconds":32,"can_pause":true,"can_resume":false}"#
    static let draftPhase = #"{"job_id":"d93eb7781a51","kind":"quickstart","target":"Gemma 3 4B (scratch test)","model_id":"scratch-gemma3-4b","status":"running","phase":"downloading","detail":"Downloading the draft model that speeds up generation","total_bytes":253115424,"done_bytes":40894464,"started_at":1794413313.851289,"error":null,"bytes_per_sec":null,"eta_seconds":null,"can_pause":true,"can_resume":false}"#

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(json.utf8))
    }

    static func snapshot(downloaded: Bool = true, free: UInt64? = 88_000_000_000) throws -> LocalModelSetupSnapshot {
        var row = try decode(LocalModelCatalogEntry.self, rowAfter)
        row.downloaded = downloaded
        return LocalModelSetupSnapshot(hardware: .init(ramTotalBytes: 206_158_430_208), models: [row], freeDiskBytes: free)
    }

    @Test func afterARealQuickStartTheChosenModelIsReadyByItsCatalogName() throws {
        let options = try Self.decode(ModelOptionsResult.self, Self.optionsAfter)
        let status = ModelReadiness.read(options, mode: .local, local: try Self.snapshot())
        #expect(status == .ready("Gemma 3 4B (scratch test)"))
        #expect(ModelReadiness.read(options, mode: .both, local: try Self.snapshot()).isReady)
    }

    @Test func aLateOrFailedCatalogNeverClaimsTheModelIsMissing() throws {
        let options = try Self.decode(ModelOptionsResult.self, Self.optionsAfter)
        for local in [nil, LocalModelSetupSnapshot(models: [], catalogIssue: .unavailable)] {
            let status = ModelReadiness.read(options, mode: .local, local: local)
            #expect(!status.isReady)
            #expect(!status.detail.contains("isn't downloaded"))
            #expect(!status.detail.contains("Q4_K_M"), "Never the build's id")
        }
        #expect(ModelReadiness.read(options, mode: .local, local: try Self.snapshot(downloaded: false)).detail.contains("isn't downloaded"))
    }

    @Test func theModelStepAsksAgainByItselfUntilHermesAnswers() throws {
        let options = try Self.decode(ModelOptionsResult.self, Self.optionsAfter)
        let late = ModelReadiness.read(options, mode: .local, local: LocalModelSetupSnapshot(models: [], catalogIssue: .unavailable))
        #expect(late.isChecking)
        #expect(late.detail.hasPrefix("Checking "), "Checking <name>… while the catalog can't be read")
        #expect(ModelStepRetry.shouldRetry(status: late, checking: false, checkFailed: false, connected: true))
        #expect(!ModelStepRetry.shouldRetry(status: late, checking: true, checkFailed: false, connected: true), "One ask at a time")
        #expect(!ModelStepRetry.shouldRetry(status: late, checking: false, checkFailed: false, connected: false),
                "Reconnecting checks again on its own")
        #expect(ModelStepRetry.shouldRetry(status: nil, checking: false, checkFailed: true, connected: true), "The whole check failed")
        #expect(!ModelStepRetry.shouldRetry(status: nil, checking: false, checkFailed: false, connected: true), "Not asked yet")
        // An answer stops it, ready or not.
        let ready = ModelReadiness.read(options, mode: .local, local: try Self.snapshot())
        #expect(!ModelStepRetry.shouldRetry(status: ready, checking: false, checkFailed: false, connected: true))
        let missing = ModelReadiness.read(options, mode: .local, local: try Self.snapshot(downloaded: false))
        #expect(!missing.isChecking)
        #expect(!ModelStepRetry.shouldRetry(status: missing, checking: false, checkFailed: false, connected: true))
    }

    @Test func aHelloThatJustPassedIsReadyAtOnceWithoutAskingHermesAgain() throws {
        let verified = LocalModelVerified(model: "gemma-3-4b-it-Q4_K_M", name: "Gemma 3 4B (scratch test)")
        #expect(ModelReadiness.read(nil, mode: .local, local: nil, verified: verified) == .ready("Gemma 3 4B (scratch test)"))
        let options = try Self.decode(ModelOptionsResult.self, Self.optionsAfter)
        #expect(ModelReadiness.read(options, mode: .local, local: nil, verified: verified)?.isReady == true)
        // Someone chose another model since: the hello no longer speaks for it.
        var other = options; other.model = "Qwen3.8-27B-UD-Q4_K_M"
        #expect(ModelReadiness.read(other, mode: .local, local: try Self.snapshot(), verified: verified)?.isReady == false)
        #expect(ModelReadiness.read(nil, mode: .cloud, local: nil, verified: verified) == nil)
        #expect(ModelReadiness.read(nil, mode: .local, local: nil, verified: nil) == nil)
    }

    @Test func theDownloadSizeIsTheCatalogsWholeSizeFromStartToFinish() throws {
        let size = try Self.snapshot().models[0].sizeBytes
        let main = try Self.decode(LocalModelJob.self, Self.mainPhase)
        let draft = try Self.decode(LocalModelJob.self, Self.draftPhase)
        #expect(main.detail == "Downloading Gemma 3 4B (scratch test)")
        // Hermes counts 3.34 GB of model files, then 0.25 GB of optional draft; the choice said 3.6 GB.
        #expect(LocalModelSize.label(try #require(size)) == "3.6 GB")
        #expect(LocalModelDownload.progressWords(main, size: size) == "1.0 of 3.6 GB")
        #expect(LocalModelDownload.progressWords(draft, size: size) == "3.4 of 3.6 GB")
        let first = try #require(LocalModelDownload.fraction(main, size: size))
        let later = try #require(LocalModelDownload.fraction(draft, size: size))
        #expect(first < later && later < 1, "Progress never jumps back when the draft starts")
        #expect(LocalModelDownload.progressWords(main) == "1.0 of 3.3 GB", "Without the catalog, Hermes's own count")
        // The real Qwen3.8 27B: 16.46 GB of weights and 0.93 GB vision file, then a 1.14 GB draft.
        var qwen = main; qwen.totalBytes = 17_395_586_656; qwen.doneBytes = 17_395_586_656
        #expect(LocalModelDownload.progressWords(qwen, size: 18_538_593_472) == "17.4 of 18.5 GB")
        #expect(LocalModelTime.left(main, size: size) != nil)
    }

    @Test func theStepSaysWhatIsUnderWayWhileTheSheetIsClosed() throws {
        let main = try Self.decode(LocalModelJob.self, Self.mainPhase)
        let snapshot = try Self.snapshot()
        let downloading = LocalModelQuickstart.picture(state: .installing, job: main, catalogID: "scratch-gemma3-4b")
        let download = LocalModelDownload(picture: downloading, snapshot: snapshot)
        let scope = try #require(downloading.receipt?.scope)
        download.attach(downloading, scope: scope, snapshot: snapshot)
        #expect(download.activity(for: scope) == "Getting Gemma 3 4B (scratch test) · 1.0 of 3.6 GB")
        #expect(download.verified(for: scope) == nil)
        let paused = LocalModelQuickstart.picture(state: .paused, job: main, catalogID: "scratch-gemma3-4b")
        download.attach(paused, scope: try #require(paused.receipt?.scope), snapshot: snapshot)
        #expect(download.activity(for: paused.receipt?.scope) == "Paused · 1.0 of 3.6 GB")
        let ready = LocalModelQuickstart.picture(state: .ready, job: main, selectedModel: "gemma-3-4b-it-Q4_K_M",
                                                 reply: "Hi there! 😊", catalogID: "scratch-gemma3-4b")
        download.attach(ready, scope: try #require(ready.receipt?.scope), snapshot: snapshot)
        #expect(download.activity(for: ready.receipt?.scope) == nil)
        #expect(download.verified(for: ready.receipt?.scope) == LocalModelVerified(model: "gemma-3-4b-it-Q4_K_M", name: "Gemma 3 4B (scratch test)"))
        #expect(download.verified(for: scope) == nil, "Another assistant's hello is not this one's")
    }

    @Test func theReadyStepIsNeverAGreyDeadEnd() {
        #expect(ReadyStepAction.decide(connected: true, modelReady: true, modelPutOff: false) == .startChatting)
        #expect(ReadyStepAction.decide(connected: true, modelReady: true, modelPutOff: true) == .startChatting)
        #expect(ReadyStepAction.decide(connected: true, modelReady: false, modelPutOff: false) == .setUpModel)
        #expect(ReadyStepAction.decide(connected: true, modelReady: false, modelPutOff: true) == .startChatting,
                "Put off on purpose: chatting is still the way on")
        #expect(ReadyStepAction.decide(connected: false, modelReady: true, modelPutOff: false) == .checkConnection)
    }

    @Test func freeSpaceMeasuredAgainChangesWhatCanStart() throws {
        let tight = LocalModelChoices(try Self.snapshot(downloaded: false, free: 4_000_000_000))
        #expect(tight.quickStart == nil)
        let freed = LocalModelChoices(try Self.snapshot(downloaded: false, free: 4_000_000_000).measured(free: 20_000_000_000))
        #expect(freed.quickStart?.id == "scratch-gemma3-4b")
        #expect(try Self.snapshot(free: 5).measured(free: nil).freeDiskBytes == 5, "No new reading keeps the last one")
    }

    @Test func theHelloRunsByItselfOnceTheModelIsChosen() async throws {
        let snapshot = try Self.snapshot()
        let replies = Counter()
        let api = LocalModelAPI { _, path, _ in
            if path.hasSuffix("/quickstart") {
                return Data(#"{"job_id":"d93eb7781a51","model_id":"scratch-gemma3-4b","display_name":"Gemma 3 4B (scratch test)","needs_runtime":true,"needs_download":true,"download_bytes":3594260768}"#.utf8)
            }
            if path.contains("/jobs/") {
                return Data(#"{"job_id":"d93eb7781a51","kind":"quickstart","target":"Gemma 3 4B (scratch test)","model_id":"scratch-gemma3-4b","status":"done","phase":"done","detail":"Gemma 3 4B (scratch test) is ready — new chats use it","total_bytes":253115424,"done_bytes":253115424,"started_at":1794413313.851289,"error":null}"#.utf8)
            }
            return Data(Self.optionsAfter.utf8)
        }
        let setup = LocalModelQuickstart(api: api, scope: .init(installationID: UUID(), connectionID: UUID(), profile: "default"),
            persistence: .init(load: { nil }, save: { _ in }), inspect: { snapshot }, isCurrent: { true },
            checkReply: { _ in replies.add(); return "Hi there! 😊" }, freeDisk: { nil })
        setup.autoHello = true
        setup.install(snapshot.models[0])
        await setup.waitForOperation()
        #expect(setup.state == .ready)
        #expect(setup.reply == "Hi there! 😊")
        #expect(replies.value == 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
