#if NOLLIE_DIRECT
import Foundation
import NollieCore

/// The running app, as the update gate sees it.
@MainActor
final class LiveUpdateEnvironment: UpdateInstallEnvironment {
    private let model: AppModel
    private let computer: ComputerCenter

    init(model: AppModel = .shared, computer: ComputerCenter = .shared) {
        self.model = model
        self.computer = computer
    }

    func runningTurns() -> [UpdateTurn] {
        // Only Nollie's own background service restarts for the update. A gateway somewhere else keeps
        // working whatever happens to this app.
        guard let runtime = model.runtime, runtime.connection.managedInstallationID != nil else { return [] }
        return runtime.chats.filter(\.isRunning).map { UpdateTurn(id: $0.storedID, bot: $0.profileName) }
    }

    func stopComputer() -> Bool {
        guard computer.task != nil else { return false }
        computer.stop()
        return true
    }

    func pause(_ turn: UpdateTurn) async {
        guard let chat = model.runtime?.chats.first(where: { $0.storedID == turn.id }) else { return }
        await chat.pauseForUpdate()
    }
}
#endif
