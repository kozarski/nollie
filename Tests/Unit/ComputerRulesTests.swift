#if os(macOS)
import Foundation
import Testing
import CryptoKit
import NollieCore
@testable import Nollie

/// Plan A2's safety rules for using this Mac, as code: which apps never, which only looked at,
/// which actions the person confirms, and the limits on a task.
@Suite struct ComputerRulesTests {
    private func info(_ id: String, _ name: String, category: String? = nil, web: Bool = false, signer: String? = nil) -> ComputerAppInfo {
        ComputerAppInfo(bundleID: id, name: name, category: category, opensWebPages: web, signer: signer)
    }

    /// Nollie Computer opens only apps a bot may use; Cua Spaces is never one of them, so Nollie never
    /// opens it (its window and menu bar item stay closed; only Cua's background part runs).
    @Test func cuaSpacesIsNeverOpenedOrUsed() {
        for signer in [nil, "YCK386LBJ7", "apple"] as [String?] {
            let cua = info("com.trycua.spaces.macos", "Cua Spaces", signer: signer)
            #expect(!ComputerAppRules.access(for: cua, ownBundleID: "com.coreykozarski.nollie").isAllowed)
        }
        #expect(!ComputerAppRules.usable.contains("com.trycua.spaces.macos"))
    }

    @Test func neverNollieTerminalsPasswordsSettingsOrMoney() {
        let never: [(ComputerAppInfo, String)] = [
            (info("com.coreykozarski.nollie", "Nollie"), ComputerAppRules.nollie),
            (info("com.coreykozarski.nollie.demo", "Nollie Demo"), ComputerAppRules.nollie),
            (info("com.example.anything", "Something"), ComputerAppRules.nollie),
            (info("com.apple.Terminal", "Terminal"), ComputerAppRules.commands),
            (info("com.googlecode.iterm2", "iTerm"), ComputerAppRules.commands),
            (info("com.mitchellh.ghostty", "Ghostty"), ComputerAppRules.commands),
            (info("com.jetbrains.pycharm", "PyCharm"), ComputerAppRules.commands),
            (info("com.microsoft.VSCode", "Visual Studio Code"), ComputerAppRules.commands),
            (info("com.apple.ScriptEditor2", "Script Editor"), ComputerAppRules.commands),
            (info("org.example.unknownterm", "Super Terminal"), ComputerAppRules.commands),
            (info("com.1password.1password", "1Password"), ComputerAppRules.passwords),
            (info("com.apple.Passwords", "Passwords"), ComputerAppRules.passwords),
            (info("com.apple.keychainaccess", "Keychain Access"), ComputerAppRules.passwords),
            (info("org.example.vault", "Password Vault"), ComputerAppRules.passwords),
            (info("com.apple.systempreferences", "System Settings"), ComputerAppRules.settings),
            (info("com.example.bank", "My Bank", category: "public.app-category.finance"), ComputerAppRules.money),
            (info("com.ledger.live", "Ledger Live"), ComputerAppRules.money),
            (info("org.example.coins", "Crypto Tracker"), ComputerAppRules.money),
            (info("com.example.banktivity", "Banktivity"), ComputerAppRules.money),
        ]
        for (app, reason) in never {
            #expect(ComputerAppRules.access(for: app, ownBundleID: "com.example.anything") == .never(reason), "\(app.name)")
        }
        #expect(ComputerAppRules.access(for: info("", "Mystery")) != .use)
    }

    @Test func browsersAreViewOnlyAndOrdinaryAppsUsable() {
        #expect(ComputerAppRules.access(for: info("com.apple.Safari", "Safari")) == .viewOnly)
        #expect(ComputerAppRules.access(for: info("com.google.Chrome", "Google Chrome")) == .viewOnly)
        #expect(ComputerAppRules.access(for: info("org.example.newbrowser", "Newt", web: true)) == .viewOnly)
        for (id, name, signer) in [("com.apple.Notes", "Notes", "apple"), ("com.apple.mail", "Mail", "apple"),
                                   ("com.apple.iCal", "Calendar", "apple"), ("com.apple.iWork.Pages", "Pages", "74J34U3R6X"),
                                   ("com.apple.TextEdit", "TextEdit", "apple"), ("com.tinyspeck.slackmacgap", "Slack", "BQR82RBBHL")] {
            #expect(ComputerAppRules.access(for: info(id, name, signer: signer)) == .use, "\(name)")
            // The same bundle id signed by anyone else, or not at all, is someone else's app.
            #expect(ComputerAppRules.access(for: info(id, name, signer: "ABCDE12345")) == .never(ComputerAppRules.notGenuine), "\(name)")
            #expect(ComputerAppRules.access(for: info(id, name)) == .never(ComputerAppRules.notGenuine), "\(name)")
        }
        // Use is an allowlist: anything else stays with the person, including apps with macros or plugins.
        #expect(ComputerAppRules.access(for: info("com.example.unknown", "Some App")) == .never(ComputerAppRules.notOffered))
        for (id, name, signer) in [("com.microsoft.Word", "Microsoft Word", "UBF8T346G9"), ("com.microsoft.Excel", "Microsoft Excel", "UBF8T346G9"),
                                   ("com.microsoft.Powerpoint", "Microsoft PowerPoint", "UBF8T346G9"), ("md.obsidian", "Obsidian", "6JSW4SJWN9")] {
            #expect(ComputerAppRules.access(for: info(id, name, signer: signer)) == .never(ComputerAppRules.notOffered), "\(name)")
        }
        for (id, name) in [("com.apple.finder", "Finder"), ("com.apple.ActivityMonitor", "Activity Monitor"),
                           ("com.apple.DiskUtility", "Disk Utility"), ("com.apple.installer", "Installer")] {
            #expect(ComputerAppRules.access(for: info(id, name)) == .never(ComputerAppRules.system), "\(name)")
        }
        for (id, name) in [("org.vim.MacVim", "MacVim"), ("org.gnu.Emacs", "Emacs"), ("com.raycast.macos", "Raycast"),
                           ("com.runningwithcrayons.Alfred", "Alfred"), ("org.hammerspoon.Hammerspoon", "Hammerspoon"),
                           ("com.docker.docker", "Docker Desktop"), ("dev.kdrag0n.MacVirt", "OrbStack"),
                           ("com.stairways.keyboardmaestro.editor", "Keyboard Maestro"), ("org.python.IDLE", "IDLE"),
                           ("com.example.tool", "Anything", )] {
            let category = name == "Anything" ? "public.app-category.developer-tools" : nil
            #expect(ComputerAppRules.access(for: info(id, name, category: category)) == .never(ComputerAppRules.commands), "\(name)")
        }
        // Whole words only: "Notes" isn't "note", "Pinboard" isn't "pin".
        #expect(!ComputerAppRules.matches("pinboard", ComputerAppRules.moneyWords))
        #expect(ComputerAppRules.matches("ledger live", ComputerAppRules.moneyWords))
    }

