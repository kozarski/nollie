import AppIntents
import NollieCore
import SwiftUI

// "Ask Nollie": one request to a helper from Siri, the Action button or Shortcuts, with the reply
// back as words and a small card. It travels the way the app's own messages do: over the link to
// the Mac on iPhone and iPad, to the Mac's own helpers on the Mac. It goes to the helper's main
// chat, so the conversation is there in Nollie afterwards.
//
// It never answers a card. A helper that reaches something needing a yes waits, and the person is
// told so and taken to the chat where the card is.

/// Siri, Shortcuts and the Action button: ask a helper something and get the reply. In Shortcuts
/// the reply is the action's output, so it can be passed on.
struct AskHelperIntent: AppIntent {
    static var title: LocalizedStringResource { "Ask Nollie" }
    static var description: IntentDescription {
        IntentDescription("Asks a helper and gives you the reply. Anything that needs your yes waits for you in Nollie.",
                          categoryName: "Helpers")
    }
    static var openAppWhenRun: Bool { false }
    /// The request goes out as you and the reply can be personal, so the device must be unlocked.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    static var parameterSummary: some ParameterSummary { Summary("Ask \(\.$helper) \(\.$request)") }

    @Parameter(title: "Request", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: IntentDialog(stringLiteral: AskWords.whatToAsk))
    var request: String

    @Parameter(title: "Helper", description: "Your usual helper when left empty.")
    var helper: BotEntity?

    init() {}

    init(request: String, helper: BotEntity? = nil) {
        self.request = request
        self.helper = helper
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let outcome = await AskHelper.ask(request, helper: helper)
        let line = AskWords.spoken(outcome)
        let card = AskSnippet(outcome: outcome)
        switch outcome {
        case .problem(let words):
            throw AskProblem(words: words)
        case .needsYou(let asked, _):
            // The card is in the helper's chat: open it there, never answer it here.
            let chat = ChatEntity(id: asked.chatID, title: asked.name, bot: asked.profile)
            return .result(value: line, opensIntent: OpenChatIntent(chat: chat), dialog: IntentDialog(stringLiteral: line), view: card)
        case .replied(_, let text):
            return .result(value: text.isEmpty ? line : text, dialog: IntentDialog(stringLiteral: line), view: card)
        case .stillWorking:
            return .result(value: line, dialog: IntentDialog(stringLiteral: line), view: card)
        }
    }
}

extension OpenChatIntent {
    init(chat: ChatEntity) {
        self.init()
        self.chat = chat
    }
}

/// A request that could not be asked. Siri says it; a shortcut stops with it.
struct AskProblem: Error, CustomLocalizedStringResourceConvertible {
    let words: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: words) }
}

// MARK: - How it went

/// Who was asked, and where.
struct AskedHelper: Equatable, Sendable {
    var profile: String
    var name: String
    /// The helper's main chat, by stored id.
    var chatID: String
}

enum AskOutcome: Equatable, Sendable {
    /// The turn ended. `text` is the reply, empty when the helper only did things.
    case replied(AskedHelper, text: String)
    /// A card is up in the chat: something waits for the person's yes. `before` is true when it
    /// was already there, so the request was not sent.
    case needsYou(AskedHelper, before: Bool)
    /// Still going when the wait ran out; the reply lands in the chat.
    case stillWorking(AskedHelper)
    /// Nothing was asked, or the request was lost. The words say why.
    case problem(String)
}

// MARK: - Asking

@MainActor
enum AskHelper {
    /// How long Siri waits for the reply. iOS gives a background app about half a minute; the Mac
    /// app keeps running, so a longer turn can still be read out there.
    static var replyWait: Duration { DeviceWords.isMac ? .seconds(90) : .seconds(25) }

    /// Asks through the app's own connection, brought up if it is not running.
    static func ask(_ request: String, helper: BotEntity?) async -> AskOutcome {
        #if os(iOS)
        let extraTime = BackgroundTime("nollie.siri.ask")
        defer { extraTime.end() }
        #endif
        guard let words = AskRules.deliverable(request) else { return .problem(AskWords.nothingToAsk) }

        let app = AppModel.shared
        guard app.hasConnections else { return .problem(AskWords.notSetUp) }
        if app.runtime == nil { await app.activateSavedConnection() }
        guard let runtime = app.runtime else { return .problem(AskWords.notSetUp) }
        if let problem = await AskRoute.waitForOpen(runtime) { return .problem(problem) }

        let target: (profile: String, name: String)
        switch AskRoute.helper(helper?.id, on: runtime) {
        case .success(let found): target = found
        case .failure(let refusal): return .problem(refusal.words)
        }
        return await ask(words, profile: target.profile, name: target.name, on: runtime, wait: replyWait)
    }

