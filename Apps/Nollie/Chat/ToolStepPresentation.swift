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
        guard !order.isEmpty else { return String(localized: "Steps", comment: "A bot's steps in a chat; a noun") }
        let descriptions = order.prefix(2).enumerated().map { index, action in
            let text = action.summary(statuses[action] ?? [])
            if index > 0, !action.isUnknown { return text.prefix(1).lowercased() + text.dropFirst() }
            return text
        }
        guard descriptions.count > 1 else { return descriptions[0] }
        let (first, second) = (descriptions[0], descriptions[1])
        guard order.count > 2 else { return String(localized: "\(first), \(second)", comment: "Two kinds of steps a bot took") }
        return String(localized: "\(first), \(second) + \(order.count - 2) more", comment: "Two kinds of steps a bot took, then how many other kinds")
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
        case read, write, edit, find, command, searchWeb, readWeb, computer, signIn, pay, cards, unknown(String)
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
            case "request_payment": self = .pay
            case "payment_cards": self = .cards
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
                    self = .unknown(words.isEmpty ? String(localized: "Tool", comment: "A tool a bot used, when its name is unknown")
                                                  : words.prefix(1).uppercased() + words.dropFirst())
                }
            }
        }

        var isUnknown: Bool { if case .unknown = self { true } else { false } }

        func title(_ status: ToolActivity.Status) -> String {
            let words: (base: String, running: String, done: String)
            switch self {
            case .read:
                words = (String(localized: "Read file", comment: "A step a bot takes, as a name"),
                         String(localized: "Reading file", comment: "A step a bot takes, while it runs"),
                         String(localized: "Read file", comment: "A step a bot took, past tense"))
            case .write:
                words = (String(localized: "Write file", comment: "A step a bot takes, as a name"),
                         String(localized: "Writing file", comment: "A step a bot takes, while it runs"),
                         String(localized: "Wrote file", comment: "A step a bot took, past tense"))
            case .edit:
                words = (String(localized: "Edit file", comment: "A step a bot takes, as a name"),
                         String(localized: "Editing file", comment: "A step a bot takes, while it runs"),
                         String(localized: "Edited file", comment: "A step a bot took, past tense"))
            case .find:
                words = (String(localized: "Search files", comment: "A step a bot takes, as a name"),
                         String(localized: "Searching files", comment: "A step a bot takes, while it runs"),
                         String(localized: "Searched files", comment: "A step a bot took, past tense"))
            case .command:
                words = (String(localized: "Run command", comment: "A step a bot takes, as a name"),
                         String(localized: "Running command", comment: "A step a bot takes, while it runs"),
                         String(localized: "Ran command", comment: "A step a bot took, past tense"))
            case .searchWeb:
                words = (String(localized: "Search web", comment: "A step a bot takes, as a name"),
                         String(localized: "Searching web", comment: "A step a bot takes, while it runs"),
                         String(localized: "Searched web", comment: "A step a bot took, past tense"))
            case .readWeb:
                words = (String(localized: "Read page", comment: "A step a bot takes, as a name"),
                         String(localized: "Reading page", comment: "A step a bot takes, while it runs"),
                         String(localized: "Read page", comment: "A step a bot took, past tense"))
            case .computer:
                words = (String(localized: "Use computer", comment: "A step a bot takes, as a name"),
                         String(localized: "Using computer", comment: "A step a bot takes, while it runs"),
                         String(localized: "Used computer", comment: "A step a bot took, past tense"))
            case .signIn:
                words = (String(localized: "Sign in", comment: "A step a bot takes, as a name"),
                         String(localized: "Signing in", comment: "A step a bot takes, while it runs"),
                         String(localized: "Asked to sign in", comment: "A step a bot took, past tense"))
            case .pay:
                words = (String(localized: "Pay", comment: "A step a bot takes, as a name"),
                         String(localized: "Asking to pay", comment: "A step a bot takes, while it runs"),
                         String(localized: "Asked to pay", comment: "A step a bot took, past tense"))
            case .cards:
                words = (String(localized: "Check cards", comment: "A step a bot takes, as a name"),
                         String(localized: "Checking your cards", comment: "A step a bot takes, while it runs"),
                         String(localized: "Checked your cards", comment: "A step a bot took, past tense"))
            case let .appleData(area, change):
                words = change ? Self.changeWords(area) : Self.lookWords(area)
            case .unknown(let name):
                words = (name, String(localized: "Running \(name)", comment: "A bot is running a tool; the tool's name follows"), name)
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
            case .read:
                words = (String(localized: "File reads", comment: "A step a bot takes, as a name"),
                         String(localized: "Reading files", comment: "A step a bot takes, while it runs"),
                         String(localized: "Read files", comment: "A step a bot took, past tense"))
            case .write:
                words = (String(localized: "File writes", comment: "A step a bot takes, as a name"),
                         String(localized: "Writing files", comment: "A step a bot takes, while it runs"),
                         String(localized: "Wrote files", comment: "A step a bot took, past tense"))
            case .edit:
                words = (String(localized: "File edits", comment: "A step a bot takes, as a name"),
                         String(localized: "Editing files", comment: "A step a bot takes, while it runs"),
                         String(localized: "Edited files", comment: "A step a bot took, past tense"))
            case .find:
                words = (String(localized: "File searches", comment: "A step a bot takes, as a name"),
                         String(localized: "Searching files", comment: "A step a bot takes, while it runs"),
                         String(localized: "Searched files", comment: "A step a bot took, past tense"))
            case .command:
                words = (String(localized: "Commands", comment: "A step a bot takes, as a name"),
                         String(localized: "Running commands", comment: "A step a bot takes, while it runs"),
                         String(localized: "Ran commands", comment: "A step a bot took, past tense"))
            case .searchWeb:
                words = (String(localized: "Web searches", comment: "A step a bot takes, as a name"),
                         String(localized: "Searching the web", comment: "A step a bot takes, while it runs"),
                         String(localized: "Searched the web", comment: "A step a bot took, past tense"))
            case .readWeb:
                words = (String(localized: "Web pages", comment: "A step a bot takes, as a name"),
                         String(localized: "Reading pages", comment: "A step a bot takes, while it runs"),
                         String(localized: "Read pages", comment: "A step a bot took, past tense"))
            case .computer:
                words = (String(localized: "Computer steps", comment: "A step a bot takes, as a name"),
                         String(localized: "Using the computer", comment: "A step a bot takes, while it runs"),
                         String(localized: "Used the computer", comment: "A step a bot took, past tense"))
            case .signIn:
                words = (String(localized: "Sign-ins", comment: "A step a bot takes, as a name"),
                         String(localized: "Signing in", comment: "A step a bot takes, while it runs"),
                         String(localized: "Asked to sign in", comment: "A step a bot took, past tense"))
            case .pay:
                words = (String(localized: "Payments", comment: "A step a bot takes, as a name"),
                         String(localized: "Asking to pay", comment: "A step a bot takes, while it runs"),
                         String(localized: "Asked to pay", comment: "A step a bot took, past tense"))
            case .cards:
                words = (String(localized: "Cards", comment: "A step a bot takes, as a name"),
                         String(localized: "Checking your cards", comment: "A step a bot takes, while it runs"),
                         String(localized: "Checked your cards", comment: "A step a bot took, past tense"))
            case let .appleData(area, _): words = (area.title, area.title, area.title)
            case .unknown(let name): words = (name, name, name)
            }
            if statuses.contains(.failed) { return words.neutral }
            return statuses.contains(.running) ? words.running : words.done
        }

        /// Changing the Mac's calendar, reminders or contacts: as a name, while it runs, once asked.
        private static func changeWords(_ area: AppleDataArea) -> (String, String, String) {
            switch area {
            case .calendar:
                (String(localized: "Change your calendar", comment: "A step a bot takes, as a name"),
                 String(localized: "Changing your calendar", comment: "A step a bot takes, while it runs"),
                 String(localized: "Asked to change your calendar", comment: "A step a bot took, past tense"))
            case .reminders:
                (String(localized: "Change your reminders", comment: "A step a bot takes, as a name"),
                 String(localized: "Changing your reminders", comment: "A step a bot takes, while it runs"),
                 String(localized: "Asked to change your reminders", comment: "A step a bot took, past tense"))
            case .contacts:
                (String(localized: "Change your contacts", comment: "A step a bot takes, as a name"),
                 String(localized: "Changing your contacts", comment: "A step a bot takes, while it runs"),
                 String(localized: "Asked to change your contacts", comment: "A step a bot took, past tense"))
            }
        }

        /// Looking at the Mac's calendar, reminders or contacts: as a name, while it runs, once done.
        private static func lookWords(_ area: AppleDataArea) -> (String, String, String) {
            switch area {
            case .calendar:
                (String(localized: "Look at your calendar", comment: "A step a bot takes, as a name"),
                 String(localized: "Looking at your calendar", comment: "A step a bot takes, while it runs"),
                 String(localized: "Looked at your calendar", comment: "A step a bot took, past tense"))
            case .reminders:
                (String(localized: "Look at your reminders", comment: "A step a bot takes, as a name"),
                 String(localized: "Looking at your reminders", comment: "A step a bot takes, while it runs"),
                 String(localized: "Looked at your reminders", comment: "A step a bot took, past tense"))
            case .contacts:
                (String(localized: "Look at your contacts", comment: "A step a bot takes, as a name"),
                 String(localized: "Looking at your contacts", comment: "A step a bot takes, while it runs"),
                 String(localized: "Looked at your contacts", comment: "A step a bot took, past tense"))
            }
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
            case .pay, .cards: "creditcard"
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
