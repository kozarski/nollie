#if os(macOS)
import AppKit
import Testing
@testable import Nollie

/// Setup's window has no title bar, and it has fields to type in.
private final class SetupLikeWindow: NSWindow {}

@MainActor
@Suite struct KeyableWindowTests {
    @Test func aWindowWithNoTitleBarTakesTheKeyboardOnceAdopted() {
        let window = SetupLikeWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                     styleMask: [.borderless, .closable, .resizable], backing: .buffered, defer: true)
        #expect(!window.canBecomeKey, "AppKit's own answer for a window with no title bar")
        KeyableWindow.adopt(window)
        #expect(window.canBecomeKey && window.canBecomeMain)
        // Another window of the same kind, not adopted, answers as it did before.
        let other = SetupLikeWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(!other.canBecomeKey)
        KeyableWindow.adopt(other)
        #expect(other.canBecomeKey)
    }
}
#endif
