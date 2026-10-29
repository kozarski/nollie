#if os(iOS)
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// "Scout is using your Mac": the helper's character, how long it has been at it, a live dot and
/// one Stop button. Past its stale date (the app has not seen the work for a while, or lost the
/// link to the Mac) it dims and says when the helper was last seen instead. A pressed Stop shows
/// a stop sign while it travels, then a green tick and "Scout stopped" before the activity goes.
struct HelperAtWorkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HelperAtWorkAttributes.self) { context in
            HelperAtWorkLockScreen(context: context)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let look = HelperAtWorkLook(context: context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HelperAvatar(name: context.attributes.avatar, dimmed: look.dimmed)
                        .frame(width: 44, height: 44)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(look.title)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        HelperAtWorkStatus(context: context, look: look)
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StopOutcome(phase: look.phase)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if look.showsStop {
                        StopButton()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 6)
                    }
                }
            } compactLeading: {
                HelperAvatar(name: context.attributes.avatar, dimmed: look.dimmed)
                    .frame(width: 24, height: 24)
            } compactTrailing: {
                if look.phase == .stopping || look.phase == .stopped {
                    StopOutcome(phase: look.phase)
                } else if look.isLive {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: 44)
                        .multilineTextAlignment(.trailing)
                } else {
                    LiveDot(live: false)
                }
            } minimal: {
                HelperAvatar(name: context.attributes.avatar, dimmed: look.dimmed)
            }
            .keylineTint(look.isLive || look.phase == .stopped ? .green : .secondary)
        }
    }
}

/// What the activity shows, worked out once from its state.
struct HelperAtWorkLook {
    let title: String
    let phase: HelperAtWorkAttributes.ContentState.Phase
    /// Past the stale date, or the link is gone: last seen, never live.
    let stale: Bool

    init(context: ActivityViewContext<HelperAtWorkAttributes>) {
        stale = context.isStale || !context.state.reachable
        // "Stopping" past its stale date means the answer never came: last seen, with Stop.
        phase = context.state.phase == .stopping && stale ? .working : context.state.phase
        let name = context.attributes.name
        title = switch phase {
        case .stopping: HelperAtWorkWords.stoppingTitle(name: name)
        case .stopped: HelperAtWorkWords.stoppedTitle(name: name)
        case .working, .notReached: HelperAtWorkWords.title(name: name, place: context.attributes.place)
        }
    }

    var isLive: Bool { phase == .working && !stale }
    var dimmed: Bool { stale || phase == .stopped }
    var showsStop: Bool { phase == .working || phase == .notReached }
}

private struct HelperAtWorkLockScreen: View {
    let context: ActivityViewContext<HelperAtWorkAttributes>

    var body: some View {
        let look = HelperAtWorkLook(context: context)
        HStack(spacing: 14) {
            HelperAvatar(name: context.attributes.avatar, dimmed: look.dimmed)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(look.title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HelperAtWorkStatus(context: context, look: look)
                    .font(.subheadline)
            }
            .opacity(look.stale ? 0.6 : 1)
            Spacer(minLength: 8)
            if look.showsStop { StopButton() } else { StopOutcome(phase: look.phase) }
        }
        .padding(16)
    }
}

/// The line under the title: live dot and elapsed time, or when the helper was last seen, or
/// how a Stop went.
private struct HelperAtWorkStatus: View {
    let context: ActivityViewContext<HelperAtWorkAttributes>
    let look: HelperAtWorkLook

    var body: some View {
        switch look.phase {
        case .working where !look.stale:
            HStack(spacing: 6) {
                LiveDot(live: true)
                Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
        case .working:
            // "Last seen 2 min ago", kept current by the system, minutes and hours only.
            Text("Last seen \(Text(.currentDate, format: .reference(to: context.state.lastSeen, allowedFields: [.hour, .minute], maxFieldCount: 1)))",
                 comment: "Then how long ago, kept current by the system")
                .foregroundStyle(.secondary)
        case .stopping:
            Text(HelperAtWorkWords.stopping).foregroundStyle(.secondary)
        case .stopped:
            Text(HelperAtWorkWords.stopped).foregroundStyle(.secondary)
        case .notReached:
            Text(HelperAtWorkWords.notReached).foregroundStyle(.secondary)
        }
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopMacIntent()) {
            Label(HelperAtWorkWords.stop, systemImage: "stop.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(.red)
        .accessibilityIdentifier("helperAtWork.stop")
    }
}

/// What a pressed Stop is doing: a stop sign while it travels, a green tick once the Mac took it.
private struct StopOutcome: View {
    let phase: HelperAtWorkAttributes.ContentState.Phase
    var body: some View {
        switch phase {
        case .stopping:
            // A still sign, not a spinner: the Lock Screen draws a spinner as an empty ring.
            Image(systemName: "stop.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(HelperAtWorkWords.stopping)
        case .stopped:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .accessibilityLabel(HelperAtWorkWords.stopped)
        case .working, .notReached:
            EmptyView()
        }
    }
}

private struct LiveDot: View {
    let live: Bool
    var body: some View {
        Circle()
            .fill(live ? Color.green : Color.secondary)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

/// The helper's character still, on its own tint, in a circle.
private struct HelperAvatar: View {
    let name: String
    let dimmed: Bool
    var body: some View {
        Image(name)
            .resizable()
            .scaledToFill()
            .clipShape(Circle())
            .saturation(dimmed ? 0 : 1)
            .opacity(dimmed ? 0.6 : 1)
            .accessibilityHidden(true)
    }
}
#endif
