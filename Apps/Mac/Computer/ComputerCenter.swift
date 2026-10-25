#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import NollieCore
import Observation

/// What the bot asked for in `mac_start`.
struct ComputerStartRequest: Sendable, Equatable {
    /// The Hermes session the request came from, checked with Hermes before any card shows.
    var sessionID: String
    var profile: String
    var apps: [String]
    var purpose: String
    /// The process that sent it, from the kernel (never from the request itself).
    var peer: ComputerPeer? = nil
}

/// One action from the bot, as the add-on relays it.
struct ComputerActRequest: Sendable, Equatable {
    var kind: ComputerAction.Kind
    var app: String
    var element: String?
    var x: Double?
    var y: Double?
    var text: String?
    var keys: [String] = []
    var direction: String?
    var amount: Int?
    var query: String?
}

/// What goes back to the bot: MCP content.
enum ComputerContent: Sendable, Equatable {
    case text(String)
    case image(base64: String, mimeType: String)
}

/// A request waiting on the person, shown as the approval card.
struct ComputerApproval: Identifiable, Equatable, Sendable {
    struct Refused: Equatable, Sendable, Hashable { var name: String; var reason: String }
    let id = UUID()
    var botName: String
    var request: ComputerStartRequest
    var apps: [ComputerTask.App]
    var refused: [Refused]
    /// The chat the request came from, as Hermes names it, so the person sees which one asked.
    var chatTitle = ""
    var platform = ""
}

/// A risky action waiting on the person.
struct ComputerConfirmation: Identifiable, Equatable, Sendable {
    let id = UUID()
    var botName: String
    /// Finishes "<bot> wants to …".
    var sentence: String
    /// "You're about to press “Send”.", shown under the title for a button that sends, pays,
    /// posts or deletes.
    var check: String? = nil
}

/// Where the cards, the Stop panel and the permission walkthrough appear. Panels on the Mac; a
/// recorder in tests.
@MainActor protocol ComputerPresenting: AnyObject {
    func showApproval()
    func showConfirmation()
    func hideCards()
    func showStop()
    func hideStop()
    func showPermissions()
}

/// The one place a bot's use of this Mac is decided: Ask (the approval card), Show (the Stop
/// panel) and Stop. Nothing runs without an approved task, at most one task runs at a time,
/// and every limit ends it by stopping the helper process itself.
@MainActor
@Observable
final class ComputerCenter {
    static let shared = ComputerCenter()

    private(set) var approval: ComputerApproval?
    private(set) var confirmation: ComputerConfirmation?
    private(set) var task: ComputerTask?
    private(set) var lastEnd: ComputerTask.End?
    /// True while Nollie Computer is starting after an approval.
    private(set) var starting = false

