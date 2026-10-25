#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Nollie

/// Pictures of the Nollie Computer screens, light and dark, rendered in real AppKit windows and
/// attached to the test results: the approval card, a confirmation, the Stop panel and the
/// permission walkthrough before and after the person allows both.
@MainActor
@Suite struct ComputerSnapshotTests {
    private let notes = ComputerTask.App(info: ComputerAppInfo(bundleID: "com.apple.Notes", name: "Notes"), viewOnly: false)
    private let safari = ComputerTask.App(info: ComputerAppInfo(bundleID: "com.apple.Safari", name: "Safari"), viewOnly: true)

    @Test func theApprovalCard() throws {
        let approval = ComputerApproval(botName: "Scout",
                                        request: ComputerStartRequest(sessionID: "s", profile: "career", apps: ["Notes", "Safari", "Terminal"],
                                                                      purpose: "Copy the three job links from your Safari tabs into a new note."),
                                        apps: [notes, safari],
                                        refused: [.init(name: "Terminal", reason: ComputerAppRules.commands)],
                                        chatTitle: "Job hunt", platform: "Signal")
        try attach(ComputerApprovalCard(approval: approval) { _ in }, named: "computer-approval")
    }

    @Test func theConfirmationCard() throws {
        let confirmation = ComputerConfirmation(botName: "Scout", sentence: "send something in Mail: click \u{201C}Send\u{201D}")
        try attach(ComputerConfirmationCard(confirmation: confirmation, answer: { _ in }, stop: {}), named: "computer-confirm")
        var checked = confirmation
        checked.check = "You're about to press \u{201C}Send\u{201D}."
        try attach(ComputerConfirmationCard(confirmation: checked, answer: { _ in }, stop: {}), named: "computer-confirm-check")
    }

    @Test func theStopPanel() throws {
        var task = ComputerTask(botName: "Scout", profile: "career", sessionID: "s", purpose: "p", apps: [notes, safari], startedAt: .now)
        task.noteActivity(in: notes, at: .now)
        try attach(ComputerStopPanelView(task: task) {}.padding(12), named: "computer-stop-panel", opaque: false)
    }

    @Test func theBetaSwitch() throws {
        try attach(Form { Section("Your Mac") { ComputerBetaToggle() } }.formStyle(.grouped).frame(width: 420, height: 130),
                   named: "computer-beta-switch")
    }

    @Test func thePermissionWalkthrough() throws {
        for granted in [false, true] {
            let permissions = ComputerPermissions()
            permissions.read = { _ in granted }
            permissions.request = { _ in }
            permissions.refresh()
            try attach(ComputerPermissionsView(permissions: permissions), named: "computer-permissions-\(granted ? "allowed" : "start")")
        }
        // Asking shows macOS's prompt (a recorder here) and then offers the settings page instead.
        let permissions = ComputerPermissions()
        var asked: [ComputerPermissions.Kind] = []
        permissions.read = { _ in false }
        permissions.request = { asked.append($0) }
        permissions.ask(.accessibility)
        #expect(asked == [.accessibility])
        #expect(permissions.asked == [.accessibility])
        try attach(ComputerPermissionsView(permissions: permissions), named: "computer-permissions-asked")
    }

    private func attach(_ view: some View, named name: String, opaque: Bool = true) throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, appearance == .aqua ? .light : .dark))
            let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.isReleasedWhenClosed = false
            window.backgroundColor = opaque ? .windowBackgroundColor : (appearance == .aqua ? .white : .black)
            window.contentView = host
            defer { window.orderOut(nil); window.close() }
            let size = host.fittingSize
            try #require(size.width > 100 && size.height > 30, "\(name) has no size")
            window.setContentSize(size)
            host.frame.size = size
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            Attachment.record(data, named: "\(name)-\(appearance == .aqua ? "light" : "dark").png")
        }
    }
}
#endif
