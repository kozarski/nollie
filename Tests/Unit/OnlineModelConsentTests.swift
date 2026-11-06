import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Before a helper's words first go to an online model, the app names the company and asks. A model on
/// the person's own computer is never asked about, a no sends nothing, and a yes is kept until taken back.

@MainActor @Suite struct ModelCompanyTests {
    @Test func plansAndKeysNameTheCompanyBehindThem() {
        #expect(ModelCompany.behind("claude-subscription-max")?.name == "Anthropic")
        #expect(ModelCompany.behind("anthropic")?.id == "anthropic")
        #expect(ModelCompany.behind("openai-codex")?.name == "OpenAI")
        #expect(ModelCompany.behind("openai-api")?.id == "openai")
        #expect(ModelCompany.behind("vertex")?.name == "Google")
        #expect(ModelCompany.behind("anthropic")?.privacyPolicy?.host == "www.anthropic.com")
    }

    @Test func aModelOnTheAssistantsOwnComputerIsNoCompany() {
        for local in ["ollama", "llamacpp", "LM-Studio", "mlx", "local", "  "] {
            #expect(ModelCompany.behind(local) == nil, "\(local)")
        }
    }

    @Test func anUnknownProviderKeepsTheNameTheGatewayGives() {
        #expect(ModelCompany.behind("acme-ai", listedName: "Acme AI")?.name == "Acme AI")
        #expect(ModelCompany.behind("acme-ai")?.name == "acme-ai")
        #expect(ModelCompany.behind("acme-ai")?.privacyPolicy == nil)
    }
}

@MainActor @Suite struct OnlineModelConsentTests {
    private let anthropic = ModelCompany.behind("anthropic")!
    private let openAI = ModelCompany.behind("openai")!

    private func fresh() -> (OnlineModelConsent, UserDefaults) {
        let name = "consent-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let consent = OnlineModelConsent(defaults: defaults)
        consent.canShow = { true }
        return (consent, defaults)
    }

    private func pump(_ ready: () -> Bool) async {
        var turns = 0
        while !ready() && turns < 1000 {
            await Task.yield()
            turns += 1
        }
    }

    @Test func withNowhereToAskNothingGoes() async {
        let (consent, _) = fresh()
        #expect(await consent.ask([anthropic], bot: "Scout", chat: nil, demo: false) == false)
        #expect(consent.pending == nil)
    }

    @Test func inTheBackgroundNothingGoesUnlessAlreadyAllowed() async {
        let (consent, _) = fresh()
        consent.hostAppeared(UUID())
        consent.canShow = { false }
        #expect(await consent.ask([anthropic], bot: "Scout", chat: nil, demo: false) == false)
        #expect(consent.pending == nil)
    }

    @Test func aYesIsKeptAndNotAskedAgain() async {
        let (consent, defaults) = fresh()
        let host = UUID()
        consent.hostAppeared(host)
        let asking = Task { await consent.ask([anthropic, openAI], bot: "Scout", chat: nil, demo: false) }
        await pump { consent.pending != nil }
        #expect(consent.pending?.host == host)
        #expect(consent.pending?.companies.map(\.id) == ["anthropic", "openai"])
        consent.answer(true)
        #expect(await asking.value)
        #expect(consent.allowed == ["anthropic": "Anthropic", "openai": "OpenAI"])
        #expect((defaults.dictionary(forKey: OnlineModelConsent.key) as? [String: String])?["anthropic"] == "Anthropic")

        #expect(await consent.ask([anthropic], bot: "Scout", chat: nil, demo: false), "already allowed")
        #expect(consent.pending == nil)
    }

    @Test func aNoSendsNothingAndAsksAgainNextTime() async {
        let (consent, _) = fresh()
        consent.hostAppeared(UUID())
        let asking = Task { await consent.ask([anthropic], bot: "Scout", chat: nil, demo: false) }
        await pump { consent.pending != nil }
        consent.answer(false)
        #expect(await asking.value == false)
        #expect(consent.allowed.isEmpty)
    }

    @Test func onlyTheCompaniesNotYetAllowedAreAskedAbout() async {
        let (consent, _) = fresh()
        consent.hostAppeared(UUID())
        let first = Task { await consent.ask([anthropic], bot: "Scout", chat: nil, demo: false) }
        await pump { consent.pending != nil }
        consent.answer(true)
        _ = await first.value
        let second = Task { await consent.ask([anthropic, openAI], bot: "Scout", chat: nil, demo: false) }
        await pump { consent.pending != nil }
        #expect(consent.pending?.companies.map(\.id) == ["openai"])
        consent.answer(true)
        #expect(await second.value)
    }

