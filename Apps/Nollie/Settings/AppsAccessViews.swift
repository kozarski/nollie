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
        "web": .init(title: "Web research", description: "Search the web and read pages."),
        "search": .init(title: "Web search", description: "Find information on the web."),
        "x_search": .init(title: "Search X", description: "Find public posts and conversations on X."),
        "vision": .init(title: "Understand images", description: "Read and describe images."),
        "video": .init(title: "Understand videos", description: "Review and describe video content."),
        "image_gen": .init(title: "Create images", description: "Make images from your descriptions."),
        "video_gen": .init(title: "Create videos", description: "Make and edit videos with a configured service."),
        "computer_use": .init(title: "Computer control", description: "See a screen and use its mouse and keyboard when access is allowed."),
        "terminal": .init(title: "Run commands", description: "Run programs and manage processes on the assistant's computer."),
        "skills": .init(title: "Skills", description: "Read and manage instructions for common tasks."),
        "browser": .init(title: "Use websites", description: "Open pages, click controls and fill in forms."),
        "cronjob": .init(title: "Scheduled tasks", description: "Create, update, pause and run scheduled tasks."),
        "file": .init(title: "Files", description: "Find, read and change files the assistant can access."),
        "tts": .init(title: "Read aloud", description: "Turn text into spoken audio."),
        "todo": .init(title: "Plan tasks", description: "Keep track of the steps in a piece of work."),
        "memory": .init(title: "Memory", description: "Remember useful details between conversations."),
        "context_engine": .init(title: "Conversation context", description: "Use the configured service for conversation context."),
        "session_search": .init(title: "Past conversations", description: "Find and recall earlier conversations."),
        "connections": .init(title: "App connections", description: "Find connected services and use their available actions."),
        "project": .init(title: "Project workspaces", description: "Create and switch between supported workspaces."),
        "bot_room": .init(title: "Group conversations", description: "Take part in supported group conversations."),
        "desktop_ui": .init(title: "Desktop controls", description: "Use controls provided by a supported desktop client."),
        "onboarding": .init(title: "Setup guidance", description: "Show setup guidance in supported clients."),
        "catalog": .init(title: "Add capabilities", description: "Request skills and extensions through supported approval controls."),
        "clarify": .init(title: "Ask questions", description: "Ask you for details or a choice before continuing."),
        "code_execution": .init(title: "Run scripts", description: "Run scripts that combine several tool actions."),
        "code": .init(title: "Run scripts", description: "Run scripts that combine several tool actions."),
        "delegation": .init(title: "Delegate work", description: "Ask helper assistants to work on parts of a task."),
        "kanban": .init(title: "Board tasks", description: "Update assigned work, request review and report progress."),
        "discord": .init(title: "Discord", description: "Read and participate in connected Discord conversations."),
        "discord_admin": .init(title: "Manage Discord", description: "Manage channels, roles and messages where the account allows it."),
        "yuanbao": .init(title: "Yuanbao", description: "Use connected Yuanbao conversations and group actions."),
        "feishu_doc": .init(title: "Lark documents", description: "Read documents available through the connected account."),
        "feishu_drive": .init(title: "Lark comments", description: "Read and add comments on connected documents."),
        "debugging": .init(title: "Troubleshooting", description: "Use commands, files and web research to investigate problems."),
        "safe": .init(title: "Research and images", description: "Use web research, image analysis and image creation."),
        "coding": .init(title: "Coding", description: "Use files, commands and research to work on code.")
    ]

    static func connectionTest(_ result: JSONValue) -> String {
        guard result["ok"]?.boolValue == true else { return "Connection check failed. Check its setup and try again." }
        let count = result["tools"]?.arrayValue?.count ?? result["tool_count"]?.intValue
        if let count, count >= 0 { return "Connection checked. \(count) tools available." }
        return "Connection checked."
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
                        LabeledContent("More capabilities", value: loaded && error == nil ? "\(groups.more.filter(\.enabled).count) on" : "")
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
            self.error = "Couldn't check this bot's tools. Try again."; loaded = true
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
        } catch { if model.runtime === rt, profile == target { self.error = "Couldn't change this tool. Try again." } }
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
        } catch { if !Task.isCancelled, model.runtime === rt, profile == target { self.error = "Couldn't check this bot's skills. Try again." } }
    }

    private func toggle(_ s: SkillInfo, _ enabled: Bool, expectedScope: String) async {
        guard scope == expectedScope, let rt, !model.lock.isLocked, !busy.contains(s.name), !Task.isCancelled else { return }
        let target = profile
        busy.insert(s.name); defer { busy.remove(s.name) }
        do {
            let _: JSONValue = try await rt.api.send("PUT", "/api/skills/toggle", profile: target, json: ["name": .string(s.name), "enabled": .bool(enabled)])
            guard !Task.isCancelled, model.runtime === rt, profile == target else { return }
            await load()
        } catch { if model.runtime === rt, profile == target { self.error = "Couldn't change this skill. Try again." } }
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
                        LabeledContent("Transport", value: s.transport ?? (s.url == nil ? "Local process" : "HTTP"))
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
        } catch { if !Task.isCancelled, model.runtime === rt, profile == target { self.error = "Couldn't check this bot's connections. Try again."; loaded = true } }
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
        } catch { if model.runtime === rt, profile == target { self.error = "Couldn't change this connection. Try again." } }
    }

    private func test(_ s: MCPServerInfo, expectedScope: String) async {
        guard scope == expectedScope, let rt, !model.lock.isLocked, !busy.contains(s.name), !Task.isCancelled else { return }
        let target = profile
        busy.insert(s.name); defer { busy.remove(s.name) }
        testResult = nil
        do {
            let r: JSONValue = try await rt.api.send("POST", "/api/mcp/servers/\(s.name)/test", profile: target, body: EmptyBody())
            guard !Task.isCancelled, model.runtime === rt, profile == target, !model.lock.isLocked else { return }
            testResult = "\(s.name): \(BotAccessPresentation.connectionTest(r))"
        } catch { if model.runtime === rt, profile == target { testResult = "Couldn't check this connection. Try again." } }
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
        } catch { if model.runtime === rt, profile == target { self.error = "Couldn't remove this connection. Try again." } }
    }
}
