import Foundation
import Security

/// What a bot may do with one app on this Mac, decided before the person is even asked.
enum ComputerAppAccess: Equatable, Sendable {
    /// The bot may look and act, with risky actions still confirmed one by one.
    case use
    /// The bot may look but never click, type or scroll (browsers).
    case viewOnly
    /// Never offered: the reason, in words for the approval card.
    case never(String)

    var isAllowed: Bool {
        guard case .never = self else { return true }
        return false
    }
}

/// The facts about an app that the rules read. They come from the app's bundle, never from what a
/// bot says about it.
struct ComputerAppInfo: Equatable, Hashable, Sendable {
    var bundleID: String
    var name: String
    /// `LSApplicationCategoryType`, for example `public.app-category.finance`.
    var category: String?
    /// The app says it opens web pages (an `http` or `https` URL type).
    var opensWebPages = false
    /// Who signed the copy on disk, checked against its signature: `apple` for macOS's own apps,
    /// otherwise the maker's team id. Nil when the signature doesn't hold or names another app.
    var signer: String? = nil
    /// Where the app is, so a task only ever acts in that copy.
    var path: String? = nil
}

/// Which apps are never touched, which are only looked at, and which a bot may use.
///
/// Never: Nollie itself, terminals and coding tools, password managers, System Settings, system
/// tools, finance and crypto apps. View only: browsers. Use is an allowlist of everyday apps that
/// can't run commands or open other apps unasked, each of which must be signed by its maker.
/// Anything else stays with the person. The refusals are checked first so the card can say why.
enum ComputerAppRules {
    static let nollie = "Nollie can't use itself."
    static let commands = "Terminals and coding tools can run commands, so they stay with you."
    static let passwords = "Password managers stay with you."
    static let settings = "System Settings stays with you."
    static let money = "Money and crypto apps stay with you."
    static let system = "System tools and Finder can open or change anything, so they stay with you."
    static let notOffered = "Nollie doesn't offer this app yet."
    static let notGenuine = "This copy isn't signed by the app's maker, so it stays with you."
    static let apple = "apple"

    // MARK: Decision

    /// The app's id and name in lower case, with the facts they came from.
    private struct Subject {
        let id: String
        let name: String
        let info: ComputerAppInfo

        init(_ info: ComputerAppInfo) {
            self.info = info
            id = info.bundleID.lowercased()
            name = info.name.lowercased()
        }

        func hasPrefix(in prefixes: [String]) -> Bool { prefixes.contains(where: id.hasPrefix) }
        func nameMatches(_ words: [String]) -> Bool { ComputerAppRules.matches(name, words) }
    }

    /// The refusals in the order they are tried: each is the words to show and when it applies.
    private static var refusals: [(why: String, applies: (Subject) -> Bool)] { [
        (settings, { settingsIDs.contains($0.id) }),
        (commands, {
            commandIDs.contains($0.id) || $0.hasPrefix(in: commandPrefixes) || $0.nameMatches(commandWords)
                || $0.info.category == "public.app-category.developer-tools"
        }),
        (system, { systemIDs.contains($0.id) }),
        (passwords, { passwordIDs.contains($0.id) || $0.hasPrefix(in: passwordPrefixes) || $0.nameMatches(passwordWords) }),
        (money, {
            $0.info.category == "public.app-category.finance" || moneyIDs.contains($0.id) || $0.nameMatches(moneyWords)
        }),
    ] }

    static func access(for app: ComputerAppInfo, ownBundleID: String? = Bundle.main.bundleIdentifier) -> ComputerAppAccess {
        let subject = Subject(app)
        if subject.id.isEmpty { return .never("This app can't be identified.") }
        let isNollie = subject.id == ownBundleID?.lowercased() || subject.id.hasPrefix("com.coreykozarski.nollie")
            || subject.name == "nollie"
        if isNollie { return .never(nollie) }
        if let refusal = refusals.first(where: { $0.applies(subject) }) { return .never(refusal.why) }

        let expected = signers[subject.id]
        if browserIDs.contains(subject.id) || (app.opensWebPages && expected == nil) { return .viewOnly }
        guard let expected else { return .never(notOffered) }
        return app.signer == expected ? .use : .never(notGenuine)
    }

    /// Whether a word or phrase of the name is one of `words`: "Banktivity" and "Ledger Live" match
    /// but "Notes" never matches "note". A word ending in a star matches any word that starts with it.
    static func matches(_ name: String, _ words: [String]) -> Bool {
        let parts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let padded = " " + parts.joined(separator: " ") + " "
        return words.contains { word in
            guard word.hasSuffix("*") else { return padded.contains(" " + word + " ") }
            let stem = word.dropLast()
            return parts.contains { $0.hasPrefix(stem) }
        }
    }

