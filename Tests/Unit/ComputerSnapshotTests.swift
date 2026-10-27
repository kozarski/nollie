#if os(macOS)
import AppKit
import SwiftUI
import NollieCore
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

    @Test func theApprovalCardWithAnAppNotPicked() throws {
        let approval = ComputerApproval(botName: "Scout",
                                        request: ComputerStartRequest(sessionID: "s", profile: "career", apps: ["Notes", "Mail"],
                                                                      purpose: "Put this week's shopping list in a new note."),
                                        apps: [notes],
                                        refused: [.init(name: "Mail", reason: ComputerPickedApps.notPicked("Mail")),
                                                  .init(name: "Terminal", reason: ComputerAppRules.commands)],
                                        chatTitle: "Groceries", platform: "Nollie")
        // On the panel's own backing, as the card shows on the Mac.
        try attach(ComputerApprovalCard(approval: approval) { _ in }
            .nollieGlass(in: .rect(cornerRadius: 32), solid: Color(nsColor: .windowBackgroundColor))
            .padding(16)
            .background(Ink.canvas), named: "computer-approval-not-picked")
    }

    @Test func theAppsPage() throws {
        let apps: [ComputerPickedApps.Candidate] = [
            .init(info: ComputerAppInfo(bundleID: "com.apple.Notes", name: "Notes"), viewOnly: false),
            .init(info: ComputerAppInfo(bundleID: "com.apple.reminders", name: "Reminders"), viewOnly: false),
            .init(info: ComputerAppInfo(bundleID: "com.apple.TextEdit", name: "TextEdit"), viewOnly: false),
            .init(info: ComputerAppInfo(bundleID: "com.apple.Safari", name: "Safari"), viewOnly: true),
        ]
        // The switch reads its own pretend settings, never this Mac's.
        let defaults = try #require(UserDefaults(suiteName: "nollie-apps-page-\(UUID().uuidString)"))
        for (name, on, model, picked) in [("off", false, "Qwen3.6 35B-A3B", Set<String>()),
                                          ("ready", true, "Qwen3.6 35B-A3B", Set(["com.apple.notes", "com.apple.reminders"])),
                                          ("needs-model", true, nil, Set<String>())] as [(String, Bool, String?, Set<String>)] {
            defaults.set(on, forKey: ComputerCenter.enabledKey)
            let page = NavigationStack {
                ScrollView {
                    VStack(spacing: 36) {
                        ComputerAppsContent(on: on, modelName: model, candidates: apps, picked: picked) { _, _ in }
                    }
                    .padding(EdgeInsets(top: 28, leading: 24, bottom: 40, trailing: 24))
                }
                .background(Ink.canvas)
            }
            .frame(width: 520, height: on ? 980 : 560)
            .defaultAppStorage(defaults)
            try attach(page, named: "computer-apps-\(name)")
        }
    }

    @Test func thePapertrailLinesForThisMac() throws {
        let sessions = [Papertrail.MacSession(at: 1_760_969_000, apps: ["Notes", "TextEdit"], actions: 6, looks: 2),
                        Papertrail.MacSession(at: 1_760_500_000, apps: ["Reminders"], actions: 1)]
        try attach(PapertrailMacUse(sessions: sessions, todayStartsAt: 1_760_914_800)
            .padding(24).frame(width: 460).background(Ink.canvas), named: "papertrail-mac-use")
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
