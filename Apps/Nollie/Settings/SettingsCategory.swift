import Foundation

/// The small set of top-level settings. Search also finds the controls grouped inside each page.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case bots, appearance, speech, notifications, privacy = "icloud", signIns = "signins", siri = "voice", connection = "gateways", away,
         keepAwake = "awake", about, advanced

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bots: "Bots"
        case .appearance: "Appearance"
        case .speech: "Voice"
        case .notifications: "Notifications"
        case .privacy: "Privacy"
        case .signIns: "Sign-ins"
        case .siri: "Siri & Shortcuts"
        case .connection: "Connection"
        case .away: "Away from home"
        case .keepAwake: "Keep awake"
        case .about: "About"
        case .advanced: "Advanced"
        }
    }
    var symbol: String {
        switch self {
        case .bots: "person.crop.square"
        case .appearance: "circle.lefthalf.filled"
        case .speech: "speaker.wave.2.fill"
        case .notifications: "bell.badge"
        case .privacy: "hand.raised.fill"
        case .signIns: "key.fill"
        case .siri: "app.connected.to.app.below.fill"
        case .connection: "network"
        case .away: "globe"
        case .keepAwake: "sun.max.fill"
        case .about: "info.circle"
        case .advanced: "slider.horizontal.3"
        }
    }
    private var keywords: String {
        switch self {
        case .bots: "bot avatar character face colour color look name default motion tilt"
        case .appearance: "theme dark light text font reading transcript glass summaries titles previews"
        case .speech: "speak speech read aloud talk talking listen hands-free"
        case .notifications: "alert permission sound haptics background"
        case .privacy: "security lock face id touch id approvals permissions camera microphone photos local network notifications accessibility screen recording"
        case .signIns: "password passwords login log in username website site keychain one-time code"
        case .siri: DeviceWords.isMac ? "shortcuts spotlight siri" : "shortcuts spotlight siri stop lock screen live activity"
        case .connection: "setup set up connect gateway sign in models local cloud import"
        case .away: "tailscale remote outside travel anywhere network wifi cellular exit node"
        case .keepAwake: "sleep awake power battery plugged night schedules overnight lid energy"
        case .about: "version help reset remove uninstall delete developer mode acknowledgements licence license"
        case .advanced: "developer hermes dashboard status troubleshooting companion"
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
    static func visible(developerMode: Bool, away: Bool = false, matching search: String = "") -> [Self] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.filter { category in
            (developerMode || category != .advanced) && (category != .signIns || hasSignIns) && (category != .away || away) &&
            (category != .keepAwake || hasKeepAwake) &&
            (query.isEmpty || (category.title + " " + category.keywords).localizedCaseInsensitiveContains(query))
        }
    }
}
