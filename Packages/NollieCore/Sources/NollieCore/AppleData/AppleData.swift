import Foundation

/// Calendar, Reminders and Contacts on the person's Mac, for the helpers they turn them on for.
///
/// The data stays in the Mac's own apps. A helper's tool call (the workflow add-on's `apple_data.py`)
/// becomes a request the Mac picks up from `GET /api/plugins/nollie-workflow/apple-data/requests`.
/// A read is answered at once. A change is only worded first (`prepare`), the add-on asks the person
/// with exactly those words through Hermes's own approval card, and the Mac makes it only once the
/// request comes back approved. Each helper has one switch per area, all off to start.
public enum AppleDataArea: String, CaseIterable, Codable, Sendable, Identifiable {
    case calendar, reminders, contacts

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .contacts: "Contacts"
        }
    }

    public var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        }
    }
}

/// Every tool the add-on gives a helper, by the name Hermes calls it.
public enum AppleDataTool: String, CaseIterable, Sendable {
    case calendarEvents = "calendar_events"
    case calendarSearch = "calendar_search"
    case calendarAddEvent = "calendar_add_event"
    case calendarChangeEvent = "calendar_change_event"
    case calendarDeleteEvent = "calendar_delete_event"
    case reminderLists = "reminder_lists"
    case remindersOpen = "reminders_open"
    case reminderAdd = "reminder_add"
    case reminderComplete = "reminder_complete"
    case reminderDelete = "reminder_delete"
    case contactsSearch = "contacts_search"
    case contactAdd = "contact_add"
    case contactChange = "contact_change"

    public var area: AppleDataArea {
        switch self {
        case .calendarEvents, .calendarSearch, .calendarAddEvent, .calendarChangeEvent, .calendarDeleteEvent: .calendar
        case .reminderLists, .remindersOpen, .reminderAdd, .reminderComplete, .reminderDelete: .reminders
        case .contactsSearch, .contactAdd, .contactChange: .contacts
        }
    }

    /// Adds, changes or deletes something: never done without the person's yes.
    public var isWrite: Bool {
        switch self {
        case .calendarEvents, .calendarSearch, .reminderLists, .remindersOpen, .contactsSearch: false
        default: true
        }
    }
}

/// What macOS says about one of the three for Nollie. Read without asking.
public enum AppleDataAccess: String, Codable, Sendable {
    case allowed, denied
    case notAsked = "not_asked"
    /// Not possible here, such as a restriction set by the Mac's owner.
    case unavailable
}

/// One open tool call, as the add-on keeps it.
public struct AppleDataRequest: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var bot: String
    public var tool: String
    /// "waiting" (new) or "approved" (a change the person said yes to).
    public var state: String
    public var args: [String: JSONValue]
    public var createdAt: Int?

    public init(id: String, bot: String, tool: AppleDataTool, state: String = "waiting", args: [String: JSONValue] = [:]) {
        self.id = id; self.bot = bot; self.tool = tool.rawValue; self.state = state; self.args = args
    }

    public var known: AppleDataTool? { AppleDataTool(rawValue: tool) }

    func text(_ key: String) -> String? {
        guard let value = args[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    func flag(_ key: String) -> Bool? { args[key]?.boolValue }
}

/// The Mac's poll: the open requests, and which helpers may use what.
public struct AppleDataSnapshot: Decodable, Equatable, Sendable {
    public var requests: [AppleDataRequest]
    public var bots: [String: [String]]

    public init(requests: [AppleDataRequest], bots: [String: [String]]) {
        self.requests = requests
        self.bots = bots
    }

    public func isOn(_ area: AppleDataArea, for bot: String) -> Bool { bots[bot]?.contains(area.rawValue) ?? false }
}

/// One helper's switches, and what the Mac last said about its permissions (nil before it has).
public struct AppleDataSwitches: Decodable, Equatable, Sendable {
    public var bot: String
    public var on: [String]
    public var mac: [String: String]?

    public init(bot: String, on: [String], mac: [String: String]? = nil) {
        self.bot = bot; self.on = on; self.mac = mac
    }

    public func isOn(_ area: AppleDataArea) -> Bool { on.contains(area.rawValue) }

    public func macAccess(_ area: AppleDataArea) -> AppleDataAccess? { mac?[area.rawValue].flatMap(AppleDataAccess.init(rawValue:)) }
}

private struct AppleDataSwitchesBody: Encodable, Sendable { var bot: String; var on: [String] }
private struct AppleDataAccessBody: Codable, Sendable { var access: [String: String] }
private struct AppleDataCardBody: Encodable, Sendable { var card: String }
private struct AppleDataAnswerBody: Encodable, Sendable { var result: JSONValue?; var error: String? }
private struct AppleDataAnswered: Decodable, Sendable { var id: String; var state: String }

@MainActor
extension GatewayRuntime {
    public static let appleDataPath = "/api/plugins/nollie-workflow/apple-data"

    public func appleDataSwitches(bot: String) async throws -> AppleDataSwitches {
        try await api.get(Self.appleDataPath + "/bots", query: [URLQueryItem(name: "bot", value: bot)])
    }

    public func saveAppleDataSwitches(bot: String, on: [AppleDataArea]) async throws -> AppleDataSwitches {
        try await api.send("PUT", Self.appleDataPath + "/bots",
                           body: AppleDataSwitchesBody(bot: bot, on: AppleDataArea.allCases.filter(on.contains).map(\.rawValue)))
    }

    /// Tells the add-on which of the three macOS lets Nollie use. Nothing from the apps themselves.
    public func reportAppleDataAccess(_ access: [AppleDataArea: AppleDataAccess]) async throws {
        let body = AppleDataAccessBody(access: Dictionary(uniqueKeysWithValues: access.map { ($0.key.rawValue, $0.value.rawValue) }))
        let _: AppleDataAccessBody = try await api.send("PUT", Self.appleDataPath + "/mac", body: body)
    }

    public func appleDataRequests() async throws -> AppleDataSnapshot {
        try await api.get(Self.appleDataPath + "/requests")
    }

    /// The words for a change not made yet. False when the helper stopped waiting (404) or it moved on (409).
    public func prepareAppleData(_ id: String, card: String) async throws -> Bool {
        do {
            let _: AppleDataAnswered = try await api.send("POST", Self.appleDataPath + "/requests/\(id)/prepare",
                                                          body: AppleDataCardBody(card: card))
            return true
        } catch HermesAPIError.http(status: 404, _), HermesAPIError.http(status: 409, _) { return false }
    }

    public func answerAppleData(_ id: String, result: [String: JSONValue]? = nil, error: String? = nil) async throws {
        do {
            let _: AppleDataAnswered = try await api.send("POST", Self.appleDataPath + "/requests/\(id)/answer",
                                                          body: AppleDataAnswerBody(result: result.map(JSONValue.object), error: error))
        } catch HermesAPIError.http(status: 404, _), HermesAPIError.http(status: 409, _) {
            // The helper stopped waiting: nobody to tell.
        }
    }
}
