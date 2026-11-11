import Foundation
import Testing
@testable import Nollie
import NollieCore

/// The rules behind the model setup on this Mac: which model is Quick start, which is Best for this
/// Mac, what fits the disk, how long it takes, what memory suggests, and why a download stopped.
@MainActor
struct LocalModelChoicesTests {
    /// What Hermes 0.23.1 answered on a Mac with 192 GB memory (11 Nov 2026), trimmed to the facts used.
    static let realCatalog = #"""
    [{"id":"qwen3.8-27b","display_name":"Qwen3.8 27B","recommended":false,"fits":true,"spilled":false,"needs_engine":false,"model_id":"Qwen3.8-27B-UD-Q4_K_M","size_bytes":18538593472,"start_window":262144,"downloaded":false},
     {"id":"qwen3.8-flash-next","display_name":"Qwen3.8 Flash Next","recommended":true,"fits":true,"spilled":false,"needs_engine":false,"model_id":"Qwen3.8-Flash-Next-UD-IQ4_XS","size_bytes":98727556448,"start_window":262144,"downloaded":false},
     {"id":"nemotron-3.5-bolt-74b-a9b","display_name":"Nemotron 3.5 Bolt","recommended":false,"fits":true,"spilled":false,"needs_engine":false,"model_id":"NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB","size_bytes":24750261824,"start_window":262144,"downloaded":false},
     {"id":"qwen3.6-35b-a3b","display_name":"Qwen3.6 35B-A3B","recommended":false,"fits":true,"spilled":false,"needs_engine":false,"model_id":"Qwen3.6-35B-A3B-UD-Q4_K_M","size_bytes":23566209952,"start_window":262144,"downloaded":false},
     {"id":"deepseek-v4-flash","display_name":"DeepSeek V4 Flash","recommended":false,"fits":true,"spilled":false,"needs_engine":false,"model_id":"DeepSeek-V4-Flash-0731-UD-Q4_K_XL","size_bytes":165991298560,"start_window":221184,"downloaded":false}]
    """#

    static func entries(_ json: String = realCatalog) throws -> [LocalModelCatalogEntry] {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([LocalModelCatalogEntry].self, from: Data(json.utf8))
    }

    static func snapshot(_ models: [LocalModelCatalogEntry], free: UInt64?) -> LocalModelSetupSnapshot {
        LocalModelSetupSnapshot(hardware: .init(ramTotalBytes: 206_158_430_208), models: models, freeDiskBytes: free)
    }

    static func entry(_ id: String, gb: Double, recommended: Bool = false, downloaded: Bool = false) throws -> LocalModelCatalogEntry {
        try entries(#"[{"id":"\#(id)","display_name":"\#(id)","recommended":\#(recommended),"fits":true,"spilled":false,"needs_engine":false,"model_id":"\#(id)-q4","size_bytes":\#(UInt64(gb * 1e9)),"start_window":65536,"downloaded":\#(downloaded)}]"#)[0]
    }

    @Test func theRealCatalogOnThisMacOffersAQuickStartThatFitsAndExplainsTheBestOne() throws {
        let choices = LocalModelChoices(Self.snapshot(try Self.entries(), free: 88_000_000_000))
        #expect(choices.quickStart?.id == "qwen3.6-35b-a3b",
                "3B active answers sooner than the dense 27B, and is within 10 GB of the smallest download")
        #expect(choices.best?.id == "qwen3.8-flash-next")
        #expect(choices.more.map(\.id) == ["qwen3.8-27b", "nemotron-3.5-bolt-74b-a9b", "deepseek-v4-flash"])
        #expect(choices.detail(try #require(choices.quickStart)).hasPrefix("23.6 GB · about"), "Quick start, with its size and time")
        let best = try #require(choices.best)
        #expect(!choices.canStart(best))
        #expect(LocalModelDisk.shortfall(best, free: choices.freeDisk)?.contains("104 GB") == true)
        #expect(LocalModelDisk.shortfall(best, free: choices.freeDisk)?.contains("88 GB") == true)
        #expect(choices.chosen("qwen3.8-flash-next")?.id == "qwen3.8-27b", "A model that can't start is never the one picked")
        #expect(choices.chosen("qwen3.8-27b")?.id == "qwen3.8-27b")
        #expect(choices.chosen("")?.id == "qwen3.6-35b-a3b")
    }

    @Test func aMixtureWithFewActiveParametersLeadsWhenItIsNotMuchBigger() throws {
        let catalog = try Self.entries()
        #expect(LocalModelChoices.activeBillions(catalog.first { $0.id == "qwen3.6-35b-a3b" }!) == 3)
        #expect(LocalModelChoices.activeBillions(catalog.first { $0.id == "nemotron-3.5-bolt-74b-a9b" }!) == 9)
        #expect(LocalModelChoices.activeBillions(catalog.first { $0.id == "qwen3.8-27b" }!) == nil, "Dense")
        #expect(LocalModelChoices.activeBillions(catalog.first { $0.id == "qwen3.8-flash-next" }!) == nil, "Its name doesn't say")
        // More than 10 GB over the smallest download: the smallest stays Quick start.
        let dense = try Self.entry("dense-8b", gb: 5), moe = try Self.entry("moe-30b-a3b", gb: 17)
        #expect(LocalModelChoices(Self.snapshot([dense, moe], free: 500_000_000_000)).quickStart?.id == "dense-8b")
        // Within 10 GB: the mixture leads, even over a small recommendation.
        let near = try Self.entry("moe-20b-a2b", gb: 12), rec = try Self.entry("rec", gb: 6, recommended: true)
        let choices = LocalModelChoices(Self.snapshot([dense, near, rec], free: 500_000_000_000))
        #expect(choices.quickStart?.id == "moe-20b-a2b")
        #expect(choices.best?.id == "rec", "Hermes's pick stays beside it")
        // Many active parameters are not quick: the usual rule.
        let heavy = try Self.entry("moe-235b-a22b", gb: 9)
        #expect(LocalModelChoices(Self.snapshot([dense, heavy], free: 500_000_000_000)).quickStart?.id == "moe-235b-a22b",
                "the largest of 10 GB or less, as before")
        #expect(LocalModelChoices.quickestToAnswer([dense, heavy]) == nil)
        // A model already on the Mac still comes first, and one that doesn't fit the disk never leads.
        let here = try Self.entry("here", gb: 4, downloaded: true)
        #expect(LocalModelChoices(Self.snapshot([here, near], free: 500_000_000_000)).quickStart?.id == "here")
        #expect(LocalModelChoices(Self.snapshot([dense, near], free: 11_000_000_000)).quickStart?.id == "dense-8b")
    }

    @Test func quickStartPrefersASmallRecommendationThenTheLargestSmallOne() throws {
        let big = try Self.entry("big", gb: 98.7, recommended: true)
        let small = try Self.entry("small", gb: 4.7), smaller = try Self.entry("smaller", gb: 2.5), mid = try Self.entry("mid", gb: 18.5)
        var choices = LocalModelChoices(Self.snapshot([big, mid, small, smaller], free: 500_000_000_000))
        #expect(choices.quickStart?.id == "small", "The largest at or under 10 GB")
        #expect(choices.best?.id == "big")
        let recommendedSmall = try Self.entry("rec", gb: 6, recommended: true)
        choices = LocalModelChoices(Self.snapshot([recommendedSmall, small, mid], free: 500_000_000_000))
        #expect(choices.quickStart?.id == "rec")
        #expect(choices.best == nil, "The recommendation is already Quick start")
        let tenExactly = try Self.entry("ten", gb: 10)
        choices = LocalModelChoices(Self.snapshot([big, tenExactly, mid], free: 500_000_000_000))
        #expect(choices.quickStart?.id == "ten")
    }

    @Test func aModelAlreadyOnTheMacIsTheQuickestStart() throws {
        let big = try Self.entry("big", gb: 40, recommended: true), small = try Self.entry("small", gb: 4)
        let here = try Self.entry("here", gb: 20, downloaded: true)
        let choices = LocalModelChoices(Self.snapshot([big, small, here], free: 1_000_000_000))
        #expect(choices.quickStart?.id == "here", "No download at all, even with little space left")
        #expect(choices.detail(here).contains("Downloaded"))
        let recommendedHere = try Self.entry("big", gb: 40, recommended: true, downloaded: true)
        #expect(LocalModelChoices(Self.snapshot([recommendedHere, small, here], free: 0)).quickStart?.id == "big")
    }

    @Test func nothingIsOfferedAsDefaultWhenNothingFitsTheDisk() throws {
        let choices = LocalModelChoices(Self.snapshot(try Self.entries(), free: 20_000_000_000))
        #expect(choices.quickStart == nil)
        #expect(choices.chosen("qwen3.8-27b") == nil)
        #expect(!choices.all.isEmpty, "They stay visible with what they need")
        #expect(choices.smallestShort?.id == "qwen3.8-27b", "The smallest shows what it needs, as Quick start would")
        #expect(LocalModelDisk.shortfall(try #require(choices.smallestShort), free: choices.freeDisk)?.hasPrefix("Needs 24 GB.") == true)
        #expect(!choices.more.contains { $0.id == "qwen3.8-27b" })
        #expect(LocalModelChoices(Self.snapshot(try Self.entries(), free: 88_000_000_000)).smallestShort == nil)
        let unknown = LocalModelChoices(Self.snapshot(try Self.entries(), free: nil))
        #expect(unknown.quickStart?.id == "qwen3.6-35b-a3b", "Unknown free space is not a reason to refuse")
    }

    @Test func diskNeedsTheModelPlusRoomToSpare() throws {
        #expect(LocalModelDisk.needed(for: 4_700_000_000) == 9_700_000_000)
        #expect(LocalModelDisk.needed(for: 98_727_556_448) == 103_727_556_448)
        #expect(LocalModelDisk.needed(for: 165_991_298_560) == 165_991_298_560 + 8_299_564_928, "5% once that is more than 5 GB")
        let mid = try Self.entry("mid", gb: 18.5)
        #expect(LocalModelDisk.fits(mid, free: 23_500_000_000))
        #expect(!LocalModelDisk.fits(mid, free: 23_499_999_999))
        #expect(LocalModelDisk.shortfall(mid, free: 23_500_000_000) == nil)
        #expect(LocalModelDisk.shortfall(mid, free: 20_000_000_000)?.hasPrefix("Needs 24 GB.") == true)
    }

    @Test func aDownloadThatDoesNotFitIsNeverStarted() async throws {
        let requests = RequestCount()
        let model = LocalModelQuickstart(api: .init { _, _, _ in requests.add(); throw CancellationError() },
            scope: .init(installationID: UUID(), connectionID: UUID(), profile: "default"),
            persistence: .init(load: { nil }, save: { _ in }), inspect: { throw CancellationError() },
            isCurrent: { true }, checkReply: { _ in "" }, freeDisk: { 20_000_000_000 })
        model.install(try Self.entry("mid", gb: 18.5))
        await model.waitForOperation()
        #expect(requests.value == 0)
        #expect(model.state == .idle)
        #expect(model.message?.contains("Nothing was started") == true)
    }

    @Test func sizesReadLikeAMac() {
        #expect(LocalModelSize.label(98_727_556_448) == "98.7 GB")
        #expect(LocalModelSize.label(18_538_593_472) == "18.5 GB")
        #expect(LocalModelSize.label(165_991_298_560) == "166 GB")
        #expect(LocalModelSize.label(850_000_000) == "850 MB")
        #expect(LocalModelSize.needed(103_663_934_270) == "104 GB")
        #expect(LocalModelSize.available(88_900_000_000) == "88 GB")
    }

    @Test func timeIsRoundedForReadingAndUsesTheRealSpeedOnceKnown() throws {
        #expect(LocalModelTime.rounded(10) == 60)
        #expect(LocalModelTime.rounded(376) == 7 * 60)
        #expect(LocalModelTime.rounded(1483) == 25 * 60)
        #expect(LocalModelTime.rounded(4900) == 80 * 60)
        #expect(LocalModelTime.estimate(bytes: 4_700_000_000, bytesPerSecond: 12_500_000).contains("7"))
        #expect(LocalModelTime.estimate(bytes: 18_538_593_472, bytesPerSecond: 12_500_000).contains("25"))
        let suite = "local-model-speed-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(LocalModelTime.measured(in: defaults) == nil)
        LocalModelTime.remember(55_000_000, in: defaults)
        #expect(LocalModelTime.measured(in: defaults) == 55_000_000)
        LocalModelTime.remember(.nan, in: defaults)
        #expect(LocalModelTime.measured(in: defaults) == 55_000_000)
    }

    @Test func timeLeftComesOnlyFromAMovingDownload() throws {
        func job(_ fields: String) throws -> LocalModelJob {
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(LocalModelJob.self, from: Data((#"{"job_id":"j","kind":"quickstart","target":"t","started_at":1,"# + fields + "}").utf8))
        }
        let moving = try job(#""status":"running","phase":"downloading","total_bytes":2000000000,"done_bytes":1000000000,"bytes_per_sec":1000000"#)
        #expect(LocalModelTime.left(moving)?.contains("15") == true)
        // What Hermes really sent between the engine and the model: a stale rate and no total.
        let stale = try job(#""status":"running","phase":"downloading","done_bytes":0,"bytes_per_sec":5594863.5,"eta_seconds":0"#)
        #expect(LocalModelTime.left(stale) == nil)
        let paused = try job(#""status":"paused","phase":"downloading","total_bytes":2000000000,"done_bytes":1000000000"#)
        #expect(LocalModelTime.left(paused) == nil)
        let engine = try job(#""status":"running","phase":"downloading-runtime","total_bytes":12201717,"done_bytes":10295163,"bytes_per_sec":4939136"#)
        #expect(LocalModelTime.left(engine) == nil)
        let almost = try job(#""status":"running","phase":"downloading","total_bytes":2000000000,"done_bytes":1990000000,"bytes_per_sec":1000000"#)
        #expect(LocalModelTime.left(almost) == "Less than a minute left")
        #expect(LocalModelDownload.progressWords(moving) == "1.0 of 2.0 GB")
        #expect(LocalModelDownload.stepWords(engine) == "Getting the engine")
    }

    @Test func failuresAreSortedFromHermesOwnWords() {
        #expect(LocalModelFailure("download failed from https://huggingface.co/x.gguf: <urlopen error [Errno 8] nodename nor servname provided, or not known>") == .network)
        #expect(LocalModelFailure("[Errno 28] No space left on device") == .disk)
        #expect(LocalModelFailure("sha256 mismatch for https://github.com/x.zip: pinned 0a, got 9f") == .checksum)
        #expect(LocalModelFailure("The local server could not start — open Local Models for details") == .other)
        #expect(LocalModelFailure(nil) == .other)
        for failure in [LocalModelFailure.network, .disk, .checksum, .other] { #expect(!failure.line.isEmpty) }
    }

    @Test func aFailedJobSaysWhyAndCanBeTriedAgain() async throws {
        let scope = LocalModelInstallScope(installationID: UUID(), connectionID: UUID(), profile: "default")
        nonisolated(unsafe) var saved: LocalModelInstallReceipt?
        let api = LocalModelAPI { _, path, _ in
            if path.hasSuffix("/quickstart") {
                return Data(#"{"job_id":"job-1","model_id":"mid","display_name":"mid","needs_runtime":false,"needs_download":true,"download_bytes":1}"#.utf8)
            }
            return Data(#"{"job_id":"job-1","kind":"quickstart","target":"mid","model_id":"mid","status":"error","phase":"downloading","done_bytes":5,"total_bytes":10,"started_at":1,"error":"[Errno 28] No space left on device"}"#.utf8)
        }
        let model = LocalModelQuickstart(api: api, scope: scope, persistence: .init(load: { saved }, save: { saved = $0 }),
            inspect: { throw CancellationError() }, isCurrent: { true }, checkReply: { _ in "" }, freeDisk: { nil })
        model.install(try Self.entry("mid", gb: 18.5))
        await model.waitForOperation()
        #expect(model.state == .failed)
        #expect(model.failure == .disk)
        #expect(model.message == LocalModelFailure.disk.line)
        #expect(model.canBegin)
        #expect(model.receipt?.catalogID == "mid")
    }

    @Test func underSixteenGigabytesAPlanIsSuggestedAndFromSixteenNothingChanges() {
        let gib: UInt64 = 1 << 30
        #expect(ModelMemoryGuidance.suggestsPlan(8 * gib))
        #expect(ModelMemoryGuidance.suggestedMode(8 * gib) == .cloud)
        #expect(ModelMemoryGuidance.line(8 * gib)?.contains("8 GB. A plan will feel faster.") == true)
        for memory in [16 * gib, 18 * gib, 192 * gib] {
            #expect(!ModelMemoryGuidance.suggestsPlan(memory))
            #expect(ModelMemoryGuidance.suggestedMode(memory) == .local)
            #expect(ModelMemoryGuidance.line(memory) == nil)
        }
        #expect(!ModelMemoryGuidance.suggestsPlan(nil))
        #expect(!ModelMemoryGuidance.suggestsPlan(0))
        #expect(ModelMemoryGuidance.suggestedMode(nil) == .local)
    }

    @Test func aJobCarriesHermesErrorAndRate() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let job = try decoder.decode(LocalModelJob.self, from: Data(#"{"job_id":"5041d7615e97","kind":"quickstart","target":"Qwen3 4B","model_id":"scratch-qwen3-4b","status":"running","phase":"downloading","detail":"Downloading","total_bytes":2497281120,"done_bytes":1155530752,"started_at":1794404457.478225,"error":null,"bytes_per_sec":71619602.8537659,"eta_seconds":19,"can_pause":true,"can_resume":false,"pause_requested":false,"percent":46,"ranges":{}}"#.utf8))
        #expect(job.bytesPerSec == 71619602.8537659)
        #expect(job.error == nil)
    }
}

private final class RequestCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
