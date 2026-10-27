import SwiftUI
import NollieCore

// MARK: Tools / Skills / MCP

enum BotAccessPresentation {
    static func profile(explicit: String?, selected: String?) -> String { explicit ?? selected ?? "default" }

    struct ToolsetCopy: Equatable {
        let title: String
        let description: String?
    }

    static func toolset(_ info: ToolsetInfo, developerMode: Bool) -> ToolsetCopy {
        if developerMode { return ToolsetCopy(title: info.label ?? info.name, description: info.description) }
        if let copy = builtInToolsets[info.name] { return copy }
        return ToolsetCopy(title: info.label ?? info.name, description: nil)
    }

    struct ToolsetGroups {
        let everyday: [ToolsetInfo]
        let actions: [ToolsetInfo]
        let more: [ToolsetInfo]
    }

    static func grouped(_ toolsets: [ToolsetInfo]) -> ToolsetGroups {
        let everyday: Set<String> = ["web", "search", "memory", "cronjob"]
        let actions: Set<String> = ["file", "browser", "terminal", "computer_use", "code_execution", "code"]
        return ToolsetGroups(
            everyday: toolsets.filter { everyday.contains($0.name) },
            actions: toolsets.filter { actions.contains($0.name) },
            more: toolsets.filter { !everyday.contains($0.name) && !actions.contains($0.name) }
        )
    }

