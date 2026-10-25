import CoreGraphics
import Foundation

/// One thing a bot asks to do in an approved app, as Nollie sees it before anything reaches the app.
struct ComputerAction: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable { case look, click, type, key, scroll }

    /// The element an action lands on: from Nollie's own last look at the window, and for typing
    /// and keys, read again from the app just before.
    struct Target: Equatable, Sendable {
        var role: String?
        var label: String?
        /// The accessibility subrole: a password field is `AXSecureTextField` here, not in the role.
        var subrole: String?
        /// Where the app says the element is (screen points), to tell it from its neighbours.
        var frame: CGRect?
        /// The address a link or other element opens, when it has one (its own, or its link's).
        var url: String?
        /// The element is inside a link a few levels up (a link's text or image).
        var inLink = false
        /// The element is in web content (a web page or an app built on one), which can act on a
        /// key before the app's menus do.
        var inWebContent = false

        var isLink: Bool { role == "AXLink" || inLink || url != nil }
    }

    /// The menu command a key combination runs in the app, read from its menu bar.
    struct Shortcut: Equatable, Sendable {
        var title: String
        /// In the Apple menu (log out, shut down, force quit), which a bot never uses.
        var inAppleMenu = false
    }

    var kind: Kind
    /// Nil when Nollie can't name what a click lands on (a point outside every element it saw).
    var target: Target?
    var text: String?
    var keys: [String] = []
    /// For a key with cmd, ctrl or option: the menu command it runs; nil when it can't be found.
    var shortcut: Shortcut?
}

/// What happens to an action: it runs, the person confirms it first, or it never runs.
enum ComputerDecision: Equatable, Sendable {
    case allow
    /// Ask the person: the sentence for the card, after "<Bot> wants to".
    case confirm(String)
    case refuse(String)
}

/// Plan A2's rules for actions, in code: browsers view-only; passwords and codes never typed by a
/// bot; sending, buying, deleting, uploading, accepting terms, installing and signing in always
/// confirmed by the person, every time. The words are read from the element Nollie saw itself,
/// never from the bot's description of it. When in doubt, it asks.
enum ComputerActionRules {
    static let viewOnly = "Browsers are view-only on your Mac. A bot can use web pages on its own computer."
    static let secret = "Passwords and codes stay with you. Nollie never types into a password field."

