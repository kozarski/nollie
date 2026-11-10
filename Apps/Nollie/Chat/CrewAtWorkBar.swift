#if os(iOS)
import SwiftUI
import NollieCore

/// At the foot of the chat list while any helper works: their faces, who is working and what at,
/// and, on a phone linked to a Mac, one red Stop for everything there, the same Stop the Lock
/// Screen, the Watch and Siri give. Tapping the faces opens the helper's chat (several: a menu).
struct CrewAtWorkBar: View {
    /// Opens a bot's chat, as tapping its row does.
    var open: (String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var stopping = false
    /// How the last Stop went, for a few seconds.
    @State private var outcome: String?
    @State private var outcomeClear: Task<Void, Never>?
    /// The bar's width, for the layout.
    @State private var width: CGFloat = 0
    /// Narrower than this, faces, words and Stop don't fit on one line.
    private static let rowWidth: CGFloat = 340

    private var members: [CrewAtWork.Member] { CrewAtWork.members(in: model.runtime) }

    /// Stop goes to the Mac this phone is linked to. The demo copy plays a linked phone with `-nollie-demo-reach`.
    private var canStop: Bool {
        model.runtime?.connection.linkedMac != nil || (DemoMode.isOn && model.linkReach != nil)
    }

    /// The one schedule run Stop ends here, when the only helper at work is on a schedule and no Mac
    /// is linked to take the bigger Stop.
    private func soleRun(_ members: [CrewAtWork.Member]) -> CrewAtWork.Member? {
        guard !canStop, members.count == 1, let only = members.first, only.work?.jobID != nil else { return nil }
        return only
    }

    var body: some View {
        let members = members
        Group {
            if !members.isEmpty || outcome != nil {
                // Each minute the "4 min" moves on.
                TimelineView(.periodic(from: .now, by: 30)) { context in bar(members, now: context.date) }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: members.map(\.id))
        .animation(.snappy, value: outcome)
    }

    private func bar(_ members: [CrewAtWork.Member], now: Date) -> some View {
        // Side by side; in a narrow column or at the largest text sizes Stop goes under the words, so
        // nothing is cut short, and the corners round more gently than a capsule would into the words.
        let run = soleRun(members)
        let withStop = (canStop || run != nil) && !members.isEmpty
        let stacked = withStop && (typeSize.isAccessibilitySize || (width > 0 && width < Self.rowWidth))
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            who(members, now: now)
            if let run { runStopButton(run) } else if withStop { stopButton }
        }
        .padding(.leading, stacked ? 16 : 10)
        .padding(.trailing, withStop && !stacked ? 8 : 20)
        .padding(.vertical, stacked ? 14 : 8)
        .frame(minHeight: 60)
        .nollieGlass(.regular, in: stacked ? AnyShape(.rect(cornerRadius: 28, style: .continuous)) : AnyShape(Capsule()), solid: Ink.card)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chats.atWork")
    }

    @ViewBuilder private func who(_ members: [CrewAtWork.Member], now: Date) -> some View {
        let label = whoLabel(members, now: now)
        if members.count > 1 {
            Menu {
                ForEach(members) { member in
                    Button { open(member.helper.profile) } label: {
                        Text(member.helper.name)
                        Text(member.line(now: now))
                    }
                }
                // A schedule's run can be stopped on its own from here; the schedule stays on.
                let runs = members.filter { $0.work?.jobID != nil }
                if !runs.isEmpty {
                    Section {
                        ForEach(runs) { member in
                            Button(role: .destructive) { stopRun(member) } label: {
                                Label(ScheduleStopWords.stopNamed(member.work?.title ?? ""), systemImage: "stop.fill")
                            }
                            .accessibilityIdentifier("chats.atWork.stopRun." + member.helper.profile)
                        }
                    }
                }
            } label: { label }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chats.atWork.who")
        } else {
            Button { if let only = members.first { open(only.helper.profile) } } label: { label }
                .buttonStyle(.plain)
                .disabled(members.isEmpty)
                .accessibilityIdentifier("chats.atWork.who")
        }
    }

    private func whoLabel(_ members: [CrewAtWork.Member], now: Date) -> some View {
        let headline = members.isEmpty ? outcome.map(Self.short) ?? "" : CrewAtWork.headline(members.map(\.helper))
        // At the largest sizes the faces sit above the words, which get the bar's whole width and
        // break only between words: "2 helpers working", never "work-ing".
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            faces(members)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: typeSize.isAccessibilitySize ? LineBreaks.wholeWords(headline) : headline)
                    .accessibilityLabel(headline)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                // At the largest text sizes the step is left to the helper's own row above, which
                // says the same words, so the bar stays one short line over the list.
                if !members.isEmpty,
                   let line = outcome.map(Self.short) ?? (members.count == 1 && !typeSize.isAccessibilitySize ? members.first?.line(now: now) : nil) {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(outcome == nil || Self.calm(outcome) ? Ink.text2 : .orange)
                        .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.capsule)
        .accessibilityElement(children: .combine)
        .accessibilityHint(members.count > 1 ? "Shows each helper" : "Opens the chat")
    }

