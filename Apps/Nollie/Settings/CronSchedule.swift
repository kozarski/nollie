import Foundation
import NollieCore

/// Words for the schedule shapes people use most. Anything else is shown as the gateway sent it.
enum CronSchedule {
    /// Extracts schedule text whatever form the gateway used: plain string, object keyed by an
    /// expression, an interval, or a one-time moment. It is the stored schedule (read back with
    /// `onceDate`, sent back on save), so it stays in English.
    static func expression(of value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.stringValue { return text }
        if let runAt = value["run_at"]?.stringValue, !runAt.isEmpty { return runAt }

        for key in ["cron", "expr", "expression", "spec", "value"] {
            if let text = value[key]?.stringValue, !text.isEmpty { return text }
        }
        if let every = value["every"]?.stringValue ?? value["interval"]?.stringValue {
            return "every \(every)"
        }
        if let seconds = value["every_seconds"]?.doubleValue ?? value["interval_seconds"]?.doubleValue {
            return seconds >= 3600 ? "every \(Int(seconds / 3600)) h" : "every \(Int(seconds / 60)) min"
        }
        if let at = value["at"]?.stringValue { return "at \(at)" }
        return value.displayText
    }

    /// A cron line in plain words, such as "Weekdays at 9:00 AM". Odd shapes come back unchanged.
    static func describe(_ schedule: String?) -> String {
        guard let schedule, !schedule.isEmpty else { return String(localized: "no schedule") }
        if let once = onceDate(schedule) {
            return String(localized: "Once, \(once.formatted(date: .abbreviated, time: .shortened))", comment: "A task that runs one time, then when")
        }
        let fields = schedule.split(separator: " ").map(String.init)
        guard fields.count == 5, let minute = Int(fields[0]), let hour = Int(fields[1]),
              (0..<24).contains(hour), (0..<60).contains(minute),
              let time = Calendar.current.date(from: DateComponents(hour: hour, minute: minute))
        else { return schedule }

        let clock = time.formatted(date: .omitted, time: .shortened)
        let (dayOfMonth, month, dayOfWeek) = (fields[2], fields[3], fields[4])

        if dayOfMonth == "*" && month == "*" {
            switch dayOfWeek {
            case "*": return String(localized: "Every day at \(clock)")
            case "1-5": return String(localized: "Weekdays at \(clock)")
            case "0,6", "6,0": return String(localized: "Weekends at \(clock)")
            case "0", "7": return String(localized: "Sundays at \(clock)")
            case "1": return String(localized: "Mondays at \(clock)")
            case "2": return String(localized: "Tuesdays at \(clock)")
            case "3": return String(localized: "Wednesdays at \(clock)")
            case "4": return String(localized: "Thursdays at \(clock)")
            case "5": return String(localized: "Fridays at \(clock)")
            case "6": return String(localized: "Saturdays at \(clock)")
            default: break
            }
        }
        if dayOfMonth != "*" && month == "*" && dayOfWeek == "*" {
            return String(localized: "Day \(dayOfMonth) of every month at \(clock)")
        }
        return schedule
    }

    /// A one-off time in the form the gateway stores.
    static func onceExpression(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Reads a one-off time, with or without an "at " in front and with or without fractions.
    static func onceDate(_ expression: String) -> Date? {
        let text = expression.hasPrefix("at ") ? String(expression.dropFirst(3)) : expression
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        return fractional.date(from: text)
    }
}

/// The schedule pickers' state, and the conversion to and from a cron line.
struct ScheduleDraft: Equatable {
    enum Repeat: String {
        case once, daily, weekdays, weekends, weekly, monthly, custom
    }

    var repeats: Repeat = .daily
    /// 0 is Sunday.
    var weekday = 1
    var monthDay = 1
    var time = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    var onceAt = Date().addingTimeInterval(86_400)

    /// Loads a cron line into the pickers when they can represent it, else switches to custom.
    mutating func read(_ line: String) {
        if let when = CronSchedule.onceDate(line) {
            onceAt = when
            repeats = .once
            return
        }
        let fields = line.split(separator: " ").map(String.init)
        guard fields.count == 5, let minute = Int(fields[0]), let hour = Int(fields[1]) else {
            repeats = .custom
            return
        }
        time = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? time

        switch (fields[2], fields[3], fields[4]) {
        case ("*", "*", "*"):
            repeats = .daily
        case ("*", "*", "1-5"):
            repeats = .weekdays
        case ("*", "*", "0,6"), ("*", "*", "6,0"):
            repeats = .weekends
        case ("*", "*", let day):
            if let number = Int(day) {
                repeats = .weekly
                weekday = number % 7
            } else {
                repeats = .custom
            }
        case (let day, "*", "*"):
            if let number = Int(day) {
                repeats = .monthly
                monthDay = number
            } else {
                repeats = .custom
            }
        default:
            repeats = .custom
        }
    }

    /// The line these pickers describe, or nil for a custom schedule (which is typed by hand).
    /// `current` is what is stored now; a one-off time keeps the gateway's own spelling until the
    /// chosen moment actually changes.
    func line(keeping current: String) -> String? {
        switch repeats {
        case .custom:
            return nil
        case .once:
            return CronSchedule.onceDate(current) == onceAt ? current : CronSchedule.onceExpression(onceAt)
        default:
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            let clock = "\(parts.minute ?? 0) \(parts.hour ?? 0)"
            switch repeats {
            case .weekdays: return "\(clock) * * 1-5"
            case .weekends: return "\(clock) * * 0,6"
            case .weekly: return "\(clock) * * \(weekday)"
            case .monthly: return "\(clock) \(monthDay) * *"
            default: return "\(clock) * * *"
            }
        }
    }
}