    @Test func takingOneBackAsksAgain() async {
        let (consent, _) = fresh()
        consent.hostAppeared(UUID())
        let first = Task { await consent.ask([anthropic], bot: "Scout", chat: nil, demo: false) }
        await pump { consent.pending != nil }
        consent.answer(true)
        _ = await first.value
        consent.withdraw("anthropic")
        #expect(consent.allowed.isEmpty)
        let again = Task { await consent.ask([anthropic], bot: "Scout", chat: nil, demo: false) }
        await pump { consent.pending != nil }
        #expect(consent.pending != nil)
        consent.answer(false)
        _ = await again.value
    }

    @Test func aClosingSheetTakesItsAskWithIt() async {
        let (consent, _) = fresh()
        let window = UUID(), sheet = UUID()
        consent.hostAppeared(window)
        consent.hostAppeared(sheet)
        let asking = Task { await consent.ask([anthropic], bot: "Scout", chat: nil, demo: false) }
        await pump { consent.pending != nil }
        #expect(consent.pending?.host == sheet, "the newest one open asks")
        consent.hostWent(sheet)
        #expect(await asking.value == false)
        #expect(consent.pending == nil)
    }

    @Test func theDemoAsksWithItsOwnLineAndForgetsWhenTheSettingsGoBack() async {
        let (consent, defaults) = fresh()
        consent.hostAppeared(UUID())
        let asking = Task { await consent.ask([OnlineModelConsent.demoCompany], bot: "Mason", chat: nil, demo: true) }
        await pump { consent.pending != nil }
        #expect(consent.pending?.demo == true)
        // The demo's model belongs to no company, so its ask names none and nothing real is ever allowed.
        #expect(consent.pending?.companies.map(\.name) == ["The demo's model"])
        #expect(ModelCompany.behind("claude-subscription")?.id != OnlineModelConsent.demoCompany.id)
        consent.answer(true)
        #expect(await asking.value)
        #expect(consent.allows(OnlineModelConsent.demoCompany), "Settings shows it during the demo")
        // Leaving the demo puts the settings back as they were before it.
        defaults.removeObject(forKey: OnlineModelConsent.key)
        consent.reload()
        #expect(!consent.allows(OnlineModelConsent.demoCompany))
    }
}

/// The message box hands its words to `ChatSession.send`, which asks the runtime's share check first.
@MainActor @Suite struct ShareCheckSendTests {
    @MainActor private final class Line {
        private(set) var prompts: [String] = []
        private(set) var uploads = 0
        func answer(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
            switch method {
            case "prompt.submit":
                prompts.append(params["text"]?.stringValue ?? "")
                return ["status": "ok"]
            case "image.attach_bytes", "pdf.attach", "file.attach":
                uploads += 1
                return ["ref_text": "@file"]
            case "session.resume":
                return ["session_id": "live-1", "running": false, "messages": []]
            default:
                return ["status": "ok"]
            }
        }
    }

    private func bench(allow: Bool) throws -> (ChatSession, Line, () -> [String]) {
        let chat = try ChatFixtures.chat(stored: "stored-share-" + UUID().uuidString)
        chat.runtimeID = "live-1"
        let line = Line()
        chat.gatewayStandIn = { method, params in try await line.answer(method, params) }
        var asked: [String] = []
        chat.runtime.shareCheck = { profile, _ in
            asked.append(profile)
            return allow
        }
        return (chat, line, { asked })
    }

    @Test func aNoSendsNothingAndGivesTheWordsAndFilesBack() async throws {
        let (chat, line, asked) = try bench(allow: false)
        chat.stageAttachment(data: Data("notes".utf8), name: "notes.txt", kind: .file)
        let back = await chat.send("Book the table")
        #expect(back == "Book the table")
        #expect(line.prompts.isEmpty)
        #expect(line.uploads == 0)
        #expect(chat.staged.map(\.name) == ["notes.txt"], "the file stays for the next try")
        #expect(chat.composerHistory.isEmpty)
        #expect(asked() == [chat.profileName])
    }

    @Test func aYesSendsAsBefore() async throws {
        let (chat, line, _) = try bench(allow: true)
        #expect(await chat.send("Book the table") == nil)
        #expect(line.prompts == ["Book the table"])
    }

    @Test func aCommandIsNotAsked() async throws {
        let (chat, _, asked) = try bench(allow: false)
        _ = await chat.send("/help")
        #expect(asked().isEmpty)
    }

    @Test func wordsTheMacCarriesForThePhoneAreNotAskedAgain() async throws {
        let (chat, line, asked) = try bench(allow: false)
        #expect(await chat.send("From the phone", askedOnPhone: true) == nil)
        #expect(asked().isEmpty)
        #expect(line.prompts == ["From the phone"])
    }
}
