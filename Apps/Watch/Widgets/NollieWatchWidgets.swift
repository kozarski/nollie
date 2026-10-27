import AppIntents
import SwiftUI
import WidgetKit

/// Nollie on the watch face and in the Smart Stack: how many helpers are working, and a Stop
/// control for Control Center and the Action button.
@main
struct NollieWatchWidgets: WidgetBundle {
    var body: some Widget {
        CrewWidget()
        StopControl()
    }
}

// MARK: - Crew

struct CrewEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchWire.Snapshot?
    /// The phone's word is older than the Watch believes it: say when it was, not that work is live.
    let stale: Bool

    var helpers: [WatchWire.Helper] { stale ? [] : snapshot?.helpers ?? [] }
    var waiting: Int { snapshot?.approvals.count ?? 0 }

    var relevance: TimelineEntryRelevance? {
        // Up the Smart Stack while someone works or something waits; quiet otherwise.
        TimelineEntryRelevance(score: helpers.isEmpty && waiting == 0 ? 0 : Float(10 + helpers.count + 2 * waiting))
    }
}

struct CrewProvider: TimelineProvider {
    func placeholder(in context: Context) -> CrewEntry {
        CrewEntry(date: .now, snapshot: Self.sample, stale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (CrewEntry) -> Void) {
        let saved = WatchSnapshotStore.load()
        completion(CrewEntry(date: .now, snapshot: context.isPreview && saved == nil ? Self.sample : saved, stale: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CrewEntry>) -> Void) {
        let now = Date()
        guard let saved = WatchSnapshotStore.load() else {
            return completion(Timeline(entries: [CrewEntry(date: now, snapshot: nil, stale: false)], policy: .never))
        }
        // Live until the phone's word goes stale, then "last seen". The app reloads on news.
        let staleAt = saved.made.addingTimeInterval(HelperAtWorkTiming.staleAfter)
        var entries = [CrewEntry(date: now, snapshot: saved, stale: now >= staleAt)]
        if staleAt > now, !saved.helpers.isEmpty { entries.append(CrewEntry(date: staleAt, snapshot: saved, stale: true)) }
        completion(Timeline(entries: entries, policy: .never))
    }

    static let sample = WatchWire.Snapshot(
        made: .now, approvals: [],
        helpers: [WatchWire.Helper(profile: "career", name: "Scout", avatar: "", place: .mac, since: .now),
                  WatchWire.Helper(profile: "nowhere", name: "Mason", avatar: "", place: nil, since: .now)],
        canStop: true, connected: true)
}

struct CrewWidget: Widget {
    static let kind = "com.coreykozarski.nollie.watch.crew"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: CrewProvider()) { entry in
            CrewWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Helpers")
        .description("Who is working, and what waits for your yes.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline, .accessoryCorner])
    }
}

struct CrewWidgetView: View {
    let entry: CrewEntry
    @Environment(\.widgetFamily) private var family

    private var count: Int { entry.helpers.count }
    private var waits: Bool { entry.waiting > 0 }
    private var headline: String {
        waits && count == 0 ? WatchWords.waiting(entry.waiting) : WatchWords.count(count)
    }
    /// Something waiting for a yes shows first: a raised hand, then who is working.
    private var symbol: String {
        waits ? "hand.raised.fill" : count > 0 ? "person.2.fill" : "moon.zzz.fill"
    }
    private var spoken: String {
        [WatchWords.count(count), waits ? WatchWords.waiting(entry.waiting) : nil].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: 0) {
                // The symbol names the number: a raised hand counts what waits, two people who works.
                Image(systemName: symbol)
                    .font(.footnote)
                Text("\(waits ? entry.waiting : count)")
                    .font(.title2.weight(.semibold))
                    .contentTransition(.numericText())
            }
            .widgetAccentable()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
        case .accessoryInline:
            Label(waits && count > 0 ? String(localized: "\(WatchWords.count(count)), \(entry.waiting) waiting", comment: "Who is working, then how many approvals wait")
                  : headline, systemImage: symbol)
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title3)
                .widgetLabel(waits && count > 0 ? String(localized: "\(count) working, \(entry.waiting) waiting", comment: "Helpers working, then approvals waiting")
                             : headline)
                .widgetAccentable()
        default:
            rectangular
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Nollie", systemImage: waits ? "hand.raised.fill" : "person.2.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .widgetAccentable()
            Text(headline)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What waits for a yes, else who, or how long since the phone last said.
    private var detail: String? {
        if waits, count > 0 { return WatchWords.waiting(entry.waiting) }
        if entry.stale, let made = entry.snapshot?.made {
            return WatchWords.seenAt(made.formatted(date: .omitted, time: .shortened))
        }
        let names = entry.helpers.map(\.name)
        return names.isEmpty ? nil : names.formatted(.list(type: .and))
    }
}

// MARK: - Stop

/// One press: the Watch opens at the crew and stops everything on the Mac, as the Lock Screen's
/// Stop does.
struct StopControl: ControlWidget {
    static let kind = "com.coreykozarski.nollie.watch.stop"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StopFromWatchIntent()) {
                Label("Stop Nollie", systemImage: "stop.circle.fill")
            }
            .tint(.red)
        }
        .displayName("Stop Nollie")
        .description("Ends the helper's task, stops replies and pauses schedules.")
    }
}
