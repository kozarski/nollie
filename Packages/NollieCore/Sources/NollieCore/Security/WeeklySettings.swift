import Foundation

/// Each helper's mute, the same on every device: kept by the workflow add-on in the main bot's home beside the
/// bots' looks (`GET /api/plugins/nollie-workflow/mutes`, `PUT .../mutes/<bot>`). Every device applies it to its
/// own reply banners, and the Mac's iCloud alerts honour it too. A private bot is never kept there.
public enum HelperMutes {
    public static let path = "/api/plugins/nollie-workflow/mutes"

    public struct Reply: Decodable, Equatable, Sendable {
        public var muted: [String]
        public var saved: Bool?
    }

    public static func request(bot: String, muted: Bool) -> WeeklyRequest {
        WeeklyRequest(method: "PUT", path: path + "/" + bot, profile: nil, body: .object(["muted": .bool(muted)]))
    }

    /// The muted helpers, or nil from an add-on without the route.
    public static func load(api: HermesAPI) async throws -> Set<String>? {
        do {
            let reply: Reply = try await api.get(path)
            return Set(reply.muted.map(PrivateBots.key))
        } catch HermesAPIError.http(let status, _) where status == 404 {
            return nil
        }
    }

    /// This device's copy, as "<connection>/<bot>", in the shared Keychain beside the Private list, so the
    /// notification extension can quieten a muted helper's replies that come by push.
    public static let sharedAccount = "weekly.muted.v1"

    public static func share(_ names: [String]) {
        try? Keychain.setCodable(names.sorted(), account: sharedAccount)
    }

    /// Whether this device has the helper muted, read afresh. Without a gateway, muted on any gateway counts.
    public static func isMutedHere(_ profile: String, connection: UUID?) -> Bool {
        let names = Keychain.getCodable([String].self, account: sharedAccount) ?? []
        let bot = PrivateBots.key(profile)
        guard let connection else { return names.contains { $0.split(separator: "/").last.map(String.init) == bot } }
        return names.contains(connection.uuidString + "/" + bot)
    }

    /// Whether a finished reply of `profile` raises a banner. Questions, approvals and "started using your Mac"
    /// always do: Ask first must never wait unseen.
    public static func bannersReply(_ profile: String, muted: Set<String>) -> Bool {
        !muted.contains(PrivateBots.key(profile))
    }
}

/// The weekly note's switch and day, the same on every device, and when the Mac last said it sends the note
/// itself with the week's counts (`GET/PUT /api/plugins/nollie-workflow/weekly-note`).
public struct WeeklyNoteSettings: Codable, Equatable, Sendable {
    public var on: Bool
    public var weekday: Int
    /// When the Mac's alert helper last said it builds and sends the note.
    public var liveAt: Double?

    public static let path = "/api/plugins/nollie-workflow/weekly-note"

    public init(on: Bool = true, weekday: Int = 1, liveAt: Double? = nil) {
        self.on = on; self.weekday = weekday; self.liveAt = liveAt
    }

    /// The Mac said it sends the note within the last day and a half, so a device with iCloud alerts on gets the
    /// live note from it, and needs no fixed reminder of its own.
    public func macSendsLive(now: Date = Date()) -> Bool {
        guard let liveAt else { return false }
        let age = now.timeIntervalSince1970 - liveAt
        return age >= -300 && age < 36 * 3600
    }

    public static func load(api: HermesAPI) async throws -> WeeklyNoteSettings? {
        do {
            return try await api.get(path)
        } catch HermesAPIError.http(let status, _) where status == 404 {
            return nil
        }
    }

    public static func request(on: Bool, weekday: Int) -> WeeklyRequest {
        WeeklyRequest(method: "PUT", path: path, profile: nil, body: .object(["on": .bool(on), "weekday": .number(Double(weekday))]))
    }
}

// MARK: The notification

public extension WeeklyNote {
    /// The notification's title, every week. In the Mac's language, which builds it.
    static var notificationTitle: String {
        String(localized: "Your week", table: "Core", comment: "The weekly note's notification title")
    }
    /// What the notification says when the records couldn't be read when it went out.
    static var notificationFallback: String {
        String(localized: "What your helpers did, and what left your Mac.", table: "Core",
               comment: "Safety: the weekly note's notification when its counts couldn't be read; it lists what left the Mac")
    }

