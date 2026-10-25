import AppKit
import NollieCore
import SwiftUI

@main
struct NollieMacApp: App {
    @AppStorage("colorSchemePreference") private var scheme = "system"
    @State private var boardRequests = BoardCommands.shared
    @State private var board = TurnBoard.shared
    @State private var model: AppModel
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate

    init() {
        MacLaunch.prepare()
        _model = State(initialValue: AppModel.shared)
    }

    var body: some Scene {
        // A single window is enough: there is one gateway, one selection and one open chat. Once
        // closed, the menu bar item carries on, and the Dock icon, Window menu or menu bar item reopen it.
        Window("Nollie", id: MacWindow.main) {
            // Debug: `-nollie-demo-new-chat <rows>` opens the new conversation screen instead.
            ConversationDemoGate { MacRootView() }
                .botWindowLiveness(needsKey: true)
                .environment(model)
                .notificationPreviewPolicy()
                .onOpenURL { model.open($0) }
                .continuesHandoff(model)
                .modifier(MacLifecycle(model: model, scheme: scheme))
        }
        .windowStyle(.plain)
        .defaultSize(width: 980, height: 700)
        .commands {
            MacSettingsCommand(model: model)
            #if NOLLIE_DIRECT
            MacUpdateCommands()
            #endif
            ImportFromDevicesCommands()
            SidebarCommands()
            MacChatCommands(model: model)
            MacGoCommands(model: model)
            MacBoardCommands(model: model, requests: boardRequests)
        }

        // Turns in flight and approvals waiting. The Dock icon carries a badge for the ones that need the person.
        MenuBarExtra {
            TurnMenu().environment(model).botWindowLiveness(needsKey: false)
        } label: {
            Image(nsImage: MenuBarIcon.image(board.menuBarBadge))
        }
        .menuBarExtraStyle(.window)
    }
}

enum MacWindow {
    static let main = "main"

    /// Shows the main window. When it has never been created, activate the app and let the scene restore it.
    @MainActor static func bringMainForward() {
        if let open = openMain { open() }
        NSApp.activate()
    }

    /// Opens the main window from code outside a view, such as an App Intent. The window's own open
    /// action is kept here once the root view appears, so it is nil only if the window has never shown.
    @MainActor static var openMain: Opener?

    typealias Opener = () -> Void
}