    /// Sends `words` to the helper's main chat on `runtime` and waits up to `wait` for the turn to
    /// end. Kept apart from the app model so tests can run it against the demo gateway.
    static func ask(_ words: String, profile: String, name: String, on runtime: GatewayRuntime,
                    wait: Duration) async -> AskOutcome {
        guard let chat = await mainChat(profile: profile, on: runtime) else { return .problem(AskWords.noChat(name)) }
        let asked = AskedHelper(profile: profile, name: name, chatID: chat.storedID)

        // A card already up means a "yes" typed now could be taken as its answer: send nothing.
        if !chat.cards.isEmpty { return .needsYou(asked, before: true) }
        if chat.isRunning { return .problem(AskWords.busy(name)) }
        if await chat.send(words) != nil { return .problem(AskWords.notSent(name)) }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait)
        while true {
            let step = AskWatch.next(cardsUp: !chat.cards.isEmpty, running: chat.isRunning, timeUp: clock.now >= deadline)
            switch step {
            case .wait:
                try? await Task.sleep(for: .milliseconds(250))
            case .needsYou:
                return .needsYou(asked, before: false)
            case .tooLong:
                return .stillWorking(asked)
            case .finished:
                let reply = AskReply.latestTurn(in: chat.items)
                if reply.failed { return .problem(AskWords.notSent(name)) }
                return .replied(asked, text: reply.text)
            }
        }
    }

    /// The helper's main chat, opened live. Started, as the app starts it, when the gateway says
    /// there is none yet.
    private static func mainChat(profile: String, on runtime: GatewayRuntime) async -> ChatSession? {
        switch await runtime.mainChat(profile: profile) {
        case .found(let id):
            return try? await runtime.openChat(storedID: id, profile: profile, waitForResume: true)
        case .missing:
            guard let started = try? await runtime.newChat(profile: profile) else { return nil }
            await started.rename("Bot Chat")
            return started.storedID.isEmpty ? nil : started
        case .unknown:
            return nil
        }
    }
}

/// Fixed rules for what Ask may send. Plain checks, not model judgement.
enum AskRules {
    /// The words to send, or nil for nothing. Leading slashes are dropped, so a request can never
    /// become a command such as /approve, and the spacing is tidied.
    static func deliverable(_ request: String) -> String? {
        TalkRules.deliverable(request, cardsUp: false, running: false)
    }
}

/// What to do on each look at the chat after the request went. There is no answer among the steps:
/// a card always ends the wait as `needsYou`, whatever it asks.
enum AskWatch {
    enum Step: Equatable, CaseIterable {
        case wait, needsYou, finished, tooLong
    }

    static func next(cardsUp: Bool, running: Bool, timeUp: Bool) -> Step {
        if cardsUp { return .needsYou }
        if !running { return .finished }
        return timeUp ? .tooLong : .wait
    }
}

/// Which connection a request takes, and what is said when it can't.
@MainActor
enum AskRoute {
    /// Where the request goes from this device.
    enum Path: Equatable {
        /// The Mac this iPhone or iPad is linked to.
        case linkedMac(NollieLinkReach)
        /// A gateway added by address.
        case gateway
        /// The Mac's own helpers, asked from the Mac.
        case thisMac
    }

    static func path(of runtime: GatewayRuntime, onMac: Bool = DeviceWords.isMac) -> Path {
        if onMac { return .thisMac }
        if let reach = runtime.linkReach { return .linkedMac(reach) }
        return .gateway
    }

