import AppKit
import NollieCore
import SwiftUI

/// One line of a menu, described as data so the three menus below read as tables.
private struct MenuLine: Identifiable {
    enum Kind { case action, separator }

    let id: Int
    var kind = Kind.action
    var title = ""
    var key: KeyEquivalent?
    var modifiers: EventModifiers = .command
    var enabled = true
    var run: () -> Void = {}
}

/// Builds the lines of a menu in order, numbering them as they are added.
private struct MenuSheet {
    private(set) var lines: [MenuLine] = []

    mutating func add(_ title: LocalizedStringResource, _ key: KeyEquivalent? = nil, _ modifiers: EventModifiers = .command,
                      enabled: Bool = true, run: @escaping () -> Void) {
        add(verbatim: String(localized: title), key, modifiers, enabled: enabled, run: run)
    }

    /// For a title that is already in the person's language.
    fileprivate mutating func add(verbatim title: String, _ key: KeyEquivalent? = nil, _ modifiers: EventModifiers = .command,
                      enabled: Bool = true, run: @escaping () -> Void) {
        lines.append(MenuLine(id: lines.count, title: title, key: key, modifiers: modifiers, enabled: enabled, run: run))
    }

    mutating func gap() {
        lines.append(MenuLine(id: lines.count, kind: .separator))
    }
}

private struct MenuLines: View {
    let lines: [MenuLine]

    var body: some View {
        ForEach(lines) { line in
            switch line.kind {
            case .separator: Divider()
            case .action: item(line)
            }
        }
    }

    @ViewBuilder private func item(_ line: MenuLine) -> some View {
        let button = Button(line.title, action: line.run).disabled(!line.enabled)
        if let key = line.key {
            button.keyboardShortcut(key, modifiers: line.modifiers)
        } else {
            button
        }
    }
}

/// What the menus need to know about the window right now.
@MainActor
private struct MenuContext {
    let model: AppModel

    var noGateway: Bool { model.runtime == nil }
    var boardShowing: Bool { model.selectedTab == .kanban }
    var boardReady: Bool { model.runtime?.kanban.isPresent == true }
    var approval: PendingCard? { model.visibleChat?.cards.first { $0.method == "approval" } }
    var lastReply: String? {
        model.visibleChat.flatMap { AutomatedReply.lastReply(in: $0.items) }
    }

    func go(_ tab: AppModel.AppTab) { model.selectedTab = tab }

    func answerApproval(_ choice: String) {
        guard let chat = model.visibleChat, let card = approval else { return }
        let reply: JSONValue = ["choice": .string(choice)]
        Task { await chat.respond(card: card, result: reply) }
    }

    func step(_ direction: Int) {
        go(.chats)
        model.chatStepRequest = .init(direction: direction)
    }
}

/// Settings is a page of the window, so the app keeps one state, not two windows.
struct MacSettingsCommand: Commands {
    let model: AppModel

    private var sheet: MenuSheet {
        var sheet = MenuSheet()
        sheet.add("Settings…", ",") { model.selectedTab = .settings }
        return sheet
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) { MenuLines(lines: sheet.lines) }
    }
}

struct MacChatCommands: Commands {
    let model: AppModel

    private var sheet: MenuSheet {
        let here = MenuContext(model: model)
        var sheet = MenuSheet()
        // On the Board, Command-N creates a task instead.
        sheet.add("New Bot…", "n", enabled: !here.noGateway && !here.boardShowing) {
            here.go(.chats)
            model.newBotRequest = UUID()
        }
        sheet.add("History", "y", enabled: model.frontBot != nil) {
            guard let bot = model.frontBot else { return }
            model.openBotPage(.history, profile: bot, chatID: model.visibleChat?.storedID)
        }
        sheet.add("Board", "b", enabled: !model.hiddenTabs.contains(.kanban) && !here.noGateway) { here.go(.kanban) }
        sheet.gap()
        sheet.add("Next Bot", .downArrow, [.command, .option], enabled: !here.noGateway) { here.step(1) }
        sheet.add("Previous Bot", .upArrow, [.command, .option], enabled: !here.noGateway) { here.step(-1) }
        sheet.add("Search", "f", enabled: !here.noGateway) {
            here.go(.chats)
            model.focusSearchRequest = UUID()
        }
        sheet.gap()
        // Stop the open chat's turn, or answer the approval it is waiting on.
        sheet.add(LocalizedStringResource("Stop", comment: "Safety: menu command that stops the open chat's turn"), ".", enabled: model.visibleChat?.isRunning == true) {
            guard let chat = model.visibleChat else { return }
            Task { await chat.stop() }
        }
        sheet.add(LocalizedStringResource("Approve Once", comment: "Safety: menu command; allows the waiting approval this one time"), "y", [.command, .shift], enabled: here.approval != nil) { here.answerApproval("once") }
        sheet.add(LocalizedStringResource("Deny", comment: "Safety: menu command; refuses the waiting approval"), "d", [.command, .shift], enabled: here.approval != nil) { here.answerApproval("deny") }
        sheet.gap()
        // The newest reply as markdown; the keyboard and VoiceOver reach the hover Copy button this way.
        sheet.add("Copy Last Reply", "c", [.command, .shift], enabled: here.lastReply != nil) {
            guard let reply = here.lastReply else { return }
            UIPasteboard.general.string = TranscriptMedia.copyText(reply)
        }
        return sheet
    }

    var body: some Commands {
        CommandMenu("Chat") { MenuLines(lines: sheet.lines) }
    }
}

/// The everyday places. Administration stays under Settings, Advanced.
struct MacGoCommands: Commands {
    let model: AppModel

    private var sheet: MenuSheet {
        var sheet = MenuSheet()
        for (place, tab) in MacPages.order.enumerated() {
            // Only the first nine pages get a number key.
            let digit = place < 9 ? KeyEquivalent(Character(String(place + 1))) : nil
            sheet.add(.verbatim(MacPages.title(tab)), digit, enabled: !model.hiddenTabs.contains(tab)) { model.selectedTab = tab }
        }
        return sheet
    }

    var body: some Commands {
        CommandMenu("Go") { MenuLines(lines: sheet.lines) }
    }
}

/// These do nothing unless the Board page is showing.
struct MacBoardCommands: Commands {
    let model: AppModel
    let requests: BoardCommands

    private var sheet: MenuSheet {
        let here = MenuContext(model: model)
        let live = here.boardShowing && here.boardReady
        var sheet = MenuSheet()
        sheet.add("New Task", "n", enabled: live) { requests.newTaskRequest = UUID() }
        sheet.add("Open Card", .return, enabled: here.boardShowing && requests.selectedID != nil) {
            requests.openRequest = UUID()
        }
        sheet.gap()
        sheet.add("Check for tasks", enabled: live) { Task { await model.runtime?.kanban.nudge() } }
        sheet.add("Refresh Board", "r", enabled: live) { Task { await model.runtime?.kanban.refresh() } }
        return sheet
    }

    var body: some Commands {
        CommandMenu("Board") { MenuLines(lines: sheet.lines) }
    }
}
