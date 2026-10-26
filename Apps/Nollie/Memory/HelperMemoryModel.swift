import Foundation
import Observation
import NollieCore

/// What one helper remembers, for its Memory tab. Everything lives on the Mac that runs Hermes: this
/// reads it, and asks the add-on for each change, which answers with the list as it is now. Nothing is
/// kept on this device.
///
/// Forgetting waits a few seconds with Undo before anything is sent. An edit to an entry Hermes has
/// changed meanwhile is refused by the add-on; the person's words stay in the editor and the list is
/// read again, so saving once more keeps them.
@MainActor @Observable
final class HelperMemoryModel {
    /// What the model needs from the gateway, for one bot. Tests stand in for it.
    struct Door {
        var load: () async throws -> HelperMemory
        var add: (String) async throws -> HelperMemory
        var edit: (_ old: String, _ new: String, HelperMemoryKind) async throws -> HelperMemory
        var forget: (String, HelperMemoryKind) async throws -> HelperMemory
        var setOn: (Bool) async throws -> HelperMemory
    }

    enum Phase: Equatable { case loading, ready, unavailable, failed }

    /// One remembered thing being written: a new one, or a change to the entry the person opened.
    struct Draft: Identifiable, Equatable {
        let id = UUID()
        var original: HelperMemoryEntry?
        var kind: HelperMemoryKind
        var text: String

        static func new() -> Draft { Draft(original: nil, kind: .user, text: "") }
        static func editing(_ entry: HelperMemoryEntry, in kind: HelperMemoryKind) -> Draft {
            Draft(original: entry, kind: kind, text: entry.text)
        }

        var isNew: Bool { original == nil }
        var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var canSave: Bool { !trimmed.isEmpty && trimmed != original?.text }
    }

    enum Saved: Equatable {
        case saved
        /// It changed on the Mac first. The draft is kept, now aimed at what is there.
        case changed(Draft)
        case refused(String)
        case failed
    }

    /// An entry on its way out: hidden at once, sent when Undo has had its few seconds.
    struct Forgetting: Equatable {
        let id = UUID()
        var entry: HelperMemoryEntry
        var kind: HelperMemoryKind
    }

    private(set) var memory: HelperMemory?
    private(set) var phase: Phase = .loading
    private(set) var switching = false
    private(set) var forgetting: Forgetting?
    /// Forgets on their way to the Mac: still hidden until it answers.
    private(set) var leaving: [Forgetting] = []
    /// What went wrong last, in a few words, until the next thing works.
    private(set) var problem: String?

    private let undoWindow: Duration
    private let wait: @Sendable (Duration) async throws -> Void
    private var door: Door?
    private var timer: Task<Void, Never>?
    private var operation = UUID()

    init(undoWindow: Duration = .seconds(5),
         wait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.undoWindow = undoWindow
        self.wait = wait
    }

    // MARK: What it shows

    /// Newest first, less anything waiting to be forgotten.
    func rows(_ kind: HelperMemoryKind) -> [HelperMemoryEntry] {
        let hidden = (leaving + [forgetting].compactMap { $0 }).filter { $0.kind == kind }.map(\.entry.text)
        return (memory?.list(kind).newestFirst ?? []).filter { !hidden.contains($0.text) }
    }

    var shownCount: Int { HelperMemoryKind.allCases.reduce(0) { $0 + rows($1).count } }
    var isEmpty: Bool { memory != nil && shownCount == 0 && forgetting == nil }
    var isOn: Bool { memory?.on ?? true }

    // MARK: Reading

    /// Reads the list for this door. A new door (another bot or gateway) starts clean.
    func load(_ door: Door) async {
        let fresh = self.door == nil
        self.door = door
        let operation = UUID()
        self.operation = operation
        if fresh { phase = .loading }
        do {
            let found = try await door.load()
            guard self.operation == operation else { return }
            memory = found
            phase = .ready
            problem = nil
        } catch HelperMemoryError.unavailable, HelperMemoryError.privateBot {
            guard self.operation == operation else { return }
            phase = .unavailable
        } catch {
            guard self.operation == operation, !Task.isCancelled else { return }
            if memory == nil { phase = .failed }
            problem = "Couldn't read this. Try again."
        }
    }

