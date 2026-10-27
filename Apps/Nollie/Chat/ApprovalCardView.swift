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

    private var who: String { botName.isEmpty ? "Your bot" : botName }
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
            return "Use \(tool.replacingOccurrences(of: "_", with: " "))."
        }
        return commandText == nil ? "Go ahead with this." : "Run a command."
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
            // stays outside that fitting, because a menu can't be laid out twice.
            HStack(alignment: .bottom, spacing: 8) {
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
        ApproveButton(title: "Allow once", locked: locked, fill: fill) { onChoice("once") }
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

    private static let verbs: [String: String] = {
        let pairs: [(String, String)] = [
            ("scroll", "Scroll"), ("drag", "Drag"), ("set_value", "Fill in a field"),
            ("click", "Click"), ("right_click", "Right-click"), ("double_click", "Double-click"),
            ("type", "Type"), ("type_text", "Type"),
            ("key", "Press keys"), ("press_key", "Press keys"), ("hotkey", "Press keys"),
            ("focus_app", "Switch to an app"), ("launch_app", "Open an app"),
            ("bring_to_front", "Bring an app to the front"),
        ]
        return Dictionary(uniqueKeysWithValues: pairs)
    }()

    private static let nouns: [String: String] = [
        "click": "a click", "double_click": "a double-click", "right_click": "a right-click",
        "middle_click": "a middle-click", "type": "typing", "key": "a key press", "scroll": "scrolling",
        "drag": "a drag", "focus_app": "switching to an app", "bring_to_front": "bringing an app to the front",
        "set_value": "filling in a field",
    ]

    /// A screen action in plain words, taken from its approval key.
    static func screenLine(_ key: String) -> String {
        let (action, mode) = parts(of: key)
        let verb = verbs[action] ?? "Use your Mac's screen"
        let tail = switch mode {
        case "foreground": " on your Mac, in front: its window comes forward for a moment."
        case "background": " on your Mac, in the background: your cursor and windows stay as they are."
        default: " on your Mac."
        }
        return verb + tail
    }

    /// The first screen action in a few words for the System control card, like "a click, in front".
    static func screenStep(_ key: String) -> String {
        let (action, mode) = parts(of: key)
        let what = nouns[action] ?? "a screen action"
        switch mode {
        case "foreground": return what + ", in front"
        case "background": return what + ", in the background"
        default: return what
        }
    }
}
