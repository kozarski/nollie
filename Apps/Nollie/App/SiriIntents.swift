import AppIntents
import NollieCore
#if canImport(UIKit)
import UIKit
#endif

// Siri, Shortcuts and Spotlight: ask a helper something (SiriAskHelper.swift), open a recent chat,
// start a new one, ask what a bot is doing, Stop and, when the person has switched it on, answer
// the one approval that is waiting. The phrases are generic. Nothing in them names anyone's bot or
// gateway.

/// One spoken line as an intent result.
private func spoken(_ line: String) -> some IntentResult & ProvidesDialog {
    .result(dialog: IntentDialog(stringLiteral: line))
}

/// Shortcuts and Siri action that opens a recent chat chosen by title.
struct OpenChatIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Chat" }
    static var description: IntentDescription { IntentDescription("Jump into a recent chat in Nollie.") }
    static var openAppWhenRun: Bool { true }
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$chat)") }

    @Parameter(title: "Chat") var chat: ChatEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriFront.start { $0.openStoredChat(id: chat.id, profile: chat.bot) }
    }
}

/// Siri and Shortcuts action: begin a chat with the bot you name, or the default bot.
struct NewChatIntent: AppIntent {
    static var title: LocalizedStringResource { "New Chat" }
    static var description: IntentDescription {
        IntentDescription("Begin a fresh chat in Nollie with a bot you choose, or your usual one.")
    }
    static var openAppWhenRun: Bool { true }
    static var parameterSummary: some ParameterSummary { Summary("New chat with \(\.$bot)") }

    @Parameter(title: "Bot") var bot: BotEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriFront.start { $0.requestNewChat(profile: bot?.id) }
    }
}

/// "What is my bot doing?" Gives the running work and the count of approvals still pending.
struct BotStatusIntent: AppIntent {
    static var title: LocalizedStringResource { "Bot Status" }
    static var description: IntentDescription {
        IntentDescription("Tells you what your bot is up to and whether it needs you.")
    }
    static var openAppWhenRun: Bool { false }
    static var parameterSummary: some ParameterSummary { Summary("What is \(\.$bot) doing") }

    @Parameter(title: "Bot") var bot: BotEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        spoken(await SiriAsk.status(bot: bot))
    }
}

/// Lets you answer the lone pending approval out loud. It requires the setting to be on, an
/// unlocked device, and a spoken confirmation naming the bot and its request.
struct AnswerApprovalIntent: AppIntent {
    static var title: LocalizedStringResource { "Answer Approval" }
    static var description: IntentDescription {
        IntentDescription("Reads out the approval Nollie is waiting on, then approves or denies it.")
    }
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    static var parameterSummary: some ParameterSummary { Summary("\(\.$answer) the waiting approval") }

    @Parameter(title: "Answer", default: .approve) var answer: ApprovalAnswer

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await SiriAsk.plan(for: answer) {
        case .say(let line):
            return spoken(line)
        case .confirm(let question, let waiting):
            try await requestConfirmation(result: spoken(question))
            let choice = answer == .approve ? "once" : "deny"
            // A yes that needs Face ID can't be given by voice: nothing goes out and the card waits.
            guard await waiting.chat.respond(card: waiting.card, result: ["choice": .string(choice)]) else {
                return spoken("Nothing was approved. Open Nollie to answer it.")
            }
            return spoken(answer == .approve ? "Approved." : "Denied.")
        }
    }
}

/// Runs what an intent wants from the app. The Mac window comes forward first; on the phone the
/// system has already opened the app.
private enum SiriFront {
    @MainActor static func start(_ job: (AppModel) -> Void) -> some IntentResult {
        #if os(macOS)
        MacWindow.bringMainForward()
        #endif
        job(AppModel.shared)
        return .result()
    }
}

#if os(iOS)
/// What the Stop control does (see StopMacIntent in Shared/StopMac.swift): ask the linked Mac to
/// stop through the gateway, then stop the replies this phone is running. The Lock Screen
/// activity shows how it went.
@MainActor
enum MacStop {
    static func press() async -> String {
        let activities = HelperAtWorkActivities.shared
        await activities.stopping()
        let outcome = await send()
        await activities.stopFinished(reachedMac: outcome == MacStopWords.stopped)
        return outcome
    }

    private static func send() async -> String {
        let app = AppModel.shared
        guard app.hasConnections else { return MacStopWords.notLinked }
        if app.runtime == nil { await app.activateSavedConnection() }
        guard let runtime = app.runtime, runtime.connection.linkedMac != nil else { return MacStopWords.notLinked }

        do {
            _ = try await runtime.api.raw("POST", "/nollie/stop", body: nil, authenticated: true, timeout: 8)
        } catch {
            return MacStopWords.unreachable
        }
        // The Mac stops what it runs. Replies started on this phone stop once the answer is out,
        // so a slow socket cannot hold the answer up.
        let startedHere = runtime.chats.filter(\.isRunning)
        Task { @MainActor in
            for chat in startedHere { await chat.stop() }
        }
        return MacStopWords.stopped
    }
}
#endif