    private let notes = ComputerTask.App(info: ComputerAppInfo(bundleID: "com.apple.Notes", name: "Notes"), viewOnly: false)
    private let safari = ComputerTask.App(info: ComputerAppInfo(bundleID: "com.apple.Safari", name: "Safari"), viewOnly: true)

    private func click(_ label: String?, role: String = "AXButton") -> ComputerAction {
        ComputerAction(kind: .click, target: label.map { .init(role: role, label: $0) })
    }

    @Test func browsersOnlyLook() {
        #expect(ComputerActionRules.decide(ComputerAction(kind: .look), in: safari) == .allow)
        for kind in [ComputerAction.Kind.click, .type, .key, .scroll] {
            #expect(ComputerActionRules.decide(ComputerAction(kind: kind, target: .init(label: "Reader"), keys: ["down"]), in: safari)
                == .refuse(ComputerActionRules.viewOnly))
        }
    }

    @Test func riskyClicksAreConfirmedEveryTime() {
        let cases: [(String, String)] = [
            ("Send", "send something"), ("Reply All", "send something"), ("Post", "send something"),
            ("Buy Now", "buy something"), ("Place order", "buy something"), ("Checkout", "buy something"),
            ("Move to Trash", "delete something"), ("Delete Note", "delete something"), ("Remove", "delete something"),
            ("Upload photos", "upload something"), ("Attach File…", "upload something"),
            ("I Agree", "accept terms"), ("Accept All Cookies", "accept terms"),
            ("Install", "install something"), ("Get", "install something"),
            ("Sign In", "sign in"), ("Log in with Apple", "sign in"), ("Open", "open something"), ("Show in Finder", "open something"),
        ]
        for (label, verb) in cases {
            #expect(ComputerActionRules.decide(click(label), in: notes) == .confirm("\(verb) in Notes: click \u{201C}\(label)\u{201D}"), "\(label)")
        }
        for label in ["New Note", "Bold", "Sort Order", "Address Book"] {
            #expect(ComputerActionRules.decide(click(label), in: notes) == .allow, "\(label)")
        }
        // A spot Nollie can't name isn't clicked at all: it could be a link.
        #expect(ComputerActionRules.decide(click(nil), in: notes) == .refuse(ComputerActionRules.unnamedSpot))
    }

    /// A button that sends, pays, posts or deletes gets a "You're about to press" line on its card,
    /// named from Nollie's own reading of it; other confirmed clicks and links don't.
    @Test func sendPayPostAndDeleteButtonsGetACheckLine() {
        for label in ["Send", "Pay now", "Delete", "Post", "Submit", "Publish", "Place order", "Move to Trash"] {
            #expect(ComputerActionRules.check(for: click(label)) == "You're about to press \u{201C}\(label)\u{201D}.", "\(label)")
        }
        for label in ["Open", "Downloads", "Install", "Sign In", "I Agree", "Bold", "https://example.com/send"] {
            #expect(ComputerActionRules.check(for: click(label)) == nil, "\(label)")
        }
        #expect(ComputerActionRules.check(for: ComputerAction(kind: .click, target: .init(role: "AXLink", label: "Send", url: "https://example.com"))) == nil)
        #expect(ComputerActionRules.check(for: ComputerAction(kind: .click, target: .init(role: "AXStaticText", label: "Delete", inLink: true))) == nil)
        #expect(ComputerActionRules.check(for: ComputerAction(kind: .key, target: .init(role: "AXButton", label: "Send"), keys: ["return"])) == nil)
        #expect(ComputerActionRules.check(for: click(nil)) == nil)
        // A long label is cut to 60 characters, with its spacing made plain.
        let long = "Send " + String(repeating: "a", count: 80)
        #expect(ComputerActionRules.check(for: click(long)) == "You're about to press \u{201C}\(long.prefix(60))\u{201D}.")
        #expect(ComputerActionRules.check(for: click("  Send\n now ")) == "You're about to press \u{201C}Send now\u{201D}.")
    }

    @Test func passwordsAndCodesAreNeverTyped() {
        // A real password field is an AXTextField whose subrole says it is secure, often unlabelled.
        let secure = ComputerAction(kind: .type, target: .init(role: "AXTextField", label: nil, subrole: "AXSecureTextField"), text: "hunter2")
        #expect(ComputerActionRules.decide(secure, in: notes) == .refuse(ComputerActionRules.secret))
        let keyed = ComputerAction(kind: .key, target: .init(role: "AXTextField", subrole: "AXSecureTextField"), keys: ["h"])
        #expect(ComputerActionRules.decide(keyed, in: notes) == .refuse(ComputerActionRules.secret))
        // Typing needs an element Nollie knows; text never moves between fields or presses Return unasked.
        #expect(ComputerActionRules.decide(ComputerAction(kind: .type, text: "x"), in: notes) == .refuse(ComputerActionRules.typeNeedsElement))
        let body = ComputerAction.Target(role: "AXTextArea", label: "Body")
        #expect(ComputerActionRules.decide(ComputerAction(kind: .type, target: body, text: "user\tpass"), in: notes) == .refuse(ComputerActionRules.oneField))
        #expect(ComputerActionRules.decide(ComputerAction(kind: .type, target: body, text: "hi\n"), in: notes)
            == .confirm("type a line break in Notes, which can send or submit"))
        #expect(ComputerActionRules.decide(ComputerAction(kind: .type, target: body, text: "a\r\nb"), in: notes)
            == .confirm("type a line break in Notes, which can send or submit"))
        if case .refuse = ComputerActionRules.decide(ComputerAction(kind: .type, target: body, text: "a\u{1B}b"), in: notes) {} else {
            Issue.record("control characters must be refused")
        }
        for label in ["Password", "Verification code", "Card number", "PIN"] {
            let action = ComputerAction(kind: .type, target: .init(role: "AXTextField", label: label), text: "1234")
            #expect(ComputerActionRules.decide(action, in: notes) == .refuse(ComputerActionRules.secret), "\(label)")
        }
        let note = ComputerAction(kind: .type, target: .init(role: "AXTextArea", label: "Body"), text: "Milk, eggs")
        #expect(ComputerActionRules.decide(note, in: notes) == .allow)
        #expect(ComputerActionRules.decide(click("Password", role: "AXSecureTextField"), in: notes) == .refuse(ComputerActionRules.secret))
    }

    @Test func keysThatSendDeleteOrQuitAreConfirmed() {
        let field = ComputerAction.Target(role: "AXTextArea", label: "Body")
        func keys(_ keys: [String], target: ComputerAction.Target? = nil, shortcut: String? = nil, apple: Bool = false) -> ComputerDecision {
            ComputerActionRules.decide(ComputerAction(kind: .key, target: target, keys: keys,
                                                      shortcut: shortcut.map { .init(title: $0, inAppleMenu: apple) }), in: notes)
        }
        func key(_ names: String..., target: ComputerAction.Target? = nil, shortcut: String? = nil) -> ComputerDecision {
            keys(names, target: target, shortcut: shortcut)
        }
        // Every spelling the driver folds onto Return is judged as Return.
        for spelling in [["kp_enter"], ["Return "], ["re_turn"], ["numpad-enter"], ["ENTER"], ["cmd+return"], ["cmd", "kpenter"]] {
            #expect(keys(spelling) == .confirm("press Return in Notes, which can send or submit"), "\(spelling)")
        }
        // A command shortcut is the menu item it runs: judged by its title, refused when unknown.
        #expect(key("cmd", "shift", "e") == .refuse(ComputerActionRules.unknownShortcut))
        #expect(key("cmd", "shift", "e", shortcut: "Redirect") == .confirm("use \u{201C}Redirect\u{201D} in Notes"))
        #expect(key("cmd", "shift", "j", shortcut: "Move to Junk") == .confirm("use \u{201C}Move to Junk\u{201D} in Notes"))
        #expect(key("cmd", "bksp", shortcut: "Delete") == .confirm("delete something in Notes: \u{201C}Delete\u{201D}"))
        #expect(key("cmd", "v", shortcut: "Paste") == .confirm("paste what you last copied into Notes"))
        #expect(key("cmd", "f", shortcut: "Find…") == .allow)
        #expect(key("cmd", "z", shortcut: "Undo Typing") == .allow)
        #expect(key("cmd", "a", shortcut: "Select All") == .allow)
        #expect(key("cmd", "n", shortcut: "New Note") == .allow)
        #expect(keys(["option", "shift", "cmd", "q"], shortcut: "Log Out Corey…", apple: true) != .allow)
        if case .refuse = keys(["option", "shift", "cmd", "q"], shortcut: "Log Out Corey…", apple: true) {} else { Issue.record("Apple menu must be refused") }
        // A character is typing: only into a text field, never a password field.
        #expect(key("a") == .refuse(ComputerActionRules.notATextField))
        #expect(key("space", target: .init(role: "AXButton", label: "Send")) == .refuse(ComputerActionRules.notATextField))
        #expect(key("shift", "a", target: field) == .allow)
        #expect(key("x", target: .init(role: "AXTextField", subrole: "AXSecureTextField")) == .refuse(ComputerActionRules.secret))
        #expect(key("delete") == .confirm("press Delete in Notes, which can delete what's selected"))
        #expect(key("delete", target: field) == .allow)
        #expect(key("down") == .allow)
        #expect(key("tab") == .allow)
        // In web content the page gets the key first: no shortcut, whatever its menu item says.
        var web = field
        web.inWebContent = true
        #expect(key("cmd", "f", target: web, shortcut: "Find…") == .refuse(ComputerActionRules.webShortcut))
        #expect(key("a", target: web) == .allow)
        for odd in [["f11"], ["capslock"], ["fn", "a"], ["cmd", "mystery"], ["a", "b"], []] {
            if case .refuse = keys(odd) {} else { Issue.record("\(odd) must be refused") }
        }
        #expect(ComputerActionRules.canonicalKeys(["Cmd", "Shift", "pg_dn"])! == (["shift", "cmd"], "pagedown"))
    }

    @Test func linksAskOnlyForWebAndMailAndOthersAreRefused() {
        func decide(_ target: ComputerAction.Target) -> ComputerDecision {
            ComputerActionRules.decide(ComputerAction(kind: .click, target: target), in: notes)
        }
        // A web or mail link asks, showing where it goes.
        #expect(decide(.init(role: "AXLink", label: "Report", url: "https://example.com/report"))
            == .confirm("open a link to example.com in Notes: \u{201C}https://example.com/report\u{201D}"))
        #expect(decide(.init(role: "AXLink", label: "Write", url: "mailto:a@example.com"))
            == .confirm("open a link to a@example.com in Notes: \u{201C}mailto:a@example.com\u{201D}"))
        // The site comes first and in full, whatever the address does to hide it.
        let long = "https://www.paypal.com.account-verify.example.net/login"
        #expect(decide(.init(role: "AXLink", label: "PayPal", url: long))
            == .confirm("open a link to www.paypal.com.account-verify.example.net in Notes: \u{201C}\(long)\u{201D}"))
        #expect(decide(.init(role: "AXLink", label: "Apple", url: "https://www.apple.com@evil.example/")) == .refuse(ComputerActionRules.hiddenUser))
        // Anything else a link can open (files, shares, screens, calls, settings) stays with the person.
        for url in ["file:///Applications/Terminal.app", "smb://server/share", "vnc://host", "facetime:+15555550100",
                    "x-apple.systempreferences:com.apple.preference.security", "applenotes:note/1"] {
            #expect(decide(.init(role: "AXLink", label: "here", url: url)) == .refuse(ComputerActionRules.otherLink), "\(url)")
        }
        // A link's text or picture under the pointer is the link; one whose address can't be read isn't clicked.
        #expect(decide(.init(role: "AXStaticText", label: "here", inLink: true)) == .refuse(ComputerActionRules.unknownLink))
        #expect(decide(.init(role: "AXImage", label: nil, url: "vnc://host")) == .refuse(ComputerActionRules.otherLink))
        #expect(decide(.init(role: "AXLink", label: "Report")) == .refuse(ComputerActionRules.unknownLink))
        // A link preview that only shows an address: the person decides, seeing its words.
        #expect(decide(.init(role: "AXGroup", label: "Weekend plans, example.com"))
            == .confirm("click \u{201C}Weekend plans, example.com\u{201D} in Notes, which may open a link"))
        #expect(decide(.init(role: "AXButton", label: "https://example.com"))
            == .confirm("click \u{201C}https://example.com\u{201D} in Notes, which may open a link"))
        // Lookalike letters and hidden direction marks never pass for a familiar name.
        #expect(decide(.init(role: "AXLink", label: "Apple", url: "https://www.xn--pple-43d.com/login")) == .refuse(ComputerActionRules.lookalike))
        #expect(decide(.init(role: "AXLink", label: "Apple", url: "https://%E2%80%AEmoc.elppa.evil.com/")) == .refuse(ComputerActionRules.unknownLink))
        #expect(decide(.init(role: "AXLink", label: "Mail", url: "mailto:%E2%80%AEmoc.live@x.com")) == .refuse(ComputerActionRules.unknownLink))
        #expect(decide(.init(role: "AXLink", label: "Run", url: "javascript:alert(1)")) == .refuse(ComputerActionRules.otherLink))
        #expect(decide(.init(role: "AXLink", label: "Up", url: "HTTPS://example.com"))
            == .confirm("open a link to example.com in Notes: \u{201C}HTTPS://example.com\u{201D}"))
        #expect(decide(.init(role: "AXTextArea", label: "see example.com")) == .allow)
        #expect(decide(.init(role: "AXButton", label: "Bold")) == .allow)
        #expect(ComputerActionRules.looksLikeAddress("news.bbc.co.uk"))
        #expect(ComputerActionRules.looksLikeAddress("Shared from bit.ly/3xYz"))
        #expect(!ComputerActionRules.looksLikeAddress("Notes"))
        #expect(!ComputerActionRules.looksLikeAddress("Send"))
        // An email address or a file name isn't a web address.
        #expect(!ComputerActionRules.looksLikeAddress("sam@me.com"))
        #expect(!ComputerActionRules.looksLikeAddress("John Appleseed <john@icloud.com>"))
        #expect(!ComputerActionRules.looksLikeAddress("main.rs"))
        // Return or Space on a link opens it: the same rule as a click.
        func key(_ keys: [String], _ target: ComputerAction.Target) -> ComputerDecision {
            ComputerActionRules.decide(ComputerAction(kind: .key, target: target, keys: keys), in: notes)
        }
        #expect(key(["return"], .init(role: "AXLink", label: "Screen", url: "vnc://host")) == .refuse(ComputerActionRules.otherLink))
        #expect(key(["space"], .init(role: "AXStaticText", label: "here", inLink: true)) == .refuse(ComputerActionRules.unknownLink))
        #expect(key(["cmd", "return"], .init(role: "AXLink", label: "Docs", url: "https://example.com"))
            == .confirm("open a link to example.com in Notes: \u{201C}https://example.com\u{201D}"))
        #expect(key(["return"], .init(role: "AXTextArea", label: "Body")) == .confirm("press Return in Notes, which can send or submit"))
    }

    @Test func appsAreCheckedAgainstTheirSignature() throws {
        // macOS's own Notes is signed by Apple for its own bundle id.
        let notes = try #require(ComputerAppInfo(bundleURL: URL(fileURLWithPath: "/System/Applications/Notes.app")))
        #expect(notes.signer == ComputerAppRules.apple)
        #expect(notes.path == "/System/Applications/Notes.app")
        #expect(ComputerAppRules.access(for: notes) == .use)
        // A bundle that only says it is Notes isn't signed by anyone.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString)/Notes.app/Contents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let plist: [String: Any] = ["CFBundleIdentifier": "com.apple.Notes", "CFBundleName": "Notes", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: folder.appendingPathComponent("Info.plist"))
        let fake = try #require(ComputerAppInfo(bundleURL: folder.deletingLastPathComponent()))
        #expect(fake.bundleID == "com.apple.Notes")
        #expect(fake.signer == nil)
        #expect(ComputerAppRules.access(for: fake) == .never(ComputerAppRules.notGenuine))
    }

    @Test func onlyTheAddOnRunByHermesItselfCounts() throws {
        let home = "/Users/x/.hermes"
        func process(_ pid: Int32, parent: Int32, _ path: String, _ arguments: [String]) -> ComputerProcess {
            ComputerProcess(pid: pid, parent: parent, started: 100, path: path, arguments: arguments)
        }
        let python = "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
        let script = home + "/profiles/career/plugins/nollie-mac/server.py"
        let addOn = process(50, parent: 40, python, [python, "-I", script])
        let hermesPython = home + "/tools/python-3.14/bin/python3.14"
        let gateway = process(40, parent: 30, hermesPython, [hermesPython, "-I", "-c", "boot", "gateway", "run", "--external-supervisor"])
        let wrapper = process(30, parent: 20, hermesPython, [hermesPython, "--run-module", "x"])
        let osascript = process(20, parent: 1, "/usr/bin/osascript", ["osascript"])
        let dashboard = process(41, parent: 1, hermesPython, [hermesPython, "-I", "-c", "boot", "dashboard", "--port", "9119"])
        func gatewayIn(_ home: String) -> ComputerProcess {
            process(40, parent: 30, home + "/tools/python/bin/python3", [home + "/tools/python/bin/python3", "-c", "boot", "gateway", "run"])
        }
        func wrapperIn(_ home: String) -> ComputerProcess { process(30, parent: 20, home + "/tools/python/bin/python3", ["python3", "x"]) }
        let apple = ComputerSignature(identifier: "com.apple.python3", team: nil, valid: true)
        func facts(_ me: ComputerProcess, parent: ComputerProcess, ancestors: [ComputerProcess] = [], launchd: Bool = true,
                   signature: ComputerSignature? = nil, stdio: Bool = true, oneJob: Bool = true, listens: Bool = true) -> ComputerPeer.Facts {
            ComputerPeer.Facts(me: me, parent: parent, ancestors: ancestors, reachedLaunchd: launchd, signature: signature ?? apple,
                               stdioFromParent: stdio, oneLaunchdJob: oneJob, parentListens: listens)
        }
        func identify(_ facts: ComputerPeer.Facts, digest: String = ComputerPeer.addOnDigest) -> ComputerPeer? {
            ComputerPeer.identify(facts, hermesHome: home) { _ in digest }
        }
        let fromGateway = identify(facts(addOn, parent: gateway, ancestors: [wrapper, osascript]))
        #expect(fromGateway == ComputerPeer(pid: 50, started: 100, host: .gateway, profile: "career"))
        let main = process(51, parent: 41, python, [python, "-I", home + "/plugins/nollie-mac/server.py"])
        #expect(identify(facts(main, parent: dashboard)) == ComputerPeer(pid: 51, started: 100, host: .dashboard, profile: "default"))

        // `hermes chat -q` or the TUI: the add-on's parent is that run, not the gateway or dashboard.
        let chat = process(42, parent: 60, hermesPython, [hermesPython, "-I", "-c", "boot", "-p", "career", "chat", "-q", "hi"])
        #expect(identify(facts(addOn, parent: chat)) == nil)
        // A gateway started from a shell, or a fake one left to launchd.
        let shell = process(60, parent: 1, "/bin/zsh", ["-zsh"])
        #expect(identify(facts(addOn, parent: gateway, ancestors: [shell])) == nil)
        #expect(identify(facts(addOn, parent: gateway, ancestors: [wrapper], launchd: false)) == nil)
        // A bot's terminal turning itself into Python under the gateway: other code, a script path
        // tacked on, an edited server.py, or stdin and stdout that aren't Hermes's MCP pipes.
        for arguments in [[python, "-I", "-c", "import socket", script], [python, script], [python, "-I", script, "extra"],
                          [python, "-I", "/tmp/nollie-mac/server.py"], [python, "-I", home + "/profiles/career/plugins/../../../tmp/nollie-mac/server.py"],
                          [python, "-I", home + "/profiles/career/plugins/nollie-mac/other.py"]] {
            #expect(identify(facts(process(52, parent: 40, python, arguments), parent: gateway, ancestors: [wrapper, osascript])) == nil,
                    "\(arguments)")
        }
        #expect(identify(facts(addOn, parent: gateway, ancestors: [wrapper, osascript]), digest: "0000") == nil)
        // The private bot's folder isn't read at all, not even its add-on's file.
        var hashed: [String] = []
        let moss = process(55, parent: 40, python, [python, "-I", home + "/profiles/private/plugins/nollie-mac/server.py"])
        #expect(ComputerPeer.identify(facts(moss, parent: gateway, ancestors: [wrapper, osascript]), hermesHome: home) { path in
            hashed.append(path)
            return ComputerPeer.addOnDigest
        } == nil)
        #expect(hashed.isEmpty)
        // Nor by another name: the file is read only by its own path, following no link anywhere
        // along it, so a bot folder (or its plugins) that leads into the private bot's reads nothing.
        // The real path: /var itself is a link on macOS (and NSString's resolver hides /private again).
        let temp = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temp) }
        let root = String(cString: temp) + "/hermes-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/profiles/private/plugins/nollie-mac", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/profiles/career/plugins", withIntermediateDirectories: true)
        let original = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Companions/nollie-mac/server.py"))
        try original.write(to: URL(fileURLWithPath: root + "/profiles/private/plugins/nollie-mac/server.py"))
        try fm.createSymbolicLink(atPath: root + "/profiles/moss2", withDestinationPath: root + "/profiles/private")
        try fm.createSymbolicLink(atPath: root + "/profiles/career/plugins/nollie-mac", withDestinationPath: root + "/profiles/private/plugins/nollie-mac")
        #expect(ComputerPeer.fileDigest(root + "/profiles/private/plugins/nollie-mac/server.py") == ComputerPeer.addOnDigest)
        #expect(ComputerPeer.fileDigest(root + "/profiles/moss2/plugins/nollie-mac/server.py") == nil)
        #expect(ComputerPeer.fileDigest(root + "/profiles/career/plugins/nollie-mac/server.py") == nil)
        try fm.createDirectory(atPath: root + "/profiles/forager/plugins/nollie-mac", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root + "/profiles/forager/plugins/nollie-mac/server.py",
                                  withDestinationPath: root + "/profiles/private/plugins/nollie-mac/server.py")
        #expect(ComputerPeer.fileDigest(root + "/profiles/forager/plugins/nollie-mac/server.py") == nil)
        // Through the whole check, with the real reader: refused, while a plain copy passes.
        for bot in ["moss2", "career", "forager"] {
            let linked = process(57, parent: 40, python, [python, "-I", root + "/profiles/\(bot)/plugins/nollie-mac/server.py"])
            #expect(ComputerPeer.identify(facts(linked, parent: gatewayIn(root), ancestors: [wrapperIn(root), osascript]), hermesHome: root,
                                          digest: ComputerPeer.fileDigest) == nil, "\(bot)")
        }
        try fm.createDirectory(atPath: root + "/profiles/scout/plugins/nollie-mac", withIntermediateDirectories: true)
        try original.write(to: URL(fileURLWithPath: root + "/profiles/scout/plugins/nollie-mac/server.py"))
        let plain = process(58, parent: 40, python, [python, "-I", root + "/profiles/scout/plugins/nollie-mac/server.py"])
        #expect(ComputerPeer.identify(facts(plain, parent: gatewayIn(root), ancestors: [wrapperIn(root), osascript]), hermesHome: root,
                                      digest: ComputerPeer.fileDigest)?.profile == "scout")
        // This test's own process is no add-on.
        #expect(ComputerPeer.identify(pid: getpid(), hermesHome: home) == nil)
        // The digest Nollie expects is the add-on in this repository.
        let server = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Companions/nollie-mac/server.py")
        let data = try Data(contentsOf: server)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == ComputerPeer.addOnDigest,
                "Companions/nollie-mac/server.py changed: update ComputerPeer.addOnDigest")
        // The kernel's signature for this test's own process: Nollie's own team.
        #expect(ComputerSignature.of(pid: getpid()).valid)
    }

    @Test func aRequestMustMatchItsOwnPendingCall() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func call(_ id: String, apps: [String] = ["Notes"], task: String = "Tidy notes") -> JSONValue {
            let arguments = try! String(data: JSONSerialization.data(withJSONObject: ["apps": apps, "task": task]), encoding: .utf8)!
            return ["id": .string(id), "function": ["name": .string(ComputerSessionCheck.toolName), "arguments": .string(arguments)]]
        }
        func assistant(_ calls: [JSONValue], at time: Double) -> JSONValue {
            ["role": "assistant", "timestamp": .number(time), "tool_calls": .array(calls)]
        }
        let user: JSONValue = ["role": "user", "timestamp": .number(now.timeIntervalSince1970 - 10), "content": "please"]
        let live = [user, assistant([call("c1")], at: now.timeIntervalSince1970 - 2)]
        let c1 = "c1@" + String(Int((now.timeIntervalSince1970 - 2) * 1000))
        #expect(ComputerSessionCheck.pendingStart(in: live, apps: ["Notes"], purpose: "Tidy notes", now: now) == c1)
        #expect(ComputerSessionCheck.pendingStart(in: live.reversed(), apps: ["Notes"], purpose: "Tidy notes", now: now) == c1)
        // Different apps or task, an answered call, an old call, or no call at all: refused.
        #expect(ComputerSessionCheck.pendingStart(in: live, apps: ["Mail"], purpose: "Tidy notes", now: now) == nil)
        #expect(ComputerSessionCheck.pendingStart(in: live, apps: ["Notes"], purpose: "Something else", now: now) == nil)
        let answered = live + [["role": "tool", "tool_call_id": "c1", "timestamp": .number(now.timeIntervalSince1970 - 1)]]
        #expect(ComputerSessionCheck.pendingStart(in: answered, apps: ["Notes"], purpose: "Tidy notes", now: now) == nil)
        let old = [user, assistant([call("c2")], at: now.timeIntervalSince1970 - 600)]
        #expect(ComputerSessionCheck.pendingStart(in: old, apps: ["Notes"], purpose: "Tidy notes", now: now) == nil)
        #expect(ComputerSessionCheck.pendingStart(in: [user], apps: ["Notes"], purpose: "Tidy notes", now: now) == nil)
        // Only the latest assistant turn counts.
        let later = live + [assistant([["id": "x", "function": ["name": "web_search", "arguments": "{}"]]], at: now.timeIntervalSince1970 - 1)]
        #expect(ComputerSessionCheck.pendingStart(in: later, apps: ["Notes"], purpose: "Tidy notes", now: now) == nil)
        // Only the add-on's own tool, by the exact name Hermes records, counts.
        func named(_ name: String) -> [JSONValue] {
            let arguments = try! String(data: JSONSerialization.data(withJSONObject: ["apps": ["Notes"], "task": "Tidy notes"]), encoding: .utf8)!
            return [user, assistant([["id": "n1", "function": ["name": .string(name), "arguments": .string(arguments)]]], at: now.timeIntervalSince1970 - 2)]
        }
        for name in ["mac_start", "mcp__other__mac_start", "mcp__nollie_mac__mac_start_v2", "mcp__nollie_mac__mac_start_1a2b3c4d",
                     "mcp__nollie_mac_extra__mac_start", "MCP__NOLLIE_MAC__MAC_START", "mcp__nollie_mac__mac_look"] {
            #expect(ComputerSessionCheck.pendingStart(in: named(name), apps: ["Notes"], purpose: "Tidy notes", now: now) == nil, "\(name)")
        }
        #expect(ComputerSessionCheck.pendingStart(in: named("mcp__nollie_mac__mac_start"), apps: ["Notes"], purpose: "Tidy notes", now: now) != nil)
        // The arguments are the request, byte for byte, apart from the add-on's stamp.
        #expect(ComputerSessionCheck.sameArguments(["apps": ["Notes"], "task": "Tidy notes", "_nollie": ["session_id": "x"]],
                                                   apps: ["Notes"], purpose: "Tidy notes"))
        #expect(!ComputerSessionCheck.sameArguments(["apps": ["Notes"], "task": "Tidy notes", "extra": 1], apps: ["Notes"], purpose: "Tidy notes"))
        #expect(!ComputerSessionCheck.sameArguments(["apps": ["Notes"]], apps: ["Notes"], purpose: ""))
        #expect(!ComputerSessionCheck.sameArguments(["apps": [7], "task": "x"], apps: ["7"], purpose: "x"))
        #expect(!ComputerSessionCheck.sameArguments(["apps": "Notes", "task": "x"], apps: ["Notes"], purpose: "x"))
        // "café" written two ways looks the same but isn't the same bytes.
        #expect(!ComputerSessionCheck.sameArguments(["apps": ["Notes"], "task": "cafe\u{301}"], apps: ["Notes"], purpose: "caf\u{E9}"))
        #expect(!ComputerSessionCheck.sameArguments(["apps": ["Notes", "Mail"], "task": "x"], apps: ["Notes"], purpose: "x"))

        // A longer wait after the yes is fine, for the same call.
        let waited = [user, assistant([call("c3")], at: now.timeIntervalSince1970 - 200)]
        #expect(ComputerSessionCheck.pendingStart(in: waited, apps: ["Notes"], purpose: "Tidy notes", now: now) == nil)
        #expect(ComputerSessionCheck.pendingStart(in: waited, apps: ["Notes"], purpose: "Tidy notes", now: now, freshFor: 86_400)
            == "c3@" + String(Int((now.timeIntervalSince1970 - 200) * 1000)))
    }

    @Test func theCardAndTaskUseOnlyWhatHermesSays() {
        let row: JSONValue = ["id": "s2", "profile": "career", "title": "Job hunt", "source": "signal"]
        let facts = ComputerSessionCheck.facts(row: row, root: "s1", callID: "c1", host: .gateway)
        #expect(facts == ComputerSessionFacts(chat: "career/s1", title: "Job hunt", source: "signal", callID: "c1", profile: "career", platform: "Signal"))
        #expect(ComputerSessionCheck.facts(row: ["id": "s2", "title": "t"], root: "s1", callID: "c1", host: .gateway) == nil)
        #expect(ComputerSessionCheck.facts(row: ["profile": "default", "source": "tui"], root: "s1", callID: "c1", host: .dashboard)?.platform == "Nollie")
        // Whatever the caller sends besides the session id, Nollie doesn't read.
        guard case let .start(request) = ComputerBroker.parse(["op": "start", "session_id": "s", "profile": "career", "chat": "someone/else",
                                                               "apps": ["Notes"], "purpose": "p"]) else { Issue.record("not a start"); return }
        #expect(request == ComputerStartRequest(sessionID: "s", profile: "career", apps: ["Notes"], purpose: "p"))
    }

    @Test func onlyChatsAPersonIsInWhereTheAddOnRan() {
        func row(_ source: String, key: String? = nil, chat: String? = nil, archived: Bool = false) -> JSONValue {
            var row: [String: JSONValue] = ["source": .string(source), "archived": .bool(archived)]
            if let key { row["session_key"] = .string(key) }
            if let chat { row["chat_id"] = .string(chat) }
            return .object(row)
        }
        // The app's chats run in the dashboard.
        #expect(ComputerSessionCheck.judge(row("tui"), host: .dashboard) == nil)
        #expect(ComputerSessionCheck.judge(row("tui", archived: true), host: .dashboard) == ComputerSessionCheck.unknown)
        for source in ["cli", "telegram", "cron", "oneshot", "api_server"] {
            #expect(ComputerSessionCheck.judge(row(source), host: .dashboard) == ComputerSessionCheck.scheduled, "\(source)")
        }
        // Messaging chats run in the gateway, with the gateway's own routing for that platform, and
        // only direct ones: in a group, someone else may have asked.
        #expect(ComputerSessionCheck.judge(row("signal", key: "agent:career:signal:dm:+1555", chat: "+1555"), host: .gateway) == nil)
        #expect(ComputerSessionCheck.judge(row("telegram", key: "agent:main:telegram:group:-100", chat: "-100"), host: .gateway)
            == ComputerSessionCheck.groupChat)
        // Slack calls a group DM a DM: only a one-to-one channel counts.
        var slack = row("slack", key: "agent:main:slack:dm:T1:G123", chat: "G123")
        if case var .object(fields) = slack { fields["chat_type"] = "dm"; slack = .object(fields) }
        #expect(ComputerSessionCheck.judge(slack, host: .gateway) == ComputerSessionCheck.groupChat)
        #expect(ComputerSessionCheck.judge(row("slack", key: "agent:main:slack:dm:T1:D123", chat: "D123"), host: .gateway) == nil)
        // iMessage comes through Photon; Matrix guesses which rooms are direct, so it doesn't count.
        #expect(ComputerSessionCheck.judge(row("photon", key: "agent:main:photon:dm:+1555", chat: "+1555"), host: .gateway) == nil)
        #expect(ComputerSessionCheck.judge(row("matrix", key: "agent:main:matrix:dm:!r", chat: "!r"), host: .gateway) == ComputerSessionCheck.scheduled)
        // `hermes chat -q --source telegram` writes no routing.
        #expect(ComputerSessionCheck.judge(row("telegram"), host: .gateway) == ComputerSessionCheck.unknown)
        #expect(ComputerSessionCheck.judge(row("telegram", key: "agent:career:signal:dm:1", chat: "1"), host: .gateway) == ComputerSessionCheck.unknown)
        for source in ["tui", "cli", "cron", "kanban", "oneshot", "webhook", "api_server", "buzz", ""] {
            #expect(ComputerSessionCheck.judge(row(source, key: "agent:x:\(source):dm:1", chat: "1"), host: .gateway) != nil, "\(source)")
        }
    }

    @Test func aTaskEndsAfterThirtyMinutesOrFiveIdle() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var task = ComputerTask(botName: "Scout", profile: "career", sessionID: "s", purpose: "p", apps: [notes], startedAt: start)
        #expect(task.limit(at: start.addingTimeInterval(299)) == nil)
        #expect(task.limit(at: start.addingTimeInterval(300)) == .idle)
        for minute in stride(from: 4.0, through: 28.0, by: 4.0) {
            task.noteActivity(in: notes, at: start.addingTimeInterval(minute * 60))
        }
        #expect(task.limit(at: start.addingTimeInterval(29 * 60)) == nil)
        #expect(task.limit(at: start.addingTimeInterval(30 * 60)) == .expired)
        #expect(task.nextDeadline == start.addingTimeInterval(30 * 60))
        #expect(task.id.count == 64)
        #expect(task.id != ComputerTask(botName: "", profile: "", sessionID: "", purpose: "", apps: [], startedAt: start).id)
    }

    @Test func manifestsListOnlyApprovedAppsAndSafeTools() throws {
        let door = ComputerManifest.door()
        #expect(door.contains("tools: [check_permissions]"))
        #expect(!door.contains("apps:"))
        #expect(door.contains("display: false"))

        let use = try #require(ComputerManifest.use([notes, safari]))
        #expect(use.contains("bundle_id: \"com.apple.Notes\""))
        #expect(!use.contains("Safari"))
        #expect(use.contains("tools: [list_windows, get_window_state, click, type_text, press_key, hotkey, scroll]"))
        #expect(use.contains("expires_after: 1800s"))
        // Each session idles out only with the task; Nollie ends the task after 5 idle minutes.
        #expect(use.contains("idle_timeout: 1800s"))
        let view = try #require(ComputerManifest.view([notes, safari]))
        #expect(view.contains("bundle_id: \"com.apple.Safari\""))
        #expect(view.contains("tools: [list_windows, get_window_state]"))
        #expect(!view.contains("Notes"))
        #expect(ComputerManifest.view([notes]) == nil)
        #expect(ComputerManifest.use([safari]) == nil)
        for manifest in [door, use, view] {
            for never in ["launch_app", "invoke_menu", "run_script", "run_steps", "kill_app", "clipboard", "get_desktop_state",
                          "list_apps", "page", "browser_", "check_for_update", "display: true"] {
                #expect(!manifest.contains(never), "\(never)")
            }
        }
        #expect(ComputerManifest.yamlString("a\"b\\c\n") == "\"a\\\"b\\\\c\\x0A\"")
    }
}
#endif