    private static let builtInToolsets: [String: ToolsetCopy] = [
        "web": .init(title: String(localized: "Web research", comment: "A bot capability"),
                     description: String(localized: "Search the web and read pages.")),
        "search": .init(title: String(localized: "Web search", comment: "A bot capability"),
                     description: String(localized: "Find information on the web.")),
        "x_search": .init(title: String(localized: "Search X", comment: "A bot capability"),
                     description: String(localized: "Find public posts and conversations on X.")),
        "vision": .init(title: String(localized: "Understand images", comment: "A bot capability"),
                     description: String(localized: "Read and describe images.")),
        "video": .init(title: String(localized: "Understand videos", comment: "A bot capability"),
                     description: String(localized: "Review and describe video content.")),
        "image_gen": .init(title: String(localized: "Create images", comment: "A bot capability"),
                     description: String(localized: "Make images from your descriptions.")),
        "video_gen": .init(title: String(localized: "Create videos", comment: "A bot capability"),
                     description: String(localized: "Make and edit videos with a configured service.")),
        "computer_use": .init(title: String(localized: "Computer control", comment: "A bot capability"),
                     description: String(localized: "See a screen and use its mouse and keyboard when access is allowed.")),
        "terminal": .init(title: String(localized: "Run commands", comment: "A bot capability"),
                     description: String(localized: "Run programs and manage processes on the assistant's computer.")),
        "skills": .init(title: String(localized: "Skills", comment: "A bot capability"),
                     description: String(localized: "Read and manage instructions for common tasks.")),
        "browser": .init(title: String(localized: "Use websites", comment: "A bot capability"),
                     description: String(localized: "Open pages, click controls and fill in forms.")),
        "cronjob": .init(title: String(localized: "Scheduled tasks", comment: "A bot capability"),
                     description: String(localized: "Create, update, pause and run scheduled tasks.")),
        "file": .init(title: String(localized: "Files", comment: "A bot capability"),
                     description: String(localized: "Find, read and change files the assistant can access.")),
        "tts": .init(title: String(localized: "Read aloud", comment: "A bot capability"),
                     description: String(localized: "Turn text into spoken audio.")),
        "todo": .init(title: String(localized: "Plan tasks", comment: "A bot capability"),
                     description: String(localized: "Keep track of the steps in a piece of work.")),
        "memory": .init(title: String(localized: "Memory", comment: "A bot capability"),
                     description: String(localized: "Remember useful details between conversations.")),
        "context_engine": .init(title: String(localized: "Conversation context", comment: "A bot capability"),
                     description: String(localized: "Use the configured service for conversation context.")),
        "session_search": .init(title: String(localized: "Past conversations", comment: "A bot capability"),
                     description: String(localized: "Find and recall earlier conversations.")),
        "connections": .init(title: String(localized: "App connections", comment: "A bot capability"),
                     description: String(localized: "Find connected services and use their available actions.")),
        "project": .init(title: String(localized: "Project workspaces", comment: "A bot capability"),
                     description: String(localized: "Create and switch between supported workspaces.")),
        "bot_room": .init(title: String(localized: "Group conversations", comment: "A bot capability"),
                     description: String(localized: "Take part in supported group conversations.")),
        "desktop_ui": .init(title: String(localized: "Desktop controls", comment: "A bot capability"),
                     description: String(localized: "Use controls provided by a supported desktop client.")),
        "onboarding": .init(title: String(localized: "Setup guidance", comment: "A bot capability"),
                     description: String(localized: "Show setup guidance in supported clients.")),
        "catalog": .init(title: String(localized: "Add capabilities", comment: "A bot capability"),
                     description: String(localized: "Request skills and extensions through supported approval controls.")),
        "clarify": .init(title: String(localized: "Ask questions", comment: "A bot capability"),
                     description: String(localized: "Ask you for details or a choice before continuing.")),
        "code_execution": .init(title: String(localized: "Run scripts", comment: "A bot capability"),
                     description: String(localized: "Run scripts that combine several tool actions.")),
        "code": .init(title: String(localized: "Run scripts", comment: "A bot capability"),
                     description: String(localized: "Run scripts that combine several tool actions.")),
        "delegation": .init(title: String(localized: "Delegate work", comment: "A bot capability"),
                     description: String(localized: "Ask helper assistants to work on parts of a task.")),
        "kanban": .init(title: String(localized: "Board tasks", comment: "A bot capability"),
                     description: String(localized: "Update assigned work, request review and report progress.")),
        "discord": .init(title: String(localized: "Discord", comment: "A bot capability"),
                     description: String(localized: "Read and participate in connected Discord conversations.")),
        "discord_admin": .init(title: String(localized: "Manage Discord", comment: "A bot capability"),
                     description: String(localized: "Manage channels, roles and messages where the account allows it.")),
        "yuanbao": .init(title: String(localized: "Yuanbao", comment: "A bot capability"),
                     description: String(localized: "Use connected Yuanbao conversations and group actions.")),
        "feishu_doc": .init(title: String(localized: "Lark documents", comment: "A bot capability"),
                     description: String(localized: "Read documents available through the connected account.")),
        "feishu_drive": .init(title: String(localized: "Lark comments", comment: "A bot capability"),
                     description: String(localized: "Read and add comments on connected documents.")),
        "debugging": .init(title: String(localized: "Troubleshooting", comment: "A bot capability"),
                     description: String(localized: "Use commands, files and web research to investigate problems.")),
        "safe": .init(title: String(localized: "Research and images", comment: "A bot capability"),
                     description: String(localized: "Use web research, image analysis and image creation.")),
        "coding": .init(title: String(localized: "Coding", comment: "A bot capability"),
                     description: String(localized: "Use files, commands and research to work on code."))
    ]

    static func connectionTest(_ result: JSONValue) -> String {
        guard result["ok"]?.boolValue == true else { return String(localized: "Connection check failed. Check its setup and try again.") }
        let count = result["tools"]?.arrayValue?.count ?? result["tool_count"]?.intValue
        if let count, count >= 0 { return String(localized: "Connection checked. \(count) tools available.") }
        return String(localized: "Connection checked.")
    }
}

struct ToolsView: View {
    var profileName: String? = nil
    @Environment(AppModel.self) private var model
    @AppStorage("nollie.developerMode") private var developerMode = false
    @State private var toolsets: [ToolsetInfo] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var busy: Set<String> = []
    @State private var showMore = false
    private var rt: GatewayRuntime? { model.runtime }
    private var profile: String { BotAccessPresentation.profile(explicit: profileName, selected: rt?.selectedProfile) }
    private var scope: String { "\(rt?.connection.id.uuidString ?? "")/\(profile)" }