/// Ready with no setup: Siri, Spotlight, the Shortcuts app and the Action button list these.
struct NollieShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .lightBlue }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHelperIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) something",
                "Ask \(\.$helper) in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Ask Nollie"),
            systemImageName: "bubble.left.and.text.bubble.right.fill")
        AppShortcut(
            intent: OpenChatIntent(),
            phrases: ["Open my \(\.$chat) chat in \(.applicationName)", "Open \(\.$chat) in \(.applicationName)"],
            shortTitle: LocalizedStringResource("Open Chat"),
            systemImageName: "bubble.left")
        AppShortcut(
            intent: NewChatIntent(),
            phrases: [
                "New chat in \(.applicationName)",
                "Start a new chat in \(.applicationName)",
                "New chat with \(\.$bot) in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("New Chat"),
            systemImageName: "square.and.pencil")
        AppShortcut(
            intent: BotStatusIntent(),
            phrases: [
                "What is \(.applicationName) doing",
                "What's \(.applicationName) doing",
                "What is my bot doing in \(.applicationName)",
                "\(.applicationName) status",
                "What is \(\.$bot) doing in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Bot Status"),
            systemImageName: "waveform.path.ecg")
        AppShortcut(
            intent: AnswerApprovalIntent(),
            phrases: ["Answer the approval in \(.applicationName)", "\(.applicationName) approval"],
            shortTitle: LocalizedStringResource("Answer Approval"),
            systemImageName: "checkmark.shield")
        AppShortcut(
            intent: StopMacIntent(),
            phrases: ["Stop \(.applicationName)", "Stop \(.applicationName) now", "Stop all helpers in \(.applicationName)"],
            shortTitle: LocalizedStringResource("Stop Nollie"),
            systemImageName: "stop.circle")
    }
}

/// What Siri asks of the gateway when the app is closed. The stored gateway is brought up and
/// its socket opened, then it is read for the running work and the pending approvals.
@MainActor
enum SiriAsk {
    /// The gateway could not be made ready; `line` is what Siri says about it.
    struct NotReady: Error {
        let line: String
    }

    /// An approval waiting in one of the open chats.
    struct Waiting {
        let chat: ChatSession
        let card: PendingCard
        let request: ApprovalRequest
        let bot: String
    }

    /// What `AnswerApprovalIntent` does next.
    enum Plan {
        case say(String)
        case confirm(question: String, waiting: Waiting)
    }

    /// The gateway with an open socket, or else the line Siri should say.
    static func readyRuntime() async throws -> GatewayRuntime {
        let app = AppModel.shared
        guard app.hasConnections else { throw NotReady(line: "Add a gateway in Nollie first.") }
        if app.runtime == nil { await app.activateSavedConnection() }
        guard let runtime = app.runtime else { throw NotReady(line: unreachableLine) }

        let giveUp = Date.now.addingTimeInterval(10)
        while !runtime.socketState.isOpen, Date.now < giveUp {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard runtime.socketState.isOpen else { throw NotReady(line: "Your gateway isn't replying at the moment.") }
        return runtime
    }

    private static let unreachableLine = "Nollie can't reach your gateway."

    /// What is running and what is pending, worded for Siri.
    static func status(bot: BotEntity?) async -> String {
        #if os(iOS)
        let extraTime = BackgroundTime("nollie.siri.status")
        defer { extraTime.end() }
        #endif
        let runtime: GatewayRuntime
        do { runtime = try await readyRuntime() } catch { return (error as? NotReady)?.line ?? unreachableLine }

        let running = runtime.chats.compactMap { chat -> (bot: String, title: String)? in
            guard chat.isRunning else { return nil }
            return (chat.profileName, chat.title.isEmpty ? "a chat" : chat.title)
        }
        let waiting = Set(runtime.chats.filter(\.needsAttention).map(\.storedID)).union(runtime.needsAttention)
        return SiriWords.status(running: running, waiting: waiting.count, bot: bot?.label)
    }

    /// Every approval card across the open chats.
    private static func approvals(in runtime: GatewayRuntime) -> [Waiting] {
        runtime.chats.flatMap { chat in
            chat.cards.compactMap { card in
                card.approval.map { Waiting(chat: chat, card: card, request: $0, bot: chat.profileName) }
            }
        }
    }

    /// Works out what to say or ask for an Approve or Deny by voice.
    static func plan(for answer: ApprovalAnswer) async -> Plan {
        guard SiriCatalog.answersApprovals else {
            return .say("Siri does not answer approvals. Turn on Answer approvals by voice in Settings, under Siri & Shortcuts, Advanced, if you want that.")
        }
        let all: [Waiting]
        do { all = approvals(in: try await readyRuntime()) } catch { return .say(unreachableLine) }

        // One approval can be answered here. With none or several, the screen is the place.
        guard all.count == 1, let waiting = all.first else {
            return .say(all.count > 1 ? "\(all.count) approvals are pending. Open Nollie to choose one." : "No approval is waiting.")
        }
        if answer == .approve, let refusal = SiriWords.approveRefusal(waiting.request) {
            return .say(refusal)
        }
        return .confirm(
            question: SiriWords.approvalQuestion(bot: waiting.bot, request: waiting.request, answer: answer),
            waiting: waiting)
    }
}
