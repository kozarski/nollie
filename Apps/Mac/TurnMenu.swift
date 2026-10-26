import AppKit
import NollieCore
import SwiftUI

/// Small bordered buttons, the weight every button in this menu has.
private struct MenuButtonLook: ViewModifier {
    var prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).controlSize(.small)
        } else {
            content.buttonStyle(.bordered).controlSize(.small)
        }
    }
}

private extension Text {
    /// A name at the head of a menu row.
    func menuHeading() -> Text {
        font(.subheadline.weight(.semibold))
    }
}

/// A caption-sized text link, as "Open Nollie" and "Open" are.
private struct LinkLook: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.plain).font(.caption)
    }
}

/// Where a turn's row takes you: a chat, named with its own bot so it opens under that bot
/// whichever one is selected.
enum TurnLink {
    static func chatURL(storedID: String, owner: String?) -> URL? {
        var parts = URLComponents()
        parts.scheme = "nollie"
        parts.host = "chat"
        parts.path = "/" + storedID
        if let owner, !owner.isEmpty {
            parts.queryItems = [URLQueryItem(name: "profile", value: owner)]
        }
        return parts.url
    }
}

/// The menu bar item's dropdown. One row per turn in flight, with approval buttons where one is
/// pending, then the bots allowed to use this Mac, each with a way to switch them off.
struct TurnMenu: View {
    @State private var board = TurnBoard.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var model

    private var control: SystemControl { .shared }

    var body: some View {
        let allowed = (model.runtime?.profiles ?? []).filter { control.isOn($0.name, model.runtime) }
        VStack(alignment: .leading, spacing: 0) {
            if board.turns.isEmpty {
                IdleHeader(gateway: model.runtime.map { "\($0.connection.name) · \($0.socketState.label)" })
            }
            ForEach(board.turns) { turn in
                TurnRow(turn: turn, open: open, switchOff: switchOff)
                if turn.id != board.turns.last?.id { Divider().inset(h: 12) }
            }
            if !allowed.isEmpty { Divider() }
            ForEach(allowed) { bot in
                MacAccessRow(bot: bot, busy: control.isBusy(bot.name, model.runtime)) { switchOff(bot.name, model.runtime) }
            }
            Divider()
            MenuFooter(attention: board.attention, running: board.running) { open(nil) }
        }
        .frame(width: 320)
    }

    /// Turns system control off for a bot. Its next screen action is refused and one in progress stops.
    private func switchOff(_ profile: String, _ runtime: GatewayRuntime?) {
        guard let runtime else { return }
        Task { await control.set(false, profile: profile, rt: runtime) }
    }

    /// Brings the app forward, onto a chat when one is given.
    private func open(_ storedID: String?) {
        // The window may be closed while the app keeps living in the menu bar.
        NSApp.activate()
        openWindow(id: MacWindow.main)
        guard let storedID else { return }
        let owner = board.turns.first { $0.id == storedID }?.profile
        if let link = TurnLink.chatURL(storedID: storedID, owner: owner) { model.open(link) }
    }
}

private struct IdleHeader: View {
    var gateway: String?

