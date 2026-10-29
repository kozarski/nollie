import Foundation

extension AppModel {
    /// The places the app can be.
    enum AppTab: String, Hashable, CaseIterable, Sendable, Identifiable {
        case chats, bots, cron, kanban, settings

        var id: String { rawValue }

        private static let names: [AppTab: String] = [
            .chats: String(localized: "Chats", comment: "A tab name"),
            .bots: String(localized: "Bots", comment: "A tab name"),
            .cron: String(localized: "Tasks", comment: "A tab name"),
            .kanban: String(localized: "Board", comment: "A tab name"),
            .settings: String(localized: "Settings", comment: "A tab name"),
        ]

        var title: String { Self.names[self] ?? rawValue.capitalized }
    }
}
