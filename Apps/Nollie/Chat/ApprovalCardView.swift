import SwiftUI
import NollieCore

/// The bot asking permission in plain words: "Nollie needs your OK", what for, the command, and
/// the answers. Allow once leads, then Deny. Allow in this chat and Always allow sit behind a
/// round button, and Always asks once more, naming the rule it would add.
///
/// A screen action (a `cua:` rule) is a different question: may the bot use this Mac at all?
/// "Allow system control" turns the bot's switch on and lets the action through, "Keep it off"
/// turns the switch off.
struct ApprovalCardView: View {
    var approval: ApprovalRequest
    var count: Int
    /// The bot's shown name, used in the question ("Nollie needs your OK").
    var botName: String = ""
    /// The bot's profile. Kept for callers, though the card itself draws no face.
    var profile: String? = nil
    var onChoice: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Receives a screen action's answer (true means System control goes on). Without it, screen
    /// actions get the usual answers.
    var onSystemControl: ((Bool) -> Void)? = nil
    /// Receives the answer to a saved sign-in. Without it, sign-ins get the usual answers.
    var onSignIn: ((Bool) async -> String?)? = nil

    @State private var confirmAlways = false
    @State private var showMore = false
    /// On a member's phone, every approval waits on the owner.
    @Environment(\.familyOwner) private var familyOwner

    private var who: String { botName.isEmpty ? String(localized: "Your bot", comment: "Stands in for a bot's name when it has none") : botName }
    private var offers: [String] { approval.offeredChoices }
    private var screenKey: String { approval.patternKey ?? "" }
    private var isScreenAction: Bool { screenKey.hasPrefix("cua:") }
    private var commandText: String? { approval.command.flatMap { $0.isEmpty ? nil : $0 } }
    private var hasMoreAnswers: Bool {
        offers.contains("session") || offers.contains("always") || commandText != nil
    }
    /// A yes to this one asks for Face ID first (buying, sending or posting).
    private var locked: Bool { ApprovalOwnerCheck.willAsk(approval) }

    /// What the request is about, for when the gateway sent no description.
    private var kind: String {
        if isScreenAction { return Self.screenLine(screenKey) }
        if let tool = approval.toolName, !tool.isEmpty, tool != "terminal" {
            let named = tool.replacingOccurrences(of: "_", with: " ")
            return String(localized: "Use \(named).", comment: "Safety: approval card, what a yes allows; a tool's name follows Use. Keep exact meaning")
        }
        return commandText == nil
            ? String(localized: "Go ahead with this.", comment: "Safety: approval card, what a yes allows. Keep exact meaning")
            : String(localized: "Run a command.", comment: "Safety: approval card, what a yes allows. Keep exact meaning")
    }

    /// A screen action reads as what it does on the Mac ("Click on your Mac, in the background")
    /// instead of the gateway's "Allow computer_use to perform `click`?".
    private var aboutLine: String {
        if !isScreenAction, let said = approval.description, !said.isEmpty { return said }
        return kind
    }

    var body: some View {
        if let familyOwner {
            FamilyWaitingCard(approval: approval, botName: who, owner: familyOwner, onChoice: onChoice)
        } else if let onSignIn, let ask = SignInAsk(approval) {
            SignInCardBody(ask: ask, botName: botName, onAnswer: onSignIn)
        } else if let ask = AskFirstAsk(approval) {
            AskFirstCardBody(ask: ask, botName: botName, locked: locked, onChoice: onChoice)
        } else if let onSystemControl, SystemControl.isScreen(approval) {
            systemControlBody(onSystemControl)
        } else {
            approvalBody
        }
    }

    // MARK: Screen action

    /// One question (may the bot use this Mac?) and two answers.
    private func systemControlBody(_ answer: @escaping (Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The question is the whole card, so no "Action needed" label; the title gets the room.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "cursorarrow.rays").foregroundStyle(Ink.text)
                Text("\(who) wants to use your Mac").foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(Ink.cardTitle)
            Text("First: \(Self.screenStep(screenKey))")
                .font(Ink.pill)
                .foregroundStyle(Ink.text2)
                .padding(.top, 6)
                .padding(.bottom, 12)
            SideBySideOrStacked { fill in systemControlAnswers(answer, fill: fill) }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.systemControl")
    }

    @ViewBuilder private func systemControlAnswers(_ answer: @escaping (Bool) -> Void, fill: Bool) -> some View {
        Button("Allow system control") { answer(true) }
            .buttonStyle(InkPillStyle(fill: fill))
            .accessibilityHint("\(who) can use your Mac from now on without asking each time.")
            .accessibilityIdentifier("approval.systemControl.on")
        Button("Keep it off") { answer(false) }
            .buttonStyle(OutlinePillStyle(fill: fill))
            .accessibilityHint("\(who) stays off your Mac and tells you what it needed.")
            .accessibilityIdentifier("approval.systemControl.off")
    }

