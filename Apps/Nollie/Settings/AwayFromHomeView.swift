import SwiftUI
import NollieCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where Tailscale is got. Opening a page is all Nollie does: it never changes Tailscale.
enum TailscaleLinks {
    static let macDownload = URL(string: "https://tailscale.com/download/mac")!
    static let iPhoneApp = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
    static let app = URL(fileURLWithPath: "/Applications/Tailscale.app")
}

/// Away from home as the screen shows it, from the Mac's helper (on the Mac) or the Mac's door
/// (on a linked iPhone).
struct AwayFacts: Equatable {
    var on: Bool
    /// "ready", "stopped" or "missing", on the Mac.
    var tailscale: String
    /// The Mac sends everything through a Tailscale exit node and its relay can't carry the
    /// helpers' computers' traffic, so the card shows (on the Mac only).
    var exitNode = false
    /// A name the person typed in on the Mac.
    var host: String?

    var ready: Bool { tailscale == "ready" }
}

@MainActor @Observable
final class AwayFromHomeModel {
    private(set) var facts: AwayFacts?
    private(set) var issue: String?
    private(set) var busy = false
    #if DEBUG
    // `-nollie-demo-away-on` starts with the switch on, for pictures. `-nollie-demo-exit-node` adds
    // an exit node whose relay can't connect; with `-nollie-demo-exit-relay on` the relay carries it.
    private var demo = AwayFacts(on: ProcessInfo.processInfo.arguments.contains("-nollie-demo-away-on"),
                                 tailscale: DemoMode.tailscale ?? "missing",
                                 exitNode: AwayFromHomeModel.demoExitNode)
    private static var demoExitNode: Bool {
        let exitNode = ProcessInfo.processInfo.arguments.contains("-nollie-demo-exit-node")
        #if os(macOS)
        return NollieExitRelayState.showsExitNodeCard(exitNode: exitNode, relay: DemoMode.exitRelay ?? "failed")
        #else
        return exitNode
        #endif
    }
    #endif

    private var pretend: Bool {
        #if DEBUG && os(macOS)
        DemoMode.isOn
        #else
        false
        #endif
    }

    func refresh(_ model: AppModel) async {
        #if DEBUG
        if pretend { facts = demo; return }
        #endif
        #if os(macOS)
        do {
            facts = Self.facts(try await NollieLinkMacClient.away())
            issue = nil
        } catch {
            issue = "Couldn't check. Make sure Nollie's background service is on."
        }
        #else
        guard let runtime = model.runtime else { return }
        if let reply = await runtime.refreshLink() {
            facts = AwayFacts(on: reply.away, tailscale: reply.tailscale)
        } else if let link = runtime.connection.linkedMac {
            facts = AwayFacts(on: link.away ?? false, tailscale: link.tailscale ?? "missing")
        }
        #endif
    }

    func set(_ on: Bool, _ model: AppModel) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        issue = nil
        #if DEBUG
        if pretend { demo.on = on; facts = demo; return }
        #endif
        #if os(macOS)
        do { facts = Self.facts(try await NollieLinkMacClient.away(on: on)) } catch {
            issue = "Couldn't change it. Try again."
        }
        #else
        guard let runtime = model.runtime, let reply = await runtime.setLinkAway(on) else {
            issue = on ? "Your Mac didn't answer. Turn this on at home, or on your Mac." : "Your Mac didn't answer. Try again."
            return
        }
        facts = AwayFacts(on: reply.away, tailscale: reply.tailscale)
        #endif
    }

    #if os(macOS)
    /// Saves a typed-in name. Returns what is wrong with it, or nil.
    func save(host: String) async -> String? {
        let typed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard typed.isEmpty || (NollieTailnet.isTailnetHost(typed) && NollieTailnet.validLinkHost(typed)) else {
            return "That isn't a Tailscale name. It looks like your-mac.tail1234.ts.net."
        }
        #if DEBUG
        if pretend { demo.host = typed.isEmpty ? nil : typed; facts = demo; return nil }
        #endif
        do { facts = Self.facts(try await NollieLinkMacClient.away(host: typed)) } catch {
            return "Couldn't save it. Try again."
        }
        return nil
    }

    private static func facts(_ away: NollieLinkIPCAway) -> AwayFacts {
        AwayFacts(on: away.on, tailscale: away.tailscale,
                  exitNode: NollieExitRelayState.showsExitNodeCard(exitNode: away.exitNode ?? false, relay: away.relay),
                  host: away.host)
    }
    #endif
}

