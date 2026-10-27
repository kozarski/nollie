import Foundation
import Observation
import UserNotifications
import NollieCore

/// The weekly note on this device: built from each helper's week as the Mac recorded it, never from a model's
/// words. Private bots are never asked about, and a member of someone's household never sees the owner's note.
@MainActor @Observable
final class WeeklyNoteModel {
    static let shared = WeeklyNoteModel()

    static let onKey = "nollie.weekly.on"
    static let weekdayKey = "nollie.weekly.weekday"
    static let putAwayKey = "nollie.weekly.putAway"

    /// The note, once read. Nil before, for a member, and with no gateway.
    private(set) var note: WeeklyNote?
    private(set) var loading = false
    /// Why the last tap didn't go through.
    private(set) var problem: String?
    /// Taps that went through, by line, so each line shows what was done and its undo.
    private(set) var done: [String: WeeklyAction] = [:]
    /// Taps in flight, by line.
    private(set) var busy: Set<String> = []
    /// When the note was read and from which gateway.
    private var readFrom: (gateway: UUID, at: Date)?
    /// The card's put-away time, mirrored so the card hides at once.
    private(set) var putAwayAt: Date? = UserDefaults.standard.object(forKey: WeeklyNoteModel.putAwayKey) as? Date

    static var isOn: Bool { UserDefaults.standard.object(forKey: onKey) as? Bool ?? true }
    static var timing: WeeklyNoteTiming {
        WeeklyNoteTiming(weekday: UserDefaults.standard.object(forKey: weekdayKey) as? Int ?? WeeklyNoteTiming.standard.weekday)
    }

    /// Whether this device may show the note: the owner's own, with the note on.
    static func shows(_ model: AppModel) -> Bool { isOn && !model.family.isMember(model) && model.runtime != nil }

    /// The card at the top of the main chat: from the note's time until the person puts it away.
    func cardShows(_ model: AppModel, now: Date = Date()) -> Bool {
        guard Self.shows(model), let note, !note.isQuiet || !note.quiet.isEmpty else { return false }
        return Self.timing.cardShows(now: now, putAwayAt: putAwayAt)
    }

    func putAway(now: Date = Date()) {
        putAwayAt = now
        UserDefaults.standard.set(now, forKey: Self.putAwayKey)
    }

    // MARK: Reading

    /// Reads every helper's week, at most every ten minutes unless `force`.
    func refresh(_ model: AppModel, force: Bool = false) async {
        // The notification stays set while there is a gateway to read, even one out of reach right now.
        WeeklyNoteReminder.sync(on: Self.isOn && model.hasConnections && !model.family.isMember(model), timing: Self.timing)
        guard Self.shows(model), let runtime = model.runtime else { note = nil; return }
        let gateway = runtime.connection.id
        if !force, let readFrom, readFrom.gateway == gateway, Date().timeIntervalSince(readFrom.at) < 600, note != nil { return }
        loading = true
        defer { loading = false }
        // Before the bots are listed there is nothing to say, and "a quiet week" would be a claim.
        guard !runtime.profiles.isEmpty else { note = nil; return }
        let profiles = runtime.profiles.filter { !PrivateBots.isPrivate($0.name, connection: gateway) }
        let api = runtime.api
        // The This Mac switches, where this device can read them (a phone over Nollie Link can't).
        await SystemControl.shared.refreshAll(runtime)
        guard model.runtime === runtime else { return }
        let records = await withTaskGroup(of: (String, WeekRecord?).self) { group in
            for profile in profiles {
                let bot = profile.name
                group.addTask { (bot, try? await WeekRecord.load(bot: bot, api: api)) }
            }
            var found: [String: WeekRecord] = [:]
            for await (bot, record) in group { if let record { found[bot] = record } }
            return found
        }
        guard model.runtime === runtime, Self.shows(model) else { return }
        let inputs = profiles.map { profile in
            WeeklyHelperInput(profile: profile.name, name: profile.shownName, record: records[profile.name],
                              macOn: SystemControl.shared.state(profile.name, runtime),
                              muted: HelperMute.isMuted(profile.name, connection: gateway))
        }
        note = WeeklyNote.build(inputs, isPrivate: { PrivateBots.isPrivate($0, connection: gateway) })
        if readFrom?.gateway != gateway { done = [:] }
        readFrom = (gateway, Date())
    }

    // MARK: Taps

    /// Carries out one tap. On success the line shows what was done, with Undo where there is one.
    func perform(_ action: WeeklyAction, line: String, model: AppModel) async {
        guard let runtime = model.runtime, Self.shows(model), !busy.contains(line), !model.lock.isLocked else { return }
        // Never for a private bot, whatever the line says.
        guard !PrivateBots.isPrivate(action.bot, connection: runtime.connection.id) else { return }
        busy.insert(line)
        defer { busy.remove(line) }
        problem = nil
        let worked: Bool
        switch action.effect {
        case .gateway(let request):
            worked = await Self.send(request, api: runtime.api)
        case .mac(let bot, let on):
            worked = await SystemControl.shared.set(on, profile: bot, rt: runtime)
        case .mute(let bot, let muted):
            HelperMute.set(muted, profile: bot, connection: runtime.connection.id)
            worked = true
        }
        guard model.runtime === runtime else { return }
        if worked {
            if let undone = done[line], undone.undo == action { done[line] = nil } else { done[line] = action }
        } else {
            problem = String(localized: "That didn't go through. Try again in a moment.")
        }
    }

    private static func send(_ request: WeeklyRequest, api: HermesAPI) async -> Bool {
        do {
            let _: JSONValue = try await api.send(request.method, request.path, profile: request.profile,
                                                  json: request.body ?? .object([:]))
            return true
        } catch {
            return false
        }
    }
}

/// The note's notification, on the chosen day at six in the evening, every week while the note is on. Its words
/// are the same every week, so it never says something the records don't.
enum WeeklyNoteReminder {
    static let identifier = "nollie.weekly"
    static let title = String(localized: "Your week", comment: "The weekly note's notification title")
    static let body = String(localized: "What your helpers did, and what left your Mac.",
                             comment: "Safety: the weekly note's notification; it lists what left the Mac")

    static func sync(on: Bool, timing: WeeklyNoteTiming, center: UNUserNotificationCenter = .current()) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard on, !DemoMode.isOn else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["nollie": "weekly"]
        content.threadIdentifier = identifier
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: timing.hour, minute: 0, weekday: timing.weekday),
                                                    repeats: true)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    /// The note's notification, by its payload.
    static func isWeekly(_ info: [AnyHashable: Any]) -> Bool { info["nollie"] as? String == "weekly" }
}