    static func decide(_ action: ComputerAction, in app: ComputerTask.App) -> ComputerDecision {
        if action.kind == .look { return .allow }
        if app.viewOnly { return .refuse(viewOnly) }
        let target = action.target
        switch action.kind {
        case .look, .scroll:
            return .allow
        case .type:
            guard let target else { return .refuse(typeNeedsElement) }
            if isSecret(target) { return .refuse(secret) }
            let text = action.text ?? ""
            if text.unicodeScalars.contains(where: { $0 == "\t" }) { return .refuse(oneField) }
            if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" }) {
                return .refuse("That text has control characters in it. Type plain text only.")
            }
            if text.contains(where: \.isNewline) {
                return .confirm("type a line break in \(app.name), which can send or submit")
            }
            return .allow
        case .click:
            guard let target else { return .refuse(unnamedSpot) }
            if isSecret(target) { return .refuse(secret) }
            // A link can open another app (file:, smb:, vnc:, facetime:, settings). Only web and mail
            // links whose address Nollie can read are offered, and the person decides each one.
            // A link preview (a Messages bubble with a page's title and site) may not say it's a link:
            // a button or picture whose words are an address counts as one, with an address unknown.
            if target.isLink { return linkDecision(target, app: app) }
            // Words that look like an address (a link preview that doesn't say it is a link): the person decides.
            if !textRoles.contains(target.role ?? ""), looksLikeAddress(target.label ?? "") {
                return .confirm("click \(quoted(target.label ?? "")) in \(app.name), which may open a link")
            }
            if let risk = risk(in: target.label ?? "") {
                return .confirm("\(risk.verb) in \(app.name): click \(quoted(target.label ?? ""))")
            }
            return .allow
        case .key:
            return keyDecision(action.keys, target: target, shortcut: action.shortcut, app: app)
        }
    }

    static let unnamedSpot = "Nollie couldn't tell what's at that spot, so it didn't click. Look again and use an element's token."
    static let unknownLink = "Nollie couldn't see where that link goes, so it didn't click it."
    static let otherLink = "That link opens something other than a web page or an email, so it stays with you."
    static let linkSchemes: Set<String> = ["http", "https", "mailto"]
    static let lookalike = "That link's address uses letters that can look like another site's, so it stays with you."
    static let hiddenUser = "That link hides where it really goes, so it stays with you."

    /// A link: refused unless it is a web or mail link whose address Nollie can read, and then the
    /// person decides, seeing the site first and the whole address after it.
    static func linkDecision(_ target: ComputerAction.Target, app: ComputerTask.App) -> ComputerDecision {
        guard let url = target.url, let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased() else {
            return .refuse(unknownLink)
        }
        guard linkSchemes.contains(scheme) else { return .refuse(otherLink) }
        if parts.user != nil || parts.password != nil { return .refuse(hiddenUser) }
        // The site exactly as written, never decoded: a lookalike letter or a hidden direction mark
        // can't pass for a familiar name.
        let place = scheme == "mailto" ? parts.percentEncodedPath : (parts.encodedHost ?? "")
        guard !place.isEmpty, place.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0 != "%" }) else { return .refuse(unknownLink) }
        guard !place.lowercased().split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) else { return .refuse(lookalike) }
        let shown = url.count > 200 ? String(url.prefix(200)) + "\u{2026}" : url
        return .confirm("open a link to \(place) in \(app.name): \u{201C}\(shown)\u{201D}")
    }

    /// Words that hold a web address or a site's name, like "example.com", "bit.ly/x" or "https://…",
    /// as macOS's own link finder reads them.
    static func looksLikeAddress(_ label: String) -> Bool {
        let lower = label.lowercased()
        if lower.contains("://") || lower.contains("www.") { return true }
        guard !label.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return false }
        // Web addresses only, with a path or several parts: not an email address or a file name.
        return detector.matches(in: label, range: NSRange(label.startIndex..., in: label)).contains { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: label) else { return false }
            let written = label[range]
            return written.contains("/") || written.split(separator: ".").count >= 3 || [".com", ".org", ".net"].contains { written.lowercased().hasSuffix($0) }
        }
    }
    static let typeNeedsElement = "Type into an element from your latest mac_look, by its token."
    static let oneField = "Type into one field at a time: no tabs in the text."

    // MARK: Words

    struct Risk: Equatable { var verb: String }

    /// The risky words, matched as whole words or phrases of the element's label.
    static let risks: [(verb: String, words: [String])] = [
        ("send something", ["send", "send now", "reply", "reply all", "forward", "post", "publish", "share", "submit",
                            "tweet", "comment", "invite"]),
        ("buy something", ["buy", "buy now", "purchase", "order now", "place order", "checkout", "check out", "pay",
                           "pay now", "subscribe", "upgrade", "donate", "book now", "reserve", "rent", "add to cart", "add to bag",
                           "confirm purchase", "confirm payment"]),
        ("delete something", ["delete", "remove", "trash", "move to trash", "erase", "discard", "clear all", "clear history",
                              "empty trash", "uninstall", "wipe", "revoke", "delete all", "permanently delete"]),
        ("upload something", ["upload", "attach", "attach file", "choose file", "add attachment"]),
        ("accept terms", ["accept", "agree", "i agree", "accept all", "allow", "consent", "accept terms",
                          "terms", "i accept", "continue and accept"]),
        ("install something", ["install", "get", "update", "download", "open anyway", "install update"]),
        ("open something", ["open", "open with", "show in finder", "show package contents", "run"]),
        ("sign in", ["sign in", "log in", "login", "sign up", "create account", "verify", "authorize"]),
    ]

    /// The kinds of button that send, pay, post or delete, worth a second look on the card.
    static let checkedVerbs: Set<String> = ["send something", "buy something", "delete something"]

    /// "You're about to press “Send”.": for a confirmed click on a button that sends, pays, posts
    /// or deletes, named by Nollie's own reading of it. Nil for anything else, links included.
    static func check(for action: ComputerAction) -> String? {
        guard action.kind == .click, let target = action.target, !target.isLink, !isSecret(target) else { return nil }
        let label = (target.label ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !label.isEmpty, textRoles.contains(target.role ?? "") || !looksLikeAddress(label),
              let risk = risk(in: label), checkedVerbs.contains(risk.verb) else { return nil }
        return "You're about to press \u{201C}\(label.prefix(60))\u{201D}."
    }

    static func risk(in label: String) -> Risk? {
        let normalized = " " + label.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") + " "
        for risk in risks where risk.words.contains(where: { normalized.contains(" \($0) ") }) {
            return Risk(verb: risk.verb)
        }
        return nil
    }

    static func isSecret(_ target: ComputerAction.Target) -> Bool {
        isSecret(role: target.role ?? "", label: target.label ?? "", subrole: target.subrole ?? "")
    }

    static func isSecret(role: String, label: String, subrole: String = "") -> Bool {
        if role.localizedCaseInsensitiveContains("secure") || subrole.localizedCaseInsensitiveContains("secure") { return true }
        let words = " " + label.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") + " "
        return [" password ", " passcode ", " passphrase ", " pin ", " verification code ", " security code ",
                " one time code ", " 2fa ", " cvv ", " cvc ", " card number "].contains(where: words.contains)
    }

    // MARK: Keys

    /// Keys as the driver reads them (its `canonical_key_name`): trimmed, lower case, spaces, `_`
    /// and `-` dropped from names, aliases folded, and `+` splitting a combination. Nollie decides
    /// on these and sends only these, so it judges exactly the key the app gets.
    static func canonicalKeys(_ keys: [String]) -> (modifiers: [String], key: String)? {
        let parts = keys.flatMap { $0.count > 1 && $0.contains("+") ? $0.split(separator: "+").map(String.init) : [$0] }
        var modifiers: [String] = []
        var plain: [String] = []
        for part in parts {
            let name = canonicalKey(part)
            if let modifier = modifierNames[name] {
                if !modifiers.contains(modifier) { modifiers.append(modifier) }
            } else if knownKeys.contains(name) {
                plain.append(name)
            } else {
                return nil
            }
        }
        guard plain.count == 1, let key = plain.first else { return nil }
        return (modifierOrder.filter(modifiers.contains), key)
    }

    static func canonicalKey(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard lower.count >= 2 else { return lower }
        let compact = String(lower.filter { $0 != " " && $0 != "_" && $0 != "-" })
        switch compact {
        case "pgdn", "pgdown", "pagedn": return "pagedown"
        case "pgup": return "pageup"
        case "arrowleft", "leftarrow": return "left"
        case "arrowright", "rightarrow": return "right"
        case "arrowup", "uparrow": return "up"
        case "arrowdown", "downarrow": return "down"
        case "forwarddelete", "fwddelete", "deleteforward", "del": return "forward_delete"
        case "bksp", "backspace": return "delete"
        case "kpenter", "numpadenter", "enter": return "return"
        case "esc": return "escape"
        default: return compact
        }
    }

    static let modifierNames = ["cmd": "cmd", "command": "cmd", "super": "cmd", "meta": "cmd", "win": "cmd",
                                "shift": "shift", "option": "option", "alt": "option", "ctrl": "ctrl", "control": "ctrl"]
    static let modifierOrder = ["ctrl", "option", "shift", "cmd"]
    /// The keys a bot may press. No function keys (they reach Mission Control and the system), no
    /// Caps Lock, no Fn.
    static let knownKeys: Set<String> = Set("abcdefghijklmnopqrstuvwxyz0123456789=-[]';,./\\`".map(String.init))
        .union(["return", "tab", "space", "delete", "forward_delete", "escape", "home", "end", "pageup", "pagedown",
                "left", "right", "up", "down"])
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static let navigationKeys: Set<String> = ["tab", "escape", "home", "end", "pageup", "pagedown", "left", "right", "up", "down"]
    /// Menu commands a bot may run unasked, by the start of their title.
    static let safeCommands = ["find", "undo", "select all", "copy", "new"]
    static let unknownShortcut = "Nollie couldn't find what that shortcut does, so it didn't press it."
    static let webShortcut = "Shortcuts don't go to web content, which can do anything with them. Use the app's buttons instead."
    static let notATextField = "Keys that type go only into a text field. Click the field first, or use mac_type."

    /// A key goes where focus is (`target`, read live). A combination with cmd, ctrl or option
    /// runs a menu command, judged by its title; a plain character types, under the typing rules.
    static func keyDecision(_ keys: [String], target: ComputerAction.Target? = nil, shortcut: ComputerAction.Shortcut? = nil,
                            app: ComputerTask.App) -> ComputerDecision {
        guard let (held, key) = canonicalKeys(keys) else {
            return .refuse("Press one ordinary key at a time, with or without cmd, shift, option or ctrl.")
        }
        if let target, isSecret(target), !["tab", "escape"].contains(key) { return .refuse(secret) }
        // Return or Space on a link opens it, the same as a click.
        if key == "return" || key == "space", let target, target.isLink {
            return linkDecision(target, app: app)
        }
        if key == "return" { return .confirm("press Return in \(app.name), which can send or submit") }
        if held.contains("cmd") || held.contains("ctrl") || held.contains("option") {
            // A web page gets the key before the menus do, so the menu item says nothing about it.
            if target?.inWebContent == true { return .refuse(webShortcut) }
            guard let shortcut else { return .refuse(unknownShortcut) }
            if shortcut.inAppleMenu { return .refuse("That shortcut belongs to the Apple menu, which stays with you.") }
            let title = shortcut.title.trimmingCharacters(in: .whitespaces)
            if title.localizedCaseInsensitiveContains("paste") { return .confirm("paste what you last copied into \(app.name)") }
            if let risk = risk(in: title) { return .confirm("\(risk.verb) in \(app.name): \(quoted(title))") }
            let lower = title.lowercased()
            if safeCommands.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + "\u{2026}") }) { return .allow }
            return .confirm("use \(quoted(title)) in \(app.name)")
        }
        if key == "delete" || key == "forward_delete" {
            if let role = target?.role, textRoles.contains(role) { return .allow }
            return .confirm("press Delete in \(app.name), which can delete what's selected")
        }
        if navigationKeys.contains(key) { return .allow }
        // A character or Space: the same as typing it.
        guard let role = target?.role, textRoles.contains(role) else { return .refuse(notATextField) }
        return .allow
    }

    static func quoted(_ label: String) -> String {
        let short = label.count > 40 ? String(label.prefix(40)) + "…" : label
        return "\u{201C}\(short)\u{201D}"
    }
}