    /// Up to three faces, overlapping a little.
    private func faces(_ members: [CrewAtWork.Member]) -> some View {
        HStack(spacing: -12) {
            ForEach(members.prefix(3)) { member in
                BotAvatar(profile: member.helper.profile, size: 40, state: .working)
                    .frame(width: 40, height: 40)
            }
            if members.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Ink.online)
                    .frame(width: 40, height: 40)
            }
        }
        .accessibilityHidden(true)
    }

    private var stopButton: some View {
        Button(action: stop) {
            Label(stopping ? HelperAtWorkWords.stopping : HelperAtWorkWords.stop, systemImage: "stop.fill")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 6)
                .frame(minHeight: 36)
        }
        .buttonStyle(NollieGlassButtonStyle(prominent: true))
        .tint(.red)
        .disabled(stopping)
        .accessibilityHint("Ends the job on your Mac, stops replies and pauses schedules.")
        .accessibilityIdentifier("chats.atWork.stop")
    }

    /// Stop for the one schedule run showing: that run ends, the schedule stays.
    private func runStopButton(_ member: CrewAtWork.Member) -> some View {
        let stoppingRun = stopping || (member.work?.jobID).map { model.runtime?.schedules.stopping.contains($0) == true } == true
        return Button { stopRun(member) } label: {
            Label(stoppingRun ? ScheduleStopWords.stopping : HelperAtWorkWords.stop, systemImage: "stop.fill")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 6)
                .frame(minHeight: 36)
        }
        .buttonStyle(NollieGlassButtonStyle(prominent: true))
        .tint(.red)
        .disabled(stoppingRun)
        .accessibilityHint(ScheduleStopWords.hint)
        .accessibilityIdentifier("chats.atWork.stopRun")
    }

    private func stopRun(_ member: CrewAtWork.Member) {
        guard !stopping, let jobID = member.work?.jobID, let runtime = model.runtime else { return }
        stopping = true
        Task {
            let line = await ScheduleStopWords.stop(jobID: jobID, profile: member.helper.profile, on: runtime)
            stopping = false
            show(line)
        }
    }

    /// A Stop that went as asked, said in grey; anything else in orange.
    private static func calm(_ outcome: String?) -> Bool {
        [MacStopWords.stopped, ScheduleStopWords.stopped, ScheduleStopWords.alreadyDone].contains(outcome ?? "")
    }

    private func stop() {
        guard !stopping else { return }
        stopping = true
        Task {
            let line = DemoMode.isOn ? await demoStop() : await MacStop.press()
            stopping = false
            show(line)
        }
    }

    /// The demo copy has no Mac: it stops the replies it runs and says what a real Stop says.
    private func demoStop() async -> String {
        try? await Task.sleep(for: .milliseconds(700))
        for chat in model.runtime?.chats.filter(\.isRunning) ?? [] { await chat.stop() }
        return MacStopWords.stopped
    }

    /// How Stop went, short enough for the bar. The full sentence is read out to VoiceOver.
    static func short(_ outcome: String) -> String {
        if [ScheduleStopWords.stopped, ScheduleStopWords.alreadyDone, ScheduleStopWords.notStopped].contains(outcome) { return outcome }
        return outcome == MacStopWords.stopped
            ? String(localized: "Stopping on your Mac", comment: "Safety: Stop was pressed and the Mac is stopping the helpers' work")
            : HelperAtWorkWords.notReached
    }

    private func show(_ line: String) {
        UIAccessibility.post(notification: .announcement, argument: line)
        outcome = line
        outcomeClear?.cancel()
        outcomeClear = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            outcome = nil
        }
    }
}
#endif
