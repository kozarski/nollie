import Foundation
import NollieCore
#if os(iOS)
import UIKit
#endif

/// Before a helper's words first go to an online model, Nollie names the company, says what goes to it
/// and asks. Every way words leave for a bot asks this first: the message box, the new chat sheet,
/// Siri, a notification's reply, talk mode, board tasks and their comments, and new schedules. Each yes
/// is kept on this device, and Settings › Privacy › Online models lists them and takes one back. A model on the person's own computer
/// is never asked about. The demo asks too; its answers go when the demo puts the settings back.
@MainActor @Observable
final class OnlineModelConsent {
    static let shared = OnlineModelConsent()

    /// Where the companies allowed on this device are kept.
    nonisolated static let key = "privacy.onlineModels.allowed"

    /// The demo's helpers think with nothing real and nothing leaves the device, so its ask names no company: it
    /// shows the ask as an example, and Settings lists the demo's model until the demo ends.
    static let demoCompany = ModelCompany(
        id: "demo", name: String(localized: "The demo's model", comment: "Privacy: a row in Settings while the demo runs; its made-up model"))

    struct Ask: Identifiable {
        let id = UUID()
        let companies: [ModelCompany]
        let bot: String
        let demo: Bool
        /// The chat to ask over, or for words sent from outside a chat, the window or sheet to ask in.
        let chat: ObjectIdentifier?
        let host: UUID?
        fileprivate let answer: CheckedContinuation<Bool, Never>
    }

    private(set) var pending: Ask?
    private let defaults: UserDefaults
    /// Chats on screen now, counted, so the ask goes over the one it is about.
    @ObservationIgnored private var chatsShown: [ObjectIdentifier: Int] = [:]
    /// Windows and sheets that can ask about words sent from outside a chat, the newest last.
    @ObservationIgnored private var hosts: [UUID] = []
    /// Each bot's companies, kept for a few minutes so a message does not wait on the gateway every time.
    @ObservationIgnored private var looked: [String: (companies: [ModelCompany], at: Date)] = [:]

    /// The companies allowed on this device, by id, each with the name it was allowed under.
    private(set) var allowed: [String: String]

