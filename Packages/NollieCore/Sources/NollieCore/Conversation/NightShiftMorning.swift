import Foundation

/// When the morning's Night shift card shows as a capsule at the top of Nollie's main chat: the newest card, on the
/// day it was posted, until the person puts it away. Putting it away keeps the time of the card put away, not this
/// device's clock, so a Mac and iPhone whose clocks differ a little never bring it back, and the next morning's card
/// (a later time) shows again. One a morning.
public enum NightShiftMorning {
    public static func cardShows(postedAt: Date?, now: Date, putAway: Date?, calendar: Calendar = .current) -> Bool {
        guard let postedAt, calendar.isDate(postedAt, inSameDayAs: now) else { return false }
        return putAway.map { $0 < postedAt } ?? true
    }
}
