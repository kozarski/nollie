import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

// If my plan runs out: the backup model written to the bot's Hermes config, and the one line the chat shows when
// Hermes moves to it and back.

private let bmLlama = BackupRoute(provider: "llamacpp", model: "llama-3.2-3b-instruct-q4_k_m")
private let bmRouter = BackupRoute(provider: "openrouter", model: "meta/llama-4")
private let bmClock: SleepNote.Clock = { _ in "3:00 PM" }
private let bmNow = Date(timeIntervalSince1970: 1_792_540_800)

@Suite struct BackupModelConfigTests {
    @Test func theChainIsReadAsHermesReadsIt() {
        let answer: JSONValue = .object(["config": .object([
            "fallback_providers": .array([.object(["provider": .string("llamacpp"), "model": .string(bmLlama.model)]),
                                          .object(["provider": .string(""), "model": .string("x")])]),
            "fallback_model": .object(["provider": .string("openrouter"), "model": .string("meta/llama-4")]),
        ])])
        #expect(BackupModelConfig.chain(in: answer) == [bmLlama, bmRouter])
        #expect(BackupModelConfig.current(in: answer) == bmLlama)
        // Without the wrapper, and with nothing set.
        #expect(BackupModelConfig.chain(in: .object(["fallback_providers": .array([])])).isEmpty)
        #expect(BackupModelConfig.current(in: .object([:])) == nil)
    }

    @Test func choosingReplacesOnlyTheFirstAndKeepsTheRest() {
        let answer: JSONValue = .object(["fallback_providers": .array([
            .object(["provider": .string("openrouter"), "model": .string("meta/llama-4")]),
            .object(["provider": .string("nous"), "model": .string("hermes-4"), "base_url": .string("https://n.example/v1")]),
        ])])
        let body = BackupModelConfig.update(choosing: bmLlama, in: answer)
        #expect(body == .object(["config": .object(["fallback_providers": .array([
            .object(["provider": .string("llamacpp"), "model": .string(bmLlama.model)]),
            .object(["provider": .string("nous"), "model": .string("hermes-4"), "base_url": .string("https://n.example/v1")]),
        ])])]))
    }

    @Test func offEmptiesTheListAndClearsTheOlderKey() {
        let older: JSONValue = .object(["config": .object(["fallback_model": .object(["provider": .string("openrouter"), "model": .string("m")])])])
        #expect(BackupModelConfig.update(choosing: nil, in: older)
                == .object(["config": .object(["fallback_providers": .array([]), "fallback_model": .null])]))
        #expect(BackupModelConfig.update(choosing: nil, in: .object([:])) == .object(["config": .object(["fallback_providers": .array([])])]))
    }

    @Test func theChoicesAreLocalModelsFirstThenOtherSignedInPlans() {
        let options = ModelOptionsResult(providers: [
            ModelProvider(slug: "anthropic", name: "Anthropic", isCurrent: true, authenticated: true),
            { var p = ModelProvider(slug: "openrouter", name: "OpenRouter", authenticated: true); p.featuredModels = ["meta/llama-4"]; return p }(),
            { var p = ModelProvider(slug: "openai", name: "OpenAI", authenticated: false); p.models = ["gpt"]; return p }(),
        ], model: "claude-sonnet-4.6", provider: "anthropic")
        let local = LocalModelSetupSnapshot(models: [
            LocalModelCatalogEntry(id: "llama-3b", displayName: "Llama 3.2 3B", downloaded: true, downloadedModelId: bmLlama.model),
            LocalModelCatalogEntry(id: "qwen-7b", displayName: "Qwen 7B", downloaded: false),
        ])
        let choices = BackupChoice.all(options: options, local: local, current: nil, privateBot: false)
        #expect(choices.map(\.route) == [bmLlama, bmRouter])
        #expect(choices.map(\.title) == ["Llama 3.2 3B \(ModelPlace.hereInSentence)", "OpenRouter"])
        // A private bot only ever gets a model on its own computer.
        #expect(BackupChoice.all(options: options, local: local, current: nil, privateBot: true).map(\.route) == [bmLlama])
        // One chosen elsewhere stays on offer.
        let other = BackupRoute(provider: "deepseek", model: "deepseek-chat")
        #expect(BackupChoice.all(options: options, local: nil, current: other, privateBot: false).first
                == BackupChoice(route: other, title: "DeepSeek"))
    }
}

@Suite struct BackupSwitchTests {
    private let switched = "⚠️ Model fallback: claude-sonnet-4.6 via claude-subscription-direct unavailable (billing or quota exhausted); "
        + "using llama-3.2-3b-instruct-q4_k_m via llamacpp. Primary retry eligible in ~5400 s; recovery is not guaranteed."

