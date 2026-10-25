#if os(macOS)
import AppKit
import Testing
@testable import Nollie

/// "Import from iPhone or iPad" belongs in a text field's right-click menu and nowhere else.
@MainActor @Suite struct ContinuityMenuTests {
    /// What the system appends: a separator, a section header and one device.
    private func continuityTail() -> [NSMenuItem] {
        [.separator(),
         .sectionHeader(title: "Import from iPhone or iPad"),
         NSMenuItem(title: "Studio Phone", action: NSSelectorFromString("importFromDeviceText:"), keyEquivalent: "")]
    }

    private func menu(titles: [String]) -> NSMenu {
        let menu = NSMenu()
        titles.forEach { menu.addItem(NSMenuItem(title: $0, action: nil, keyEquivalent: "")) }
        return menu
    }

    @Test func aMessageMenuDropsTheImportItemsAndTheirSeparator() {
        let titles = ["Reply", "Speak", "Copy", "Select Text", "Share"]
        let messageMenu = menu(titles: titles)
        for extra in continuityTail() { messageMenu.addItem(extra) }
        ContinuityMenuFilter.strip(messageMenu)
        #expect(messageMenu.items.map { $0.title } == titles)
    }

    @Test func aTextFieldMenuKeepsEverything() {
        let editing: [(String, Selector)] = [("Copy", #selector(NSText.copy(_:))), ("Paste", #selector(NSText.paste(_:)))]
        let menu = NSMenu()
        for (title, action) in editing { menu.addItem(withTitle: title, action: action, keyEquivalent: "") }
        for item in continuityTail() { menu.addItem(item) }
        ContinuityMenuFilter.strip(menu)
        #expect(menu.numberOfItems == editing.count + 3)
    }

    @Test func aSubmenuIsNotTouched() {
        let outer = NSMenu()
        let entry = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let inner = NSMenu()
        continuityTail().forEach(inner.addItem)
        entry.submenu = inner
        outer.addItem(entry)
        ContinuityMenuFilter.strip(inner)
        #expect(inner.items.count == 3)
    }
}
#endif
