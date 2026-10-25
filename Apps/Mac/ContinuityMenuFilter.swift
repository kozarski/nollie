import AppKit

/// Keeps "Import from iPhone or iPad" out of menus where it does nothing.
///
/// AppKit puts these Continuity Camera entries, labelled with the person's own phone, into every
/// right-click menu of a window that takes imports. They should appear only in the composer's text
/// menu and the File menu. A menu without Paste is not a text field's, and that is how we decide
/// where to tidy up.
@MainActor
enum ContinuityMenuFilter {
    private static var observers = [NSObjectProtocol]()

    /// Starts watching menus. A second call changes nothing.
    static func start() {
        if !observers.isEmpty { return }
        observers = [
            // A menu opens: clean it now, and again once AppKit has finished filling it.
            watch(NSMenu.didBeginTrackingNotification) { menu, _ in
                strip(menu)
                Task { @MainActor in strip(menu) }
            },
            // Some menus (a reply bubble's) are filled while already showing. When a Continuity
            // entry arrives, clean on the next turn, never in the middle of AppKit's own insert.
            watch(NSMenu.didAddItemNotification) { menu, slot in
                guard let slot, menu.items.indices.contains(slot), isContinuityItem(menu.items[slot]) else { return }
                Task { @MainActor in strip(menu) }
            },
        ]
    }

    private static func watch(_ name: Notification.Name, _ react: @escaping @MainActor (NSMenu, Int?) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu else { return }
            nonisolated(unsafe) let target = menu
            let slot = note.userInfo?["NSMenuItemIndex"] as? Int
            MainActor.assumeIsolated { react(target, slot) }
        }
    }

    /// Deletes the entries from a menu that does not belong to a text field, then the separators left
    /// dangling. The menu bar and submenus stay as they are.
    static func strip(_ menu: NSMenu) {
        let isContextMenu = menu.supermenu == nil && menu !== NSApp?.mainMenu
        if acceptsPaste(menu) || !isContextMenu { return }
        let unwanted = menu.items.filter { isContinuityItem($0) }
        if unwanted.isEmpty { return }
        unwanted.forEach { menu.removeItem($0) }
        dropStraySeparators(menu)
    }

    static func isContinuityItem(_ item: NSMenuItem) -> Bool {
        let marker = "importFromDevice"
        let labels = [item.action.map(NSStringFromSelector), item.identifier?.rawValue]
        if labels.contains(where: { $0?.localizedCaseInsensitiveContains(marker) == true }) { return true }
        if item.isSectionHeader && item.title.localizedCaseInsensitiveContains("Import from") { return true }
        // A submenu with one entry per device.
        guard let devices = item.submenu?.items, !devices.isEmpty else { return false }
        return devices.allSatisfy(isContinuityItem)
    }

    private static func acceptsPaste(_ menu: NSMenu) -> Bool {
        menu.items.contains { $0.action == #selector(NSText.paste(_:)) }
    }

    /// Nothing at the top or bottom, and never two in a row.
    private static func dropStraySeparators(_ menu: NSMenu) {
        var afterLine = true
        for item in menu.items {
            if item.isSeparatorItem && afterLine {
                menu.removeItem(item)
            } else {
                afterLine = item.isSeparatorItem
            }
        }
        if let tail = menu.items.last, tail.isSeparatorItem { menu.removeItem(tail) }
    }
}