    @Test func hermesWordsBecomeOnePlainLine() throws {
        let change = try #require(BackupSwitch.read(kind: "lifecycle", text: switched, now: bmNow))
        #expect(change == .switched(from: BackupRoute(provider: "claude-subscription-direct", model: "claude-sonnet-4.6"),
                                    to: bmLlama, reason: .limit, retryAt: bmNow.addingTimeInterval(5400)))
        #expect(change.line(here: "on your Mac", clock: bmClock)
                == "Your Claude plan hit its limit, so Nollie is using Llama on your Mac until 3:00 PM.")
    }

    @Test func withoutATimeItSaysThisReplyOnly() throws {
        let text = "⚠️ Model fallback: gpt-5.5 via openai-codex unavailable (provider overloaded); using meta/llama-4 via openrouter."
        let change = try #require(BackupSwitch.read(kind: "lifecycle", text: text))
        #expect(change.line(here: "on this Mac") == "Your ChatGPT plan is busy, so Nollie is using OpenRouter for this reply.")
        let before = "⚠️ Provider fallback: anthropic/claude-opus-4.6 unavailable; using llamacpp/qwen2.5-7b for this response."
        #expect(BackupSwitch.read(kind: "lifecycle", text: before)?.line(here: "on this Mac")
                == "Your Anthropic account isn't answering, so Nollie is using Qwen on this Mac for this reply.")
    }

    @Test func andBackAgain() {
        let text = "✅ Primary model restored: claude-sonnet-4.6 via claude-subscription-direct; fallback llama-3.2 via llamacpp is no longer active."
        #expect(BackupSwitch.read(kind: "lifecycle", text: text)?.line(here: "on your Mac") == "Back on your Claude plan.")
        let unknown = "✅ Primary model restored: assistant via workshop; fallback x via llamacpp is no longer active."
        #expect(BackupSwitch.read(kind: "lifecycle", text: unknown)?.line(here: "on your Mac") == "Back on your main model.")
    }

    @Test func otherStatusLinesAreLeftAlone() {
        #expect(BackupSwitch.read(kind: "lifecycle", text: "⚠️ Rate limited — switching to fallback provider...") == nil)
        #expect(BackupSwitch.read(kind: "compacting", text: "Compacting context") == nil)
        #expect(BackupSwitch.reason("authentication failed") == .signIn)
        #expect(BackupSwitch.reason("context window exceeded") == .other)
        #expect(BackupRoute.shortName("unsloth/gemma-3-4b-it-GGUF") == "Gemma")
        #expect(BackupRoute.shortName("assistant") == "Assistant")
    }

    @Test func theNewChatViewShowsTheLineOnceAsANotice() {
        var state = ConversationReducer.reduce(ConversationState(lineage: ConversationLineage(tip: "s0")),
                                               .attached(ConversationSnapshot(runtimeSession: "rt-1", storedSession: "s0"),
                                                         held: [], requestedAt: 0, full: false))
        state = ConversationReducer.reduce(state, [
            .event(GatewayEventEnvelope(type: "message.delta", sessionId: "rt-1", seq: 1, payload: ["text": "Done."])),
            .event(GatewayEventEnvelope(type: "status.update", sessionId: "rt-1", seq: 2,
                                        payload: ["kind": "lifecycle", "text": .string(switched)])),
            .event(GatewayEventEnvelope(type: "message.complete", sessionId: "rt-1", seq: 3,
                                        payload: ["text": "Done.", "status": "complete"])),
        ])
        let notices = state.rows.compactMap { row -> String? in
            if case .note(.notice(let text)) = row.kind { return text } else { return nil }
        }
        #expect(notices.count == 1)
        #expect(notices.first?.hasPrefix("Your Claude plan hit its limit, so Nollie is using Llama") == true)
        #expect(state.activity != .status(switched))
    }

    @MainActor @Test func theChatShowsTheLineAsARow() throws {
        let chat = try ChatFixtures.chat(stored: "stored-backup", named: "backup")
        chat.handle(event: GatewayEvent(type: "status.update", sessionID: "s1",
                                        payload: .object(["kind": .string("lifecycle"), "text": .string(switched)])))
        let rows = chat.items.compactMap { item -> String? in
            if case .system(let text, _) = item.kind { return text } else { return nil }
        }
        #expect(rows.count == 1)
        #expect(rows.first?.contains("so Nollie is using Llama \(BackupSwitch.here) until") == true)
        #expect(chat.statusLine != switched)
    }
}
