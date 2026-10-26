import Foundation

/// Times as a helper sends them and as the person reads them, in the Mac's own time zone.
///
/// A helper writes local times like `2026-11-04T10:00`, or a date like `2026-11-04` for a whole day
/// (an offset such as `+01:00` or `Z` is honoured). Cards read "Tue 4 Nov, 10:00", with the year only
/// when it isn't this one.
public struct AppleDataTime: Sendable {
    public var calendar: Calendar
    public var now: Date

    public init(timeZone: TimeZone = .current, now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_GB")
        self.calendar = calendar
        self.now = now
    }

    public var timeZone: TimeZone { calendar.timeZone }

    /// The moment, and whether a time was given (no time means the whole day).
    public func parse(_ text: String) -> (date: Date, hasTime: Bool)? {
        let pattern = /(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?\s*(Z|[+-]\d{2}:?\d{2})?/
        guard let match = text.trimmingCharacters(in: .whitespaces).wholeMatch(of: pattern) else { return nil }
        var parts = DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3))
        let hasTime = match.4 != nil
        parts.hour = match.4.flatMap { Int($0) } ?? 0
        parts.minute = match.5.flatMap { Int($0) } ?? 0
        parts.second = match.6.flatMap { Int($0) } ?? 0
        guard let month = parts.month, (1...12).contains(month), let day = parts.day, (1...31).contains(day),
              (0...23).contains(parts.hour ?? 0), (0...59).contains(parts.minute ?? 0) else { return nil }
        var zoned = calendar
        if let offset = match.7 {
            let text = String(offset)
            if text == "Z" {
                zoned.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
            } else {
                let digits = text.dropFirst().replacingOccurrences(of: ":", with: "")
                guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
                      let zone = TimeZone(secondsFromGMT: (text.hasPrefix("-") ? -1 : 1) * (hours * 3600 + minutes * 60))
                else { return nil }
                zoned.timeZone = zone
            }
        }
        guard let date = zoned.date(from: parts),
              zoned.component(.day, from: date) == day else { return nil }  // no 31 November
        return (date, hasTime)
    }

    /// For the helper: `2026-11-04T10:00`, or `2026-11-04` for a day.
    public func iso(_ date: Date, time: Bool = true) -> String {
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
        return time ? day + String(format: "T%02d:%02d", p.hour ?? 0, p.minute ?? 0) : day
    }

    /// For the person: "Tue 4 Nov, 10:00", "Tue 4 Nov", or "Tue 4 Nov 2027, 10:00" in another year.
    public func when(_ date: Date, time: Bool = true) -> String {
        let pattern = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "EEE d MMM" : "EEE d MMM yyyy"
        return format(date, pattern) + (time ? ", " + clock(date) : "")
    }

    /// "10:00".
    public func clock(_ date: Date) -> String { format(date, "HH:mm") }

    public func sameDay(_ a: Date, _ b: Date) -> Bool { calendar.isDate(a, inSameDayAs: b) }

    public func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    public func adding(days: Int = 0, hours: Int = 0, to date: Date) -> Date {
        calendar.date(byAdding: DateComponents(day: days, hour: hours), to: date) ?? date
    }

    /// `1990-11-04`, or `--11-04` without a year.
    public func birthday(_ text: String) -> Birthday? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let match = trimmed.wholeMatch(of: /--(\d{2})-(\d{2})/), let month = Int(match.1), let day = Int(match.2),
           (1...12).contains(month), (1...31).contains(day) {
            return Birthday(month: month, day: day)
        }
        guard let match = trimmed.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})/), let year = Int(match.1),
              let month = Int(match.2), let day = Int(match.3), (1...12).contains(month), (1...31).contains(day) else { return nil }
        return Birthday(year: year, month: month, day: day)
    }

    /// "4 Nov 1990", or "4 Nov".
    public func birthdayText(_ birthday: Birthday) -> String {
        let months = calendar.shortMonthSymbols
        let month = months.indices.contains(birthday.month - 1) ? months[birthday.month - 1] : "\(birthday.month)"
        return "\(birthday.day) \(month)" + (birthday.year.map { " \($0)" } ?? "")
    }

    public func birthdayISO(_ birthday: Birthday) -> String {
        birthday.year.map { String(format: "%04d-%02d-%02d", $0, birthday.month, birthday.day) }
            ?? String(format: "--%02d-%02d", birthday.month, birthday.day)
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
