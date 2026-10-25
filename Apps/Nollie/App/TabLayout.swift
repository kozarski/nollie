import Foundation

/// Which pages sit in the tab bar, and in what order. Layouts that older versions saved still
/// read fine. Chats is the root on the phone; the Board and Settings open above it, and the
/// administrative pages live under Advanced settings.
struct TabLayout: Equatable, Sendable {
    typealias Tab = AppModel.AppTab

    static let storageKey = "tabLayout"
    static let chatFirstAppliedKey = "navigation.chatFirstApplied"

    /// Every tab a layout may hold, in the order a fresh install shows them.
    static let primary: [Tab] = [.chats, .kanban, .settings]
    /// Tabs that always stay.
    static let required: [Tab] = [.chats, .settings]
    static let maxTabs = primary.count
    static let `default` = TabLayout(tabs: primary)

    private(set) var tabs: [Tab]

    init(tabs: [Tab]) {
        self.tabs = Self.tidy(tabs)
    }

    var isFull: Bool { tabs.count >= Self.maxTabs }

    var encoded: String {
        tabs.dropFirst().reduce(tabs.first?.rawValue ?? "") { $0 + "," + $1.rawValue }
    }

    func contains(_ tab: Tab) -> Bool { tabs.contains(tab) }

    /// The tabs to show now. A page that is not ready (the Board before its plugin) is left out,
    /// while the saved choice stays as it was.
    func visible(hiding hidden: Set<Tab> = []) -> [Tab] {
        tabs.filter { !hidden.contains($0) }
    }

    /// Reads a saved string. Names nobody knows are dropped and the required tabs come back.
    static func parse(_ raw: String?) -> TabLayout {
        guard let raw = raw, raw.isEmpty == false else { return .default }
        let found = raw.split(separator: ",").compactMap { Tab(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        return TabLayout(tabs: found)
    }

    /// The page to open on launch: the Board if that is what was chosen, else the conversations.
    /// Every older choice (Home, Settings, the admin pages) also means the conversations.
    static func launchTab(_ raw: String?) -> Tab {
        raw == Tab.kanban.rawValue ? .kanban : .chats
    }

    /// Turns an optional tab on or off. Required tabs and unknown ones are left alone.
    mutating func set(_ tab: Tab, enabled: Bool) {
        guard Self.primary.contains(tab), !Self.required.contains(tab) else { return }
        if !enabled {
            tabs = tabs.filter { $0 != tab }
        } else if !contains(tab), !isFull {
            // Settings stays last, as in the system apps.
            tabs.insert(tab, at: tabs.firstIndex(of: .settings) ?? tabs.count)
        }
    }

    /// Drops repeats and unknown tabs, then puts Chats first and Settings last if missing.
    private static func tidy(_ list: [Tab]) -> [Tab] {
        var kept = list.reduce(into: [Tab]()) { out, tab in
            if primary.contains(tab), !out.contains(tab) { out.append(tab) }
        }
        if !kept.contains(.chats) { kept.insert(.chats, at: 0) }
        if !kept.contains(.settings) { kept.append(.settings) }
        return kept
    }
}
