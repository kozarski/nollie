import SwiftUI
import Observation
import NollieCore

/// The Papertrail tab's read for one bot on one connection. A read that comes back after the
/// card has moved to another bot or gateway is dropped.
@MainActor @Observable
final class PapertrailModel {
    enum State: Equatable { case loading, on(Papertrail), off, privateBot, failed }
    private(set) var state: State = .loading
    /// The bot's name as the person knows it, for the Why on each entry.
    private(set) var botName = ""
    private var key: String?
    private let apiOverride: HermesAPI?

    init(api: HermesAPI? = nil) { apiOverride = api }

    /// False when the read failed. What was on show stays while a fresh read is out.
    @discardableResult
    func load(bot: String, runtime: GatewayRuntime) async -> Bool {
        let key = "\(runtime.connection.id)/\(bot)"
        if self.key != key { state = .loading; self.key = key }
        let named = runtime.profiles.first { $0.name == bot }?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        botName = named.flatMap { $0.isEmpty ? nil : $0 } ?? ProfileInfo.shownName(of: bot)
        do {
            let result = try await Papertrail.load(bot: bot, api: apiOverride ?? runtime.api)
            guard !Task.isCancelled, self.key == key else { return true }
            switch result {
            case .on(let trail): state = .on(trail)
            case .off: state = .off
            case .privateBot: state = .privateBot
            }
            return true
        } catch {
            guard !Task.isCancelled, self.key == key else { return true }
            if case .on = state {} else { state = .failed }
            return false
        }
    }

    /// Waits until just after the Mac's next midnight, so an open tab moves today's rows along.
    /// False when cancelled, or when there is no week on show to keep current.
    func waitForNextDay() async -> Bool {
        guard case .on(let trail) = state, let next = trail.nextDayStartsAt else { return false }
        // At least five minutes, so a clock that disagrees with the Mac's never spins.
        let wait = max(next - Date().timeIntervalSince1970 + 5, 300)
        do { try await Task.sleep(for: .seconds(wait)) } catch { return false }
        return true
    }
}


/// Today in a bot's Papertrail, in a few words: for the top of its card and of the tab.
struct PapertrailToday: Equatable {
    /// Everything that left this Mac today, and the part of it that went online.
    var left: Int
    var online: Int
    /// The route most of today's online ones took ("Claude plan"), and whether all of them did.
    var topRoute: String?
    var allOneRoute = false

    init(_ trail: Papertrail, now: Date = Date()) {
        let today = trail.split(now: now).today
        // The add-on's own count, unless a midnight has passed since it was read.
        let fresh = trail.nextDayStartsAt.map { now.timeIntervalSince1970 < $0 } ?? true
        left = fresh ? (trail.left?.today ?? today.count) : today.count
        online = max(0, left - today.filter { $0.route == "network" }.count)
        let routes = Dictionary(grouping: today.filter { $0.route != "network" }, by: \.routeLabel)
        topRoute = routes.max { $0.value.count < $1.value.count }?.key
        allOneRoute = routes.count == 1
    }

    var tint: Color { left == 0 ? .green : online > 0 ? .blue : .teal }
    var symbol: String { left == 0 ? "lock.laptopcomputer" : online > 0 ? "globe" : "network" }

    /// The line under the bot's name.
    var headline: String {
        if left == 0 { return "Nothing left your Mac today" }
        if online > 0 { return Self.wentOnline(online) }
        return "Stayed on your network today"
    }

    static func wentOnline(_ n: Int) -> String { n == 1 ? "Went online once today" : "Went online \(n) times today" }
}

