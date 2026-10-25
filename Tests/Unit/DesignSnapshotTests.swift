import Foundation
import SwiftUI
import UserNotifications
import Testing
@testable import Nollie
@testable import NollieCore

/// Pictures of the redesign's parts, drawn off screen and attached to the test run: the bot rows
/// (idle, working, unread, private), the approval card and the working line, light and dark. They
/// can be looked at without a simulator screen to take them from.
@MainActor @Suite struct DesignSnapshotTests {
    @Test func notificationPermissionPrompts() {
        for (name, status) in [("allow", UNAuthorizationStatus.notDetermined), ("settings", .denied), ("allowed", .authorized)] {
            attach(CompanionPromptSheet(found: "1.0.40", authorization: status,
                                       install: {}, allow: {}, later: {}).card.padding(.top, 40),
                   named: "notifications-\(name)", width: 390)
        }
    }

    /// Fixed setup choices only. These pictures do not connect, install or request permissions.
    @Test func onboardingFixtures() {
        for step in [OnboardingProgress.Step.welcome, .home, .team] {
            var progress = OnboardingProgress()
            progress.step = step
            if step == .team { progress.route = .new }
            let screen = OnboardingView(fixtureProgress: progress)
            attach(screen, named: "onboarding-fixture-\(step.rawValue)", width: 390)
        }
        var largeText = OnboardingProgress()
        largeText.step = .home
        attach(OnboardingView(fixtureProgress: largeText)
            .dynamicTypeSize(.accessibility3),
            named: "onboarding-fixture-home-large-text", width: 390)
    }

    private func runtime() throws -> GatewayRuntime {
        let conn = GatewayConnection(name: "Snapshots", gateway: try GatewayURL.normalize("http://127.0.0.1:9", pathPrefix: nil), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        rt.profiles = [
            ProfileInfo(name: "default", displayName: "Nollie", isDefault: true),
            ProfileInfo(name: "career"),
            ProfileInfo(name: "nowhere"),
            ProfileInfo(name: "forager"),
            ProfileInfo(name: "private", description: "Moss, the private bee"),
        ]
        return rt
    }

    /// Settings for the pictures: glass off, because ImageRenderer can't draw Liquid Glass (it
    /// stops on a layout precondition). The pictures show the solid fallback; the UI tests show glass.
    private static let snapshotDefaults: UserDefaults = {
        let d = UserDefaults(suiteName: "nollie.design-snapshots")!
        d.set(false, forKey: GlassAppearance.enabledKey)
        return d
    }()

    private func attach(_ view: some View, named name: String, width: CGFloat) {
        for scheme in [ColorScheme.light, .dark] {
            let r = ImageRenderer(content: view
                .frame(width: width)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme)
                .defaultAppStorage(Self.snapshotDefaults)
                .environment(AppModel.shared))
            r.scale = 3
            guard let image = r.uiImage, let data = image.pngData() else { Issue.record("no picture for \(name)"); continue }
            Attachment.record(data, named: "\(name)-\(scheme == .dark ? "dark" : "light").png")
        }
    }

