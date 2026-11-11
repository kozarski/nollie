import Foundation
import Testing
@testable import Nollie
import NollieCore

/// The setup step's model row: a green check and Continue only for a model that can answer.
struct ModelReadinessTests {
    private func options(_ provider: String, _ model: String?, authenticated: Bool?, warning: String? = nil) -> ModelOptionsResult {
        var entry = ModelProvider(slug: provider, name: provider, isCurrent: true, authenticated: authenticated)
        entry.warning = warning
        return ModelOptionsResult(providers: [entry], model: model, provider: provider)
    }

    private func local(downloaded: Bool) throws -> LocalModelSetupSnapshot {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let entry = try decoder.decode(LocalModelCatalogEntry.self, from: Data(#"{"id":"qwen3.8-27b","display_name":"Qwen3.8 27B","fits":true,"spilled":false,"needs_engine":false,"model_id":"Qwen3.8-27B-UD-Q4_K_M","size_bytes":18538593472,"start_window":262144,"downloaded":\#(downloaded)}"#.utf8))
        return LocalModelSetupSnapshot(models: [entry])
    }

    @Test func hermesUntouchedOnlineDefaultNeverCountsWhileOnThisMacIsChosen() {
        // What a fresh setup showed: Hermes's default, said to be signed in, with no key behind it.
        let fresh = options("anthropic", "anthropic/claude-sonnet-4.6", authenticated: true)
        let status = ModelReadiness.read(fresh, mode: .local, local: nil)
        #expect(!status.isReady)
        #expect(!status.detail.contains("anthropic/"), "Never the raw id")
        #expect(ModelReadiness.read(fresh, mode: .cloud, local: nil) == .ready("Claude Sonnet 4.6"))
        #expect(ModelReadiness.read(fresh, mode: .both, local: nil).isReady)
    }

    @Test func anOnlineModelNeedsAWorkingSignIn() {
        #expect(ModelReadiness.read(options("anthropic", "anthropic/claude-sonnet-4.6", authenticated: false), mode: .cloud, local: nil)
                == .needsSignIn("Claude Sonnet 4.6"))
        #expect(!ModelReadiness.read(options("anthropic", "anthropic/claude-sonnet-4.6", authenticated: nil), mode: .cloud, local: nil).isReady)
        #expect(!ModelReadiness.read(options("claude-subscription-direct", "claude-subscription/opus-4.6", authenticated: true,
                                             warning: "Needs a sign-in on the Mac"), mode: .cloud, local: nil).isReady)
        let missing = ModelOptionsResult(providers: [], model: "anthropic/claude-sonnet-4.6", provider: "anthropic")
        #expect(!ModelReadiness.read(missing, mode: .cloud, local: nil).isReady)
    }

    @Test func aModelOnThisMacCountsOnceDownloadedAndChosen() throws {
        let chosen = options("llamacpp", "Qwen3.8-27B-UD-Q4_K_M", authenticated: true)
        #expect(ModelReadiness.read(chosen, mode: .local, local: try local(downloaded: true)) == .ready("Qwen3.8 27B"))
        #expect(!ModelReadiness.read(chosen, mode: .local, local: try local(downloaded: false)).isReady)
        #expect(!ModelReadiness.read(chosen, mode: .local, local: nil).isReady, "Not yet known is not ready")
        #expect(ModelReadiness.read(chosen, mode: .both, local: try local(downloaded: true)).isReady)
        #expect(!ModelReadiness.read(chosen, mode: .cloud, local: try local(downloaded: true)).isReady)
    }

    @Test func noModelSaysSoSteadily() {
        let empty = ModelOptionsResult(providers: [], model: "", provider: "")
        for mode in ModelSetupMode.allCases {
            #expect(ModelReadiness.read(empty, mode: mode, local: nil) == .none)
        }
        #expect(ModelReadiness.none.detail == "No model selected yet")
    }

    @Test func friendlyNamesReadAsPeopleSayThem() {
        #expect(ModelPlace.friendlyName("anthropic/claude-sonnet-4.6") == "Claude Sonnet 4.6")
        #expect(ModelPlace.friendlyName("openai/gpt-5.1-mini") == "GPT 5.1 Mini")
        #expect(ModelPlace.friendlyName("nous/hermes-4-70b") == "Hermes 4 70b")
        #expect(ModelPlace.friendlyName("Qwen3.8-27B-UD-Q4_K_M") == "Qwen3.8 27B UD Q4 K M")
        #expect(ModelPlace.friendlyName("") == "")
    }
}