    private var botName: String { rt?.profiles.first { $0.name == profile }?.shownName ?? profile }
    private var groups: BotAccessPresentation.ToolsetGroups { BotAccessPresentation.grouped(toolsets) }

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Apps & access")
            if let error { Text(error).small(.footnote, .red) }
            Section {
                NavigationLink { MCPView(profileName: profile) } label: {
                    Label("Connections", systemImage: "point.3.connected.trianglepath.dotted")
                }.testID("apps.connections")
            } header: { Text("Apps & services") }
            if !loaded {
                Section { ProgressView("Checking capabilities…") }
            } else if toolsets.isEmpty, error == nil {
                Section { Text("No capabilities were reported for this bot.").foregroundStyle(.secondary) }
            }
            if developerMode {
                Section("Tools") { toolRows(toolsets) }
                Section { skillsLink }
            } else {
                if !groups.everyday.isEmpty {
                    Section("Everyday") { toolRows(groups.everyday) }
                }
                if !groups.actions.isEmpty {
                    Section {
                        toolRows(groups.actions)
                    } header: { Text("Actions & access") }
                }
                Section {
                    DisclosureGroup(isExpanded: $showMore) {
                        toolRows(groups.more)
                        skillsLink
                    } label: {
                        LabeledContent("More capabilities", value: loaded && error == nil
                                       ? String(localized: "\(groups.more.filter(\.enabled).count) on", comment: "How many capabilities are switched on")
                                       : "")
                            .testID("apps.more")
                    }
                }
            }
        }
        .navigationTitle("Apps & access")
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .testID("settings.tools.page")
        .reloadable { await load() }
        .task(id: scope) { toolsets = []; loaded = false; showMore = false; await load() }
    }

    @ViewBuilder private func toolRows(_ items: [ToolsetInfo]) -> some View {
        ForEach(items) { t in
            let copy = BotAccessPresentation.toolset(t, developerMode: developerMode)
            Toggle(isOn: Binding(get: { t.enabled }, set: { v in
                let expected = scope
                Task { await toggle(t, v, expectedScope: expected) }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(copy.title); if t.configured == false { Text("Needs setup").small(.caption2, .orange) } }
                    if let d = copy.description { Text(d).small(.caption, .secondary).lineLimit(3) }
                    if developerMode, let tools = t.tools, !tools.isEmpty {
                        Text(tools.joined(separator: ", ")).small(.caption2, .tertiary).lineLimit(2)
                    }
                }
            }
            .disabled(busy.contains(t.name) || model.lock.isLocked)
            .testID("tool.toggle.\(t.name)")
        }
    }

    private var skillsLink: some View {
        NavigationLink { SkillsView(profileName: profile) } label: {
            Label("Skills", systemImage: "sparkles")
        }.testID("apps.skills")
    }

    private func load() async {
        guard let rt else { return }
        let target = profile
        do {
            let result: [ToolsetInfo] = try await rt.api.get("/api/tools/toolsets", profile: target)
            guard !Task.isCancelled, model.runtime === rt, profile == target else { return }
            toolsets = result; error = nil; loaded = true
        } catch {
            guard !Task.isCancelled, model.runtime === rt, profile == target else { return }
            self.error = String(localized: "Couldn't check this bot's tools. Try again."); loaded = true
        }
    }

    private func toggle(_ t: ToolsetInfo, _ enabled: Bool, expectedScope: String) async {
        guard scope == expectedScope, let rt, !model.lock.isLocked, !busy.contains(t.name), !Task.isCancelled else { return }
        let target = profile
        busy.insert(t.name)
        defer { busy.remove(t.name) }
        do {
            let _: JSONValue = try await rt.api.send("PUT", "/api/tools/toolsets/\(t.name)", profile: target, json: ["enabled": .bool(enabled)])
            guard !Task.isCancelled, model.runtime === rt, profile == target else { return }
            await load()
        } catch { if model.runtime === rt, profile == target { self.error = String(localized: "Couldn't change this tool. Try again.") } }
    }
}

struct SkillsView: View {
    var profileName: String? = nil
    @Environment(AppModel.self) private var model
    @AppStorage("nollie.developerMode") private var developerMode = false
    @State private var skills: [SkillInfo] = []
    @State private var error: String?
    @State private var search = ""
    @State private var busy: Set<String> = []
    private var rt: GatewayRuntime? { model.runtime }
    private var profile: String { BotAccessPresentation.profile(explicit: profileName, selected: rt?.selectedProfile) }
    private var scope: String { "\(rt?.connection.id.uuidString ?? "")/\(profile)" }

