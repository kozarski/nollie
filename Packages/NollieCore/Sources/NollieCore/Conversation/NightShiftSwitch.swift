import Foundation

/// Night shift's one switch, as the workflow add-on keeps it (`GET` and `PUT /api/plugins/nollie-workflow/night-shift`).
/// Off when it was never turned on. A damaged settings file reads as on, as the recorder treats it, so a broken file
/// never turns the watch off. Only the owner's own devices reach it: the Link door keeps shared members out.
public struct NightShiftSwitch: Codable, Equatable, Sendable {
    public var on: Bool
    public var damaged: Bool?

    public static let path = "/api/plugins/nollie-workflow/night-shift"

    public init(on: Bool, damaged: Bool? = nil) {
        self.on = on
        self.damaged = damaged
    }

    /// The switch, or nil from an add-on too old to have it.
    public static func load(api: HermesAPI) async throws -> NightShiftSwitch? {
        do {
            return try await api.get(path, profile: "default")
        } catch HermesAPIError.http(let status, _) where status == 404 {
            return nil
        }
    }

    /// Turns it on or off; answers the switch as the add-on saved it.
    public static func save(_ on: Bool, api: HermesAPI) async throws -> NightShiftSwitch {
        try await api.send("PUT", path, profile: "default", json: .object(["on": .bool(on)]))
    }
}