    /// The notification's line, from the same records as the note, built when it is sent: "Scout and Planner did 12
    /// things. 4 places online, 1 new." Nil when part of the week couldn't be read, so a count is never short:
    /// the fixed line goes instead.
    var notificationLine: String? {
        guard unread.isEmpty else { return nil }
        guard !helpers.isEmpty else {
            return quiet.isEmpty ? nil : String(localized: "A quiet week. Nothing recorded.", table: "Core", comment: "The weekly note's notification")
        }
        let things = helpers.reduce(0) { total, helper in
            total + helper.did.filter { [.schedule, .board, .asked].contains($0.kind) }.reduce(0) { $0 + $1.count }
        }
        let places = helpers.reduce(0) { $0 + $1.onlinePlaces }
        let names = Self.names(helpers.map(\.name))
        let new = news.count
        // Whole sentences per case, so each language can build its own.
        let first = things > 0
            ? String(localized: "\(names) did \(things) things.", table: "Core", comment: "The weekly note's notification: the helpers' names, then how many things they did")
            : String(localized: "\(names) kept busy.", table: "Core", comment: "The weekly note's notification: the helpers' names")
        let second: String
        if places > 0 {
            let online = String(localized: "\(places) places online", table: "Core", comment: "The weekly note's notification: how many places went online")
            second = new > 0
                ? String(localized: "\(online), \(new) new.", table: "Core", comment: "The weekly note's notification: places online, then how many were new")
                : String(localized: "\(online).", table: "Core", comment: "The weekly note's notification: places online, as a sentence")
        } else {
            second = new > 0
                ? String(localized: "Nothing went online, \(new) new.", table: "Core", comment: "Safety: the weekly note's notification; nothing left the Mac, then how many things were new")
                : String(localized: "Nothing went online.", table: "Core", comment: "Safety: the weekly note's notification; nothing left the Mac")
        }
        return String(localized: "\(first) \(second)", table: "Core", comment: "Two whole sentences one after the other")
    }

    /// "Scout", "Scout and Planner", "Scout, Mason and 2 more".
    static func names(_ names: [String]) -> String {
        switch names.count {
        case 0: return String(localized: "Your helpers", table: "Core", comment: "Stands in for the helpers' names in the weekly notification")
        case 1: return names[0]
        case 2: return String(localized: "\(names[0]) and \(names[1])", table: "Core", comment: "Two names in a list")
        case 3: return String(localized: "\(names[0]), \(names[1]) and \(names[2])", table: "Core", comment: "Three names in a list")
        default: return String(localized: "\(names[0]), \(names[1]) and \(names.count - 2) more", table: "Core",
                               comment: "Two names, then how many more helpers")
        }
    }
}

extension WeeklyNote.Helper {
    /// Places that went online this week, every one, shown or not: not the person's iCloud, not their own network.
    var onlinePlaces: Int { onlinePlaceCount }
}

// MARK: Sending, on the Mac

/// The live notification is built on the Mac by its iCloud alerts helper, at the moment it goes out, from the same
/// records as the note. A device with iCloud alerts on gets it from there; any other device says the fixed line.
public enum WeeklyNoteSending {
    /// How late the note may still go out, for a Mac that was asleep at the time.
    public static let lateness: TimeInterval = 12 * 3600
    /// How often the Mac says it sends the note itself.
    public static let heartbeat: TimeInterval = 6 * 3600

    /// The note's time that is due now: the latest on the chosen day, not yet sent, not too late, and not before
    /// iCloud alerts were turned on. Nil when nothing is due.
    public static func due(_ settings: WeeklyNoteSettings, now: Date, sentFor: Date?, since baseline: Date,
                           calendar: Calendar = .current) -> Date? {
        guard settings.on else { return nil }
        let time = WeeklyNoteTiming(weekday: settings.weekday).latest(before: now, calendar: calendar)
        guard time <= now, now.timeIntervalSince(time) < lateness, time >= baseline else { return nil }
        if let sentFor, sentFor >= time { return nil }
        return time
    }

    /// One helper the Mac reads for the note.
    public struct Helper: Equatable, Sendable {
        public var profile: String
        public var name: String
        public init(profile: String, name: String) { self.profile = profile; self.name = name }

        /// As the list shows it: the bot's own display name, else its profile name with a capital.
        public init(_ info: ProfileInfo) {
            profile = info.name
            if let shown = info.displayName, !shown.isEmpty {
                name = shown
            } else {
                name = info.name.prefix(1).uppercased() + info.name.dropFirst()
            }
        }
    }

    /// The notification's line from the records read just now: the counts when every helper's week was read, else
    /// the fixed line. `helpers` is nil when the bots couldn't be listed.
    public static func line(helpers: [Helper]?, records: [String: WeekRecord], now: Date = Date(),
                            isPrivate: (String) -> Bool) -> String {
        guard let helpers, !helpers.isEmpty else { return WeeklyNote.notificationFallback }
        let inputs = helpers.map { WeeklyHelperInput(profile: $0.profile, name: $0.name, record: records[$0.profile]) }
        return WeeklyNote.build(inputs, isPrivate: isPrivate, now: now).notificationLine ?? WeeklyNote.notificationFallback
    }
}