/// Settings › Away from home: where you are, what works where, one switch, and Tailscale's steps
/// only once it is on. The model for every settings page: a hero, few words, glass pills, air.
struct AwayFromHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var away = AwayFromHomeModel()

    private var hero: AwayHero.State {
        #if os(macOS)
        guard let facts = away.facts, facts.on else { return .home }
        return facts.ready ? .anywhere : .needsTailscale
        #else
        switch model.linkReach {
        case .tailnet?: return .tailnet
        case .away?: return model.cloudAlerts.isEnabled || DemoMode.alertsOn ? .alertsOnly : .away
        default: return .home
        }
        #endif
    }

    /// A name typed in on the Mac; the phone has no such field.
    private func save(_ host: String) async -> String? {
        #if os(macOS)
        await away.save(host: host)
        #else
        nil
        #endif
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                AwayFromHomePage(hero: hero, facts: away.facts, busy: away.busy, issue: away.issue,
                                 set: { on in Task { await away.set(on, model) } },
                                 save: save)
                    .animation(.snappy, value: away.facts)
            }
            .background(Ink.canvas.ignoresSafeArea())
            #if os(iOS)
            // The floating back button: words scrolled under it fade out instead of showing through.
            .scrollEdgeEffectStyle(.hard, for: .top)
            #endif
            #if DEBUG
            // Pictures of the lower half: `-nollie-demo-scroll-end`.
            .task(id: away.facts) {
                guard DemoMode.isOn, away.facts != nil, ProcessInfo.processInfo.arguments.contains("-nollie-demo-scroll-end") else { return }
                try? await Task.sleep(for: .milliseconds(600))
                reader.scrollTo("away.end", anchor: .bottom)
            }
            #endif
        }
        .testID("away.page")
        .task {
            // Nollie looks again by itself while the screen is open, so "Ready" shows up on its own.
            while !Task.isCancelled {
                await away.refresh(model)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

/// What the page shows, apart from where it comes from: also drawn by the design snapshots.
struct AwayFromHomePage: View {
    var hero: AwayHero.State
    var facts: AwayFacts?
    var busy = false
    var issue: String?
    var set: (Bool) -> Void = { _ in }
    var save: (String) async -> String? = { _ in nil }

    var body: some View {
        VStack(spacing: 40) {
            AwayHero(state: hero)
            AwayComparison()
            VStack(spacing: 18) {
                switchRow
                if let facts, facts.on, facts.ready {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.green)
                        .testID("away.ready")
                }
                if let issue {
                    Text(issue).foregroundStyle(Ink.text2).multilineTextAlignment(.center)
                        .testID("away.issue")
                }
            }
            if let facts, facts.on, !facts.ready {
                VStack(alignment: .leading, spacing: 28) {
                    TailscaleSetupSteps()
                    #if os(macOS)
                    AwayManualHost(saved: facts.host, save: save)
                    #endif
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            #if os(macOS)
            if facts?.exitNode == true { ExitNodeCard() }
            #endif
            Color.clear.frame(height: 1).id("away.end")
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 40)
        .frame(maxWidth: .infinity)
    }

    /// One clear row: the switch, on a glass capsule.
    private var switchRow: some View {
        Toggle(isOn: Binding(get: { facts?.on ?? false }, set: set)) {
            Text("Use Nollie away from home").font(.headline).foregroundStyle(Ink.text)
        }
        .toggleStyle(.switch)
        .disabled(facts == nil || busy)
        .inset(h: 22, v: 14)
        .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
        .testID("away.switch")
    }
}

/// The top of the page: one large symbol and where you are, in its own colour.
struct AwayHero: View {
    enum State: Equatable {
        case home, tailnet, away, alertsOnly, anywhere, needsTailscale

        var symbol: String {
            switch self {
            case .home: "house.fill"
            case .tailnet, .anywhere: "globe.americas.fill"
            case .away, .alertsOnly, .needsTailscale: "airplane"
            }
        }
        var title: String {
            switch self {
            case .home: "At home"
            case .tailnet: "Connected through Tailscale"
            case .away, .needsTailscale: "Away from home"
            case .alertsOnly: "Alerts only"
            case .anywhere: "Ready anywhere"
            }
        }
        var line: String {
            switch self {
            case .home: "Everything works."
            case .tailnet, .anywhere: "Everything works, wherever you are."
            case .away, .alertsOnly: "Your Mac is out of reach."
            case .needsTailscale: "This needs Tailscale."
            }
        }
        var tint: Color {
            switch self {
            case .home: .blue
            case .tailnet, .anywhere: .green
            case .away, .needsTailscale: .orange
            case .alertsOnly: .purple
            }
        }
    }

    var state: State

    var body: some View {
        PageHero(symbol: state.symbol, title: state.title, line: state.line, tint: state.tint, id: "away.hero")
    }
}

/// Without Tailscale and with it, side by side: a few symbols and a word each.
struct AwayComparison: View {
    var body: some View {
        FactTiles(leading: FactTile(title: "Without Tailscale", tint: Ink.text2, facts: [Fact(symbol: "bell.fill", word: "Alerts")], id: "away.without"),
                  trailing: FactTile(title: "With Tailscale", tint: .green,
                                     facts: [Fact(symbol: "bubble.left.fill", word: "Chat"), Fact(symbol: "checkmark", word: "Approve"),
                                             Fact(symbol: "stop.fill", word: "Stop"), Fact(symbol: "eye.fill", word: "Watch")],
                                     id: "away.with"))
    }
}

/// "This needs Tailscale": a stepper of four, each with the one thing to do.
struct TailscaleSetupSteps: View {
    /// On a phone whose Mac still has Away from home off, the last step turns it on there.
    var macSwitchOff = false
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("This needs Tailscale, a free app that links your Mac and iPhone privately.")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
                .testID("away.needsTailscale")
            VStack(alignment: .leading, spacing: 0) {
                #if os(macOS)
                step(1, "Get Tailscale on this Mac") {
                    Button("Download") { openURL(TailscaleLinks.macDownload) }.testID("away.step.mac")
                }
                step(2, "Get it on your iPhone") {
                    Button(copied ? "Copied" : "Copy link") { copy(TailscaleLinks.iPhoneApp.absoluteString) }
                        .testID("away.step.phone")
                }
                #else
                step(1, "Get Tailscale on your Mac") {
                    Button(copied ? "Copied" : "Copy link") { copy(TailscaleLinks.macDownload.absoluteString) }
                        .testID("away.step.mac")
                }
                step(2, "Get it on \(DeviceWords.this)") {
                    Button("App Store") { openURL(TailscaleLinks.iPhoneApp) }.testID("away.step.phone")
                }
                #endif
                step(3, "Sign in with the same account on both") { EmptyView() }
                if macSwitchOff {
                    step(4, "On your Mac, turn on Away from home", last: true) { EmptyView() }
                } else {
                    step(4, "Come back here", detail: "Nollie checks by itself.", last: true) { EmptyView() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .testID("away.steps")
    }

    private func step<Action: View>(_ number: Int, _ title: String, detail: String? = nil, last: Bool = false,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 16) {
            // The number, and a quiet line down to the next one.
            VStack(spacing: 0) {
                Text("\(number)")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(Ink.onInk)
                    .frame(width: 44, height: 44)
                    .background(Ink.ink, in: .circle)
                if !last {
                    Rectangle().fill(Ink.line).frame(width: 2, height: 22)
                }
            }
            .accessibilityHidden(true)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail { Text(detail).foregroundStyle(Ink.text2) }
                }
                Spacer(minLength: 8)
                action().buttonStyle(.nollieGlassProminent).buttonBorderShape(.capsule).controlSize(.large)
            }
            .frame(minHeight: 44)
        }
        .accessibilityElement(children: .combine)
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        copied = true
    }
}

#if os(macOS)
/// "Enter it yourself": the Mac's Tailscale name, for when Nollie can't ask Tailscale for it.
struct AwayManualHost: View {
    var saved: String?
    var save: (String) async -> String?
    @State private var text = ""
    @State private var problem: String?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                Label("Enter it yourself", systemImage: open ? "chevron.down" : "chevron.right")
                    .font(.body.weight(.medium)).foregroundStyle(Ink.text2)
            }
            .buttonStyle(.plain)
            .testID("away.manual.open")
            if open {
                HStack(spacing: 10) {
                    TextField("Name", text: $text, prompt: Text("your-mac.tail1234.ts.net"))
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .onSubmit { submit() }
                        .inset(h: 16, v: 10)
                        .background(Ink.field, in: Capsule())
                        .testID("away.manual.field")
                    Button("Paste") { text = NSPasteboard.general.string(forType: .string) ?? text }
                        .buttonStyle(.nollieGlass)
                        .testID("away.manual.paste")
                    Button("Save") { submit() }
                        .buttonStyle(.nollieGlassProminent)
                        .testID("away.manual.save")
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                if let problem {
                    Text(problem).foregroundStyle(.red).testID("away.manual.problem")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .testID("away.manual")
        .onAppear { if text.isEmpty { text = saved ?? "" } }
    }

    private func submit() {
        let typed = text
        Task { problem = await save(typed) }
    }
}
#endif

/// One plain card when the Mac sends everything through a Tailscale exit node and Nollie's relay
/// can't carry the helpers' computers' traffic: they then get no internet. Open Tailscale only
/// opens the app; Nollie never changes it.
struct ExitNodeCard: View {
    private static var where_: String {
        #if os(macOS)
        "this Mac"
        #else
        "your Mac"
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "wifi.exclamationmark")
                    .accessibilityHidden(true)
                    .foregroundStyle(.orange)
                    .font(.title2.weight(.semibold))
                Text("Your Mac sends everything through a Tailscale exit node, so your helpers' computers can't reach the internet. Turn off the exit node in Tailscale on \(Self.where_).")
                    .foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #if os(macOS)
            Button("Open Tailscale") { NSWorkspace.shared.open(TailscaleLinks.app) }
                .buttonStyle(.nollieGlassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .padding(.leading, 40)
                .testID("exitNode.open")
            #endif
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.warnFill, in: .rect(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .contain)
        .testID("exitNode.card")
    }
}

/// The away card: something that needs the Mac live was tapped while the phone can't reach it.
struct AwayCardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var steps = false

    private var link: LinkedMac? { model.runtime?.connection.linkedMac }
    /// The Mac was ready: Tailscale may be off on a device, or the Mac asleep.
    private var macReady: Bool { link?.awayReady == true }

    var body: some View {
        FittedSheet {
            VStack(spacing: 18) {
                if steps {
                    TailscaleSetupSteps(macSwitchOff: link?.away != true)
                    Button { dismiss() } label: { Text("Done").fullWidthLabel() }
                        .buttonStyle(.nollieGlassProminent)
                        .testID("awayCard.done")
                } else {
                    Image(systemName: macReady ? "moon.zzz.fill" : "airplane")
                        .font(.system(size: 56, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(macReady ? "Your Mac isn't answering." : "You're away from home.")
                        .font(.title2.weight(.bold)).multilineTextAlignment(.center)
                        .testID("awayCard.title")
                    Text(macReady ? "Check that your Mac is awake, and that Tailscale is on, on both."
                                  : "This needs Tailscale to reach your Mac.")
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .testID("awayCard.message")
                    VStack(spacing: 10) {
                        Button { withAnimation(.snappy) { steps = true } } label: {
                            Text("Set up").fullWidthLabel()
                        }
                        .buttonStyle(.nollieGlassProminent)
                        .testID("awayCard.setUp")
                        Button("Not now") { dismiss() }
                            .small(.subheadline, .secondary)
                            .testID("awayCard.notNow")
                    }
                    .padding(.top, 6)
                }
            }
            .sheetColumn()
        }
        .accessibilityElement(children: .contain)
        .testID("awayCard")
    }
}

/// A quiet line at the top of the bots list on a linked phone: how it reaches the Mac now.
struct LinkReachLine: View {
    var reach: NollieLinkReach
    var alertsOn: Bool
    var onAway: () -> Void = {}

    static func text(_ reach: NollieLinkReach, alertsOn: Bool) -> String {
        switch reach {
        case .home: "At home"
        case .tailnet: "Connected through Tailscale"
        case .away: alertsOn ? "Away · alerts only" : "Away from home"
        }
    }

    private var symbol: String {
        switch reach {
        case .home: "house.fill"
        case .tailnet: "point.3.connected.trianglepath.dotted"
        case .away: "moon.zzz.fill"
        }
    }

    var body: some View {
        let label = Label(Self.text(reach, alertsOn: alertsOn), systemImage: symbol)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .inset(h: 12, v: 4)
        Group {
            if reach == .away {
                Button(action: onAway) { label }.buttonStyle(.plain)
            } else {
                label
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.text(reach, alertsOn: alertsOn))
        .testID("link.reach")
    }
}