    /// One skill with its on/off switch. The scope is noted when the switch is flipped, so a late
    /// answer for another bot or gateway is ignored.
    private func skillRow(_ skill: SkillInfo) -> some View {
        let isOn = Binding(
            get: { skill.enabled ?? true },
            set: { wanted in
                let expected = scope
                Task { await toggle(skill, wanted, expectedScope: expected) }
            })
        return Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(skill.name)
                    if developerMode, let origin = skill.provenance { Text(origin).small(.caption2, .tertiary) }
                }
                if let about = skill.description { Text(about).small(.caption, .secondary).lineLimit(2) }
            }
        }
        .disabled(model.lock.isLocked || busy.contains(skill.name))
    }

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Skills")
            if let error { Text(error).small(.footnote, .red) }
            ForEach(skills.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { skillRow($0) }
        }
        .reloadable { await load() }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle("Skills")
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .task(id: scope) { skills = []; await load() }
    }

    private func load() async {
        guard let rt else { return }
        let target = profile
        do {
            let result: [SkillInfo] = try await rt.api.get("/api/skills", profile: target)
            guard !Task.isCancelled, model.runtime === rt, profile == target else { return }
            skills = result; error = nil
        } catch { if !Task.isCancelled, model.runtime === rt, profile == target { self.error = String(localized: "Couldn't check this bot's skills. Try again.") } }
    }

    private func toggle(_ s: SkillInfo, _ enabled: Bool, expectedScope: String) async {
        guard scope == expectedScope, let rt, !model.lock.isLocked, !busy.contains(s.name), !Task.isCancelled else { return }
        let target = profile
        busy.insert(s.name); defer { busy.remove(s.name) }
        do {
            let _: JSONValue = try await rt.api.send("PUT", "/api/skills/toggle", profile: target, json: ["name": .string(s.name), "enabled": .bool(enabled)])
            guard !Task.isCancelled, model.runtime === rt, profile == target else { return }
            await load()
        } catch { if model.runtime === rt, profile == target { self.error = String(localized: "Couldn't change this skill. Try again.") } }
    }
}

