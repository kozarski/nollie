import Foundation

extension AppModel {
    /// The places the app can be.
    enum AppTab: String, Hashable, CaseIterable, Sendable, Identifiable {
        case chats, bots, cron, kanban, settings

        var id: String { rawValue }

        private static let names: [AppTab: String] = [
            .chats: "Chats", .bots: "Bots", .cron: "Tasks", .kanban: "Board", .settings: "Settings",
        ]

        var title: String { Self.names[self] ?? rawValue.capitalized }
    }
}
