import Foundation

/// The small set of top-level settings. Search also finds the controls grouped inside each page.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case bots, appearance, speech, notifications, weekly, privacy = "icloud", signIns = "signins", cards, siri = "voice",
         connection = "gateways", away, keepAwake = "awake", about, advanced

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bots: String(localized: "Bots", comment: "A Settings page name")
        case .appearance: String(localized: "Appearance", comment: "A Settings page name")
        case .speech: String(localized: "Voice", comment: "A Settings page name")
        case .notifications: String(localized: "Notifications", comment: "A Settings page name")
        case .weekly: String(localized: "Your week", comment: "A Settings page name")
        case .privacy: String(localized: "Privacy", comment: "A Settings page name")
        case .signIns: String(localized: "Sign-ins", comment: "A Settings page name")
        case .cards: String(localized: "Cards", comment: "A Settings page name")
        case .siri: String(localized: "Siri & Shortcuts", comment: "A Settings page name")
        case .connection: String(localized: "Connection", comment: "A Settings page name")
        case .away: String(localized: "Away from home", comment: "A Settings page name")
        case .keepAwake: String(localized: "Keep awake", comment: "A Settings page name")
        case .about: String(localized: "About", comment: "A Settings page name")
        case .advanced: String(localized: "Advanced", comment: "A Settings page name")
        }
    }
    var symbol: String {
        switch self {
        case .bots: "person.crop.square"
        case .appearance: "circle.lefthalf.filled"
        case .speech: "speaker.wave.2.fill"
        case .notifications: "bell.badge"
        case .weekly: "calendar"
        case .privacy: "hand.raised.fill"
        case .signIns: "key.fill"
        case .cards: "creditcard.fill"
        case .siri: "app.connected.to.app.below.fill"
        case .connection: "network"
        case .away: "globe"
        case .keepAwake: "sun.max.fill"
        case .about: "info.circle"
        case .advanced: "slider.horizontal.3"
        }
    }
    /// Search words: localized so a search in the person's language finds the page.
    private var keywords: String {
        switch self {
        case .bots: String(localized: "bot avatar character face colour color look name default motion tilt", comment: "Settings search words, not shown")
        case .appearance: String(localized: "theme dark light text font reading transcript glass summaries titles previews", comment: "Settings search words, not shown")
        case .speech: String(localized: "speak speech read aloud talk talking listen hands-free", comment: "Settings search words, not shown")
        case .notifications: String(localized: "alert permission sound haptics background", comment: "Settings search words, not shown")
        case .weekly: String(localized: "weekly note week summary sunday helpers papertrail left undo mute pause", comment: "Settings search words, not shown")
        case .privacy: String(localized: "security lock face id touch id approvals permissions camera microphone photos local network notifications accessibility screen recording", comment: "Settings search words, not shown")
        case .signIns: String(localized: "password passwords login log in username website site keychain one-time code", comment: "Settings search words, not shown")
        case .cards: String(localized: "card cards credit debit pay payment buy buying checkout shop money visa mastercard", comment: "Settings search words, not shown")
        case .siri: DeviceWords.isMac
            ? String(localized: "shortcuts spotlight siri", comment: "Settings search words, not shown")
            : String(localized: "shortcuts spotlight siri stop lock screen live activity", comment: "Settings search words, not shown")
        case .connection: String(localized: "setup set up connect gateway sign in models local cloud import", comment: "Settings search words, not shown")
        case .away: String(localized: "tailscale remote outside travel anywhere network wifi cellular exit node", comment: "Settings search words, not shown")
        case .keepAwake: String(localized: "sleep awake power battery plugged night schedules overnight lid energy", comment: "Settings search words, not shown")
        case .about: String(localized: "version help reset remove uninstall delete developer mode acknowledgements licence license", comment: "Settings search words, not shown")
        case .advanced: String(localized: "developer hermes dashboard status troubleshooting companion", comment: "Settings search words, not shown")
        }
    }
    /// Saved sign-ins live on the Mac only: the iPhone never holds a password. Keep awake is the Mac's own sleep.
    #if os(macOS)
    static let hasSignIns = true
    static let hasKeepAwake = true
    #else
    static let hasSignIns = false
    static let hasKeepAwake = false
    #endif

    /// `away`: Away from home shows on a Mac that runs its own assistant and on a phone linked to one.
    /// `weekly`: the weekly note is the owner's, so a member of someone's household never sees it.
    static func visible(developerMode: Bool, away: Bool = false, weekly: Bool = true, matching search: String = "") -> [Self] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.filter { category in
            (developerMode || category != .advanced) && (category != .signIns || hasSignIns) && (category != .away || away) &&
            (category != .weekly || weekly) &&
            (category != .keepAwake || hasKeepAwake) &&
            (query.isEmpty || (category.title + " " + category.keywords).localizedCaseInsensitiveContains(query))
        }
    }
}
