import Foundation
import NollieCore

/// Display words for a tool step; the activity keeps its original name and arguments.
struct ToolStepPresentation: Sendable {
    let title: String
    let symbol: String
    let detail: String?

    init(_ activity: ToolActivity) {
        let action = Action(activity.name)
        title = action.title(activity.status)
        symbol = action.symbol
        if let context = activity.context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detail = context
        } else if let text = activity.argsText, let data = text.data(using: .utf8),
                  let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            detail = action.detailKeys.compactMap { args[$0] as? String }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        } else {
            detail = nil
        }
    }

    static func summary(_ steps: [ToolActivity]) -> String {
        var order: [Action] = []
        var statuses: [Action: [ToolActivity.Status]] = [:]
        for step in steps {
            let action = Action(step.name)
            if statuses[action] == nil { order.append(action) }
            statuses[action, default: []].append(step.status)
        }
        guard !order.isEmpty else { return "Steps" }
        let descriptions = order.prefix(2).enumerated().map { index, action in
            let text = action.summary(statuses[action] ?? [])
            if index > 0, !action.isUnknown { return text.prefix(1).lowercased() + text.dropFirst() }
            return text
        }
        return descriptions.joined(separator: ", ") + (order.count > 2 ? " + \(order.count - 2) more" : "")
    }

    static func symbols(_ steps: [ToolActivity]) -> [String] {
        var result: [String] = []
        for step in steps {
            let symbol = Action(step.name).symbol
            if !result.contains(symbol) { result.append(symbol) }
            if result.count == 3 { break }
        }
        return result
    }

    private enum Action: Hashable {
        case read, write, edit, find, command, searchWeb, readWeb, computer, signIn, unknown(String)
        /// The Mac's calendar, reminders or contacts: a look, or a change that waits for a yes.
        case appleData(AppleDataArea, change: Bool)

        init(_ name: String) {
            let pieces = name.components(separatedBy: "__")
            let leaf = pieces.count >= 3 && pieces[0].lowercased() == "mcp"
                ? pieces.dropFirst(2).joined(separator: "__") : name
            let key = leaf.lowercased()
            switch key {
            case "read", "read_file", "readfile", "read_text_file", "read_file_lines": self = .read
            case "write", "write_file", "writefile", "write_text_file": self = .write
            case "edit", "edit_file", "editfile", "patch", "patch_file", "apply_patch": self = .edit
            case "search_files", "search_file", "file_search", "grep", "glob": self = .find
            case "terminal", "bash", "shell", "run_command", "exec_command", "execute_command": self = .command
            case "web_search", "websearch", "search_web": self = .searchWeb
            case "web_extract", "web_fetch", "fetch_url": self = .readWeb
            case "computer_use": self = .computer
            case "request_sign_in": self = .signIn
            default:
                if let tool = AppleDataTool(rawValue: name) {
                    self = .appleData(tool.area, change: tool.isWrite)
                    return
                }
                if name.lowercased().hasPrefix("mcp__cua__"), key.hasPrefix("computer_") || key.hasPrefix("space_") {
                    self = .computer
                } else {
                    let words = leaf.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
                        .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
                        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    self = .unknown(words.isEmpty ? "Tool" : words.prefix(1).uppercased() + words.dropFirst())
                }
            }
        }

        var isUnknown: Bool { if case .unknown = self { true } else { false } }

        func title(_ status: ToolActivity.Status) -> String {
            let words: (base: String, running: String, done: String)
            switch self {
            case .read: words = ("Read file", "Reading file", "Read file")
            case .write: words = ("Write file", "Writing file", "Wrote file")
            case .edit: words = ("Edit file", "Editing file", "Edited file")
            case .find: words = ("Search files", "Searching files", "Searched files")
            case .command: words = ("Run command", "Running command", "Ran command")
            case .searchWeb: words = ("Search web", "Searching web", "Searched web")
            case .readWeb: words = ("Read page", "Reading page", "Read page")
            case .computer: words = ("Use computer", "Using computer", "Used computer")
            case .signIn: words = ("Sign in", "Signing in", "Asked to sign in")
            case let .appleData(area, change):
                let what = "your " + area.title.lowercased()
                words = change ? ("Change \(what)", "Changing \(what)", "Asked to change \(what)")
                               : ("Look at \(what)", "Looking at \(what)", "Looked at \(what)")
            case .unknown(let name): words = (name, "Running \(name)", name)
            }
            switch status {
            case .running: return words.running
            case .done: return words.done
            case .failed: return words.base
            }
        }

        func summary(_ statuses: [ToolActivity.Status]) -> String {
            let words: (neutral: String, running: String, done: String)
            switch self {
            case .read: words = ("File reads", "Reading files", "Read files")
            case .write: words = ("File writes", "Writing files", "Wrote files")
            case .edit: words = ("File edits", "Editing files", "Edited files")
            case .find: words = ("File searches", "Searching files", "Searched files")
            case .command: words = ("Commands", "Running commands", "Ran commands")
            case .searchWeb: words = ("Web searches", "Searching the web", "Searched the web")
            case .readWeb: words = ("Web pages", "Reading pages", "Read pages")
            case .computer: words = ("Computer steps", "Using the computer", "Used the computer")
            case .signIn: words = ("Sign-ins", "Signing in", "Asked to sign in")
            case let .appleData(area, _): words = (area.title, area.title, area.title)
            case .unknown(let name): words = (name, name, name)
            }
            if statuses.contains(.failed) { return words.neutral }
            return statuses.contains(.running) ? words.running : words.done
        }

        var symbol: String {
            switch self {
            case .read: "doc.text"
            case .write, .edit: "square.and.pencil"
            case .find: "doc.text.magnifyingglass"
            case .command: "terminal"
            case .searchWeb, .readWeb: "globe"
            case .computer: "desktopcomputer"
            case .signIn: "key"
            case let .appleData(area, _): area.symbol
            case .unknown: "gearshape"
            }
        }

        var detailKeys: [String] {
            let common = ["path", "file_path", "filePath", "filename", "query", "pattern", "url", "command", "cmd"]
            switch self {
            case .command: return ["command", "cmd"] + common
            case .searchWeb, .find: return ["query", "pattern"] + common
            case .readWeb: return ["url"] + common
            default: return common
            }
        }
    }
}
