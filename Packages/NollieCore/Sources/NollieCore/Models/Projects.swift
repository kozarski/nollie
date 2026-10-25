import Foundation

/// A Hermes project is one name over one or more gateway folders. A chat belongs to it when it works
/// inside any of those folders, and a new chat joins by starting in the main folder. The gateway sends
/// snake_case keys, which the shared decoder maps to the names used here.
public struct Project: Sendable, Identifiable, Hashable, Codable {
    public struct Folder: Sendable, Hashable, Codable {
        public let isPrimary: Bool?
        public let label: String?
        public let path: String
    }

    public var folders: [Folder]?
    public var createdAt: Double?
    public var color: String?
    public var icon: String?
    public var description: String?
    public var slug: String?
    public var archived: Bool?
    public var primaryPath: String?
    public var name: String
    public var id: String

    public init(id: String,
                name: String,
                primaryPath: String? = nil,
                archived: Bool? = nil,
                slug: String? = nil,
                description: String? = nil,
                icon: String? = nil,
                color: String? = nil,
                createdAt: Double? = nil,
                folders: [Folder]? = nil) {
        self.id = id
        self.name = name
        self.primaryPath = primaryPath
        self.archived = archived
        self.slug = slug
        self.description = description
        self.icon = icon
        self.color = color
        self.createdAt = createdAt
        self.folders = folders
    }

    public var isArchived: Bool { archived == true }

    /// Where a new chat in this project begins.
    public var startPath: String? {
        if let primaryPath { return primaryPath }
        let listed = folders ?? []
        let chosen = listed.first { $0.isPrimary == true } ?? listed.first
        return chosen?.path
    }

    /// The colour's hue as a fraction of the wheel, read from the gateway's `hsl(...)` text.
    public var hue: Double? {
        guard let color else { return nil }
        let reader = Scanner(string: color)
        reader.charactersToBeSkipped = nil
        _ = reader.scanUpToString("(")
        guard reader.scanString("(") != nil, let degrees = reader.scanDouble(), degrees >= 0 else { return nil }
        return degrees.truncatingRemainder(dividingBy: 360) / 360
    }
}

public struct ProjectsListResponse: Codable, Sendable {
    public let projects: [Project]
    public let activeId: String?
}

/// One group in the `projects.tree` answer, cut down to which stored chats are inside it.
/// The gateway also lists automatic groups (a git root no one turned into a project) and a Home group.
public struct ProjectTreeNode: Codable, Sendable {
    public let isAuto: Bool?
    public let isNoProject: Bool?
    public let sessionIds: [String]?
    public let id: String
    public let label: String?
}

public struct ProjectsTreeResponse: Codable, Sendable {
    public let projects: [ProjectTreeNode]
}
