import SwiftUI
import NollieCore

/// The way into quick answers during setup: one glass pill that opens the sheet. It is not there
/// when this device can't run Apple's model or quick answers are switched off.
struct QuickAnswerButton: View {
    var place: QuickAnswerRules.Place
    @State private var open = false

    var body: some View {
        if QuickAnswers.offered {
            Button { open = true } label: {
                Label("Quick question", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.nollieGlass)
            .buttonBorderShape(.capsule)
            .tint(.primary)
            .help("Ask Nollie something now. It stays on \(DeviceWords.this).")
            .testID("quickAnswer.open")
            .sheet(isPresented: $open) {
                QuickAnswerSheet(place: place, script: QuickAnswerDemo.script).withAppModel()
            }
            .task { if QuickAnswerDemo.opensByItself { open = true } }
        }
    }
}

#if os(iOS)
/// Above the Chats list while the Mac can't be reached: says so, and offers a quick answer here.
/// It also sends questions kept for the Mac once it is back, and says when they went.
struct QuickAnswerAwayBar: View {
    var runtime: GatewayRuntime
    @Environment(AppModel.self) private var model
    @State private var outOfReachSince: Date?
    @State private var now = Date()
    @State private var open = false

    private var handoff: QuickAnswerHandoff { QuickAnswerHandoff.shared }

    private var away: Bool {
        guard QuickAnswers.offered, let since = outOfReachSince else { return false }
        return QuickAnswerRules.offersWhileAway(runtime.socketState, outOfReachFor: now.timeIntervalSince(since))
    }

    var body: some View {
        VStack(spacing: 8) {
            if away {
                awayPill.transition(.move(edge: .top).combined(with: .opacity))
            } else if let delivered = handoff.delivered {
                sentPill(delivered.count).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, away || handoff.delivered != nil ? 8 : 0)
        .animation(.snappy, value: away)
        .animation(.snappy, value: handoff.delivered?.at)
        .onChange(of: runtime.socketState, initial: true) { _, state in
            if state.isOpen {
                outOfReachSince = nil
                Task { await handoff.deliverWaiting(model: model) }
            } else if outOfReachSince == nil {
                outOfReachSince = Date()
            }
        }
        .onChange(of: runtime.profiles.count) {
            if runtime.socketState.isOpen { Task { await handoff.deliverWaiting(model: model) } }
        }
        .onChange(of: model.lock.isLocked) { _, locked in
            if !locked { Task { await handoff.deliverWaiting(model: model) } }
        }
        // Looks again once the grace has passed, so a quick reconnect never shows the pill.
        .task(id: outOfReachSince) {
            now = Date()
            guard outOfReachSince != nil else { return }
            try? await Task.sleep(for: .seconds(QuickAnswerRules.awayGrace + 0.5))
            now = Date()
        }
        .task(id: handoff.delivered?.at) {
            guard handoff.delivered != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            withAnimation(.snappy) { handoff.clearDelivered() }
        }
        .sheet(isPresented: $open) {
            QuickAnswerSheet(place: .macAway, script: QuickAnswerDemo.script).withAppModel()
        }
        .task(id: away) { if away, QuickAnswerDemo.opensByItself { open = true } }
    }

    private var awayPill: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Can't reach your Mac").font(.subheadline.weight(.semibold)).foregroundStyle(Ink.text)
                if !handoff.waiting.isEmpty {
                    Text("\(handoff.waiting.count) questions waiting")
                        .font(.footnote).foregroundStyle(Ink.text2)
                }
            }
            Spacer(minLength: 8)
            Button { open = true } label: {
                Text("Quick answer").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.nollieGlassProminent)
            .buttonBorderShape(.capsule)
            .testID("quickAnswer.open")
        }
        .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
        .nollieGlass(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .testID("quickAnswer.away")
    }

    private func sentPill(_ count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.readableGreen).accessibilityHidden(true)
            Text("\(count) questions went to your Mac")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Ink.text)
            Spacer(minLength: 8)
            Button {
                handoff.clearDelivered()
                Task { _ = await model.openMainChat(QuickAnswerHandoff.mainBot(runtime)) }
            } label: { Text("Open").font(.subheadline.weight(.semibold)) }
            .buttonStyle(.nollieGlass)
            .buttonBorderShape(.capsule)
            .tint(.primary)
            .testID("quickAnswer.sent.open")
        }
        .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
        .nollieGlass(.regular, in: Capsule())
        .testID("quickAnswer.sent")
    }
}
#endif

/// Debug launch flags for pictures: `-nollie-demo-quick-ask "first|second"` opens quick answers
/// as soon as they are offered and asks those questions in turn. Add `-nollie-test-quick-answers`
/// where Apple's model can't run.
enum QuickAnswerDemo {
    static var script: [String] {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard DemoMode.isOn || QuickAnswers.pretend, let at = args.firstIndex(of: "-nollie-demo-quick-ask"),
              args.indices.contains(at + 1) else { return [] }
        return args[at + 1].split(separator: "|").map(String.init)
        #else
        return []
        #endif
    }

    static var opensByItself: Bool { !script.isEmpty }

    /// With `-nollie-demo-quick-hand-off`, a scripted question for the helper is handed to it.
    static var handsOff: Bool {
        #if DEBUG
        !script.isEmpty && ProcessInfo.processInfo.arguments.contains("-nollie-demo-quick-hand-off")
        #else
        false
        #endif
    }
}
