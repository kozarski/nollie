import SwiftUI

/// Who is working now, calmly: each helper's character, name and what it is doing, and one red
/// Stop for everything on the Mac. With nobody at work it says so and shows Nollie.
struct CrewPage: View {
    @Environment(WatchModel.self) private var model

    private var snapshot: WatchWire.Snapshot { model.snapshot ?? .empty() }
    private var helpers: [WatchWire.Helper] { snapshot.helpers }
    private var stopping: Bool { model.sending.contains(WatchModel.stopKey) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let stale = model.snapshot.map { WatchFreshness.isStale($0, now: context.date) } ?? true
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if helpers.isEmpty {
                        quiet
                    } else {
                        Text(WatchWords.count(helpers.count))
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        ForEach(helpers) { HelperRow(helper: $0, stale: stale) }
                        if stale, let made = model.snapshot?.made {
                            Text("\(WatchWords.lastSeen) \(made.formatted(date: .omitted, time: .shortened))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if snapshot.canStop { stopButton }
                    }
                    if let note = model.note, model.page == WatchModel.crewPage {
                        NoteLine(text: note)
                    } else if model.phoneAway {
                        NoteLine(text: WatchWords.phoneAway)
                    } else if model.snapshot?.connected == false {
                        NoteLine(text: WatchWords.openPhone)
                    }
                }
                .scenePadding(.horizontal)
            }
        }
    }

    private var quiet: some View {
        VStack(spacing: 8) {
            BotFace(avatar: "character-nollie-avatar", size: 52)
            Text(WatchWords.allQuiet)
                .font(.title3.weight(.semibold))
            Text(WatchWords.nobodyWorking)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var stopButton: some View {
        Button {
            Task { await model.stop() }
        } label: {
            Label(stopping ? HelperAtWorkWords.stopping : WatchWords.stop, systemImage: "stop.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.red)
        .disabled(stopping)
        .padding(.top, 4)
        .accessibilityHint(MacStopHint.text)
        .accessibilityIdentifier("watch.stop")
    }
}

/// One helper at work.
private struct HelperRow: View {
    let helper: WatchWire.Helper
    let stale: Bool

    var body: some View {
        HStack(spacing: 10) {
            BotFace(avatar: helper.avatar, size: 32)
                .saturation(stale ? 0 : 1)
                .opacity(stale ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(helper.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(WatchWords.doing(helper.place))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if !stale {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What Stop does, for VoiceOver.
enum MacStopHint {
    static let text = "Ends the helper's task on your Mac, stops replies and pauses schedules."
}