/// Bot settings' Papertrail tab: today's answer first, then how many replies stayed on this Mac
/// and how many went online this week, then each one that left, by where it went and when.
/// Amounts, models and hosts wait under Advanced.
struct PapertrailView: View {
    var model: PapertrailModel
    /// The last read failed while an earlier one is on show.
    var stale = false
    var retry: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Entries whose Why is open.
    @State private var open: Set<String> = []

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 180)
        case .off:
            hero("eye.slash", "Not recording yet", line: "Papertrail isn't on for this bot yet.", tint: Ink.text2)
                .accessibilityIdentifier("papertrail.off")
        case .privateBot:
            hero("lock.fill", "Private", line: "Papertrail isn't kept for private bots.", tint: .purple)
                .accessibilityIdentifier("papertrail.off")
        case .failed:
            VStack(spacing: 24) {
                hero("wifi.exclamationmark", "Couldn't check", line: "Your Mac didn't answer this time.", tint: .orange)
                GlassButton("Try again", symbol: "arrow.clockwise", id: "papertrail.retry", action: retry)
            }
        case .on(let trail):
            week(trail)
        }
    }

    // MARK: Pieces

    private func hero(_ symbol: String, _ title: String, line: String?, tint: Color) -> some View {
        PageHero(symbol: symbol, title: title, line: line, tint: tint, id: "papertrail.hero")
    }

    @ViewBuilder private func week(_ trail: Papertrail) -> some View {
        let today = PapertrailToday(trail)
        let (todayRows, earlier) = trail.split()
        let empty = todayRows.isEmpty && earlier.isEmpty
        VStack(spacing: 32) {
            Group {
                if today.left == 0 {
                    hero(today.symbol, "Stayed on your Mac", line: empty ? "Nothing left all week." : "Nothing left today.", tint: today.tint)
                } else if today.online > 0 {
                    hero(today.symbol, PapertrailToday.wentOnline(today.online), line: routeLine(today), tint: today.tint)
                } else {
                    hero(today.symbol, "Stayed on your network", line: "Nothing went online today.", tint: today.tint)
                }
            }
            .modifier(EmptyWeekIdentifier(empty: empty))
            if stale {
                PageNote("Couldn't check just now. This is from earlier.", symbol: "exclamationmark.triangle.fill", tint: .orange,
                         id: "papertrail.stale")
            }
            totals(trail)
            if !todayRows.isEmpty { rows("Today", todayRows, from: 0, today: true) }
            if !earlier.isEmpty { rows("Earlier this week", earlier, from: todayRows.count, today: false) }
            AdvancedLink(id: "papertrail.advanced") { PapertrailDetails(trail: trail) }
        }
    }

    /// "To Claude plan." for one, "All to Claude plan." or "Mostly to Claude plan." for more.
    private func routeLine(_ today: PapertrailToday) -> String? {
        guard let route = today.topRoute else { return nil }
        if today.online == 1 { return "To \(route)." }
        return today.allOneRoute ? "All to \(route)." : "Mostly to \(route)."
    }

    /// The week in two big numbers, side by side, or stacked when the text is large.
    private func totals(_ trail: Papertrail) -> some View {
        VStack(spacing: 16) {
            PageHeading("This week")
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 20)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                total(trail.stayedCount, symbol: "desktopcomputer", word: PapertrailWords.onMac, tint: .green,
                      spoken: trail.stayedCount == 1 ? "1 reply stayed on this Mac" : "\(trail.stayedCount) replies stayed on this Mac",
                      id: "papertrail.stayed")
                total(trail.onlineCount, symbol: "globe", word: "Online", tint: .blue,
                      spoken: trail.onlineCount == 1 ? "1 reply went online" : "\(trail.onlineCount) replies went online",
                      id: "papertrail.online")
            }
        }
    }

    /// One fact: a big symbol, the count, and a word or two.
    private func total(_ count: Int, symbol: String, word: String, tint: Color, spoken: String, id: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(height: 30)
            Text(count, format: .number)
                .font(.largeTitle.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Ink.text)
            Text(word)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Ink.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier(id)
    }

    private func rows(_ heading: String, _ entries: [Papertrail.Entry], from start: Int, today: Bool) -> some View {
        VStack(spacing: 14) {
            PageHeading(heading)
            ForEach(Array(entries.enumerated()), id: \.offset) { i, entry in row(entry, index: start + i, today: today) }
        }
    }

    /// One entry, with its Why opened or closed in place.
    private func row(_ entry: Papertrail.Entry, index: Int, today: Bool) -> some View {
        let id = "\(index)/\(entry.id)"
        return PapertrailRow(entry: entry, index: index, today: today, bot: model.botName, open: open.contains(id)) {
            withAnimation(reduceMotion ? nil : .snappy) { if open.remove(id) == nil { open.insert(id) } }
        }
    }

    /// "14:32" today, "Mon 09:12" before, in this device's own clock style. A Today row (the
    /// Mac's today) that falls on another day here, with the phone in another time zone, names its day.
    static func time(_ at: Double, today: Bool, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: at)
        return today && calendar.isDateInToday(date) ? date.formatted(.dateTime.hour().minute())
                     : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// Where it went and when, and a Why? that opens why it went and what went, in place. How much, and which model,
