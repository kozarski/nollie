#if os(iOS)
import ActivityKit
import Foundation
import NollieCore

/// One helper the app can see using a computer: what a Live Activity is made from.
struct HelperAtWork: Equatable, Sendable {
    var profile: String
    var name: String
    var avatar: String
    var place: HelperWorkPlace
    var since: Date
}

/// Keeps the Lock Screen "Scout is using your Mac" Live Activities matching what the app can
/// see. ActivityKit only lets an app start one while it is in front (Nollie has no server to start
/// or update one by push), so they begin when someone allows a computer task here or the app is
/// open while a helper works. In the background the activity holds its last state until it goes
/// stale, then reports when the helper was last seen. If the link to the Mac drops it goes stale
/// immediately. It never claims live work the app cannot see.
@MainActor
final class HelperAtWorkActivities {
    static let shared = HelperAtWorkActivities()

    private var loop: Task<Void, Never>?
    /// A Stop is on its way: its "Stopping" is left alone until it comes back.
    private var stopInFlight = false
    /// Allowed from this phone a moment ago: shown before the first computer tool comes in.
    private var allowed: [String: (place: HelperWorkPlace, at: Date)] = [:]
    static let allowedGrace: TimeInterval = 30
    private static let checkEvery: Duration = .seconds(3)

    // MARK: What the app can see

    /// The helpers using a computer in the chats this phone has open, one each, private bots
    /// left out. `allowed` stands in for a helper someone just allowed here, while its chat runs.
    static func seen(runtime: GatewayRuntime, allowed: [String: (place: HelperWorkPlace, at: Date)] = [:],
                     now: Date = Date()) -> [HelperAtWork] {
        var found: [String: HelperAtWork] = [:]
        for chat in runtime.chats {
            let profile = chat.profileName
            guard let bot = runtime.profiles.first(where: { $0.name == profile }), !bot.isPrivateBot(on: runtime.connection.id) else { continue }
            var work = BotComputerActivity.workPlace(in: chat.items, isRunning: chat.isRunning)
            if work == nil, chat.isRunning, let a = allowed[profile], now.timeIntervalSince(a.at) < allowedGrace {
                work = (a.place, a.at)
            }
            guard let work else { continue }
            if let earlier = found[profile], earlier.since <= work.since { continue }
            found[profile] = HelperAtWork(profile: profile, name: bot.shownName,
                                          avatar: CharacterDrawing.avatarName(BotAvatarStore.look(for: profile)),
                                          place: work.place, since: work.since)
        }
        return found.values.sorted { $0.since < $1.since }
    }

    // MARK: Lifecycle

