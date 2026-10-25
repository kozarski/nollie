import SwiftUI
import NollieCore

/// A one-line goal for each chat with a busy bot, such as "Tracking down a slow report". It names
/// the purpose rather than the step in progress. Nollie Summaries writes it on the device, working
/// out the purpose from what was asked plus the steps taken. It runs soon after a turn begins and then whenever the work
/// shifts, never faster than `Pace` allows. Nothing is saved or sent off the device. When the model
/// is off or unavailable there is no line and screens show the current step.
@MainActor @Observable
final class ChatGoals {
    static let shared = ChatGoals()

    /// Nollie Summaries has a third switch. Untouched, it is on whenever one of the other two is on.
    static let enabledKey = "chats.aiSummaries.goals"
    static var isOn: Bool {
        let stored = UserDefaults.standard.object(forKey: enabledKey) as? Bool
        return stored ?? (ChatSummarizer.titlesOn || ChatSummarizer.previewsOn)
    }

    typealias TurnLookup = @MainActor (String) -> String?
    typealias Writer = @Sendable (Input) async -> String?

    private(set) var goals = [String: Goal]()
    /// Produces a line, or nil when it cannot. Tests replace it.
    var writer: Writer = ChatGoals.onDevice
    /// True when the Nollie Summaries setting allows this line.
    var on: () -> Bool = { ChatGoals.isOn }
    var now: () -> Date = { Date() }

    /// Per stored chat id: the turn first seen and when.
    private var sightings = [String: (turn: String, since: Date)]()
    private var writing = Set<String>()
    private var watcher: Task<Void, Never>?
    private weak var runtime: GatewayRuntime?

    /// Whether the model is mid-write for any chat; tests poll this.
    var isWriting: Bool { !writing.isEmpty }

    /// The current line for a chat, if its bot is busy and a line exists.
    func goal(for storedID: String) -> String? {
        if storedID.isEmpty || !on() { return nil }
        if let found = goals[storedID] { return found.text }
        return nil
    }

    #if DEBUG
    /// Screenshots in the simulator cannot run the model. Launch with `-nollie-test-goal "..."` to
    /// stand in for it, and add `-nollie-test-goal-delay 4` to make the stand-in slow like the model.
    func useTestWriterIfAsked() {
        let defaults = UserDefaults.standard
        guard let line = defaults.string(forKey: "nollie-test-goal"), !line.isEmpty else { return }
        let delay = defaults.double(forKey: "nollie-test-goal-delay")
        writer = { _ in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            return line
        }
    }
    #endif

    // MARK: Watching a gateway

    /// Starts following the chats of `runtime`, dropping everything held for the previous one.
    func attach(_ runtime: GatewayRuntime?) {
        if runtime === self.runtime && watcher != nil { return }
        self.runtime = runtime
        goals = [:]
        sightings = [:]
        watcher?.cancel()
        guard runtime != nil else {
            watcher = nil
            return
        }
        watcher = Task { [weak self] in await self?.watch() }
    }

    private func watch() async {
        while !Task.isCancelled, let live = runtime {
            let busy = live.chats.filter { $0.isRunning && !$0.storedID.isEmpty }
            let snapshots = busy.map { Working($0, earlier: goals[$0.storedID]?.text) }
            tick(snapshots) { [weak live] id in
                guard let chat = live?.chatForStored(id), chat.isRunning else { return nil }
                return ChatGoals.turnKey(chat.items)
            }
            try? await Task.sleep(for: .seconds(busy.isEmpty ? 5 : 2))
        }
    }

    /// A single look at the busy chats. Lines for chats that have stopped are dropped, and the first
    /// chat whose line is due gets one. When the model answers, `turnNow` says which turn the chat is
    /// in now (nil if it stopped), so an old answer never lands on a newer turn.
    func tick(_ working: [Working], turnNow: @escaping TurnLookup) {
        let alive = Set(working.map(\.id))
        goals = goals.filter { alive.contains($0.key) }
        sightings = sightings.filter { alive.contains($0.key) }
        guard on() else {
            goals = [:]
            return
        }
        let moment = now()
        for chat in working {
            noticeTurn(of: chat, at: moment)
            // Only one at a time, since the summaries share the same model.
            let ready = writing.isEmpty && chat.input.hasContent && isDue(chat, at: moment)
            if ready { write(chat, turnNow: turnNow) }
        }
    }

    private func isDue(_ chat: Working, at moment: Date) -> Bool {
        let seenAt = sightings[chat.id]?.since ?? moment
        return Pace.due(goal: goals[chat.id], turn: chat.turn, turnAge: moment.timeIntervalSince(seenAt),
                        steps: chat.steps, now: moment)
    }

    /// Notes a new turn, and discards a line written for an older one.
    private func noticeTurn(of chat: Working, at moment: Date) {
        if sightings[chat.id]?.turn != chat.turn { sightings[chat.id] = (chat.turn, moment) }
        if let old = goals[chat.id], old.turn != chat.turn { goals[chat.id] = nil }
    }

    private func write(_ chat: Working, turnNow: @escaping TurnLookup) {
        writing.insert(chat.id)
        let compose = writer
        Task(priority: .utility) { [weak self] in
            let raw = await compose(chat.input)
            guard let self else { return }
            writing.remove(chat.id)
            // By the time the model replied, the turn could be over or a different one.
            guard turnNow(chat.id) == chat.turn else { return }
            guard let text = raw.flatMap(Self.clean) else {
                postponeRetry(for: chat)
                return
            }
            store(text, for: chat)
        }
    }

    /// With no answer, hold off for a full gap before trying again. Otherwise a model that is switched
    /// off or keeps refusing would be asked every two seconds.
    private func postponeRetry(for chat: Working) {
        guard goals[chat.id] == nil else { return }
        sightings[chat.id] = (chat.turn, now().addingTimeInterval(Pace.gap))
    }

    private func store(_ text: String, for chat: Working) {
        let previous = goals[chat.id]?.text
        goals[chat.id] = Goal(text: text, turn: chat.turn, madeAt: now(), steps: chat.steps)
        guard previous != text else { return }
        NotificationCenter.default.post(name: .nollieGoalChanged, object: nil,
                                        userInfo: ["storedID": chat.id, "goal": text])
    }
}