/// are under Advanced.
struct PapertrailRow: View {
    let entry: Papertrail.Entry
    let index: Int
    let today: Bool
    /// The bot's name as the person knows it.
    let bot: String
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        let time = PapertrailView.time(entry.at, today: today)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: entry.route == "network" ? "network" : "globe")
                        .foregroundStyle(Ink.text2)
                        .frame(width: 24)
                    Text(entry.routeLabel)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(time).font(.body).foregroundStyle(Ink.text2).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(entry.routeLabel), \(time)")
                .accessibilityIdentifier("papertrail.row.\(index)")
                WhyButton(open: open, action: toggle)
                    .accessibilityIdentifier("papertrail.why.\(index)")
            }
            if open {
                let why = entry.why(bot: bot.isEmpty ? "This bot" : bot)
                WhyNote(text: why.reason, detail: why.sent, colors: PostColors(text: Ink.text, detail: Ink.text2))
                    .padding(.leading, 36)
                    .accessibilityIdentifier("papertrail.why.\(index).text")
            }
        }
    }
}

private enum PapertrailWords {
    /// Where the replies stayed, said from the device in hand.
    static var onMac: String {
        #if os(macOS)
        "On this Mac"
        #else
        "On your Mac"
        #endif
    }
}

/// The hero of a week with nothing in it keeps the identifier the empty note had.
private struct EmptyWeekIdentifier: ViewModifier {
    var empty: Bool
    func body(content: Content) -> some View {
        if empty { content.accessibilityIdentifier("papertrail.empty") } else { content }
    }
}

/// Papertrail › Advanced: how many left this week at the top, then each one with how much it
/// sent, the model and the host, and since when this bot has been keeping a papertrail.
private struct PapertrailDetails: View {
    var trail: Papertrail

    var body: some View {
        let (today, earlier) = trail.split()
        SettingsPage("papertrail.details") {
            PageHero(symbol: "list.bullet.rectangle", title: Self.title(trail.left?.window ?? today.count + earlier.count), tint: Ink.text,
                     id: "papertrail.details.hero")
            if let since = trail.recordingSince {
                PageNote("Keeping a papertrail since \(Date(timeIntervalSince1970: since).formatted(date: .abbreviated, time: .omitted)).",
                         symbol: "calendar")
            }
            if !today.isEmpty { section("Today", today, today: true) }
            if !earlier.isEmpty { section("Earlier this week", earlier, today: false) }
            if let more = trail.more, more > 0 {
                PageNote(more == 1 ? "1 older one isn't listed." : "\(more) older ones aren't listed.")
            }
            PageNote("Searches answered from memory still count, so search counts can run a little high.", symbol: "info.circle")
        }
        .untitledPage()
    }

    /// The top of the page: how many times something left this week.
    private static func title(_ count: Int) -> String {
        switch count {
        case 0: "Nothing left this week"
        case 1: "Left once this week"
        default: "Left \(count) times this week"
        }
    }

    private func section(_ heading: String, _ entries: [Papertrail.Entry], today: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(heading)
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in detail(entry, today: today) }
        }
    }

    private func detail(_ entry: Papertrail.Entry, today: Bool) -> some View {
        let time = PapertrailView.time(entry.at, today: today)
        let place = [entry.model, entry.host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.routeLabel).font(.body.weight(.semibold)).foregroundStyle(Ink.text)
                Spacer(minLength: 8)
                Text(time).font(.body).foregroundStyle(Ink.text2).monospacedDigit()
            }
            let amount = entry.amountText
            if !amount.isEmpty { Text(amount).font(.body).foregroundStyle(Ink.text2) }
            if !place.isEmpty {
                Text(place).font(.callout.monospaced()).foregroundStyle(Ink.text2).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .spread()
        .accessibilityElement(children: .combine)
    }
}
