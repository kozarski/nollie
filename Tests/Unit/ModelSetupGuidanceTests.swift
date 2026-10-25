import Foundation
import Testing
@testable import Nollie
import NollieCore

struct ModelSetupGuidanceTests {
    private let hardware = Data(#"{"uma":true,"ram_total_bytes":17179869184,"vram_usable_bytes":10737418240}"#.utf8)
    private let catalog = Data(#"{"models":[{"id":"small-model","display_name":"Example local model","recommended":true,"fits":true,"spilled":false,"needs_engine":false,"model_id":"small-model-q4","size_bytes":3500000000,"start_window":65536,"downloaded":false}]}"#.utf8)

    @Test func privateNeverInheritsGeneralCloudChoice() {
        for mode in ModelSetupMode.allCases {
            #expect(!mode.allowsCloud(isPrivate: true))
        }
        #expect(ModelSetupMode.cloud.allowsCloud(isPrivate: false))
        #expect(ModelSetupMode.both.allowsCloud(isPrivate: true, explicitlyAllowedForPrivate: true))
        #expect(!ModelSetupMode.local.allowsCloud(isPrivate: true, explicitlyAllowedForPrivate: true))
    }

    @Test func inspectionReadsOnlyHardwareAndCatalog() async throws {
        let reads = ModelSetupReads()
        let hardware = self.hardware, catalog = self.catalog
        let client = LocalModelSetupClient { path in
            await reads.append(path)
            return path.hasSuffix("/hardware") ? hardware : catalog
        }
        let snapshot = try await client.inspect()
        #expect(await reads.paths.sorted() == ["/api/local-models/catalog", "/api/local-models/hardware"])
        #expect(snapshot.hardware?.ramTotalBytes == 17_179_869_184)
        #expect(snapshot.recommended?.modelId == "small-model-q4")
        #expect(snapshot.recommended?.downloaded == false)
        #expect(snapshot.summary.contains("before continuing"))
    }

    @Test func missingFitFactsCannotBecomeAnAutomaticRecommendation() async throws {
        let hardware = self.hardware
        for mutation in [#""spilled":true"#, #""needs_engine":true"#, #""fits":false"#, #""start_window":0"#, #""size_bytes":0"#] {
            var row = try #require(try JSONSerialization.jsonObject(with: catalog) as? [String: Any])
            var models = try #require(row["models"] as? [[String: Any]])
            let change = try #require(try JSONSerialization.jsonObject(with: Data(("{" + mutation + "}").utf8)) as? [String: Any])
            models[0].merge(change) { _, new in new }; row["models"] = models
            let payload = try JSONSerialization.data(withJSONObject: row)
            let snapshot = try await LocalModelSetupClient { $0.hasSuffix("/hardware") ? hardware : payload }.inspect()
            #expect(snapshot.recommended == nil)
            #expect(snapshot.models.count == 1)
        }
        let incomplete = Data(#"{"models":[{"id":"unknown","display_name":"Unknown","recommended":true}]}"#.utf8)
        let snapshot = try await LocalModelSetupClient { $0.hasSuffix("/hardware") ? hardware : incomplete }.inspect()
        #expect(snapshot.recommended == nil)
    }

    @Test func olderHermesAndPartialFailureStayTruthful() async throws {
        let hardware = self.hardware
        let snapshot = try await LocalModelSetupClient { path in
            if path.hasSuffix("/catalog") { throw HermesAPIError.http(status: 404, detail: "not found") }
            return hardware
        }.inspect()
        #expect(snapshot.hardware != nil)
        #expect(snapshot.catalogIssue == .unsupported)
        #expect(snapshot.recommended == nil)
        let malformed = try await LocalModelSetupClient { _ in Data("not JSON".utf8) }.inspect()
        #expect(malformed.hardwareIssue == .invalidResponse)
        #expect(malformed.catalogIssue == .invalidResponse)
    }

    @Test func cancellationDoesNotTurnIntoUnavailableGuidance() async {
        do {
            _ = try await LocalModelSetupClient { _ in throw CancellationError() }.inspect()
            Issue.record("Cancelled inspection returned a snapshot")
        } catch { #expect(error is CancellationError) }
    }

    @Test func memoryIsDescriptiveAndDoesNotPromiseFit() {
        let mac = MacModelHardware(processor: "Example chip", totalMemoryBytes: 8 * 1024 * 1024 * 1024, isAppleSilicon: true)
        #expect(mac.summary.contains("Example chip"))
        #expect(mac.summary.contains("memory"))
        #expect(!mac.summary.contains("fits"))
    }
}

private actor ModelSetupReads {
    private(set) var paths: [String] = []
    func append(_ path: String) { paths.append(path) }
}
