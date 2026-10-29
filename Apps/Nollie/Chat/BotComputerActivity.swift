import Foundation
import NollieCore

/// Computer work comes from tool events. A busy chat or an available computer is not activity.
@MainActor
enum BotComputerActivity {
    enum Status: Equatable {
        case usingComputer, working, idle, unknown
        var title: String {
            switch self {
            case .usingComputer: String(localized: "Using the computer")
            case .working: String(localized: "Working on a task")
            case .idle: String(localized: "No active task reported")
            case .unknown: String(localized: "Activity not available")
            }
        }
    }

    static func status(runtime: GatewayRuntime, profile: String) -> Status {
        if isActive(runtime: runtime, profile: profile) { return .usingComputer }
        if runtime.chats.contains(where: { $0.profileName == profile && $0.isRunning }) || hasDelegatedWork(runtime: runtime, profile: profile) { return .working }
        switch runtime.kanban.activity.state(for: profile) {
        case .working: return .working
        case .idle: return .idle
        case .unknown: return .unknown
        }
    }

    static func isActive(in chat: ChatSession) -> Bool {
        isActive(in: chat.items, isRunning: chat.isRunning)
    }

    static func isActive(runtime: GatewayRuntime, profile: String) -> Bool {
        runtime.chats.contains { $0.profileName == profile && isActive(in: $0) }
    }

    /// A live call to another bot is work even when its chat is not open on this device.
    /// It does not prove that the other bot is using a computer.
    static func hasDelegatedWork(runtime: GatewayRuntime, profile: String) -> Bool {
        runtime.chats.contains { chat in
            guard chat.isRunning else { return false }
            for item in chat.items.reversed() {
                switch item.kind {
                case .user, .steer, .error: return false
                case .assistant where item.stats != nil: return false
                case .tool(let tool):
                    if item.rowID == nil, tool.status == .running, tool.delivery?.target == profile { return true }
                default: break
                }
            }
            return false
        }
    }

    static func isActive(in items: [TranscriptItem], isRunning: Bool) -> Bool {
        guard isRunning else { return false }
        for item in items.reversed() {
            switch item.kind {
            case .user, .error:
                return false
            case .assistant where item.stats != nil:
                return false
            case .tool(let tool):
                if tool.status == .running, item.rowID == nil, isComputerTool(tool) { return true }
            default:
                break
            }
        }
        return false
    }

    /// Where a running turn is using a computer, and since when, for the Lock Screen's Stop. A
    /// turn that has used a computer counts until it ends, so the pauses between its tool calls
    /// do not make the Live Activity come and go. Mac: Hermes's `computer_use`, and Nollie
    /// Computer's `mac_*` tools once `mac_start` has come back (while it runs, the person at the
    /// Mac has not said yes yet) and until `mac_done` or a refused call; its own computer: the
    /// `cua` Space tools. The time is when this place's work began in the turn.
    static func workPlace(in items: [TranscriptItem], isRunning: Bool) -> (place: HelperWorkPlace, since: Date)? {
        guard isRunning else { return nil }
        var latest: HelperWorkPlace?
        var since: Date?
        /// Nollie Computer's task is over (or never began) for every older `mac_*` call.
        var macClosed = false
        scan: for item in items.reversed() {
            switch item.kind {
            case .user, .error: break scan
            case .assistant where item.stats != nil: break scan
            case .tool(let tool):
                let name = tool.name.lowercased()
                let place: HelperWorkPlace?
                if name.hasPrefix("mcp__nollie_mac__mac_") {
                    let refused = tool.status == .failed || tool.resultText.map(isFailedOutput) == true
                    if name == "mcp__nollie_mac__mac_done" || refused { macClosed = true; continue }
                    if name == "mcp__nollie_mac__mac_start" && tool.status == .running { continue }
                    place = macClosed ? nil : .mac
                    // Older calls belong to this task until its start, then to an earlier one.
                    if name == "mcp__nollie_mac__mac_start", place != nil {
                        if latest == nil || latest == .mac { latest = .mac; since = item.timestamp }
                        macClosed = true
                        continue
                    }
                } else if tool.status == .failed || !isComputerTool(tool) {
                    place = nil
                } else {
                    place = name == "computer_use" ? .mac : .ownComputer
                }
                guard let place else { continue }
                if latest == nil { latest = place }
                if place == latest { since = item.timestamp }
            default: continue
            }
        }
        guard let latest, let since else { return nil }
        return (latest, since)
    }

