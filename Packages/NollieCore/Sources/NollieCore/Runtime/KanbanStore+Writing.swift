import Foundation

// Board edits. Each is sent to the plugin and the board is then reloaded; one that succeeded
// also pokes the dispatcher, as the desktop client does.

extension KanbanStore {
    private enum Change {
        case patch(String, KanbanTaskPatch)
        case comment(String, String)
        case reassign(String, to: String?, reclaimFirst: Bool)
        case remove(String)
        case add(KanbanNewTask)

        /// Sends the change. Only an add has an answer worth keeping.
        func send(via api: KanbanAPI) async throws -> KanbanTaskEnvelope? {
            switch self {
            case .patch(let id, let patch): return try await api.update(id, patch)
            case .add(let task): return try await api.create(task)
            case .comment(let id, let text): try await api.comment(id, text)
            case .reassign(let id, let profile, let reclaim): try await api.reassign(id, to: profile, reclaimFirst: reclaim)
            case .remove(let id): try await api.delete(id)
            }
            return nil
        }
    }

    /// Sends a change, then reads the board whatever happened. If the server turns the change
    /// down, its words are stored only after that read: the read clears older errors, and a
    /// refused move used to look as if nothing had happened.
    private func submit(_ change: Change) async -> (accepted: Bool, answer: KanbanTaskEnvelope?) {
        guard let api else { return (false, nil) }
        let outcome: Result<KanbanTaskEnvelope?, Error>
        do { outcome = .success(try await change.send(via: api)) } catch { outcome = .failure(error) }
        if case .success = outcome { clearProblems() }
        await refresh()
        switch outcome {
        case .failure(let error):
            keep(refusal: Self.message(error))
            return (false, nil)
        case .success(let answer):
            _ = try? await api.dispatch()
            return (true, answer)
        }
    }

    private func clearProblems() {
        lastError = nil
        lastRefusal = nil
    }

    private func keep(refusal words: String) {
        lastError = words
        lastRefusal = words
    }

    /// Reads the board again and keeps the server's words in view.
    private func report(refusal words: String) async {
        await refresh()
        keep(refusal: words)
    }

    // MARK: What the page can ask for

    public func move(_ task: KanbanTask, to status: KanbanStatus, summary: String? = .none, blockReason: String? = .none) async -> Bool {
        var patch = KanbanTaskPatch()
        patch.status = status
        let note = (status == .done ? summary : status == .blocked ? blockReason : nil) ?? ""
        if !note.isEmpty {
            if status == .done {
                patch.result = note
                patch.summary = note
            } else {
                patch.blockReason = note
            }
        }
        return await submit(.patch(task.id, patch)).accepted
    }

    public func setPriority(_ task: KanbanTask, _ priority: Int) async -> Bool {
        await submit(.patch(task.id, KanbanTaskPatch(priority: priority))).accepted
    }

    public func edit(_ task: KanbanTask, title: String? = nil, body: String? = nil) async -> Bool {
        await submit(.patch(task.id, KanbanTaskPatch(title: title, body: body))).accepted
    }

    /// Gives the task to a different bot, reclaiming the worker first if it is running.
    public func reassign(_ task: KanbanTask, to profile: String?) async -> Bool {
        await submit(.reassign(task.id, to: profile, reclaimFirst: task.column == .running)).accepted
    }

    public func comment(_ task: KanbanTask, _ text: String) async -> Bool {
        await submit(.comment(task.id, text)).accepted
    }

    public func delete(_ task: KanbanTask) async -> Bool {
        await submit(.remove(task.id)).accepted
    }

    /// Creates a task. If nothing would pick it up, the reply includes the dispatcher's warning.
    public func create(_ new: KanbanNewTask) async -> KanbanTaskEnvelope? {
        await submit(.add(new)).answer
    }

    private enum StopOutcome {
        case stopped
        case alreadyOver
        case refused(String)
    }

    /// Ends the run if there is one, otherwise reclaims the task; reclaiming is also the fallback
    /// when ending the run fails.
    private func endWork(of task: KanbanTask, run: Int?, reason: String?, via api: KanbanAPI) async -> StopOutcome {
        do {
            switch run {
            case let run?: try await api.terminate(run: run, reason: reason)
            case nil: try await api.reclaim(task.id, reason: reason)
            }
            return .stopped
        } catch HermesAPIError.http(let status, _) where status == 409 {
            return .alreadyOver
        } catch {
            if run != nil, (try? await api.reclaim(task.id, reason: reason)) != nil { return .stopped }
            return .refused(Self.message(error))
        }
    }

    /// Stops a task's worker. A 409 means the run had already ended, so we just reload.
    public func stop(_ task: KanbanTask, reason: String? = nil) async -> Bool {
        guard let api = self.api else { return false }
        let run = task.currentRunId ?? worker(for: task)?.runId
        switch await endWork(of: task, run: run, reason: reason, via: api) {
        case .refused(let words):
            await report(refusal: words)
            return false
        case .stopped:
            lastError = nil
        case .alreadyOver:
            break
        }
        await refresh()
        return true
    }

    /// Asks the dispatcher to look at the board now instead of at its next tick.
    public func nudge() async {
        guard let api else { return }
        do {
            _ = try await api.dispatch()
        } catch {
            await report(refusal: Self.message(error))
            return
        }
        clearProblems()
        await refresh()
    }

    /// The server's `detail` if it refused the request; otherwise the error's own text.
    public nonisolated static func message(_ error: Error) -> String {
        if case HermesAPIError.http(_, let detail) = error, !detail.isEmpty { return detail }
        return error.localizedDescription
    }
}
