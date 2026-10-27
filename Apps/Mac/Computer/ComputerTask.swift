import Foundation

/// One approved use of this Mac: which bot, which chat, which apps, and until when.
/// Nothing runs without one, and it never outlives its limits: 30 minutes in all, 5 without a
/// single action. Pure values, so the limits are tested without a clock or a helper process.
struct ComputerTask: Equatable, Sendable, Identifiable {
    static let lifetime: TimeInterval = 30 * 60
    static let idleLimit: TimeInterval = 5 * 60

    struct App: Equatable, Hashable, Sendable {
        var info: ComputerAppInfo
        var viewOnly: Bool
        var name: String { info.name }
        var bundleID: String { info.bundleID }
    }

    /// The secret the add-on proves the task with on every action. Never shown.
    let id: String
    let botName: String
    let profile: String
    /// The chat, as Nollie Computer keys it: the bot, "/", and the chat's first session.
    let sessionID: String
    /// The chat's own session ids: the one that asked and each before it, back to the first, and
    /// any found since that continue it. Hermes gives a chat a new id when it compresses.
    private(set) var chatIDs: Set<String>
    /// What the bot said it needs the apps for, shown on the card.
    let purpose: String
    let apps: [App]
    let startedAt: Date
    private(set) var lastActivity: Date
    /// The app the bot last acted in, for the "Using Mail: Stop" panel.
    private(set) var currentApp: String?
    /// Actions that reached an app, and pictures of a window the model on this Mac looked at, for
    /// Papertrail. Pictures never leave the Mac, so none of them is ever sent anywhere.
    private(set) var actions = 0
    private(set) var looks = 0

    init(id: String = ComputerTask.newID(), botName: String, profile: String, sessionID: String, chatIDs: [String] = [],
         purpose: String, apps: [App], startedAt: Date) {
        self.id = id
        self.botName = botName
        self.profile = profile
        self.sessionID = sessionID
        self.chatIDs = Set(chatIDs)
        self.purpose = purpose
        self.apps = apps
        self.startedAt = startedAt
        self.lastActivity = startedAt
        self.currentApp = apps.first?.name
    }

    var expiresAt: Date { startedAt.addingTimeInterval(Self.lifetime) }
    var idleAt: Date { lastActivity.addingTimeInterval(Self.idleLimit) }
    /// The next moment a limit could end the task.
    var nextDeadline: Date { min(expiresAt, idleAt) }

    enum End: Equatable, Sendable {
        case expired, idle, stopped, phone, finished, presence, away, otherApp, otherControl, helperExited
        /// Why it ended. Goes back to the bot's model as a refusal, so it stays in English.
        var message: String {
            switch self {
            case .expired: "Time's up. The 30 minutes you allowed are over."
            case .idle: "Stopped after 5 minutes without anything to do."
            case .stopped: "You stopped it."
            case .phone: "You stopped it from your iPhone."
            case .finished: "The bot said it was done."
            case .presence: "Stopped because your Mac locked or went to sleep."
            case .away: "Stopped because nobody has used the Mac for 5 minutes."
            case .otherApp: "Stopped because another app opened after the bot's last step."
            case .otherControl: "Stopped because something else started controlling the Mac."
            case .helperExited: "Stopped because Nollie Computer quit."
            }
        }
    }

    /// Whether a limit has ended the task at `now`. Expiry wins over idleness.
    func limit(at now: Date) -> End? {
        if now >= expiresAt { return .expired }
        if now >= idleAt { return .idle }
        return nil
    }

    func app(_ bundleID: String) -> App? { apps.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame } }

    /// The approved app a bot named, by name or bundle id.
    func app(named name: String) -> App? {
        apps.first { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.bundleID.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether a bot's session id is this task's chat, by Hermes's own ids only.
    func isChat(profile: String, sessionID: String) -> Bool {
        profile == self.profile && !sessionID.isEmpty && (self.sessionID == profile + "/" + sessionID || chatIDs.contains(sessionID))
    }

    /// Session ids found to continue this task's chat.
    mutating func noteChatIDs(_ ids: [String]) { chatIDs.formUnion(ids) }

    mutating func noteAction() { actions += 1 }
    mutating func noteLook() { looks += 1 }

    mutating func noteActivity(in app: App?, at now: Date) {
        lastActivity = max(lastActivity, now)
        if let app { currentApp = app.name }
    }

    static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
