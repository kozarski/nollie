#if os(macOS)
import AppKit
import SwiftUI

/// The windows Nollie Computer shows on the Mac: the approval and confirmation cards (floating,
/// in front of everything, so the person sees them wherever they are), the Stop panel on every
/// Space, and the permission walkthrough.
@MainActor
final class ComputerPanels: ComputerPresenting {
    static let shared = ComputerPanels()

    private let center: ComputerCenter
    private var card: NSPanel?
    private var stopPanel: NSPanel?
    private var permissionsWindow: NSWindow?

    init(center: ComputerCenter = .shared) { self.center = center }

    func showApproval() {
        guard let approval = center.approval else { return }
        present(ComputerApprovalCard(approval: approval) { [weak center] allowed in
            if allowed { Task { await center?.allowWithOwner() } } else { center?.answerApproval(false) }
        })
    }

    func showConfirmation() {
        guard let confirmation = center.confirmation else { return }
        let id = confirmation.id
        present(ComputerConfirmationCard(confirmation: confirmation,
                                         answer: { [weak center] allowed in
                                             if allowed { Task { await center?.allowOnceWithOwner(id: id) } } else { center?.answerConfirmation(false, id: id) }
                                         },
                                         stop: { [weak center] in center?.stop() }))
    }

    func hideCards() {
        card?.orderOut(nil)
        card = nil
    }

    func showStop() {
        guard let task = center.task else { return }
        let panel = stopPanel ?? Self.panel(level: .statusBar, key: false)
        panel.contentView = NSHostingView(rootView: StopPanelHost(center: center, fallback: task))
        panel.setContentSize(panel.contentView!.fittingSize)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - 8))
        }
        panel.orderFrontRegardless()
        stopPanel = panel
        ComputerStopShortcut.shared.register { [weak center] in center?.stop() }
    }

    func hideStop() {
        stopPanel?.orderOut(nil)
        stopPanel = nil
        ComputerStopShortcut.shared.unregister()
    }

    func showPermissions() {
        if let window = permissionsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: "Use Your Mac", comment: "Window title: the permissions walkthrough for using this Mac")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ComputerPermissionsView(permissions: .shared) { [weak window] in window?.close() })
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        permissionsWindow = window
    }

    private func present(_ view: some View) {
        hideCards()
        let panel = Self.panel(level: .modalPanel, key: true)
        panel.contentView = NSHostingView(rootView: view
            .nollieGlass(in: .rect(cornerRadius: 32), solid: Color(nsColor: .windowBackgroundColor))
            .padding(1))
        panel.setContentSize(panel.contentView!.fittingSize)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.requestUserAttention(.criticalRequest)
        card = panel
    }

    private static func panel(level: NSWindow.Level, key: Bool) -> NSPanel {
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.canTakeKey = key
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        return panel
    }
}

private final class KeyablePanel: NSPanel {
    var canTakeKey = true
    override var canBecomeKey: Bool { canTakeKey }
}

/// Keeps the Stop panel's app name current as the bot moves between apps.
private struct StopPanelHost: View {
    var center: ComputerCenter
    var fallback: ComputerTask

    var body: some View {
        ComputerStopPanelView(task: center.task ?? fallback) { center.stop() }
            .padding(4)
    }
}
#endif