    // MARK: The lists

    /// A comma separated list as words, trimmed.
    private static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Each maker and the apps they must have signed (lower case bundle ids): everyday apps that
    /// can't run commands. Word, Excel and PowerPoint (macros), and apps with plugins that can run
    /// anything, are left out.
    private static let allowedMakers: [(maker: String, apps: String)] = [
        (apple, """
            com.apple.notes, com.apple.mail, com.apple.ical, com.apple.reminders, com.apple.addressbook,
            com.apple.textedit, com.apple.preview, com.apple.photos, com.apple.music, com.apple.maps,
            com.apple.mobilesms, com.apple.freeform, com.apple.weather, com.apple.ibooksx, com.apple.news,
            com.apple.podcasts, com.apple.stickies, com.apple.clock, com.apple.calculator,
            com.apple.dictionary, com.apple.journal
            """),
        // From the Mac App Store, signed for Apple's own team.
        ("74J34U3R6X", "com.apple.iwork.pages, com.apple.iwork.numbers, com.apple.iwork.keynote"),
        ("BQR82RBBHL", "com.tinyspeck.slackmacgap"),
        ("JLMPQHK86H", "com.culturedcode.thingsmac"),
        ("UBF8T346G9", "com.microsoft.outlook"),
        ("2FNC3A47ZF", "com.spotify.client"),
        ("85C27NK92C", "com.flexibits.fantastical2.mac"),
    ]

    /// Lower case bundle id to who must have signed it.
    static let signers: [String: String] = {
        var table: [String: String] = [:]
        for (maker, apps) in allowedMakers {
            for id in list(apps) { table[id] = maker }
        }
        return table
    }()

    static var usable: Set<String> { Set(signers.keys) }

    /// System tools that can open, run, install or erase anything.
    static let systemIDs = Set(list("""
        com.apple.finder, com.apple.activitymonitor, com.apple.diskutility, com.apple.installer,
        com.apple.systemprofiler, com.apple.console, com.apple.migrateassistant, com.apple.bootcampassistant,
        com.apple.directoryutility, com.apple.appstore
        """))

    static let settingsIDs = Set(list("""
        com.apple.systempreferences, com.apple.settings, com.apple.systemsettings,
        com.apple.preferences.extensions
        """))

    static let commandIDs = Set(list("""
        com.apple.terminal, com.googlecode.iterm2, dev.warp.warp-stable, dev.warp.warp,
        net.kovidgoyal.kitty, io.alacritty, org.alacritty, com.github.wez.wezterm, co.zeit.hyper,
        com.mitchellh.ghostty, org.tabby, com.termius-dmg.mac, com.panic.prompt3,
        com.apple.scripteditor2, com.apple.automator, com.apple.shortcuts, com.apple.dt.xcode,
        com.microsoft.vscode, com.microsoft.vscodeinsiders, com.todesktop.230313mzl4w4u92,
        dev.zed.zed, com.vscodium, com.sublimetext.4, com.panic.nova, com.barebones.bbedit,
        com.apple.screensharing, com.apple.remotedesktop, com.utmapp.utm,
        com.parallels.desktop.console, com.vmware.fusion,
        org.gnu.emacs, org.vim.macvim, org.python.idle, com.macromates.textmate, org.rstudio.rstudio,
        com.exafunction.windsurf, com.latenightsw.scriptdebugger8, com.stairways.keyboardmaestro.editor,
        com.stairways.keyboardmaestro.engine, org.hammerspoon.hammerspoon, com.raycast.macos,
        com.runningwithcrayons.alfred, com.docker.docker, dev.kdrag0n.macvirt,
        com.apple.automator.automator-application-stub
        """))
    static let commandPrefixes = list("com.jetbrains., com.google.android.studio, org.gnu., org.vim., org.python.")
    static let commandWords = list("""
        terminal, iterm, iterm2, ghostty, warp, kitty, alacritty, wezterm, console, shell, emacs, vim,
        macvim, idle, textmate, rstudio, windsurf, script debugger, keyboard maestro, hammerspoon,
        raycast, alfred, docker, orbstack
        """)

