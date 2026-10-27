import Foundation

/// When "Keep Mac awake for my crew" may hold the Mac out of idle sleep. Pure: the Mac app reads the facts and
/// holds a power assertion while this says so. The screen may always sleep, and a closed laptop lid still sleeps.
///
/// The rule:
/// - Only for an assistant on this Mac. A crew on another computer gains nothing from this one staying awake.
/// - Plugged in: awake while helpers work, and while a schedule is due within the next 12 hours, so a night's
///   runs happen on time. With nothing due, the Mac sleeps as usual.
/// - On battery: awake while helpers work, or a schedule is due within 15 minutes, never in Low Power Mode or
///   below 20%. A Mac can't be woken from sleep by an app, so a later run waits for it.
public enum KeepAwakePolicy {
    public static let pluggedInLookAhead: TimeInterval = 12 * 3600
    public static let batteryLookAhead: TimeInterval = 15 * 60
    /// A schedule just due is still given time to start: Hermes checks its schedules once a minute.
    public static let startGrace: TimeInterval = 5 * 60
    public static let lowestBattery = 0.2

    public enum Power: Equatable, Sendable {
        case pluggedIn
        /// The charge left, 0 to 1, when the Mac says.
        case battery(Double?)
    }

    public struct Facts: Equatable, Sendable {
        public var on: Bool
        public var assistantHere: Bool
        public var working: Bool
        /// Every schedule's next run, of any bot.
        public var due: [Date]
        public var power: Power
        public var lowPowerMode: Bool
        public var now: Date

        public init(on: Bool, assistantHere: Bool, working: Bool = false, due: [Date] = [], power: Power = .pluggedIn,
                    lowPowerMode: Bool = false, now: Date = Date()) {
            self.on = on
            self.assistantHere = assistantHere
            self.working = working
            self.due = due
            self.power = power
            self.lowPowerMode = lowPowerMode
            self.now = now
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Hold the Mac awake, for this reason.
        case awake(Reason)
        /// Let it sleep as usual, and why.
        case sleep(Rest)
    }

    public enum Reason: Equatable, Sendable {
        case working
        case due(Date)
    }

    public enum Rest: Equatable, Sendable {
        case off, elsewhere, lowBattery, nothingDue
    }

    public static func decide(_ facts: Facts) -> Decision {
        guard facts.on else { return .sleep(.off) }
        guard facts.assistantHere else { return .sleep(.elsewhere) }
        let lookAhead: TimeInterval
        switch facts.power {
        case .pluggedIn:
            lookAhead = pluggedInLookAhead
        case .battery(let charge):
            if facts.lowPowerMode || (charge.map { $0 < lowestBattery } ?? false) { return .sleep(.lowBattery) }
            lookAhead = batteryLookAhead
        }
        if facts.working { return .awake(.working) }
        let next = facts.due.filter { $0 > facts.now.addingTimeInterval(-startGrace) }.min()
        if let next, next.timeIntervalSince(facts.now) <= lookAhead { return .awake(.due(next)) }
        return .sleep(.nothingDue)
    }

    /// What the Mac lists for the assertion (`pmset -g assertions`, Activity Monitor): it names Nollie and the
    /// reason, never a bot or a schedule's title.
    public static func assertionName(_ reason: Reason, clock: SleepNote.Clock = SleepNote.clock) -> String {
        switch reason {
        case .working: String(localized: "Nollie is keeping your Mac awake while a helper works", table: "Core")
        case .due(let date): String(localized: "Nollie is keeping your Mac awake for a schedule at \(clock(date))", table: "Core")
        }
    }
}