    // MARK: Ordinary approval

    /// Shows how many approvals are waiting.
    private var waitingChip: some View {
        HStack(spacing: 5) {
            Circle().fill(Ink.warnText).frame(square: 7)
            Text("\(count) waiting")
        }
        .font(Ink.chip)
        .foregroundStyle(Ink.warnText)
        .inset(h: 10, v: 3)
        .background(Ink.warnFill, in: .capsule)
    }

    private var approvalHead: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("\(who) needs your OK").font(Ink.cardTitle).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if count > 1 { waitingChip }
        }
    }

    private var flagNote: some View {
        Label("The safety check flagged this one. Only allow it if you meant it.", systemImage: "exclamationmark.triangle.fill")
            .font(Ink.pill)
            .foregroundStyle(Ink.warnText)
            .padding(.bottom, 10)
    }

    private var approvalBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            approvalHead
            Text(aboutLine)
                .font(Ink.cardBody)
                .foregroundStyle(Ink.cardText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, 10)
            if let commandText { commandBlock(commandText) }
            if approval.smartDenied == true { flagNote }
            // Answers sit side by side, or stack on a narrow phone with big text. The round menu
            // stays outside that fitting, because a menu can't be laid out twice. At the largest
            // sizes it takes a row of its own under the answers, so it never sits on Deny's edge.
            let answerLayout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .bottom, spacing: 8))
            answerLayout {
                SideBySideOrStacked { fill in answers(fill: fill) }
                moreAnswers
            }
        }
        .contentShape(.rect)
        .contextMenu { quickMenu }
        .accessibilityElement(children: .contain)
        .alert("Always allow \(approval.alwaysScope)?", isPresented: $confirmAlways) {
            Button("Cancel", role: .cancel) {}
            Button("Always Allow") { onChoice("always") }
        } message: {
            Text("In every chat, without asking.")
        }
    }

    @ViewBuilder private var quickMenu: some View {
        if offers.contains("session") {
            Button { onChoice("session") } label: { Label("Allow in this chat", systemImage: "checkmark.circle") }
        }
        if let commandText {
            Button { UIPasteboard.general.string = commandText } label: { Label("Copy command", systemImage: "doc.on.doc") }
        }
    }

    /// The whole command is always shown, so what runs is what you read. A long one scrolls in
    /// its box instead of being cut off.
    private func commandBlock(_ command: String) -> some View {
        ScrollView(.vertical) {
            Text(command)
                .font(Ink.code11)
                .foregroundStyle(Ink.codeText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .spread()
                .inset(h: 14, v: 10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: typeSize.isAccessibilitySize ? nil : 180)
        .fixedSize(horizontal: false, vertical: true)
        .background(Ink.code, in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityLabel("Command: \(command)")
        .accessibilityIdentifier("approval.command")
        .padding(.bottom, 12)
    }

    @ViewBuilder private func answers(fill: Bool) -> some View {
        ApproveButton(title: LocalizedStringResource("Allow once", comment: "Safety: approval answer, allows this one action only"),
                      locked: locked, fill: fill) { onChoice("once") }
        Button("Deny") { onChoice("deny") }
            .buttonStyle(OutlinePillStyle(fill: fill))
            .accessibilityIdentifier("approval.deny")
    }

    /// The extra answers (this chat, always, copy) behind a round button. It opens a dialog and not
    /// a menu, since ImageRenderer also draws this card and stalls on a menu.
    @ViewBuilder private var moreAnswers: some View {
        if hasMoreAnswers {
            Button { showMore = true } label: {
                Image(systemName: "ellipsis")
                    .font(Ink.button)
                    .foregroundStyle(Ink.text)
                    .frame(square: 44)
                    .nollieGlass(.regular, in: Circle(), solid: Ink.canvas)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More answers")
            .accessibilityIdentifier("approval.more")
            .confirmationDialog("More answers", isPresented: $showMore) { moreChoices }
        }
    }

    @ViewBuilder private var moreChoices: some View {
        if offers.contains("session") {
            Button("Allow in this chat") { onChoice("session") }.accessibilityIdentifier("approval.session")
        }
        if offers.contains("always") {
            Button("Always allow…") { confirmAlways = true }.accessibilityIdentifier("approval.always")
        }
        if let commandText {
            Button("Copy command") { UIPasteboard.general.string = commandText }
        }
    }

    // MARK: Words for screen actions

    /// Splits an approval key of the form `cua:<action>:<background|foreground>`.
    private static func parts(of key: String) -> (action: String, mode: String) {
        let pieces = key.split(separator: ":").map(String.init)
        return (pieces.count > 1 ? pieces[1] : "", pieces.count > 2 ? pieces[2] : "")
    }

    /// The keys are the gateway's action names; only the words are shown.
    private static let verbs: [String: String] = {
        let press = String(localized: "Press keys", comment: "Safety: a screen action on the Mac, starts a sentence")
        let type = String(localized: "Type", comment: "Safety: a screen action on the Mac (type text), starts a sentence")
        let pairs: [(String, String)] = [
            ("scroll", String(localized: "Scroll", comment: "Safety: a screen action on the Mac, starts a sentence")),
            ("drag", String(localized: "Drag", comment: "Safety: a screen action on the Mac, starts a sentence")),
            ("set_value", String(localized: "Fill in a field", comment: "Safety: a screen action on the Mac, starts a sentence")),
            ("click", String(localized: "Click", comment: "Safety: a screen action on the Mac, starts a sentence")),
            ("right_click", String(localized: "Right-click", comment: "Safety: a screen action on the Mac, starts a sentence")),
            ("double_click", String(localized: "Double-click", comment: "Safety: a screen action on the Mac, starts a sentence")),
            ("type", type), ("type_text", type),
            ("key", press), ("press_key", press), ("hotkey", press),
            ("focus_app", String(localized: "Switch to an app", comment: "Safety: a screen action on the Mac, starts a sentence")),
            ("launch_app", String(localized: "Open an app", comment: "Safety: a screen action on the Mac, starts a sentence")),
            ("bring_to_front", String(localized: "Bring an app to the front", comment: "Safety: a screen action on the Mac, starts a sentence")),
        ]
        return Dictionary(uniqueKeysWithValues: pairs)
    }()

    private static let nouns: [String: String] = [
        "click": String(localized: "a click", comment: "Safety: a screen action on the Mac, as a noun"),
        "double_click": String(localized: "a double-click", comment: "Safety: a screen action on the Mac, as a noun"),
        "right_click": String(localized: "a right-click", comment: "Safety: a screen action on the Mac, as a noun"),
        "middle_click": String(localized: "a middle-click", comment: "Safety: a screen action on the Mac, as a noun"),
        "type": String(localized: "typing", comment: "Safety: a screen action on the Mac, as a noun"),
        "key": String(localized: "a key press", comment: "Safety: a screen action on the Mac, as a noun"),
        "scroll": String(localized: "scrolling", comment: "Safety: a screen action on the Mac, as a noun"),
        "drag": String(localized: "a drag", comment: "Safety: a screen action on the Mac, as a noun"),
        "focus_app": String(localized: "switching to an app", comment: "Safety: a screen action on the Mac, as a noun"),
        "bring_to_front": String(localized: "bringing an app to the front", comment: "Safety: a screen action on the Mac, as a noun"),
        "set_value": String(localized: "filling in a field", comment: "Safety: a screen action on the Mac, as a noun"),
    ]

    /// A screen action in plain words, taken from its approval key.
    static func screenLine(_ key: String) -> String {
        let (action, mode) = parts(of: key)
        let verb = verbs[action] ?? String(localized: "Use your Mac's screen", comment: "Safety: a screen action on the Mac, starts a sentence")
        return switch mode {
        case "foreground":
            String(localized: "\(verb) on your Mac, in front: its window comes forward for a moment.",
                   comment: "Safety: approval card; the screen action comes first, like Click. Keep exact meaning")
        case "background":
            String(localized: "\(verb) on your Mac, in the background: your cursor and windows stay as they are.",
                   comment: "Safety: approval card; the screen action comes first, like Click. Keep exact meaning")
        default:
            String(localized: "\(verb) on your Mac.", comment: "Safety: approval card; the screen action comes first, like Click. Keep exact meaning")
        }
    }

    /// The first screen action in a few words for the System control card, like "a click, in front".
    static func screenStep(_ key: String) -> String {
        let (action, mode) = parts(of: key)
        let what = nouns[action] ?? String(localized: "a screen action", comment: "Safety: a screen action on the Mac, as a noun")
        switch mode {
        case "foreground": return String(localized: "\(what), in front", comment: "Safety: a screen action, like a click, done with its window brought forward")
        case "background": return String(localized: "\(what), in the background", comment: "Safety: a screen action, like a click, done without moving the cursor or windows")
        default: return what
        }
    }
}
