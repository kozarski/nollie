import NollieCore
import SwiftUI

/// What the Board's inspector knows about the chosen card, and everything it can change on it.
/// The views only show these values and call these functions.
@MainActor @Observable
final class TaskInspectorModel {
    var detail: KanbanTaskDetail?
    var loadProblem: String?
    /// The question waiting on a yes (or a note), and the note typed so far.
    var ask: KanbanAsk?
    var answer = ""
    /// A reason to show the person, after a change the gateway refused.
    var notice: String?

    private var store: KanbanStore?
    private var taskID = ""

    var task: KanbanTask? { detail?.task }

    /// Points the model at a card. What was loaded for the last one is dropped.
    func show(_ id: String, in store: KanbanStore?) {
        self.store = store
        taskID = id
        detail = nil
        loadProblem = nil
    }

    // MARK: Reading

    func load() async {
        guard let store else { return }
        do {
            let fresh = try await store.detail(taskID)
            loadProblem = nil
            detail = fresh
        } catch {
            if detail == nil { loadProblem = KanbanStore.message(error) }
        }
    }

    /// While a worker is on the card, read it again every few seconds until the view goes away.
    func followWorker() async {
        guard task?.isWorking ?? false else { return }
        while true {
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            await load()
        }
    }

    /// Everyone the card could be given to: the board's people, this gateway's bots, and its
    /// current owner when that is neither.
    func candidates(gatewayBots: [String]) -> [String] {
        var names = store?.assignees.map(\.name) ?? []
        let extras = gatewayBots + [task?.assignee ?? ""]
        for name in extras where !name.isEmpty && !names.contains(name) { names.append(name) }
        return names
    }

    // MARK: Changing

    /// After a change: say why if it failed, and read the card again either way.
    private func settle(_ worked: Bool?) async {
        if worked == false, let reason = store?.lastError { notice = reason }
        await load()
    }

    func move(to status: KanbanStatus) async {
        guard let task, let store else { return }
        guard status.isMoveTarget else {
            notice = status.notMovableReason
            return
        }
        if let question = KanbanAsk.gate(task, movingTo: status) {
            ask = question
        } else {
            await settle(store.move(task, to: status))
        }
    }

    func give(to bot: String?) async {
        guard let task, let store else { return }
        await settle(store.reassign(task, to: bot))
    }

    func prioritise(_ level: Int) async {
        guard let task, let store else { return }
        await settle(store.setPriority(task, level))
    }

    /// Runs the question the person just confirmed. True when the card itself was deleted.
    func confirm(_ chosen: KanbanAsk) async -> Bool {
        let typed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        answer = ""
        ask = nil
        guard let store else { return false }
        await settle(await store.carryOut(chosen, typed: typed))
        if case .delete = chosen { return true }
        return false
    }

    func retitle(_ title: String) async {
        guard let task, let store, title != task.title else { return }
        await settle(store.edit(task, title: title, body: nil))
    }

    func rewrite(_ text: String) async {
        guard let task, let store, text != (task.body ?? "") else { return }
        await settle(store.edit(task, title: nil, body: text))
    }

    /// Adds a comment. True when it went through.
    func post(_ text: String) async -> Bool {
        guard let task, let store else { return false }
        guard await store.comment(task, text) else {
            notice = store.lastError
            return false
        }
        await load()
        return true
    }
}
