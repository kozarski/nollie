#if DEBUG
import NollieCore
import SwiftUI

/// Launch flags for the demo copy, used to take pictures of the Mac window. Each one waits for the
/// bots to arrive, then sets the app up the way the flag asks:
///
///     -nollie-demo-remove review|working|finished   opens the Remove sheet
///     -nollie-demo-tab settings                      opens Settings (with -nollie-demo-settings <page>)
///     -nollie-demo-mac-tab kanban|cron|settings      opens that page
///     -nollie-demo-window <width>x<height>           sizes the window
///     -nollie-demo-bot-page <kind>                   opens one of a bot's pages
///     -nollie-demo-bot-profile <name>                which bot that page is for
///     -nollie-demo-say <words>                       sends those words in a new chat
///     -nollie-demo-app-menu                          shows the app menu open after 45 seconds, for a picture of it
///
/// (`-nollie-demo-sidebar`, which hides the sidebar, lives in the split view.)
struct MacDemoLaunch: ViewModifier {
    @Environment(AppModel.self) private var model
    let touring: Bool

    @State private var removeSheet: AboutView.DemoStart?

    private static let arguments = ProcessInfo.processInfo.arguments

    private static func value(after flag: String) -> String? {
        guard let at = arguments.firstIndex(of: flag), arguments.indices.contains(at + 1) else { return nil }
        return arguments[at + 1]
    }

    private func waitForBots(polls: Int) async {
        var left = polls
        while left > 0, model.runtime?.profiles.isEmpty ?? true {
            try? await Task.sleep(for: .milliseconds(500))
            left -= 1
        }
    }

    func body(content: Content) -> some View {
        content
            .task { if AppModel.forceSignIn, let active = model.store.active { model.signInPrompt = [active] } }
            .task { await showRemoveSheet() }
            .sheet(item: $removeSheet) { RemoveNollieSheet(demoStart: $0.value).withAppModel() }
            .task { await holdSettingsTab() }
            .task { await openPageAndSizeWindow() }
            .task { await openBotPage() }
            .task { await sayForDemo() }
            .onAppear { showAppMenu() }
    }

    /// `-nollie-demo-say <words-with-dashes>`: once the bots are in, a new chat with the default bot
    /// sends those words, as on the iPhone, for pictures of a turn (an approval, a card).
    private func sayForDemo() async {
        guard DemoMode.isOn, let words = Self.value(after: "-nollie-demo-say") else { return }
        await waitForBots(polls: 60)
        try? await Task.sleep(for: .seconds(2))
        model.demoFirstMessage = words.replacingOccurrences(of: "-", with: " ")
        model.sideChatRequestedAt = Date()
        model.newChatRequest = UUID()
    }

    /// Pops the app menu (the one named for the app) open over the window and leaves it there. A timer, not
    /// a task: a task can be cancelled early, and an open menu holds the run loop in tracking mode, which
    /// stalls the updater's first check, so it waits for that.
    private func showAppMenu() {
        guard DemoMode.isOn, Self.arguments.contains("-nollie-demo-app-menu") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  let menu = NSApp.mainMenu?.item(at: 0)?.submenu, let view = window.contentView else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 24, y: view.bounds.height - 24), in: view)
        }
    }

    private func showRemoveSheet() async {
        guard DemoMode.isOn, let which = Self.value(after: "-nollie-demo-remove") else { return }
        try? await Task.sleep(for: .seconds(3))
        removeSheet = .init(value: which == "review" ? nil : which)
    }

    // The first bot's chat can take the window back once it opens, so keep choosing Settings for a while.
    private func holdSettingsTab() async {
        guard DemoMode.isOn, let name = Self.value(after: "-nollie-demo-tab"),
              let tab = AppModel.AppTab(rawValue: name), tab == .settings else { return }
        await waitForBots(polls: 120)
        for _ in 0..<40 {
            if model.selectedTab != tab { model.selectedTab = tab }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func openPageAndSizeWindow() async {
        guard DemoMode.isOn, !touring else { return }
        await waitForBots(polls: 60)
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }

        if let tab = Self.value(after: "-nollie-demo-mac-tab").flatMap(AppModel.AppTab.init(rawValue:)) {
            model.selectedTab = tab
        }
        let wanted = (Self.value(after: "-nollie-demo-window") ?? "").split(separator: "x").compactMap { Double($0) }
        guard wanted.count == 2 else { return }
        // Keep the top edge where it is, as the origin is the bottom-left.
        var frame = window.frame
        frame.origin.y += frame.height - wanted[1]
        frame.size = CGSize(width: wanted[0], height: wanted[1])
        window.setFrame(frame, display: true)
    }

    private func openBotPage() async {
        guard DemoMode.isOn, let name = Self.value(after: "-nollie-demo-bot-page"),
              let kind = BotSheet.Kind(rawValue: name) else { return }
        try? await Task.sleep(for: .seconds(5))
        let chosen = Self.value(after: "-nollie-demo-bot-profile")
        if let profile = chosen ?? model.runtime?.defaultProfile ?? model.runtime?.profiles.first?.name {
            model.openBotPage(kind, profile: profile)
        }
    }
}
#endif