    /// In the foreground: looks every few seconds, so activities start and end with the work.
    func foreground() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: Self.checkEvery)
            }
        }
    }

    /// Leaving the foreground: one last look, so the stale clock starts from now, then quiet.
    func background() {
        loop?.cancel()
        loop = nil
        Task { await sync(refreshAll: true) }
    }

    /// Someone allowed a helper to use this Mac from the phone: show Stop straight away.
    func allowedHere(profile: String, place: HelperWorkPlace = .mac) {
        allowed[profile] = (place, Date())
        Task { await sync() }
    }

    /// The setting was turned off: every activity goes.
    func settingChanged() {
        Task { await sync() }
    }

    // MARK: Keeping activities in step

    /// What an activity is showing, read on the main actor; the activity itself is reached by id.
    private struct Shown: Sendable {
        let id: String
        let attributes: HelperAtWorkAttributes
        let state: HelperAtWorkAttributes.ContentState
    }
    private typealias Content = ActivityContent<HelperAtWorkAttributes.ContentState>

    private var shown: [Shown] {
        Activity<HelperAtWorkAttributes>.activities.map { Shown(id: $0.id, attributes: $0.attributes, state: $0.content.state) }
    }

    private nonisolated static func update(_ id: String, _ content: Content) async {
        guard let activity = Activity<HelperAtWorkAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(content)
    }

    private nonisolated static func end(_ id: String, _ content: Content?, dismissal: ActivityUIDismissalPolicy) async {
        guard let activity = Activity<HelperAtWorkAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(content, dismissalPolicy: dismissal)
    }

    func sync(refreshAll: Bool = false) async {
        let now = Date()
        allowed = allowed.filter { now.timeIntervalSince($0.value.at) < Self.allowedGrace }
        guard HelperAtWorkSetting.isOn else { await endAll(); return }
        if Self.preview != nil { return }
        guard let rt = AppModel.shared.runtime, rt.connection.linkedMac != nil else { await endAll(); return }
        guard rt.socketState.isOpen else {
            // The link is gone: what was seen last stays, marked as last seen, never as live.
            for item in shown where item.state.reachable && item.state.phase == .working {
                var state = item.state
                state.reachable = false
                await Self.update(item.id, Content(state: state, staleDate: HelperAtWorkTiming.staleDate(lastSeen: state.lastSeen, reachable: false)))
            }
            return
        }
        let seen = Self.seen(runtime: rt, allowed: allowed, now: now)
        let current = shown
        for item in current where item.state.phase == .stopped {
            // A finished Stop whose ending did not take (the app was ended first).
            await Self.end(item.id, nil, dismissal: .immediate)
        }
        for item in current where item.state.phase != .stopped && (item.state.phase != .stopping || !stopInFlight) {
            guard let work = seen.first(where: { $0.profile == item.attributes.profile && $0.place == item.attributes.place }) else {
                await Self.end(item.id, nil, dismissal: .immediate)
                continue
            }
            var state = item.state
            // A "Stopping" left over from a Stop that never came back is just work seen again.
            let leftOver = state.phase == .stopping
            let due = refreshAll || leftOver || !state.reachable || now.timeIntervalSince(state.lastSeen) >= HelperAtWorkTiming.refreshEvery
            guard due else { continue }
            if leftOver { state.phase = .working }
            state.lastSeen = now
            state.reachable = true
            state.startedAt = min(state.startedAt, work.since)
            await Self.update(item.id, Content(state: state, staleDate: HelperAtWorkTiming.staleDate(lastSeen: now, reachable: true)))
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for work in seen where !current.contains(where: { $0.attributes.profile == work.profile && $0.attributes.place == work.place
                                                          && $0.state.phase != .stopped }) {
            start(work, now: now)
        }
    }

    private func start(_ work: HelperAtWork, now: Date) {
        let attributes = HelperAtWorkAttributes(profile: work.profile, name: work.name, avatar: work.avatar, place: work.place)
        let state = HelperAtWorkAttributes.ContentState(startedAt: work.since, lastSeen: now)
        _ = try? Activity.request(attributes: attributes,
                                  content: Content(state: state, staleDate: HelperAtWorkTiming.staleDate(lastSeen: now, reachable: true)),
                                  pushType: nil)
    }

    private func endAll() async {
        for item in shown { await Self.end(item.id, nil, dismissal: .immediate) }
    }

    // MARK: Stop

    /// Stop was pressed (on the Lock Screen, through Siri or a Stop alert): the activities say so
    /// while it travels.
    func stopping() async {
        stopInFlight = true
        // Should the app be ended before the answer, the Lock Screen soon says "Last seen" again,
        // with Stop, rather than "Stopping" for hours.
        let soon = Date().addingTimeInterval(30)
        for item in shown where item.state.phase != .stopped {
            var state = item.state
            state.phase = .stopping
            await Self.update(item.id, Content(state: state, staleDate: soon))
        }
    }

    /// How the Stop went: taken by the Mac, they end after a moment; not reached, Stop stays.
    func stopFinished(reachedMac: Bool) async {
        stopInFlight = false
        let now = Date()
        for item in shown {
            var state = item.state
            if reachedMac {
                state.phase = .stopped
                await Self.end(item.id, Content(state: state, staleDate: nil),
                               dismissal: .after(now.addingTimeInterval(HelperAtWorkTiming.stoppedLingers)))
            } else {
                state.phase = .notReached
                await Self.update(item.id, Content(state: state, staleDate: nil))
            }
        }
    }

    // MARK: Pictures (debug builds)

    /// `-nollie-preview-helper-at-work live|stale|stopping|stopped`: a debug build shows one activity for a
    /// sample helper without a gateway, for the Lock Screen and Dynamic Island pictures. "stale"
    /// is the lost link, which looks the same as an activity past its stale date.
    static var preview: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-nollie-preview-helper-at-work"), i + 1 < args.count else { return nil }
        return args[i + 1]
        #else
        return nil
        #endif
    }

    func showPreview() async {
        guard let kind = Self.preview else { return }
        await endAll()
        let now = Date()
        let attributes = HelperAtWorkAttributes(profile: "career", name: "Scout",
                                                avatar: CharacterDrawing.avatarName(.defaultLook(forProfile: "career")), place: .mac)
        var state = HelperAtWorkAttributes.ContentState(startedAt: now.addingTimeInterval(-(4 * 60 + 12)), lastSeen: now)
        var stale: Date? = HelperAtWorkTiming.staleDate(lastSeen: now, reachable: true)
        switch kind {
        case "stale":
            // Seen two minutes ago, then the link to the Mac went: last seen, never live.
            state.lastSeen = now.addingTimeInterval(-2 * 60)
            state.reachable = false
            stale = HelperAtWorkTiming.staleDate(lastSeen: state.lastSeen, reachable: false)
        case "stopping":
            state.phase = .stopping
        case "stopped":
            state.phase = .stopped
            stale = nil
        default: break
        }
        _ = try? Activity.request(attributes: attributes, content: Content(state: state, staleDate: stale), pushType: nil)
    }
}
#endif