    /// Waits up to ten seconds for the live connection. Nil when it is open, else what to say.
    static func waitForOpen(_ runtime: GatewayRuntime) async -> String? {
        let giveUp = Date.now.addingTimeInterval(10)
        while !runtime.socketState.isOpen, Date.now < giveUp, runtime.linkReach != .away {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return problem(path: path(of: runtime), open: runtime.socketState.isOpen)
    }

    /// The words for a connection that is not there. Nil when the request can go.
    static func problem(path: Path, open: Bool) -> String? {
        switch path {
        case .linkedMac(.away): return AskWords.macAway
        case _ where open: return nil
        case .linkedMac: return AskWords.macQuiet
        case .gateway: return AskWords.gatewayQuiet
        case .thisMac: return AskWords.thisMacQuiet
        }
    }

    enum Refusal: Error, Equatable {
        case unknown, isPrivate(String)

        var words: String {
            switch self {
            case .unknown: AskWords.unknownHelper
            case .isPrivate(let name): AskWords.privateHelper(name)
            }
        }
    }

    /// The helper a request is for: the one named, else the usual helper, else the one selected.
    /// A Private helper is never asked from outside the app.
    static func helper(_ named: String?, on runtime: GatewayRuntime) -> Result<(profile: String, name: String), Refusal> {
        let chosen = named ?? runtime.defaultProfile ?? runtime.selectedProfile ?? runtime.profiles.first?.name
        return pick(chosen, among: runtime.profiles, isPrivate: { PrivateBots.isPrivate($0, connection: runtime.connection.id) })
    }

    static func pick(_ chosen: String?, among profiles: [ProfileInfo],
                     isPrivate: (String) -> Bool) -> Result<(profile: String, name: String), Refusal> {
        guard let chosen, !chosen.isEmpty else { return .failure(.unknown) }
        let known = profiles.first { $0.name == chosen }
        // A list that has loaded and lacks the name means the helper has gone.
        if known == nil, !profiles.isEmpty { return .failure(.unknown) }
        let name = known?.shownName ?? chosen
        if chosen == "private" || isPrivate(chosen) { return .failure(.isPrivate(name)) }
        return .success((chosen, name))
    }
}

/// The latest turn's reply, as text to hand on.
enum AskReply {
    /// The helper's words after the person's last message, without pictures or files, and whether
    /// the turn failed instead of answering.
    static func latestTurn(in items: [TranscriptItem]) -> (text: String, failed: Bool) {
        let lastPerson = items.lastIndex { if case .user = $0.kind { true } else { false } } ?? -1
        var replies: [String] = []
        var failed = false
        for item in items.suffix(from: lastPerson + 1) {
            switch item.kind {
            case .assistant(let text, _, _) where InterruptedTurn.parse(text) == nil:
                let words = MediaScan.textWithoutMedia(text).trimmingCharacters(in: .whitespacesAndNewlines)
                if !words.isEmpty { replies.append(words) }
            case .error:
                failed = true
            default:
                continue
            }
        }
        return (replies.joined(separator: "\n\n"), failed && replies.isEmpty)
    }
}

// MARK: - Words

/// Everything Ask says. Pure, so tests can hold it to the copy rules.
enum AskWords {
    static let whatToAsk = "What would you like to ask?"
    static let nothingToAsk = "Say what you'd like to ask, then try again."
    static let notSetUp = "Set up Nollie first, then ask again."
    static let macAway = MacStopWords.unreachable
    static let macQuiet = "Your Mac isn't answering. Check it's awake, then try again."
    static let gatewayQuiet = "Nollie can't reach your helpers right now."
    static let thisMacQuiet = "Your helpers aren't answering on this Mac. Open Nollie to check."
    static let unknownHelper = "Nollie can't find that helper."
    static func privateHelper(_ name: String) -> String { "\(name) is private. Ask in Nollie." }
    static func noChat(_ name: String) -> String { "Can't open \(name)'s chat right now. Try again in a moment." }
    static func busy(_ name: String) -> String { "\(name) is busy right now. Ask again when it's done." }
    static func notSent(_ name: String) -> String { "That didn't reach \(name). Try again in a moment." }

    static func needsYou(_ name: String, before: Bool) -> String {
        before ? "\(name) is waiting for your yes on something else. It's in Nollie."
               : "\(name) needs your yes to go on. It's waiting in Nollie."
    }
    static func stillWorking(_ name: String) -> String { "\(name) is still on it. The reply will be in Nollie." }
    static func doneQuietly(_ name: String) -> String { "\(name) has finished. The details are in Nollie." }

    /// The snippet's short labels.
    static let waitingLabel = "Waiting for your yes"
    static let workingLabel = "Still working"

    /// The longest reply Siri reads out. Longer ones are cut at a sentence and the rest is on the card.
    static let spokenLimit = 400

    /// What Siri says for an outcome.
    static func spoken(_ outcome: AskOutcome) -> String {
        switch outcome {
        case .replied(let asked, let text):
            let plain = SpokenReply.plain(text)
            return plain.isEmpty ? doneQuietly(asked.name) : shortened(plain)
        case .needsYou(let asked, let before): return needsYou(asked.name, before: before)
        case .stillWorking(let asked): return stillWorking(asked.name)
        case .problem(let words): return words
        }
    }

    /// Cut at the last sentence that fits, or at a word.
    static func shortened(_ text: String, limit: Int = spokenLimit) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let end = head.lastIndex(where: { ".!?".contains($0) }), head.distance(from: head.startIndex, to: end) > limit / 3 {
            return String(head[...end])
        }
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return cut + "…"
    }
}

// MARK: - The card Siri shows

/// The small card under Siri's words: the helper's character, its name and the reply, or a pill
/// saying it waits for you.
struct AskSnippet: View {
    let outcome: AskOutcome

    private var asked: AskedHelper? {
        switch outcome {
        case .replied(let asked, _), .needsYou(let asked, _), .stillWorking(let asked): asked
        case .problem: nil
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if let asked {
                Image(CharacterDrawing.avatarName(BotAvatarStore.look(for: asked.profile)))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                Text(asked.name)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
    }

    @ViewBuilder private var content: some View {
        switch outcome {
        case .replied(let asked, let text):
            Text(text.isEmpty ? AskWords.doneQuietly(asked.name) : AskWords.shortened(text, limit: 600))
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .needsYou:
            AskPill(symbol: "hand.raised.fill", words: AskWords.waitingLabel, tint: .orange)
        case .stillWorking:
            AskPill(symbol: "ellipsis", words: AskWords.workingLabel, tint: .secondary)
        case .problem(let words):
            Text(words).font(.body)
        }
    }
}

/// One short state in a capsule.
private struct AskPill: View {
    var symbol: String
    var words: String
    var tint: Color

    var body: some View {
        Label(words, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(tint.opacity(0.14), in: Capsule())
    }
}
