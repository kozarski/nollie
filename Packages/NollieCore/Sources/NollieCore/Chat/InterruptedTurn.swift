import Foundation

/// A turn the gateway cut off. It is stored as a normal bot message starting "Operation
/// interrupted", whether Stop was pressed or no app stayed connected too long, so the wording
/// cannot distinguish the two. The chat shows a card able to explain either.
public struct InterruptedTurn: Hashable, Sendable {
    public enum Cause: String, Hashable, Sendable {
        /// Stop was pressed on this device.
        case stopped
        /// No app was connected (asleep, suspended, offline) and the gateway ran out of patience.
        case appWasAway
        /// Nollie paused it on purpose, because the Mac app was about to update and restart.
        case pausedForUpdate
    }

    /// What the bot was busy with when it ended ("waiting for model response"), if the gateway said.
    public var doing: String?

    public init(doing: String? = nil) { self.doing = doing }

    /// Reads a message as an interruption. A bot that quotes the sentence inside a longer
    /// explanation is not one, so only a short single line that starts with it counts.
    public static func parse(_ text: String) -> InterruptedTurn? {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.count <= 240, !message.contains("\n"),
              let lead = message.range(of: "operation interrupted", options: [.anchored, .caseInsensitive])
        else { return nil }

        let after = message[lead.upperBound...].trimmingCharacters(in: .whitespaces)
        if after.isEmpty || after == "." { return InterruptedTurn() }

        // Two tails are possible after that sentence: a wait notice carrying elapsed seconds, or a retry
        // notice naming the reason and attempt count.
        var detail = after
        if after.hasPrefix(":") {
            detail = String(after.dropFirst())
        } else if after.range(of: "during ", options: [.anchored, .caseInsensitive]) == nil {
            return nil
        }
        detail = detail.trimmingCharacters(in: .whitespaces)
        while detail.hasSuffix(".") { detail.removeLast() }
        return detail.isEmpty ? InterruptedTurn() : InterruptedTurn(doing: detail)
    }
}

/// Time the gateway keeps a chat alive with no app attached before ending the turn. It is stored
/// in the gateway's config in seconds (default 20; 0 means never give up) and takes effect once
/// the dashboard restarts.
public struct AwayGrace: Hashable, Sendable {
    /// True when the gateway's environment sets it, which outranks the config.
    public var envOverride = false
    /// Nil when the config leaves it unset and the gateway default rules.
    public var seconds: Double?

    public init(seconds: Double? = nil, envOverride: Bool = false) {
        self.envOverride = envOverride
        self.seconds = seconds
    }

    /// The value in force, whether it was set or not.
    public var effective: Double { seconds ?? Self.gatewayDefault }

    /// Brief enough that an app dropping to the background may lose a long turn.
    public var isShort: Bool { 0 < effective && effective < 600 }

    // MARK: The gateway's side

    public static let gatewayDefault: Double = 20
    public static let envKey = "HERMES_TUI_WS_ORPHAN_REAP_GRACE_S"

    /// Where the setting sits in the gateway's config, outermost key first.
    private static let settingPath = ["dashboard", "ws_orphan_reap_grace_s"]

    /// Reads `GET /api/config`, where the settings may be wrapped in a `config` object.
    public static func read(config: JSONValue) -> AwayGrace {
        let setting = settingPath.reduce(Optional(config["config"] ?? config)) { node, key in node?[key] }
        guard let setting else { return AwayGrace() }
        let parsed = setting.doubleValue ?? setting.stringValue.flatMap { Double($0) }
        return AwayGrace(seconds: parsed.map { Swift.max(0, $0) })
    }

    /// The body `PUT /api/config` wants for a new value.
    public static func writeBody(seconds: Double) -> JSONValue {
        let nested = settingPath.reversed().reduce(JSONValue.number(seconds)) { inner, key in .object([key: inner]) }
        return .object(["config": nested])
    }

    // MARK: The picker

    /// What the settings picker offers, shortest first, with zero ("never") last.
    public static let choices: [Double] = [20, 600, 3_600, 28_800, 0]

    public static func label(_ seconds: Double) -> String {
        let whole = Int(seconds)
        if whole == 0 { return String(localized: "Never stop it", table: "Core", comment: "A choice: the gateway never ends a turn left without the app") }
        if whole < 60 { return String(localized: "\(whole) seconds", table: "Core") }
        if whole < 3600 {
            let minutes = whole / 60
            return String(localized: "\(minutes) minutes", table: "Core")
        }
        let hours = whole / 3600
        return String(localized: "\(hours) hours", table: "Core")
    }
}