    /// Whether a bot is running a command, file or code tool right now. With a computer of its
    /// own, those run on that computer, so its card says Working. A busy chat alone is not.
    static func usesOwnComputer(runtime: GatewayRuntime, profile: String) -> Bool {
        runtime.chats.contains { $0.profileName == profile && usesOwnComputer(in: $0.items, isRunning: $0.isRunning) }
    }

    private static let ownComputerTools: Set<String> = ["terminal", "process", "execute_code", "read_file", "write_file",
                                                        "patch", "search_files"]

    static func usesOwnComputer(in items: [TranscriptItem], isRunning: Bool) -> Bool {
        guard isRunning else { return false }
        for item in items.reversed() {
            switch item.kind {
            case .user, .error: return false
            case .assistant where item.stats != nil: return false
            case .tool(let tool):
                if tool.status == .running, item.rowID == nil, ownComputerTools.contains(tool.name.lowercased()) { return true }
            default: break
            }
        }
        return false
    }

    /// The last screen actually returned by a computer tool, retained while the bot thinks.
    /// Uploaded pictures and images from unrelated tools never stand in for its screen.
    static func latestScreen(in chat: ChatSession) -> MediaRef? {
        latestScreen(in: chat.items)
    }

    static func latestScreen(in items: [TranscriptItem]) -> MediaRef? {
        for item in items.reversed() {
            guard case .tool(let tool) = item.kind, tool.status != .failed,
                  isComputerTool(tool), let output = tool.resultText,
                  !isFailedOutput(output) else { continue }
            if let path = screenshotPath(in: output) { return MediaRef(path: path) }
            // Some gateways keep only the tool's text summary. Limit its path fallback to
            // captures, so a shell command naming an image does not become a screen preview.
            if isCaptureTool(tool), let image = MediaScan.imagePaths(inToolOutput: output).last {
                return image
            }
        }
        return nil
    }

    private static let discoveryActions: Set<String> = [
        "list", "list_apps", "list_windows", "list_displays", "list_spaces", "list_tools",
        "info", "status", "get_info", "get_status", "get_screen_size", "get_computer_info",
        "help", "doctor", "permissions", "get_permissions"
    ]

    private static func isComputerTool(_ tool: ToolActivity) -> Bool {
        let name = tool.name.lowercased()
        if name == "computer_use" {
            let action = arguments(tool)?["action"] as? String ?? ""
            return !discoveryActions.contains(action.lowercased())
        }
        guard name.hasPrefix("mcp__cua__") else { return false }
        let action = String(name.dropFirst("mcp__cua__".count))
        if discoveryActions.contains(action) { return false }
        for prefix in ["computer_", "space_"] where action.hasPrefix(prefix) {
            return !discoveryActions.contains(String(action.dropFirst(prefix.count)))
        }
        return ["create_space", "start_space", "stop_space", "restart_space", "resume_space", "pause_space"].contains(action)
    }

    private static func isCaptureTool(_ tool: ToolActivity) -> Bool {
        let name = tool.name.lowercased()
        if name == "computer_use" {
            guard let args = arguments(tool) else { return true }
            return ["capture", "screenshot", "get_window_state"].contains((args["action"] as? String ?? "").lowercased())
                || args["capture_after"] as? Bool == true
        }
        return ["mcp__cua__computer_screenshot", "mcp__cua__computer_capture",
                "mcp__cua__computer_get_window_state", "mcp__cua__space_screenshot"].contains(name)
    }

    private static func arguments(_ tool: ToolActivity) -> [String: Any]? {
        guard let text = tool.argsText, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func screenshotPath(in output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return screenshotPath(in: value)
    }

    private static func isFailedOutput(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        if object["ok"] as? Bool == false || object["success"] as? Bool == false || object["isError"] as? Bool == true { return true }
        if let error = object["error"], !(error is NSNull) {
            return (error as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
        }
        return false
    }

    private static func screenshotPath(in value: Any) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        for key in ["screenshot_path", "screenshot_file_path"] {
            if let path = object[key] as? String,
               (path.hasPrefix("/") || path.hasPrefix("~/")), MediaRef.isImage(path) { return path }
        }
        for key in ["meta", "structuredContent", "result"] {
            if let nested = object[key], let path = screenshotPath(in: nested) { return path }
        }
        return nil
    }
}