    @ObservationIgnored weak var presenter: (any ComputerPresenting)?
    /// Told when a task starts, to send the iPhone its "started using your Mac" alert with Stop.
    @ObservationIgnored var announceStart: ((ComputerTask) -> Void)?
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var botName: (String) -> String = { profile in
        AppModel.shared.runtime?.profiles.first { $0.name == profile }?.shownName ?? profile.capitalized
    }
    @ObservationIgnored var resolveApp: @Sendable (String) -> ComputerAppInfo? = ComputerApps.find
    @ObservationIgnored var permissionsGranted: () -> Bool = { AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() }
    @ObservationIgnored var personPresent: () -> Bool = ComputerPresence.personIsAtTheMac
    @ObservationIgnored var helperAvailable: () -> Bool = { ComputerHelper.isBundled }
    @ObservationIgnored var startHelper: @Sendable ([ComputerTask.App]) async throws -> any ComputerDriving = ComputerCenter.launchHelper
    @ObservationIgnored var answerTimeout: TimeInterval = 120
    /// Asks Hermes for the pending `mac_start` call a request answers, and the chat it is in. Never
    /// trusts what the caller says about itself.
    @ObservationIgnored var verifySession: (ComputerStartRequest) async -> Result<ComputerSessionFacts, Refusal> = ComputerSessionCheck.check
    /// Why Nollie can't start now because something else can drive this Mac (Hermes's own System
    /// control, or a standalone Cua Driver), or nil.
    @ObservationIgnored var otherControl: () async -> String? = ComputerOtherControl.check
    /// The same, from what is already known plus a fresh look for driver processes: once a second.
    @ObservationIgnored var otherControlNow: () async -> String? = {
        ComputerOtherControl.quickCheck(driverRunning: await Task.detached { ComputerOtherControl.otherDriverRunning() }.value)
    }
    /// The session a chat continued from, by Hermes's own record (`parent_session_id`).
    @ObservationIgnored var parentSession: (_ profile: String, _ sessionID: String) async -> String? = { await ComputerSessionCheck.parent(profile: $0, of: $1) }
    /// After the person's yes: whether the request's call is still the one waiting in Hermes.
    @ObservationIgnored var stillPending: (ComputerStartRequest, String) async -> Bool = ComputerSessionCheck.stillPending
    /// Whether a profile is private: its chats are never read or shown.
    @ObservationIgnored var isPrivate: (String) -> Bool = { PrivateBots.isPrivate($0) || $0.lowercased() == "private" }
    /// Touch ID or the Mac's password, behind every Allow: no other process can answer it.
    @ObservationIgnored var authenticate: (String) async -> Bool = ComputerOwnerCheck.authenticate
    /// The running app's pid, for an approved app: only the copy the person approved, never another
    /// app that gives itself the same bundle id.
    @ObservationIgnored var runningPID: @Sendable (ComputerTask.App) -> Int? = { app in
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .first { ComputerAppInfo.runningCopyIsSignedBy(pid: $0.processIdentifier, bundleID: app.bundleID, signer: app.info.signer) }
            .map { Int($0.processIdentifier) }
    }
    /// Whether an app is built on a web engine (Electron or Chromium Embedded), so a page sees
    /// every key first.
    @ObservationIgnored var isWebApp: @Sendable (ComputerTask.App) -> Bool = { app in
        guard let path = app.info.path else { return true }
        let frameworks = URL(fileURLWithPath: path).appendingPathComponent("Contents/Frameworks")
        return ["Electron Framework.framework", "Chromium Embedded Framework.framework"].contains {
            FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path)
        }
    }
    /// The menu command a key combination runs in an app.
    @ObservationIgnored var resolveShortcut: @Sendable (_ pid: Int, _ key: String, _ modifiers: [String]) -> ComputerAction.Shortcut? = ComputerAXProbe.shortcut
    @ObservationIgnored var isLocked: () -> Bool = ComputerPresence.isLocked
    /// Reads an element of an app again, live, from its screen frame (for typing and keys).
    @ObservationIgnored var inspect: @Sendable (_ pid: Int, _ frame: CGRect?) -> ComputerAction.Target? = ComputerAXProbe.target

    @ObservationIgnored private var helper: (any ComputerDriving)?
    /// The process the running task answers to: the one that asked for it.
    @ObservationIgnored private var owner: ComputerPeer?
    @ObservationIgnored private var approvalAnswer: CheckedContinuation<Answer, Never>?
    @ObservationIgnored private var confirmationAnswer: CheckedContinuation<Answer, Never>?
    @ObservationIgnored private var limitWatch: Task<Void, Never>?
    @ObservationIgnored private var elements: [String: Element] = [:]
    @ObservationIgnored private var lastWindow: [Int: Int] = [:]
    /// Apps whose element map is a full look with nothing done since: only then is a point in
    /// the screenshot judged by what Nollie saw there.
    @ObservationIgnored private var freshLook: Set<Int> = []
    /// One action at a time: a second one waits for nothing and is refused.
    @ObservationIgnored private var acting = false
    /// When Nollie's own actions reached the Mac, so they never count as a person being there.
    @ObservationIgnored private var botInput: [ClosedRange<Date>] = []
    @ObservationIgnored private var personSeen = Date.distantPast
    /// Seconds since the last keyboard, mouse or trackpad input, whoever made it.
    @ObservationIgnored var secondsSinceInput: () -> TimeInterval = ComputerPresence.secondsSinceInput
    @ObservationIgnored private var presence: ComputerPresence?
    /// Hermes tool calls already answered with a card: each request is good for one, also after
    /// Nollie restarts.
    @ObservationIgnored var usedCalls = ComputerUsedCalls()
    /// True only while an action is on its way to the app: an app coming forward then is the bot's doing.
    @ObservationIgnored private var sending = false
    /// A start request is being checked, shown or started.
    @ObservationIgnored private var requesting = false
    /// Another app came forward just after the bot's last step while a card was up.
    @ObservationIgnored private var escaped = false
    @ObservationIgnored private var frontWatch: (any NSObjectProtocol)?

    struct Element: Equatable {
        var pid: Int
        var windowID: Int
        var role: String?
        var label: String?
        /// The address the driver reported for it, if any.
        var url: String? = nil
        /// Inside a link, by the driver's own tree (a link's text or picture).
        var inLink = false
        /// In web content, by the driver's own tree.
        var inWebContent = false
        /// Screen points, top left: where Nollie reads the element again.
        var frame: CGRect?
        /// Pixels of the screenshot the bot saw: where its x and y are.
        var screenshotFrame: CGRect?
    }

    struct Refusal: Error, Equatable { var message: String }
    enum Answer: Sendable { case allow, deny, timeout, ended }

    // MARK: Ask

    static let noHelper = "This copy of Nollie can't use the Mac."
    static let off = "Nollie Computer is off on this Mac. The person can turn it on in a bot's settings, under Your Mac."
    /// The setting, app-wide: off until the person turns it on.
    static let enabledKey = "nollie.computer.enabled"
    @ObservationIgnored var enabled: () -> Bool = { UserDefaults.standard.bool(forKey: ComputerCenter.enabledKey) }
    static let unattended = "Nobody is at the Mac right now, so Nollie won't let a bot use it. Try again when the person is back."
    static let needsPermissions = "Nollie needs Accessibility and Screen Recording first. The person can allow them in the window Nollie just opened on the Mac."
    static let busy = "Another bot is using the Mac. Try again when it's done."
    static let asking = "Nollie is already asking the person about another request."
    static let noAnswer = "Nobody answered on the Mac, so nothing was allowed."
    static let declined = "The person said no. Don't try again unless they ask."

    func requestStart(_ request: ComputerStartRequest) async -> Result<ComputerTask, Refusal> {
        guard helperAvailable() else {
            return .failure(Refusal(message: Self.noHelper))
        }
        if request.sessionID.isEmpty || request.sessionID.hasPrefix("cron_") || !personPresent() {
            return .failure(Refusal(message: Self.unattended))
        }
        // A private bot's chats are never read, so they can't be checked: never.
        if isPrivate(request.profile) { return .failure(Refusal(message: ComputerSessionCheck.unknown)) }
        guard enabled() else { return .failure(Refusal(message: Self.off)) }
        // One request at a time, from here until it is answered: a second one can't slip in
        // between the checks and the card.
        if approval != nil || starting || requesting { return .failure(Refusal(message: Self.asking)) }
        requesting = true
        defer { requesting = false }
        guard permissionsGranted() else {
            presenter?.showPermissions()
            return .failure(Refusal(message: Self.needsPermissions))
        }
        starting = true
        let verified = await verifySession(request)
        let otherDriver = await otherControl()
        starting = false
        guard case let .success(facts) = verified else {
            if case let .failure(refusal) = verified { return .failure(refusal) }
            return .failure(Refusal(message: ComputerSessionCheck.unknown))
        }
        if let otherDriver { return .failure(Refusal(message: otherDriver)) }
        // From here on, the bot is the one Hermes filed the chat under.
        let profile = facts.profile.isEmpty ? request.profile : facts.profile
        if isPrivate(profile) { return .failure(Refusal(message: ComputerSessionCheck.unknown)) }
        let call = facts.chat + "/" + facts.callID
        guard !usedCalls.contains(call) else { return .failure(Refusal(message: ComputerSessionCheck.noPendingCall)) }
        if approval != nil || starting { return .failure(Refusal(message: Self.asking)) }
        if let task {
            guard task.sessionID == facts.chat else { return .failure(Refusal(message: Self.busy)) }
            end(.finished)
        }
        usedCalls.insert(call)

        var apps: [ComputerTask.App] = []
        var refused: [ComputerApproval.Refused] = []
        let resolve = resolveApp
        let found = await Task.detached { request.apps.prefix(8).map { (name: $0, info: resolve($0)) } }.value
        for (name, info) in found {
            guard let info else {
                refused.append(.init(name: name, reason: "Not on this Mac."))
                continue
            }
            switch ComputerAppRules.access(for: info) {
            case .use: apps.append(.init(info: info, viewOnly: false))
            case .viewOnly: apps.append(.init(info: info, viewOnly: true))
            case let .never(reason): refused.append(.init(name: info.name, reason: reason))
            }
        }
        apps = apps.reduce(into: []) { kept, app in if !kept.contains(where: { $0.bundleID == app.bundleID }) { kept.append(app) } }
        guard !apps.isEmpty else {
            let reasons = refused.map { "\($0.name): \($0.reason)" }.joined(separator: " ")
            return .failure(Refusal(message: "None of those apps can be used. " + reasons))
        }

        let bot = botName(profile)
        approval = ComputerApproval(botName: bot, request: request, apps: apps, refused: refused,
                                    chatTitle: facts.title,
                                    platform: facts.platform.isEmpty ? ComputerOtherControl.platformName(facts.source) : facts.platform)
        lastEnd = nil
        presenter?.showApproval()
        let answer = await waitForApproval()
        approval = nil
        presenter?.hideCards()
        if answer == .timeout { return .failure(Refusal(message: Self.noAnswer)) }
        guard answer == .allow else { return .failure(Refusal(message: Self.declined)) }
        guard personPresent() else { return .failure(Refusal(message: Self.unattended)) }

        // Everything again after the yes: the card may have been up for two minutes.
        starting = true
        defer { starting = false }
        if let otherDriver = await otherControl() { return .failure(Refusal(message: otherDriver)) }
        guard await stillPending(request, facts.callID) else { return .failure(Refusal(message: ComputerSessionCheck.noPendingCall)) }
        if self.task != nil { return .failure(Refusal(message: Self.busy)) }
        let helper: any ComputerDriving
        do {
            helper = try await startHelper(apps)
        } catch {
            return .failure(Refusal(message: (error as? LocalizedError)?.errorDescription ?? ComputerHelper.Failure.notReady.errorDescription!))
        }
        self.helper = helper
        owner = request.peer
        elements = [:]
        lastWindow = [:]
        freshLook = []
        botInput = []
        personSeen = now()
        let task = ComputerTask(botName: bot, profile: profile, sessionID: facts.chat, chatIDs: facts.lineage,
                                purpose: request.purpose, apps: apps, startedAt: now())
        self.task = task
        presenter?.showStop()
        announceStart?(task)
        watchLimits()
        watchPresence()
        return .success(task)
    }

    func answerApproval(_ allowed: Bool) { resolveApproval(allowed ? .allow : .deny) }

    /// Allow, from the card: only after Touch ID or the Mac's password, so nothing but the person
    /// at the Mac can say yes (any app with Accessibility could press the button itself).
    func allowWithOwner() async {
        guard let approval else { return }
        let apps = approval.apps.map(\.name).joined(separator: ", ")
        guard await authenticate("let \(approval.botName) use \(apps)"), self.approval?.id == approval.id else { return }
        answerApproval(true)
    }

    /// Allow Once, from a confirmation card: the same proof, for each risky step.
    func allowOnceWithOwner(id: UUID) async {
        guard let confirmation, confirmation.id == id else { return }
        guard await authenticate("let \(confirmation.botName) \(confirmation.sentence)"), self.confirmation?.id == id else { return }
        answerConfirmation(true, id: id)
    }

    /// The person's answer to the confirmation card they saw. An answer for a card that has
    /// since gone is ignored, so a click can never approve a different action.
    func answerConfirmation(_ allowed: Bool, id: UUID? = nil) {
        guard id == nil || id == confirmation?.id else { return }
        resolveConfirmation(allowed ? .allow : .deny)
    }

    private func resolveApproval(_ answer: Answer) {
        approvalAnswer?.resume(returning: answer)
        approvalAnswer = nil
    }

    private func resolveConfirmation(_ answer: Answer) {
        confirmationAnswer?.resume(returning: answer)
        confirmationAnswer = nil
    }

    /// Waits for the card's answer, or the timeout.
    private func waitForApproval() async -> Answer {
        let timeout = answerTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.resolveApproval(.timeout)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { approvalAnswer = $0 }
    }

    private func waitForConfirmation(_ confirmation: ComputerConfirmation) async -> Answer {
        self.confirmation = confirmation
        escaped = false
        presenter?.showConfirmation()
        let timeout = answerTimeout
        let id = confirmation.id
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, self?.confirmation?.id == id else { return }
            self?.resolveConfirmation(.timeout)
        }
        defer { timer.cancel() }
        let answer = await withCheckedContinuation { confirmationAnswer = $0 }
        self.confirmation = nil
        presenter?.hideCards()
        // Something else opened while the card was up, just after the bot's last step.
        if escaped, task != nil {
            escaped = false
            end(.otherApp)
            return .ended
        }
        return answer
    }

    // MARK: Act

    static let ended = "Access to the Mac has ended. Ask again with mac_start if the person wants."
    static let stillActing = "Nollie is still doing the last action. Wait for its answer, then try again."
    static let staleElement = "Use an element from a new mac_look of that app: each look is good for one action."
    static let lookFirst = "Look again with mac_look first: the window may have changed."
    static let notAField = "Nollie only types into a text field it can see, so look again and use the field's token."
    static let cantCheckKey = "Nollie couldn't check where that key would go, so it didn't press it."
    static let focusFirst = "Click that element first so the keys go there, then try again."
    static let focusMoved = "The focus moved while you were asked, so Nollie didn't press that. Look again first."
    static let linkByPoint = "Click a link by its spot in the screenshot (x and y), so Nollie can check what's there."
    static let scrollWhere = "Scroll at an element from your latest mac_look, by its token."

    func perform(taskID: String, _ act: ComputerActRequest, from peer: ComputerPeer? = nil) async -> Result<[ComputerContent], Refusal> {
        guard let task, task.id == taskID, helper != nil, peer == owner else { return .failure(Refusal(message: Self.ended)) }
        guard !acting else { return .failure(Refusal(message: Self.stillActing)) }
        acting = true
        defer { acting = false }
        return await performOne(task, act)
    }

    private func performOne(_ started: ComputerTask, _ act: ComputerActRequest) async -> Result<[ComputerContent], Refusal> {
        var task = started
        if let limit = task.limit(at: now()) {
            end(limit)
            return .failure(Refusal(message: limit.message))
        }
        guard let app = task.app(named: act.app) else {
            return .failure(Refusal(message: "\(act.app) isn't approved for this task. Approved: \(task.apps.map(\.name).joined(separator: ", "))."))
        }
        // Asking other apps (Accessibility, signatures) can wait on them: never on the main thread,
        // so Stop and the cards always answer.
        let probe = inspect, find = runningPID, menu = resolveShortcut, web = isWebApp
        guard let pid = await Self.off({ find(app) }) else {
            return .failure(Refusal(message: "\(app.name) isn't open."))
        }

        // What the action lands on: Nollie's own last look (good for one action only), checked
        // against what the app reports now.
        var element: Element?
        if let token = act.element {
            guard let known = elements[token], known.pid == pid else { return .failure(Refusal(message: Self.staleElement)) }
            element = known
        } else if act.kind == .click, let x = act.x, let y = act.y {
            guard freshLook.contains(pid) else { return .failure(Refusal(message: Self.lookFirst)) }
            element = hit(CGPoint(x: x, y: y), pid: pid)
        }
        var target = element.map { ComputerAction.Target(role: $0.role, label: $0.label) }
        var shortcut: ComputerAction.Shortcut?
        var clickPoint: CGPoint?
        var seenLive: ComputerAction.Target?
        var seenFocus: ComputerAction.Target?
        switch act.kind {
        case .look:
            break
        case .scroll:
            // A scroll needs a place: a wheel at an element, which moves no focus and presses nothing.
            guard element != nil else { return .failure(Refusal(message: Self.scrollWhere)) }
        case .click:
            // Judged on what is at that spot now, as well as on what Nollie saw there. Anything it
            // can't confirm is a spot it can't name, which the person confirms.
            if let element {
                let point = act.element == nil ? Self.screenPoint(CGPoint(x: act.x ?? 0, y: act.y ?? 0), in: element) : element.frame.map { CGPoint(x: $0.midX, y: $0.midY) }
                clickPoint = point
                let live = await Self.probe(probe, pid, point)
                seenLive = live
                if let live, act.element == nil || Self.sameElement(live, element) {
                    target = Self.merged(element, live)
                } else {
                    target = nil
                }
                // By token the driver presses the element it remembers, which something else may
                // cover: a link only by its spot, where Nollie and the driver find the same one.
                if act.element != nil, target?.isLink == true || element.role == "AXLink" || element.inLink {
                    return .failure(Refusal(message: Self.linkByPoint))
                }
            }
        case .type:
            guard let element else { break }
            let frame = element.frame
            guard let live = await Self.off({ probe(pid, frame) }), Self.sameElement(live, element),
                  let role = live.role, ComputerActionRules.textRoles.contains(role) else {
                return .failure(Refusal(message: Self.notAField))
            }
            // The driver may fall back to typing keys, which go where focus is: it must be this field.
            guard let focused = await Self.off({ probe(pid, nil) }) else { return .failure(Refusal(message: Self.cantCheckKey)) }
            seenFocus = focused
            if ComputerActionRules.isSecret(focused) { return .failure(Refusal(message: ComputerActionRules.secret)) }
            guard Self.sameElement(focused, element), !focused.isLink else { return .failure(Refusal(message: Self.focusFirst)) }
            target = Self.merged(element, live)
        case .key:
            // A key goes to the focused element (or the token's, which the driver focuses first).
            guard let focused = await Self.off({ probe(pid, nil) }) else { return .failure(Refusal(message: Self.cantCheckKey)) }
            seenFocus = focused
            if let element {
                let frame = element.frame
                guard let live = await Self.off({ probe(pid, frame) }), Self.sameElement(live, element) else {
                    return .failure(Refusal(message: Self.staleElement))
                }
                // The driver moves focus there only as best it can: the key may go where focus is
                // now, so the two must be the same.
                guard Self.sameElement(focused, element) else { return .failure(Refusal(message: Self.focusFirst)) }
                target = Self.merged(element, live)
                // The focused one is what gets the key: a link there is a link.
                if focused.isLink {
                    target?.inLink = true
                    target?.url = focused.url
                }
            } else {
                target = focused
            }
            if ComputerActionRules.isSecret(focused) { target?.subrole = "AXSecureTextField" }
            // An app built on a web engine is web content throughout, however deep its tree.
            if focused.inWebContent { target?.inWebContent = true }
            if await Self.off({ web(app) }) { target?.inWebContent = true }
            if let (held, key) = ComputerActionRules.canonicalKeys(act.keys), held.contains(where: { $0 != "shift" }) {
                shortcut = await Self.off { menu(pid, key, held) }
            }
        }
        let action = ComputerAction(kind: act.kind, target: target, text: act.text, keys: act.keys, shortcut: shortcut)
        // Stop while Nollie was asking the app wins.
        guard let current = self.task, current.id == started.id else { return .failure(Refusal(message: lastEnd?.message ?? Self.ended)) }
        task = current
        task.noteActivity(in: app, at: now())
        self.task = task
        switch ComputerActionRules.decide(action, in: app) {
        case .allow: break
        case let .refuse(message): return .failure(Refusal(message: message))
        case let .confirm(sentence):
            let asking = ComputerConfirmation(botName: task.botName, sentence: sentence, check: ComputerActionRules.check(for: action))
            switch await waitForConfirmation(asking) {
            case .allow: break
            case .ended: return .failure(Refusal(message: lastEnd?.message ?? Self.ended))
            case .timeout: return .failure(Refusal(message: "Nobody answered on the Mac, so Nollie didn't do that."))
            case .deny: return .failure(Refusal(message: "The person said no to that. Don't do it another way."))
            }
            // The person said yes to what was under that spot then. Content moves and pages change
            // their words: the same thing, with the same words and address, must still be there.
            if act.kind == .click, let judged = seenLive {
                let again = await Self.probe(probe, pid, clickPoint)
                guard let again, again.role == judged.role, again.label == judged.label, again.url == judged.url,
                      again.isLink == judged.isLink, let a = again.frame, let b = judged.frame,
                      abs(a.minX - b.minX) <= 2, abs(a.minY - b.minY) <= 2, abs(a.width - b.width) <= 2, abs(a.height - b.height) <= 2 else {
                    return .failure(Refusal(message: Self.lookFirst))
                }
            }
            // A key or a typed line break goes where focus is: it must still be where the person
            // saw it, and a link that came into focus meanwhile is judged as one.
            if act.kind == .key || act.kind == .type, let judged = seenFocus {
                let again = await Self.off({ probe(pid, nil) })
                guard let again, again.role == judged.role, again.label == judged.label, again.url == judged.url,
                      again.isLink == judged.isLink, let a = again.frame, let b = judged.frame,
                      abs(a.minX - b.minX) <= 2, abs(a.minY - b.minY) <= 2, abs(a.width - b.width) <= 2, abs(a.height - b.height) <= 2 else {
                    return .failure(Refusal(message: Self.focusMoved))
                }
            }
            guard var current = self.task, current.id == task.id else { return .failure(Refusal(message: lastEnd?.message ?? Self.ended)) }
            current.noteActivity(in: app, at: now())
            self.task = current
        }
        guard let helper else { return .failure(Refusal(message: Self.ended)) }
        let session = app.viewOnly ? "view" : "use"
        let taskID = task.id
        do {
            if act.kind == .look {
                let (content, seen, window) = try await Task.detached { try Self.look(helper, session: session, pid: pid, query: act.query) }.value
                guard self.task?.id == taskID else { return .failure(Refusal(message: lastEnd?.message ?? Self.ended)) }
                elements = elements.filter { $0.value.pid != pid }.merging(seen) { $1 }
                lastWindow[pid] = window
                if act.query?.isEmpty ?? true { freshLook.insert(pid) } else { freshLook.remove(pid) }
                return .success(content)
            }
            // Each look is good for one action: after it, the window may have changed.
            freshLook.remove(pid)
            elements = elements.filter { $0.value.pid != pid }
            guard let (tool, arguments) = Self.driverArguments(act, pid: pid, element: element, lastWindow: lastWindow[pid]) else {
                return .failure(Refusal(message: "Nollie couldn't work out where to do that."))
            }
            // The last word before anything reaches the app: a Stop pressed during the checks wins.
            guard self.task?.id == taskID, self.helper === helper else { return .failure(Refusal(message: lastEnd?.message ?? Self.ended)) }
            let sent = now()
            sending = true
            defer {
                sending = false
                botInput.append(sent...now().addingTimeInterval(1.5))
                botInput = botInput.suffix(50)
            }
            try await Task.detached { _ = try helper.call(session, tool, arguments.dictionary) }.value
            return .success([.text("Done. Use mac_look before the next action.")])
        } catch ComputerHelper.Failure.refused(let message) {
            return .failure(Refusal(message: message))
        } catch {
            // The connection to the helper broke: nothing can be trusted about it now.
            if self.task?.id == taskID { end(.helperExited) }
            return .failure(Refusal(message: ComputerTask.End.helperExited.message))
        }
    }

    /// Work that may wait on another app (Accessibility, signatures), off the main thread.
    nonisolated static func off<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached { work() }.value
    }

    nonisolated static func probe(_ probe: @escaping @Sendable (Int, CGRect?) -> ComputerAction.Target?, _ pid: Int,
                                  _ point: CGPoint?) async -> ComputerAction.Target? {
        guard let point else { return nil }
        return await off { probe(pid, CGRect(origin: point, size: .zero)) }
    }

    /// The same element as Nollie saw: its frame now matches the recorded one within two points.
    nonisolated static func sameElement(_ live: ComputerAction.Target, _ element: Element) -> Bool {
        guard let a = live.frame, let b = element.frame else { return false }
        return abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    /// What Nollie saw and what the app says now, with a risky label from either winning. A link
    /// in either is a link: what the app says now never makes one something else.
    nonisolated static func merged(_ element: Element, _ live: ComputerAction.Target) -> ComputerAction.Target {
        let label = ComputerActionRules.risk(in: live.label ?? "") != nil ? live.label : (element.label ?? live.label)
        var target = live
        target.role = element.role == "AXLink" ? "AXLink" : (live.role ?? element.role)
        target.label = label
        target.url = live.url ?? element.url
        target.inLink = live.inLink || element.inLink
        target.inWebContent = live.inWebContent || element.inWebContent
        return target
    }

    /// A point of the screenshot, in screen points, through the element it falls in.
    nonisolated static func screenPoint(_ point: CGPoint, in element: Element) -> CGPoint? {
        guard let s = element.screenshotFrame, let f = element.frame, s.width > 0, s.height > 0 else { return nil }
        return CGPoint(x: f.minX + (point.x - s.minX) * f.width / s.width, y: f.minY + (point.y - s.minY) * f.height / s.height)
    }

    /// The smallest element under a point of the screenshot the bot saw.
    private func hit(_ point: CGPoint, pid: Int) -> Element? {
        elements.values
            .filter { $0.pid == pid && ($0.screenshotFrame?.contains(point) ?? false) }
            .min { ($0.screenshotFrame!.width * $0.screenshotFrame!.height) < ($1.screenshotFrame!.width * $1.screenshotFrame!.height) }
    }

    /// The driver tool and its arguments for an action: always a pid, never `scope: desktop`,
    /// and keys only in the canonical form Nollie judged. Nil when there's nothing safe to send.
    nonisolated static func driverArguments(_ act: ComputerActRequest, pid: Int, element: Element?, lastWindow: Int?)
        -> (String, SendableArguments)? {
        var args: [String: SendableArguments.Value] = ["pid": .int(pid)]
        // Never for a scroll: the driver focuses a token's element first, which a scroll mustn't do.
        if let token = act.element, act.kind != .scroll { args["element_token"] = .string(token) }
        switch act.kind {
        case .look:
            return ("get_window_state", SendableArguments(args))
        case .click:
            if act.element == nil {
                guard let x = act.x, let y = act.y, let window = element?.windowID ?? lastWindow else { return nil }
                args["x"] = .double(x)
                args["y"] = .double(y)
                args["window_id"] = .int(window)
            }
            return ("click", SendableArguments(args))
        case .type:
            guard act.element != nil else { return nil }
            args["text"] = .string(act.text ?? "")
            return ("type_text", SendableArguments(args))
        case .key:
            guard let (modifiers, key) = ComputerActionRules.canonicalKeys(act.keys) else { return nil }
            if modifiers.isEmpty {
                args["key"] = .string(key)
                return ("press_key", SendableArguments(args))
            }
            args["keys"] = .strings(modifiers + [key])
            return ("hotkey", SendableArguments(args))
        case .scroll:
            // A wheel at the element's centre in the screenshot, never by token (that moves focus).
            guard let frame = element?.screenshotFrame, let window = element?.windowID else { return nil }
            args["x"] = .double(frame.midX)
            args["y"] = .double(frame.midY)
            args["window_id"] = .int(window)
            args["direction"] = .string(["up", "down", "left", "right"].contains(act.direction ?? "") ? act.direction! : "down")
            args["amount"] = .int(max(1, min(act.amount ?? 3, 20)))
            return ("scroll", SendableArguments(args))
        }
    }

    /// The app's front window: its elements and one screenshot.
    nonisolated private static func look(_ helper: any ComputerDriving, session: String, pid: Int, query: String?) throws
        -> ([ComputerContent], [String: Element], Int) {
        let listed = try helper.call(session, "list_windows", ["pid": pid])
        let windows = (listed["structuredContent"] as? [String: Any])?["windows"] as? [[String: Any]] ?? []
        let normal = windows.filter { ($0["layer"] as? NSNumber)?.intValue ?? 0 == 0 }
        guard let window = (normal.first { $0["is_on_screen"] as? Bool == true } ?? normal.first ?? windows.first),
              let windowID = (window["window_id"] as? NSNumber)?.intValue else {
            throw ComputerHelper.Failure.refused("That app has no window open.")
        }
        // Both: the markdown tree for the bot, and the elements (with their parents) for Nollie.
        var args: [String: Any] = ["pid": pid, "window_id": windowID, "max_image_dimension": 1280, "tree_format": "both"]
        if let query, !query.isEmpty { args["query"] = query }
        let state = try helper.call(session, "get_window_state", args)
        let structured = state["structuredContent"] as? [String: Any] ?? [:]
        var seen: [String: Element] = [:]
        let entries = structured["elements"] as? [[String: Any]] ?? []
        // The driver's tree: each entry names its nearest parent it lists, so a link's text knows its link.
        var byIndex: [Int: [String: Any]] = [:]
        for entry in entries { if let index = (entry["element_index"] as? NSNumber)?.intValue { byIndex[index] = entry } }
        for entry in entries {
            guard let token = entry["element_token"] as? String else { continue }
            // Up the driver's tree to the top: a link anywhere above makes this one. Too deep to
            // see the top counts as a link.
            var inLink = true
            var parent = (entry["parent_index"] as? NSNumber)?.intValue
            for _ in 0..<ComputerAXProbe.ancestorLimit {
                guard let index = parent, let up = byIndex[index] else { inLink = false; break }
                if up["role"] as? String == "AXLink" { break }
                parent = (up["parent_index"] as? NSNumber)?.intValue
            }
            seen[token] = Element(pid: pid, windowID: windowID, role: entry["role"] as? String, label: entry["label"] as? String,
                                  inLink: inLink, inWebContent: entry["in_web_content"] as? Bool ?? false,
                                  frame: rect(entry["frame"]), screenshotFrame: rect(entry["screenshot_frame"]))
        }
        // The rows say [N]; an element's token is this look's snapshot id and N.
        let snapshot = (structured["snapshot_id"] as? String)
            ?? (entries.lazy.compactMap { ($0["element_token"] as? String)?.split(separator: ":").first.map(String.init) }.first)
        let tree = structured["tree_markdown"] as? String ?? "No elements."
        let intro = snapshot.map { "Element tokens for this look: \($0):N for the row marked [N], like \($0):3.\n" } ?? ""
        var content: [ComputerContent] = [.text(intro + tree)]
        if let image = (state["content"] as? [[String: Any]] ?? []).first(where: { $0["type"] as? String == "image" }),
           let data = image["data"] as? String {
            content.append(.image(base64: data, mimeType: image["mimeType"] as? String ?? "image/png"))
        }
        return (content, seen, windowID)
    }

    /// `{x, y, w, h}` from the driver, whose numbers may be integers or not.
    nonisolated static func rect(_ value: Any?) -> CGRect? {
        guard let f = value as? [String: Any], let x = f["x"] as? NSNumber, let y = f["y"] as? NSNumber,
              let w = f["w"] as? NSNumber, let h = f["h"] as? NSNumber else { return nil }
        return CGRect(x: x.doubleValue, y: y.doubleValue, width: w.doubleValue, height: h.doubleValue)
    }

    // MARK: Stop

    /// Ends the task now: the helper process is revoked and gone within a second.
    func end(_ reason: ComputerTask.End) {
        guard task != nil || helper != nil else { resolveConfirmation(.ended); return }
        lastEnd = reason
        resolveConfirmation(.ended)
        let helper = self.helper
        self.helper = nil
        task = nil
        elements = [:]
        lastWindow = [:]
        freshLook = []
        limitWatch?.cancel()
        limitWatch = nil
        presence?.stop()
        presence = nil
        owner = nil
        if let frontWatch { NSWorkspace.shared.notificationCenter.removeObserver(frontWatch) }
        frontWatch = nil
        presenter?.hideStop()
        if let helper { Task.detached { helper.stop() } }
    }

    func stop() { end(.stopped) }

    /// Whether a chat a viewer names is the running task's: the same bot, and one of the ids Hermes
    /// gave that chat. A chat compressed since the task started has a newer id: it is followed
    /// back through Hermes's own parent links, as the start was checked, and remembered. Never a guess.
    func isTaskChat(profile: String, sessionID: String) async -> Bool {
        guard let task, task.profile == profile, !isPrivate(profile) else { return false }
        if task.isChat(profile: profile, sessionID: sessionID) { return true }
        var walked = [sessionID]
        for _ in 0..<30 {
            guard let parent = await parentSession(profile, walked[walked.count - 1]), !walked.contains(parent),
                  var now = self.task, now.id == task.id else { return false }
            if now.isChat(profile: profile, sessionID: parent) {
                now.noteChatIDs(walked)
                self.task = now
                return true
            }
            walked.append(parent)
        }
        return false
    }

    /// The window Nollie last looked at or acted in, for an app's pid: what a live picture shows.
    func lastActedWindow(pid: Int) -> Int? { lastWindow[pid] }

    func finish(taskID: String, from peer: ComputerPeer? = nil) {
        guard task?.id == taskID, peer == owner else { return }
        end(.finished)
    }

    /// Called when the helper process exits on its own.
    func helperExited(_ helper: any ComputerDriving) {
        guard self.helper === helper else { return }
        end(.helperExited)
    }

    private func watchLimits() {
        limitWatch?.cancel()
        limitWatch = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self, let task = self.task else { return }
                // Every second, so a person's input is seen before the bot's next action hides it.
                let wait = max(0.2, min(task.nextDeadline.timeIntervalSince(self.now()), 1))
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let current = self.task else { return }
                if let limit = current.limit(at: self.now()) { self.end(limit); return }
                // Nobody at the Mac any more: a task never runs unattended.
                if !self.personStillThere() { self.end(.away); return }
                if self.isLocked() { self.end(.presence); return }
                if !self.enabled() { self.end(.stopped); return }
                if let helper = self.helper, !helper.isRunning { self.helperExited(helper); return }
                // The add-on that asked is gone: nobody can finish the task, so it ends.
                if let owner = self.owner, !owner.isStillThere { self.end(.finished); return }
                // Something else that can drive the Mac came on: the two can't be kept apart.
                ticks += 1
                // Hermes's own gate for every bot, read again every few seconds.
                if ticks % 5 == 0, !self.refreshing {
                    self.refreshing = true
                    Task { await self.refreshSystemControl(); self.refreshing = false }
                }
                if await self.otherControlNow() != nil, self.task?.id == current.id { self.end(.otherControl); return }
            }
        }
    }

    /// Reads the bots' System control switches again (never a private bot's).
    @ObservationIgnored var refreshSystemControl: @MainActor () async -> Void = { await ComputerOtherControl.refresh() }
    @ObservationIgnored private var refreshing = false

    /// Whether a person has touched the Mac in the last 5 minutes. Input that came from Nollie's
    /// own actions (the driver's events reset the same idle clock) doesn't count.
    func personStillThere() -> Bool {
        let lastInput = now().addingTimeInterval(-secondsSinceInput())
        if !botInput.contains(where: { $0.contains(lastInput) }) { personSeen = max(personSeen, lastInput) }
        return now().timeIntervalSince(personSeen) < ComputerPresence.awayAfter
    }

    /// Another app coming to the front just after the bot acted (a link, a file, an "Open in")
    /// means the bot reached past its apps: the task ends. The person switching apps doesn't count,
    /// and nor does anything while a card waits for them.
    func appCameForward(_ bundleID: String?, at date: Date) {
        guard let task, let bundleID else { return }
        if task.app(bundleID) != nil || bundleID == Bundle.main.bundleIdentifier { return }
        guard sending || botInput.contains(where: { $0.contains(date) }) else { return }
        // While a card waits, the person may switch apps: an escape just after the bot's last step
        // is kept and ends the task when the card closes.
        if confirmation != nil { escaped = true } else { end(.otherApp) }
    }

    private func watchPresence() {
        if let frontWatch { NSWorkspace.shared.notificationCenter.removeObserver(frontWatch) }
        frontWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                       object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.appCameForward(id, at: Date()) }
        }
        presence?.stop()
        let presence = ComputerPresence { [weak self] in self?.end(.presence) }
        presence.start()
        self.presence = presence
    }

    #if DEBUG
    /// Pictures of the screens from the demo copy only:
    /// `-nollie-computer-preview approval|confirm|stop|permissions`. Nothing starts or runs.
    func showPreview(_ screen: String) {
        guard DemoMode.isOn else { return }
        let notes = ComputerTask.App(info: ComputerAppInfo(bundleID: "com.apple.Notes", name: "Notes"), viewOnly: false)
        let safari = ComputerTask.App(info: ComputerAppInfo(bundleID: "com.apple.Safari", name: "Safari"), viewOnly: true)
        switch screen {
        case "approval":
            approval = ComputerApproval(botName: "Scout",
                                        request: ComputerStartRequest(sessionID: "preview", profile: "career", apps: [],
                                                                      purpose: "Copy the three job links from your Safari tabs into a new note."),
                                        apps: [notes, safari], refused: [.init(name: "Terminal", reason: ComputerAppRules.commands)],
                                        chatTitle: "Job hunt", platform: "Nollie")
            presenter?.showApproval()
        case "confirm":
            confirmation = ComputerConfirmation(botName: "Scout", sentence: "send something in Mail: click \u{201C}Send\u{201D}",
                                                check: "You're about to press \u{201C}Send\u{201D}.")
            presenter?.showConfirmation()
        case "stop":
            task = ComputerTask(botName: "Scout", profile: "career", sessionID: "preview", purpose: "", apps: [notes, safari], startedAt: now())
            presenter?.showStop()
        default:
            presenter?.showPermissions()
        }
    }
    #endif

    // MARK: Launching

    /// Opens apps that aren't running yet, starts the helper and opens its sessions.
    nonisolated static func launchHelper(_ apps: [ComputerTask.App]) async throws -> any ComputerDriving {
        // Apps that aren't running yet open in the background; Nollie waits 10 seconds at most.
        let opening = Task {
            for app in apps where NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty {
                // The copy the person approved, never another one with the same bundle id.
                guard let path = app.info.path else { continue }
                let url = URL(fileURLWithPath: path)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
        }
        let deadline = Date().addingTimeInterval(10)
        while !opening.isCancelled, Date() < deadline,
              apps.contains(where: { NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return try await Task.detached { () throws -> any ComputerDriving in
            let helper = try ComputerHelper()
            do {
                if let use = ComputerManifest.use(apps) { try helper.openSession("use", manifest: use) }
                if let view = ComputerManifest.view(apps) { try helper.openSession("view", manifest: view) }
            } catch {
                helper.stop()
                throw error
            }
            return helper
        }.value
    }
}

/// Arguments that cross from the main actor to the helper's thread.
struct SendableArguments: Sendable, Equatable {
    enum Value: Sendable, Equatable { case int(Int), double(Double), string(String), strings([String]) }
    var values: [String: Value]
    init(_ values: [String: Value]) { self.values = values }
    var dictionary: [String: Any] {
        values.mapValues { value -> Any in
            switch value {
            case let .int(v): v
            case let .double(v): v
            case let .string(v): v
            case let .strings(v): v
            }
        }
    }
}
#endif