    var body: some View {
        HStack(spacing: 10) {
            CharacterView(look: .main, size: 28, seed: CharacterLookID.seed("nollie-menubar"))
            VStack(alignment: .leading, spacing: 1) {
                Text("Nothing running").menuHeading()
                Text(gateway ?? "No gateway").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

private struct MacAccessRow: View {
    var bot: ProfileInfo
    var busy: Bool
    var turnOff: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.rays").foregroundStyle(Color.secondary)
            Text("\(bot.shownName) can use this Mac").lineLimit(1).font(.caption)
            Spacer(minLength: 6)
            Button("Turn off", action: turnOff)
                .modifier(MenuButtonLook(prominent: false))
                .disabled(busy)
                .help("System control off: \(bot.shownName) stops using your Mac at once")
        }
        .inset(h: 12, v: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menubar.systemControl." + bot.name)
    }
}

private struct MenuFooter: View {
    var attention: Int
    var running: Int
    var openApp: () -> Void

    private var summary: String {
        guard attention > 0 else { return "\(running) working" }
        return "\(attention) need\(attention == 1 ? "s" : "") you"
    }

    var body: some View {
        HStack {
            Button("Open Nollie", action: openApp).modifier(LinkLook())
            Spacer()
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
        .inset(h: 12, v: 8)
    }
}

/// One button in a row: its words, its weight, and what it does.
private struct RowChoice: Identifiable {
    let title: String
    var prominent = false
    var identifier: String?
    var help: String?
    let run: () -> Void

    var id: String { title }
}

private struct TurnRow: View {
    let turn: TurnBoard.Turn
    let open: (String?) -> Void
    let switchOff: (String, GatewayRuntime?) -> Void

    private var control: SystemControl { .shared }

    /// The approval this row waits on, and the chat to answer it in.
    private var waiting: (chat: ChatSession, card: PendingCard, approval: ApprovalRequest)? {
        guard turn.attention, let chat = turn.chat, let card = chat.firstCard, let approval = card.approval else { return nil }
        return (chat, card, approval)
    }

    private var mustOpenCard: Bool {
        guard let approval = waiting?.approval else { return false }
        return TurnBoard.answersInApp(approval)
    }

    /// Needs-you while it waits. Otherwise what the chat is doing, and working until it says.
    private var avatarState: CharacterState {
        if turn.attention { return .needsYou }
        let own = turn.chat?.botState ?? .idle
        return own == .idle ? .working : own
    }

    /// A turn that is waiting says what it needs. One that is working shows the on-device model's
    /// summary of its goal, or its current step in everyday words.
    private var progress: (words: String, tint: Color) {
        if turn.attention { return (turn.detail, .orange) }
        return (ChatGoals.shared.goal(for: turn.id) ?? BotActivity.humanize(turn.detail), .secondary)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BotAvatar(profile: turn.profile, size: 30, state: avatarState)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(turn.bot).menuHeading().lineLimit(1)
                    if turn.attention { Circle().fill(.yellow).frame(square: 7) }
                    Spacer(minLength: 0)
                    Text(turn.startedAt, style: .timer).foregroundStyle(.secondary).font(.caption2.monospacedDigit())
                }
                Text(turn.title).font(.caption).lineLimit(1)
                Text(progress.words).font(.caption).foregroundStyle(progress.tint).lineLimit(2)
                HStack(spacing: 8) {
                    ForEach(choices) { choice in
                        choiceButton(choice)
                    }
                    if !mustOpenCard {
                        Button(turn.attention ? "Answer in Nollie" : "Open") { open(turn.id) }
                            .modifier(LinkLook())
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
    }

    @ViewBuilder private func choiceButton(_ choice: RowChoice) -> some View {
        let button = Button(choice.title, action: choice.run)
            .modifier(MenuButtonLook(prominent: choice.prominent))
        switch (choice.identifier, choice.help) {
        case let (id?, help?): button.help(help).accessibilityIdentifier(id)
        case let (id?, nil): button.accessibilityIdentifier(id)
        case let (nil, help?): button.help(help)
        case (nil, nil): button
        }
    }

    // MARK: Buttons

    private var choices: [RowChoice] {
        if let waiting { return approvalChoices(waiting.chat, waiting.card, waiting.approval) }
        let usingMac = !turn.attention && turn.detail.contains("computer_use") && control.isOn(turn.profile, turn.chat?.runtime)
        guard usingMac else { return [] }
        return [RowChoice(title: "Stop", identifier: "menubar.stopUsingMac",
                          help: "System control off: it stops using your Mac at once") { switchOff(turn.profile, turn.chat?.runtime) }]
    }

    private func approvalChoices(_ chat: ChatSession, _ card: PendingCard, _ approval: ApprovalRequest) -> [RowChoice] {
        func reply(_ choice: String) -> () -> Void {
            let answer: JSONValue = ["choice": .string(choice)]
            return { Task { await chat.respond(card: card, result: answer) } }
        }
        let deny = RowChoice(title: "Deny", run: reply("deny"))

        if SystemControl.isScreen(approval) {
            // The question is whether the bot may use this Mac at all.
            return [RowChoice(title: "Allow system control", prominent: true) { SystemControl.answer(true, card: card, chat: chat) },
                    RowChoice(title: "Keep it off") { SystemControl.answer(false, card: card, chat: chat) }]
        }
        if mustOpenCard {
            // Ask first and sign-ins are allowed only on the full card (read the whole action, or
            // Touch ID). Saying no is fine from here.
            return [RowChoice(title: "Answer in Nollie", prominent: true, identifier: "menubar.answerInNollie") { open(turn.id) }, deny]
        }
        return [RowChoice(title: "Approve once", prominent: true, run: reply("once")), deny]
    }
}
