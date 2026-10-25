import Foundation

/// Projects of the selected bot as the gateway reports them, plus which saved chat is filed where.
///
/// Nothing is known until `refresh()` has run. After that `available` tells whether this Hermes
/// has projects at all: it is false only when the gateway answers "method not found" (-32601),
/// the one way to tell.
@MainActor
@Observable
public final class ProjectsStore {
    /// The projects of one bot, and which of its chats are in which. Projects belong to a bot on
    /// the gateway, so when the chat list shows every bot's chats, the bots that aren't selected
    /// keep theirs here under their profile name.
    public struct Scope: Sendable {
        /// Chat id to project id, for the chats that are filed in one.
        public var membership: [String: String]
        public var projects: [Project]

        public init(projects: [Project] = [], membership: [String: String] = [:]) {
            self.membership = membership
            self.projects = projects
        }

        func project(containing session: String) -> Project? {
            guard let id = membership[session] else { return nil }
            return projects.first { $0.id == id }
        }

        var unarchived: [Project] { projects.filter { !$0.isArchived } }
    }

    public enum MoveError: LocalizedError {
        case unsupported
        case noFolder(String)
        case stillInProject(String, String)

        public var errorDescription: String? {
            switch self {
            case .unsupported:
                "This Hermes can't move chats between projects yet. Update it on the gateway, then try again."
            case .noFolder(let who):
                "\(who) has no folder on the gateway to move this chat into."
            case .stillInProject(let folder, let project):
                "The bot's own folder (\(folder)) belongs to \(project), so there's no spot outside a project for this chat."
            }
        }
    }

    public private(set) var available: Bool?
    public private(set) var canMove = true
    public private(set) var activeID: String?
    public private(set) var lastError: String?
    /// The selected bot's own projects and chat membership.
    private var mine = Scope()
    public private(set) var others: [String: Scope] = [:]

    private weak var runtime: GatewayRuntime?
    private var busyReading = false

    private static let treeQuery: [String: JSONValue] = ["preview_limit": 0, "session_limit": 2000]

    public init() {}

    func attach(_ runtime: GatewayRuntime) { self.runtime = runtime }

    // MARK: Looking things up

    public var projects: [Project] { mine.projects }

    /// Chat id to project id for the selected bot. Chats in the gateway's automatic groups,
    /// or in its Home group, are left out.
    public var membership: [String: String] { mine.membership }

    public var open: [Project] { mine.unarchived }

    public func project(id: String?) -> Project? {
        id.flatMap { wanted in mine.projects.first { $0.id == wanted } }
    }

    public func project(forSession id: String) -> Project? {
        if let found = mine.project(containing: id) { return found }
        return others.values.lazy.compactMap { $0.project(containing: id) }.first
    }

    /// Projects open to a chat of `profile`: only that bot's own, never someone else's.
    public func open(for profile: String?) -> [Project] {
        if let profile, profile != runtime?.selectedProfile, let theirs = others[profile] { return theirs.unarchived }
        return open
    }

    /// Project a chat is filed in, no matter which bot it belongs to.
    public func projectID(forSession id: String) -> String? {
        if let own = mine.membership[id] { return own }
        return others.values.lazy.compactMap { $0.membership[id] }.first
    }

    // MARK: Reading from the gateway

