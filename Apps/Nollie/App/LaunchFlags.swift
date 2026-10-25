#if DEBUG
import Foundation
import NollieCore

/// Launch flags for demos and screenshots (debug builds only).
///
/// - `-nollie-demo-tab <tab>` opens that tab.
/// - `-nollie-demo-profile <bot>` selects a bot once the gateway lists it.
/// - `-nollie-demo-open-chat <id>` and `-nollie-demo-open-main` open a chat.
/// - `-nollie-demo-say <words>` starts a new chat with those words.
/// - `-nollie-demo-bot-page history|knows|settings` opens a bot page.
@MainActor
enum LaunchFlags {
    static func apply(model: AppModel, companion: CompanionFlow) {
        let arguments = ProcessInfo.processInfo.arguments
        func value(of flag: String) -> String? {
            guard let at = arguments.firstIndex(of: flag), arguments.indices.contains(at + 1) else { return nil }
            return arguments[at + 1]
        }
        /// Runs `work` after a pause, on the main actor.
        func later(_ seconds: Double, _ work: @escaping @MainActor () async -> Void) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                await work()
            }
        }

        companion.showsPrompt = arguments.contains("-nollie-show-companion-prompt")
        companion.showsInstaller = arguments.contains("-nollie-show-setup")
        if AppModel.forceSignIn, let active = model.store.active { model.signInPrompt = [active] }

        if let name = value(of: "-nollie-demo-tab"), let tab = AppModel.AppTab(rawValue: name) {
            model.selectedTab = tab
            if tab == .kanban {
                // The Board only opens once the gateway has said it has one, so ask again later.
                later(4) {
                    model.selectedTab = .chats
                    try? await Task.sleep(for: .milliseconds(300))
                    model.selectedTab = .kanban
                }
            }
        }

        if let bot = value(of: "-nollie-demo-profile") {
            Task { @MainActor in
                for _ in 0..<60 {
                    if let runtime = model.runtime, runtime.profiles.contains(where: { $0.name == bot }) {
                        runtime.selectedProfile = bot
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }

        // The bot's launch arguments carry no underscores, so "-" stands in for "_" in ids.
        if let id = value(of: "-nollie-demo-open-chat"),
           let link = URL(string: "nollie://chat/" + id.replacingOccurrences(of: "-", with: "_")) {
            later(4) { model.open(link) }
        }

        if let words = value(of: "-nollie-demo-say") {
            later(4) {
                model.demoFirstMessage = words.replacingOccurrences(of: "-", with: " ")
                model.sideChatRequestedAt = Date()
                model.newChatRequest = UUID()
            }
        }

        if arguments.contains("-nollie-demo-open-main") {
            later(4) { await model.openMainChat() }
        }

        if let name = value(of: "-nollie-demo-bot-page"), let kind = BotSheet.Kind(rawValue: name) {
            later(5) {
                let chosen = value(of: "-nollie-demo-bot-profile")
                    ?? model.runtime?.defaultProfile ?? model.runtime?.profiles.first?.name
                if let chosen { model.openBotPage(kind, profile: chosen) }
            }
        }
    }
}
#endif
