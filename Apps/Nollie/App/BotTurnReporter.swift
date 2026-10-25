import NollieCore

/// What a finished turn does on the phone and iPad: the bot spins once. Nothing shows while a turn
/// runs. (The Mac reports through `MenuBarTurnReporter`.)
@MainActor
final class BotTurnReporter: TurnActivityReporting {
    func end(for chat: ChatSession, phase: String) {
        BotAmbient.shared.turnFinished(profile: chat.profileName)
    }

    // Nothing to show while a turn runs.
    func start(for chat: ChatSession) {}
    func update(for chat: ChatSession, attention: Bool, detail: String?) {}
}