    static let passwordIDs = Set(list("""
        com.apple.passwords, com.apple.keychainaccess, com.bitwarden.desktop, com.lastpass.lastpass,
        com.dashlane.dashlanephonefinal, org.keepassxc.keepassxc, com.keepersecurity.passwordmanager,
        com.callpod.keepermac.lite, com.nordpass.macos.nordpass, com.roboform.mac, com.enpass.enpass,
        com.proton.pass, me.proton.pass.electron, com.yubico.authenticator
        """))
    static let passwordPrefixes = list("com.1password., com.agilebits.")
    static let passwordWords = list("""
        1password, password*, passwords, keychain, bitwarden, lastpass, dashlane, keepass*, enpass,
        nordpass, authenticator, authy
        """)

    static let moneyIDs = Set(list("""
        com.apple.stocks, com.ledger.live, com.exodus.exodus, io.trezor.trezorsuite, org.electrum.electrum,
        com.coinbase.wallet, com.quicken.quicken, com.iggsoftware.banktivity, com.moneymoney-app.retail,
        com.youneedabudget.ynab, com.paypal.paypal, com.robinhood.robinhood
        """))
    static let moneyWords = list("""
        bank*, wallet, crypto*, bitcoin, ethereum, coinbase, binance, kraken, ledger live, trezor,
        metamask, exodus, electrum, quicken, paypal, venmo, revolut, monzo, wise, robinhood, trading,
        broker*, invest*, stocks
        """)

    static let browserIDs = Set(list("""
        com.apple.safari, com.apple.safaritechnologypreview, com.google.chrome, com.google.chrome.canary,
        org.mozilla.firefox, org.mozilla.firefoxdeveloperedition, com.microsoft.edgemac,
        company.thebrowser.browser, com.brave.browser, com.operasoftware.opera, com.vivaldi.vivaldi,
        com.kagi.kagimacos, com.duckduckgo.macos.browser, org.chromium.chromium, app.zen-browser.zen,
        org.torproject.torbrowser, com.sigmaos.sigmaos.macos
        """))
}

// MARK: Reading an app and its signature

/// The code-signing requirement that says "this bundle id, from this kind of maker".
private func makerRequirement(bundleID: String, isApple: Bool) -> SecRequirement? {
    let id = bundleID.replacingOccurrences(of: "\"", with: "")
    let anchor = isApple ? "anchor apple" : "anchor apple generic"
    var requirement: SecRequirement?
    let made = SecRequirementCreateWithString("\(anchor) and identifier \"\(id)\"" as CFString, [], &requirement)
    return made == errSecSuccess ? requirement : nil
}

extension ComputerAppInfo {
    /// The facts from an app's bundle on disk.
    init?(bundleURL: URL) {
        guard let bundle = Bundle(url: bundleURL), let id = bundle.bundleIdentifier else { return nil }
        let plist = bundle.infoDictionary ?? [:]
        let shownName = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let urlTypes = plist["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = Set(urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() })
        self.init(bundleID: id, name: shownName, category: plist["LSApplicationCategoryType"] as? String,
                  opensWebPages: !schemes.isDisjoint(with: ["http", "https"]),
                  signer: Self.signer(of: bundleURL, bundleID: id),
                  path: bundleURL.resolvingSymlinksInPath().path)
    }

    /// Whether the running process is that app as its maker signed it. Checked on the running code,
    /// so a copy swapped on disk, or another app with the same bundle id, doesn't pass.
    static func runningCopyIsSignedBy(pid: pid_t, bundleID: String, signer: String?) -> Bool {
        guard let signer else { return false }
        let isApple = signer == ComputerAppRules.apple
        var guest: SecCode?
        let found = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &guest)
        guard found == errSecSuccess, let guest,
              let requirement = makerRequirement(bundleID: bundleID, isApple: isApple),
              SecCodeCheckValidity(guest, [], requirement) == errSecSuccess else { return false }
        return isApple || ComputerSignature.of(pid: pid).team == signer
    }

    /// Who signed the app at `url`, when the signature holds and was made for `bundleID`: `apple`, or
    /// the maker's team id read from that same signature.
    static func signer(of url: URL, bundleID: String) -> String? {
        var program: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &program) == errSecSuccess, let program else { return nil }
        // The program and its signature; the running copy is checked again before every action.
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSDoNotValidateResources)
        func holds(isApple: Bool) -> Bool {
            guard let requirement = makerRequirement(bundleID: bundleID, isApple: isApple) else { return false }
            return SecStaticCodeCheckValidity(program, flags, requirement) == errSecSuccess
        }
        if holds(isApple: true) { return ComputerAppRules.apple }
        guard holds(isApple: false) else { return nil }
        var details: CFDictionary?
        let read = SecCodeCopySigningInformation(program, SecCSFlags(rawValue: kSecCSSigningInformation), &details)
        guard read == errSecSuccess else { return nil }
        return (details as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
