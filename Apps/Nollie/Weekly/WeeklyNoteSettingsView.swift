import SwiftUI
import NollieCore

/// Settings › Your week: when the note comes, one switch, the day, and this week's note.
struct WeeklyNoteSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(WeeklyNoteModel.onKey) private var on = true
    @AppStorage(WeeklyNoteModel.weekdayKey) private var weekday = WeeklyNoteTiming.standard.weekday
    private var weekly: WeeklyNoteModel { .shared }

    /// "4 new", when something is.
    private var newCount: String? {
        guard let count = weekly.note?.news.count, count > 0 else { return nil }
        return String(localized: "\(count) new", comment: "How many new things are in this week's note")
    }

    var body: some View {
        SettingsPage("weekly.page") {
            PageHero(symbol: on ? "calendar.badge.checkmark" : WeeklyInk.symbol,
                     title: .verbatim(on ? WeeklyNoteDays.evenings(weekday) : String(localized: "Off", comment: "The weekly note is switched off")),
                     line: LocalizedStringResource("A short note on your helpers' week."),
                     tint: on ? WeeklyInk.tint : Ink.text2, id: "weekly.settings.hero")
            FactStrip(facts: [Fact(symbol: "person.2.fill", word: "What they did"),
                              Fact(symbol: "arrow.up.right.circle.fill", word: "What left"),
                              Fact(symbol: "arrow.uturn.backward.circle.fill", word: "Undo in a tap")],
                      tint: on ? WeeklyInk.tint : Ink.text2, id: "weekly.facts")
            GlassStack {
                GlassSwitch("Weekly note", isOn: Binding(get: { on }, set: { on = $0; WeeklyNoteModel.changed(model) }),
                            id: "weekly.switch")
                if on {
                    GlassChoice("Day", selection: Binding(get: { weekday }, set: { weekday = $0; WeeklyNoteModel.changed(model) }),
                                options: WeeklyNoteDays.options(), id: "weekly.day")
                    GlassLink("This week", symbol: WeeklyInk.symbol, value: newCount, id: "weekly.open") {
                        WeeklyNotePage()
                    }
                }
            }
        }
        .animation(.snappy, value: on)
        .untitledPage()
    }
}

/// The days the note can come, as this device names them.
enum WeeklyNoteDays {
    /// Monday first where the week starts on Monday, Sunday first where it starts on Sunday.
    static func options(calendar: Calendar = .current) -> [(Int, String)] {
        let names = calendar.weekdaySymbols
        return (0..<7).map { offset in
            let day = (calendar.firstWeekday - 1 + offset) % 7 + 1
            return (day, names[day - 1])
        }
    }

    /// "Sunday evenings".
    /// One whole phrase per day, since languages say this in their own way.
    static func evenings(_ weekday: Int, calendar: Calendar = .current) -> String {
        switch (1...7).contains(weekday) ? weekday : 1 {
        case 2: String(localized: "Monday evenings")
        case 3: String(localized: "Tuesday evenings")
        case 4: String(localized: "Wednesday evenings")
        case 5: String(localized: "Thursday evenings")
        case 6: String(localized: "Friday evenings")
        case 7: String(localized: "Saturday evenings")
        default: String(localized: "Sunday evenings")
        }
    }
}
