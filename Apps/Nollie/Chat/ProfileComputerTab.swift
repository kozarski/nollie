import SwiftUI
import NollieCore

/// Computer: the one switch for this Mac, and a computer of its own inside the Mac.
struct ProfileComputerTab: View {
    var state: ProfileCardState
    /// Present only from a chat, which has a preview to open.
    var chat: ChatSession?
    var openPreview: () -> Void

    var body: some View {
        let control = SystemControl.shared
        let stance = state.computer.stance
        PageHero(symbol: stance.symbol, title: .verbatim(stance.title), line: .verbatim(stance.line), tint: stance.tint, id: "profile.computer.hero")
        GlassSwitch("Allow Mac control", isOn: Binding(
            get: { control.isOn(state.name, state.runtime) },
            set: { on in
                guard let runtime = state.runtime else { return }
                Task { await control.set(on, profile: state.name, rt: runtime) }
            }), id: "profile.systemControl")
            .disabled(control.isBusy(state.name, state.runtime))
        if control.lastError != nil {
            PageNote("Couldn't change that. Try again.", symbol: "exclamationmark.triangle.fill", tint: .orange,
                     id: "profile.systemControl.problem")
        }
        if chat != nil {
            GlassButton("Open preview", symbol: "desktopcomputer", id: "profile.openPreview", action: openPreview)
        }
        if state.mayHaveOwnComputer {
            HelperComputerSection(profile: state.name, chat: chat, computer: state.ownComputer).id("ownComputer")
        }
        if state.mayHaveOwnComputer || Self.hasAdvanced {
            AdvancedLink(id: "profile.computer.advanced") { ComputerAdvanced(state: state) }
        }
    }

    private static var hasAdvanced: Bool {
        #if os(macOS) && NOLLIE_DIRECT
        true
        #else
        SystemControl.shared.lastError != nil
        #endif
    }
}

/// Apps: the way to what it can use, which is built-in tools, connections and skills for this bot, and
/// the Mac's Calendar, Reminders and Contacts.
struct ProfileAppsTab: View {
    var state: ProfileCardState
    var openOnMac: () -> Void

    var body: some View {
        CardHeadline(symbol: "square.stack.3d.up.fill", tint: state.tint, title: "What \(state.label) can use", id: "profile.apps.hero")
        #if os(macOS)
        GlassButton("Apps & access", symbol: "square.stack.3d.up", id: "profile.apps", action: openOnMac)
        #else
        GlassLink("Apps & access", symbol: "square.stack.3d.up", id: "profile.apps") { ToolsView(profileName: state.name) }
        #endif
        if !state.isHidden, !AskFirstModel.isPrivateBot(state.name) {
            AppleDataSection(profileName: state.name)
            PaymentSwitchSection(profileName: state.name)
        }
    }
}

/// This chat: its name and how full it is. Its model and the exact numbers are under Advanced.
struct ProfileChatTab: View {
    var state: ProfileCardState
    var chat: ChatSession
    var rename: () -> Void

    var body: some View {
        let percent = chat.usage?.computedContextPercent
        let long = (percent ?? 0) >= 80
        let name = chat.title.isEmpty ? String(localized: "Untitled", comment: "A chat with no name") : chat.title
        CardHeadline(symbol: "bubble.left.fill", tint: long ? .orange : state.tint, title: .verbatim(name),
                     titleTint: long ? .orange : Ink.text, line: long ? "Getting long. A new chat starts fresh." : nil,
                     id: "profile.thisChat.hero")
        GlassButton("Name", symbol: "pencil", value: name, id: "profile.rename", action: rename)
            .accessibilityHint("Renames this chat")
        if let percent {
            FactStrip(facts: [Fact(symbol: "gauge.with.dots.needle.33percent", word: "\(percent)% full")],
                      tint: long ? .orange : Ink.text2, id: "profile.thisChat.full")
        }
        if !chat.modelName.isEmpty || percent != nil {
            AdvancedLink(id: "profile.thisChat.advanced") {
                ThisChatAdvanced(model: chat.modelName.isEmpty ? nil : chat.modelName,
                                 context: percent.map {
                                     String(localized: "\($0)% of \((chat.usage?.contextMax ?? 0).formatted())",
                                            comment: "How full a chat is: a percentage of its context size in tokens")
                                 })
            }
        }
    }
}

/// Display: what a chat shows, for every bot.
struct ProfileDisplayTab: View {
    var state: ProfileCardState
    @AppStorage(ChatStyle.showToolCalls) private var toolCalls = true
    @AppStorage(ChatStyle.showReasoning) private var reasoning = true
    @AppStorage(ChatStyle.showTurnStats) private var turnStats = false
    @AppStorage(ChatStyle.showSystemNotes) private var systemNotes = true

    var body: some View {
        CardHeadline(symbol: "eye.fill", tint: state.tint, title: "Show in chats", line: "For every bot.", id: "profile.display.hero")
        GlassStack {
            GlassSwitch("Steps it takes", isOn: $toolCalls, id: "profile.display.toolCalls")
            GlassSwitch("Its thinking", isOn: $reasoning, id: "profile.display.reasoning")
            GlassSwitch("Reply speed", isOn: $turnStats, id: "profile.display.speed")
            GlassSwitch("Notes from Nollie", isOn: $systemNotes, id: "profile.display.systemNotes")
        }
    }
}