    public func refresh() async {
        guard let runtime, !busyReading else { return }
        busyReading = true
        defer { busyReading = false }
        do {
            let list: ProjectsListResponse = try await runtime.rpc("projects.list").decode()
            mine.projects = list.projects
            activeID = list.activeId
            available = true
            lastError = nil
            await refreshTree()
        } catch let failure as RPCError where failure.code == RPCError.methodNotFound {
            available = false
            activeID = nil
            mine = Scope()
            others = [:]
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Refreshes the chat-to-project mapping. It is inexpensive, so it runs on every chat list change.
    public func refreshTree() async {
        guard available == true, let runtime else { return }
        if let tree = try? await runtime.rpc("projects.tree", Self.treeQuery).decode(ProjectsTreeResponse.self) {
            mine.membership = Self.table(from: tree)
        }
    }

    /// Reads the other bots' projects for a list that mixes every bot's chats. A bot missing
    /// from `profiles` is forgotten.
    public func refreshOthers(_ profiles: [String]) async {
        guard let runtime else { return }
        guard available == true else {
            if available == false { others = [:] }
            return
        }
        var gathered: [String: Scope] = [:]
        for name in profiles where name != runtime.selectedProfile {
            guard let list = try? await runtime.rpc("projects.list", profile: name).decode(ProjectsListResponse.self) else { continue }
            let tree = try? await runtime.rpc("projects.tree", Self.treeQuery, profile: name).decode(ProjectsTreeResponse.self)
            gathered[name] = Scope(projects: list.projects, membership: tree.map(Self.table(from:)) ?? [:])
        }
        others = gathered
    }

    private static func table(from tree: ProjectsTreeResponse) -> [String: String] {
        var table: [String: String] = [:]
        for node in tree.projects where node.isNoProject != true && node.isAuto != true {
            for session in node.sessionIds ?? [] { table[session] = node.id }
        }
        return table
    }

    // MARK: Moving chats

    /// Files chats under `project`, or under no project (`nil`).
    ///
    /// On the gateway, a chat sits in a project since it works inside that project's folder. A move
    /// therefore rewrites the chat's working folder through `session.workspace.move`. Target: the
    /// project's start folder, or the bot's default folder when no project is wanted. A chat in progress
    /// picks the change up straight away. `profile` is the owning bot (nil = the selected one). Returns
    /// how many chats moved.
    @discardableResult
    public func move(_ sessionIDs: [String], to project: Project?, profile: String? = nil) async throws -> Int {
        guard let runtime else { throw HermesAPIError.transport("No gateway connected") }
        let folder = try await folder(for: project, profile: profile, runtime: runtime)
        var moved = 0

        for id in sessionIDs {
            do {
                try await relocate(id, to: folder, profile: profile, via: runtime)
            } catch {
                // Part of the batch may have gone through, and the list should show that part.
                if moved > 0, !(error is MoveError) { await reload(profile: profile) }
                throw error
            }
            showAtOnce(id, in: project, profile: profile)
            moved += 1
        }

        await reload(profile: profile)
        if project == nil, let first = sessionIDs.first, let stuck = self.project(forSession: first) {
            throw MoveError.stillInProject(folder, stuck.name)
        }
        return moved
    }

    /// Moves one chat's working folder. A gateway that doesn't know the method can't move chats at all.
    private func relocate(_ id: String, to folder: String, profile: String?, via runtime: GatewayRuntime) async throws {
        let fields: [String: JSONValue] = ["cwd": .string(folder), "session_key": .string(id)]
        do {
            _ = try await runtime.rpc("session.workspace.move", fields, profile: profile)
        } catch let failure as RPCError where failure.code == RPCError.methodNotFound {
            canMove = false
            throw MoveError.unsupported
        }
    }

    /// Updates the list straight away; the tree read after the move has the final word.
    private func showAtOnce(_ session: String, in project: Project?, profile: String?) {
        if let profile, profile != runtime?.selectedProfile {
            others[profile, default: Scope()].membership[session] = project?.id
        } else {
            mine.membership[session] = project?.id
        }
    }

    private func folder(for project: Project?, profile: String?, runtime: GatewayRuntime) async throws -> String {
        if let project {
            guard let start = project.startPath, !start.isEmpty else { throw MoveError.noFolder(project.name) }
            return start
        }
        let config = try await runtime.rpc("config.get", ["key": "project"], profile: profile)
        guard let cwd = config["cwd"]?.stringValue, !cwd.isEmpty else { throw MoveError.noFolder("The bot") }
        return cwd
    }

    private func reload(profile: String?) async {
        let isOther = profile != nil && profile != runtime?.selectedProfile
        if isOther {
            await refreshOthers(Array(others.keys))
        } else {
            await refreshTree()
        }
    }
}