    #if os(macOS)
    /// Nollie Link on the Mac: the code with a linked device below it, and the confirmation
    /// after a phone has used it. The code is inert.
    @Test func theNollieLinkSheet() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let device = NollieLinkIPCDevice(id: UUID(), name: "Corey's iPhone", linkedAt: now.addingTimeInterval(-86_400),
                                         lastActive: now.addingTimeInterval(-300))
        attach(NollieLinkPanel(state: .code("Nollie Link preview. This code cannot connect."), devices: [device], now: now)
            .padding(28), named: "nollie-link-mac-code", width: 480)
        attach(NollieLinkPanel(linkedName: "Corey's iPhone", state: .linked, devices: [device], now: now)
            .padding(28), named: "nollie-link-mac-linked", width: 480)
        attach(NollieLinkPanel(state: .hidden, devices: [], now: now).padding(28), named: "nollie-link-mac-hidden", width: 480)
    }
    #endif

    #if os(macOS)
    /// Away from home on the Mac: off, on and needing Tailscale (with the exit node card), and ready.
    @Test func theAwayFromHomePage() {
        attach(AwayFromHomePage(hero: .home, facts: AwayFacts(on: false, tailscale: "missing")),
               named: "away-mac-off", width: 760)
        attach(AwayFromHomePage(hero: .needsTailscale, facts: AwayFacts(on: true, tailscale: "missing", exitNode: true)),
               named: "away-mac-needs-setup", width: 760)
        attach(AwayFromHomePage(hero: .anywhere, facts: AwayFacts(on: true, tailscale: "ready")),
               named: "away-mac-ready", width: 760)
    }
    #endif

    @Test func theBotRows() throws {
        let rt = try runtime()
        let now = Date()
        let p = rt.profiles
        let rows = VStack(spacing: 2) {
            BotListRow(runtime: rt, profile: p[0], entry: .init(storedID: "a", lastText: "Done. Amazon's closed and Nowhere leads.", lastDate: now), selected: true)
            BotListRow(runtime: rt, profile: p[1], entry: .init(storedID: "b", lastText: "Typing", lastDate: now.addingTimeInterval(-180), busy: true))
            BotListRow(runtime: rt, profile: p[2], entry: .init(storedID: "c", lastText: "Build 73 needs a diagnostic export.", lastDate: now.addingTimeInterval(-86_400)), unread: true)
            BotListRow(runtime: rt, profile: p[3], entry: .init(storedID: "d", lastText: "Found 3 London iOS meetups this month.", lastDate: now.addingTimeInterval(-3 * 86_400)))
            BotListRow(runtime: rt, profile: p[4], entry: .init(storedID: "e", lastText: "never shown", lastDate: now.addingTimeInterval(-3 * 86_400)))
        }
        .padding(8)
        .background(Ink.sidebar)
        attach(rows, named: "rows", width: 390)
        let tiles = HStack(spacing: 0) {
            BotTile(runtime: rt, profile: p[0], entry: .init(storedID: "a"), star: true).frame(maxWidth: .infinity)
            BotTile(runtime: rt, profile: p[1], entry: .init(storedID: "b", busy: true)).frame(maxWidth: .infinity)
            BotTile(runtime: rt, profile: p[3], entry: .init(storedID: "d"), unread: true).frame(maxWidth: .infinity)
        }
        .padding(8)
        .background(Ink.canvas)
        attach(tiles, named: "tiles", width: 390)
    }

    @Test func theApprovalCardAndTheWorkingLine() {
        let a = ApprovalRequest(requestId: "r", sessionId: "s",
                                command: "python3 - <<'E'  p='wiki/private/health-notes.md'  s=open(p).read() and a good deal more after it",
                                description: "Edit a private page in your vault: health-notes.md.",
                                choices: ["once", "session", "always", "deny"], patternKey: "python3")
        let card = VStack(alignment: .leading, spacing: 12) {
            ApprovalCardView(approval: a, count: 1, botName: "Nollie", profile: "default") { _ in }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Ink.card, in: .rect(cornerRadius: 18, style: .continuous))
            WorkingLine(profile: "default", text: "Checking the board")
            Text("Board triage is ready. 16 cards need one answer from you.")
                .font(Ink.message).lineSpacing(Ink.lineSpacing).foregroundStyle(Ink.text)
                .padding(.horizontal, Ink.bubblePadH).padding(.vertical, Ink.bubblePadV)
                .background(Ink.bubble, in: .rect(cornerRadius: Ink.bubbleRadius, style: .continuous))
            HStack {
                Spacer()
                Text("60k floor. Drop Amazon. Nowhere leads.")
                    .font(Ink.message).foregroundStyle(Ink.onInk)
                    .padding(.horizontal, Ink.bubblePadH).padding(.vertical, Ink.bubblePadV)
                    .background(Ink.ink, in: .rect(cornerRadius: Ink.bubbleRadius, style: .continuous))
            }
        }
        .padding(16)
        attach(card, named: "card", width: 390)
    }

    /// The night shift card (one run opened), the rehearsal card waiting, turned on, failed and as a check, and the
    /// picture the Share button makes, with its personal parts blurred.
    @Test func theNightShiftCards() throws {
        let night = try #require(nightShiftSample().nightShift)
        attach(NightShiftCard(card: night, expanded: ["cron:244c3b0b8e42:e-80"]) { _ in }.padding(16),
               named: "night-shift-card", width: 390)
        attach(NightShiftCard(card: .init(counts: .init()), expanded: []) { _ in }.padding(16),
               named: "night-shift-quiet", width: 390)
        attach(NightShiftCard(card: night, expanded: []) { _ in }.padding(16)
            .environment(\.nightSkySolid, true), named: "night-shift-solid", width: 390)
        let held = ConversationPost.NightShift(counts: .init(runs: 1, actions: 1, held: 1), runs: [
            .init(id: "held-note", bot: "default", botName: "Nollie", title: "Morning note", outcome: .done,
                  actions: [.init(tool: "send_message", target: "Send with mail: send email to sam@example.com",
                                  status: .blocked, receipt: .init(kind: .held, detail: "ask_first"))])
        ])
        attach(NightShiftCard(card: held, expanded: []) { _ in }.padding(16)
            .dynamicTypeSize(.accessibility3), named: "night-shift-held-large-text", width: 390)
        let cards = VStack(spacing: 14) {
            ConversationPostView(post: rehearsalSample(), expanded: []) { _ in }
            ConversationPostView(post: rehearsalSample(state: .on), expanded: []) { _ in }
            ConversationPostView(post: rehearsalSample(pending: .turnOn, problem: "That didn't go through. Try again in a moment."),
                                 expanded: []) { _ in }
            ConversationPostView(post: rehearsalSample(check: .init(reason: .script, prompt: "Tidy the downloads folder",
                                                                   script: "~/bin/tidy.sh", hash: "3f2a9c01be44")),
                                 expanded: []) { _ in }
        }
        .padding(16)
        attach(cards, named: "rehearsal-cards", width: 390)
        attach(NightShiftShareView(model: NightShiftShareModel(night)), named: "night-shift-share", width: NightShiftShareView.width)
        attach(NightShiftShareView(model: NightShiftShareModel(held))
            .environment(\.nightSkySolid, true),
            named: "night-shift-share-solid", width: NightShiftShareView.width)
    }

    /// System control's two cards: a screen action asking whether the bot may use this Mac, and
    /// the one after a turn that stopped because it was off.
    @Test func theSystemControlCards() {
        let a = ApprovalRequest(requestId: "r", sessionId: "s",
                                command: "computer_use: click at (489, 65)",
                                description: "Allow computer_use to perform `click`?",
                                choices: ["once", "session", "always", "deny"], toolName: "computer_use", patternKey: "cua:click:foreground")
        let cards = VStack(alignment: .leading, spacing: 12) {
            ApprovalCardView(approval: a, count: 1, botName: "Nollie", profile: "default", onChoice: { _ in }, onSystemControl: { _ in })
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Ink.card, in: .rect(cornerRadius: 18, style: .continuous))
            SystemControlAskCard(botName: "Nollie", onTurnOn: {}, onDismiss: {})
        }
        .padding(16)
        attach(cards, named: "system-control", width: 390)
    }

    /// Ask first holding an action: an email with everything in it, and a click with its
    /// "you're about to…" line on its own.
    @Test func theAskFirstCards() {
        func card(_ words: String, tool: String) -> some View {
            let a = ApprovalRequest(requestId: "r", sessionId: "s", command: "<\(tool)> (plugin approval rule)", description: words,
                                    choices: ["once", "session", "always", "deny"], toolName: tool,
                                    patternKey: "plugin_rule:nollie-ask-first:send:0123456789abcdef0123456789abcdef")
            return ApprovalCardView(approval: a, count: 1, botName: "Scout", profile: "career", onChoice: { _ in })
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Ink.card, in: .rect(cornerRadius: 18, style: .continuous))
                .padding(16)
        }
        attach(card("Send with gmail: send email\nto: sam@example.com\nsubject: Lunch on Friday\nbody: Are you free at noon?",
                    tool: "mcp__gmail__send_email"), named: "ask-first-send", width: 390)
        attach(card("Press “Send” on its computer.\nYou're about to press “Send”.",
                    tool: "computer_use"), named: "ask-first-check", width: 390)
    }
}