    /// Forgets everything shown, for a bot that became private or a gateway that went away.
    func reset() {
        timer?.cancel()
        timer = nil
        forgetting = nil
        leaving = []
        operation = UUID()
        memory = nil
        door = nil
        phase = .loading
        problem = nil
    }

    // MARK: Changing

    func save(_ draft: Draft) async -> Saved {
        guard let door, draft.canSave else { return .failed }
        let words = draft.trimmed
        do {
            if let original = draft.original {
                memory = try await door.edit(original.text, words, draft.kind)
            } else {
                memory = try await door.add(words)
            }
            problem = nil
            return .saved
        } catch HelperMemoryError.changed {
            // Read again, and aim the same words at what is there now: the entry if it is still
            // there, or a new one if it went.
            await load(door)
            var kept = draft
            if let original = draft.original, !(memory?.contains(original.text, in: draft.kind) ?? false) {
                kept.original = nil
            }
            return .changed(kept)
        } catch HelperMemoryError.refused(let words) {
            return .refused(words.isEmpty ? "Your helper can't keep that." : words)
        } catch {
            return .failed
        }
    }

    /// Hides the entry and gives Undo a few seconds. Another forget sends the one before at once.
    func forget(_ entry: HelperMemoryEntry, in kind: HelperMemoryKind) {
        if let earlier = forgetting { leave(earlier) }
        let next = Forgetting(entry: entry, kind: kind)
        forgetting = next
        let window = undoWindow
        let wait = self.wait
        timer = Task { [weak self] in
            do { try await wait(window) } catch { return }
            guard let self, self.forgetting?.id == next.id else { return }
            self.leave(next)
        }
    }

    func undo() {
        timer?.cancel()
        timer = nil
        forgetting = nil
    }

    /// Sends the waiting forget now, as the tab closes.
    func sendForget() async {
        guard let waiting = forgetting else { return }
        hold(waiting)
        await send(waiting)
    }

    /// Undo's time is up: send it, keeping it hidden until the Mac answers.
    private func leave(_ waiting: Forgetting) {
        hold(waiting)
        Task { await send(waiting) }
    }

    private func hold(_ waiting: Forgetting) {
        if forgetting?.id == waiting.id {
            timer?.cancel()
            timer = nil
            forgetting = nil
        }
        leaving.append(waiting)
    }

    private func send(_ waiting: Forgetting) async {
        defer { leaving.removeAll { $0 == waiting } }
        guard let door else { return }
        do {
            memory = try await door.forget(waiting.entry.text, waiting.kind)
            problem = nil
        } catch {
            leaving.removeAll { $0 == waiting }
            await load(door)
            problem = "Couldn't forget that. Try again."
        }
    }

    func setOn(_ on: Bool) async {
        guard let door, !switching, memory?.on != on else { return }
        switching = true
        defer { switching = false }
        let was = memory
        memory?.on = on
        do {
            memory = try await door.setOn(on)
            problem = nil
        } catch {
            memory = was
            problem = "Couldn't change that. Try again."
        }
    }

    // MARK: The gateway

    static func door(runtime: GatewayRuntime, bot: String, onThisMac: Bool) -> Door {
        Door(load: { try await runtime.helperMemory(bot: bot, onThisMac: onThisMac) },
             add: { try await runtime.rememberForHelper($0, bot: bot, onThisMac: onThisMac) },
             edit: { try await runtime.editHelperMemory($0, to: $1, kind: $2, bot: bot, onThisMac: onThisMac) },
             forget: { try await runtime.forgetHelperMemory($0, kind: $1, bot: bot, onThisMac: onThisMac) },
             setOn: { try await runtime.setHelperMemory(on: $0, bot: bot, onThisMac: onThisMac) })
    }
}