    /// Whether an ask can be seen now. In the background (Siri, a notification's reply) it can't, so
    /// words for a company not yet allowed don't go.
    @ObservationIgnored var canShow: @MainActor () -> Bool = {
        #if os(iOS)
        UIApplication.shared.applicationState != .background
        #else
        true
        #endif
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        allowed = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func allows(_ company: ModelCompany) -> Bool { allowed[company.id] != nil }

    func withdraw(_ id: String) {
        allowed[id] = nil
        defaults.set(allowed, forKey: Self.key)
    }

    /// Reads the list again, once the demo has put the settings back.
    func reload() {
        allowed = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    private func allow(_ companies: [ModelCompany]) {
        for company in companies { allowed[company.id] = company.name }
        defaults.set(allowed, forKey: Self.key)
    }

    // MARK: Asking

    /// True once every company may have the words. The ask goes over the chat when it is on screen,
    /// otherwise over the newest window or sheet. With nowhere to ask, another ask already up, or the
    /// app in the background, nothing goes.
    func ask(_ companies: [ModelCompany], bot: String, chat: ChatSession?, demo: Bool) async -> Bool {
        let missing = companies.filter { !allows($0) }
        guard !missing.isEmpty else { return true }
        guard pending == nil, canShow() else { return false }
        if let chat { await settle(chat) }
        let shown = chat.map(ObjectIdentifier.init).flatMap { chatsShown[$0, default: 0] > 0 ? $0 : nil }
        let host = shown == nil ? hosts.last : nil
        guard shown != nil || host != nil else { return false }
        let yes = await withCheckedContinuation { answer in
            pending = Ask(companies: missing, bot: bot, demo: demo, chat: shown, host: host, answer: answer)
        }
        if yes { allow(missing) }
        return yes
    }

    /// A chat's first message can go before its screen is up, while the new chat sheet is still closing.
    /// Wait a moment for the screen, and for it to finish arriving, so the ask is not lost in between.
    private func settle(_ chat: ChatSession) async {
        let key = ObjectIdentifier(chat)
        guard chatsShown[key, default: 0] == 0 else { return }
        for _ in 0..<20 where chatsShown[key, default: 0] == 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if chatsShown[key, default: 0] > 0 { try? await Task.sleep(for: .milliseconds(400)) }
    }

    func answer(_ yes: Bool) {
        guard let ask = pending else { return }
        pending = nil
        ask.answer.resume(returning: yes)
    }

    func chatAppeared(_ chat: ChatSession) {
        chatsShown[ObjectIdentifier(chat), default: 0] += 1
    }

    /// A chat that leaves the screen takes its ask with it, unanswered.
    func chatWent(_ chat: ChatSession) {
        let key = ObjectIdentifier(chat)
        chatsShown[key, default: 1] -= 1
        guard chatsShown[key] == 0 else { return }
        chatsShown[key] = nil
        if pending?.chat == key { answer(false) }
    }

    func hostAppeared(_ id: UUID) { hosts.append(id) }

    /// A window or sheet that closes takes its ask with it, unanswered.
    func hostWent(_ id: UUID) {
        hosts.removeAll { $0 == id }
        if pending?.host == id { answer(false) }
    }

    // MARK: Where the words go

    /// The hook a gateway's runtime asks before words for a bot go out.
    static func hook(for runtime: GatewayRuntime, demo: @escaping @MainActor () -> Bool) -> @MainActor (String, ChatSession?) async -> Bool {
        { [weak runtime] profile, chat in
            guard let runtime else { return false }
            let isDemo = demo()
            let consent = OnlineModelConsent.shared
            let companies = isDemo ? [demoCompany] : await consent.companies(for: profile, chat: chat, on: runtime)
            guard !companies.isEmpty else { return true }
            let bot = runtime.profiles.first { $0.name == profile }?.shownName ?? profile.capitalized
            return await consent.ask(companies, bot: bot, chat: chat, demo: isDemo)
        }
    }

    /// The companies a bot's words can reach: its model's, then any backup's the gateway lets this
    /// device read. A model that can't be found at all is asked about in general words.
    func companies(for profile: String, chat: ChatSession?, on runtime: GatewayRuntime) async -> [ModelCompany] {
        let key = runtime.connection.id.uuidString + "|" + profile
        let main: [ModelCompany]
        if let live = chat?.info?.provider ?? runtime.profiles.first(where: { $0.name == profile })?.provider, !live.isEmpty {
            main = ModelCompany.behind(live).map { [$0] } ?? []
        } else if let options: ModelOptionsResult = try? await runtime.api.get("/api/model/options", profile: profile) {
            main = ModelPlace.provider(options).flatMap { slug in
                ModelCompany.behind(slug, listedName: options.providers.first { $0.slug == slug }?.name)
            }.map { [$0] } ?? []
        } else {
            main = [Self.unknownCompany]
        }
        let backups: [ModelCompany]
        if let kept = looked[key], kept.at.timeIntervalSinceNow > -300 {
            backups = kept.companies
        } else {
            let config: JSONValue? = try? await runtime.api.get("/api/config", profile: profile)
            backups = config.map { BackupModelConfig.chain(in: $0).compactMap { ModelCompany.behind($0.provider) } } ?? []
            looked[key] = (backups, Date())
        }
        var seen = Set<String>()
        return (main + backups).filter { seen.insert($0.id).inserted }
    }

    /// For a gateway that won't say which model a bot uses.
    static let unknownCompany = ModelCompany(
        id: "unknown", name: String(localized: "An online model", comment: "Privacy: a row in Settings for a model the gateway didn't name"))
}
