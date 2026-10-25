#if os(macOS)
import AppKit
import LocalAuthentication
import SwiftUI
import Testing
@testable import Nollie
@testable import NollieCore

/// Pictures of saved sign-ins on the Mac, light and dark, rendered in real AppKit windows and
/// attached to the test results: Settings › Sign-ins with its recent uses, the empty page, the
/// editor, and the card in a chat. Demo data only; no Keychain and no password is read.
@MainActor
@Suite struct SignInSnapshotTests {
    private func center(empty: Bool = false) throws -> SignInCenter {
        let store = SavedSignInStore(backend: MemorySavedSignInBackend()) { _ in LAContext() }
        if !empty {
            try store.save(site: "example.com", username: "corey@example.com", secret: SignInSecret(password: "demo", note: "Codes come by text"))
            try store.save(site: "library.org", username: "corey.k", secret: SignInSecret(password: "demo"))
            try store.save(site: "shop.example.net", username: "corey", secret: SignInSecret(password: "demo"))
        }
        let c = SignInCenter(store: store)
        c.runtime = { nil }
        return c
    }

    private var history: [SignInHistoryEntry] {
        let now = Int(Date().timeIntervalSince1970)
        return [SignInHistoryEntry(at: now - 600, bot: "scout", site: "example.com", outcome: "signed_in", approver: "iphone", computer: "space"),
                SignInHistoryEntry(at: now - 26 * 3600, bot: "forager", site: "library.org", outcome: "signed_in", approver: "mac", computer: "space"),
                SignInHistoryEntry(at: now - 50 * 3600, bot: "scout", site: "shop.example.net", outcome: "declined", computer: "space")]
    }

    @Test func theSettingsPage() throws {
        try attach(SignInsSettingsView(center: try center(), fixedHistory: history).frame(width: 620, height: 640), named: "sign-ins-settings")
        try attach(SignInsSettingsView(center: try center(empty: true), fixedHistory: []).frame(width: 620, height: 440), named: "sign-ins-settings-empty")
    }

    @Test func theEditor() throws {
        try attach(SignInEditor(target: .add, store: try center().store) {}, named: "sign-ins-editor-add")
        let item = try #require(try center().store.items.first)
        try attach(SignInEditor(target: .edit(item), store: try center().store) {}, named: "sign-ins-editor-locked")
    }

    @Test func theCardInAChat() throws {
        let card = SignInCardBody(ask: SignInAsk(requestID: String(repeating: "a", count: 32), site: "example.com"),
                                  botName: "Scout") { _ in nil }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(width: 470, alignment: .leading)
            .background(Ink.card, in: .rect(cornerRadius: Ink.cardRadius, style: .continuous))
            .padding(24)
        try attach(card, named: "sign-in-card-mac")
    }

    @Test func historyLinesSayWhoAndHowInPlainWords() {
        #expect(SignInsSettingsView.line(history[0], bot: "Scout") == "Scout signed in to example.com")
        #expect(SignInsSettingsView.detail(history[0]) == "Allowed on your iPhone")
        #expect(SignInsSettingsView.detail(history[1]) == "Allowed on this Mac")
        #expect(SignInsSettingsView.line(history[2], bot: "Scout") == "You said no to Scout on shop.example.net")
        #expect(SignInsSettingsView.detail(history[2]) == nil)
        for outcome in ["signed_in", "declined", "cancelled", "no_answer", "not_saved", "expired", "failed"] {
            let line = SignInsSettingsView.line(SignInHistoryEntry(at: 0, bot: "scout", site: "a.com", outcome: outcome), bot: "Scout")
            #expect(!line.contains("\u{2014}") && line.contains("a.com"), "\(outcome)")
        }
    }

    /// Glass off for pictures: drawn from the views, Liquid Glass (composited by the window server)
    /// would come out blank. The pictures show the solid fallback, as the design snapshots do.
    private static let snapshotDefaults: UserDefaults = {
        let d = UserDefaults(suiteName: "nollie.sign-in-snapshots")!
        d.set(false, forKey: GlassAppearance.enabledKey)
        return d
    }()

    private func attach(_ view: some View, named name: String) throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            // The window's own background is drawn by the window server, so the picture paints its own.
            let host = NSHostingView(rootView: view
                .background(appearance == .aqua ? Color.white : Color(white: 0.12))
                .environment(\.colorScheme, appearance == .aqua ? .light : .dark)
                .defaultAppStorage(Self.snapshotDefaults)
                .environment(AppModel.shared))
            let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            defer { window.orderOut(nil); window.close() }
            let size = host.fittingSize
            try #require(size.width > 100 && size.height > 30, "\(name) has no size")
            window.setContentSize(size)
            host.frame.size = size
            // A Mac Form is a table that makes its rows only once its window is on screen: up for a
            // moment, then the picture is drawn from the views themselves (no screen recording).
            window.setFrameOrigin(NSPoint(x: 40, y: 40))
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
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