struct MCPView: View {
    var profileName: String? = nil
    @Environment(AppModel.self) private var model
    @AppStorage("nollie.developerMode") private var developerMode = false
    @State private var servers: [MCPServerInfo] = []
    @State private var error: String?
    @State private var testResult: String?
    @State private var pendingDelete: MCPServerInfo?
    @State private var pendingDeleteScope: String?
    @State private var busy: Set<String> = []
    @State private var loaded = false
    private var rt: GatewayRuntime? { model.runtime }
    private var profile: String { BotAccessPresentation.profile(explicit: profileName, selected: rt?.selectedProfile) }
    private var scope: String { "\(rt?.connection.id.uuidString ?? "")/\(profile)" }

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Connections")
            if let error { Text(error).small(.footnote, .red) }
            if let testResult { Text(testResult).font(.footnote) }
            if !loaded { ProgressView("Checking connections…") }
            else if servers.isEmpty {
                Text("No app connections have been added for this bot.").foregroundStyle(.secondary)
            }
            ForEach(servers) { s in
                Section {
                    Toggle("Allow connection", isOn: Binding(get: { s.enabled ?? true }, set: { v in
                        let expected = scope
                        Task { await setEnabled(s, v, expectedScope: expected) }
                    }))
                        .testID("apps.connection.\(s.name).enabled")
                    Button("Test connection", systemImage: "bolt") {
                        let expected = scope
                        Task { await test(s, expectedScope: expected) }
                    }
                        .testID("apps.connection.\(s.name).test")
                    Button(role: .destructive) { pendingDeleteScope = scope; pendingDelete = s } label: {
                        Label("Remove connection", systemImage: "trash")
                    }
                        .testID("apps.connection.\(s.name).remove")
                    if developerMode {
                        LabeledContent("Transport", value: s.transport ?? (s.url == nil ? String(localized: "Local process", comment: "How a connection runs") : "HTTP"))
                        if let raw = s.url, let host = URLComponents(string: raw)?.host { LabeledContent("Host", value: host) }
                        if let command = s.command { LabeledContent("Program", value: URL(fileURLWithPath: command).lastPathComponent) }
                    }
                } header: { Text(s.name) }
                .disabled(busy.contains(s.name) || model.lock.isLocked)
            }
        }
        .navigationTitle("Connections")
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .testID("settings.connections.page")
        .reloadable { await load() }
        .task(id: scope) { servers = []; loaded = false; testResult = nil; pendingDelete = nil; await load() }
        .alert("Remove this connection?", isPresented: .present($pendingDelete), presenting: pendingDelete) { doomed in
            Button("Remove", role: .destructive) {
                guard let expected = pendingDeleteScope else { return }
                Task { await remove(doomed, expectedScope: expected) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Removes this bot's saved connection. Its account at the service stays unchanged.")
        }
    }

    private func load() async {
        guard let rt else { return }
        let target = profile
        do {
            let raw: JSONValue = try await rt.api.get("/api/mcp/servers", profile: target)
            guard !Task.isCancelled, model.runtime === rt, profile == target else { return }
            servers = Self.parse(raw)
            error = nil; loaded = true
        } catch { if !Task.isCancelled, model.runtime === rt, profile == target { self.error = String(localized: "Couldn't check this bot's connections. Try again."); loaded = true } }
    }

    static func parse(_ raw: JSONValue) -> [MCPServerInfo] {
        let container = raw["servers"] ?? raw
        // Either a list of servers, or an object keyed by each server's name.
        if let list = container.arrayValue {
            return list.compactMap { try? $0.decode(MCPServerInfo.self) }
        }
        guard let byName = container.objectValue else { return [] }
        return byName.sorted(by: { $0.key < $1.key }).compactMap { name, entry in
            var fields = entry.objectValue ?? [:]
            fields["name"] = .string(name)
            return try? JSONValue.object(fields).decode(MCPServerInfo.self)
        }
    }

    private func setEnabled(_ s: MCPServerInfo, _ enabled: Bool, expectedScope: String) async {
        guard scope == expectedScope, let rt, !model.lock.isLocked, !busy.contains(s.name), !Task.isCancelled else { return }
        let target = profile
        busy.insert(s.name); defer { busy.remove(s.name) }
        do {
            let _: JSONValue = try await rt.api.send("PUT", "/api/mcp/servers/\(s.name)/enabled", profile: target, json: ["enabled": .bool(enabled)])
            guard !Task.isCancelled, model.runtime === rt, profile == target else { return }
            testResult = nil
            await load()
        } catch { if model.runtime === rt, profile == target { self.error = String(localized: "Couldn't change this connection. Try again.") } }
    }

    private func test(_ s: MCPServerInfo, expectedScope: String) async {
        guard scope == expectedScope, let rt, !model.lock.isLocked, !busy.contains(s.name), !Task.isCancelled else { return }
        let target = profile
        busy.insert(s.name); defer { busy.remove(s.name) }
        testResult = nil
        do {
            let r: JSONValue = try await rt.api.send("POST", "/api/mcp/servers/\(s.name)/test", profile: target, body: EmptyBody())
            guard !Task.isCancelled, model.runtime === rt, profile == target, !model.lock.isLocked else { return }
            testResult = String(localized: "\(s.name): \(BotAccessPresentation.connectionTest(r))",
                                comment: "A connection's name, then how its check went")
        } catch { if model.runtime === rt, profile == target { testResult = String(localized: "Couldn't check this connection. Try again.") } }
    }

    private func remove(_ s: MCPServerInfo, expectedScope: String) async {
        guard scope == expectedScope, let rt, !model.lock.isLocked, !busy.contains(s.name), !Task.isCancelled else { return }
        let target = profile
        busy.insert(s.name); defer { busy.remove(s.name) }
        do {
            let _: JSONValue = try await rt.api.send("DELETE", "/api/mcp/servers/\(s.name)", profile: target, body: EmptyBody())
            guard !Task.isCancelled, model.runtime === rt, profile == target else { return }
            testResult = nil
            await load()
        } catch { if model.runtime === rt, profile == target { self.error = String(localized: "Couldn't remove this connection. Try again.") } }
    }
}
