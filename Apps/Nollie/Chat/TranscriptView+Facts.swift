import SwiftUI
import NollieCore

// Numbers and yes/no answers the thread works out from its state: spacing around the dock and
// keyboard, and which parts of the chat deserve a row.

extension TranscriptView {
    // MARK: Spacing

    /// Space the scroll view adds by itself (the safe area, a parent's margins). It is
    /// measured one time, from the first report once the dock is known.
    var autoInset: CGFloat { autoInsetFixed ?? 0 }

    /// Identifies this chat for the disclosure holding code.
    var disclosureScope: String { "\(chat.runtime.connection.id):\(chat.profileName):\(chat.storedID)" }

    /// True for the first moments after opening, while history and measurements are still arriving.
    var settling: Bool { Date().timeIntervalSince(openedAt) < 1.5 }

    /// How much of the scroll view's frame the dock covers. Overlays stay clear of it.
    var dockReach: CGFloat {
        guard dockTop > 0, scrollBottom > dockTop else { return fallbackInset }
        return scrollBottom - dockTop
    }

    /// The lowest y the content can occupy. The frame may end at the safe area or run to the
    /// screen's edge; subtracting the measured inset and taking the smaller makes both agree.
    var visibleBottom: CGFloat { min(scrollBottom, UIScreen.main.bounds.height - autoInset) }

    /// Margin that leaves the last line 8pt clear of the dock. It never drops below the keyboard
    /// plus one composer line: a first message in a fresh chat once ended up hidden behind both.
    var bottomInset: CGFloat {
        let fromDock = (dockTop > 0 && visibleBottom > dockTop) ? visibleBottom - dockTop : fallbackInset
        let fromKeyboard = keyboardFloor > 0 ? keyboardFloor + 44 : 0
        return max(fromDock, fromKeyboard)
    }

    /// Widest a bubble may be. The phone has no cap. The Mac keeps replies to a share of the
    /// reading column, as Messages does, unless wide replies are on.
    var bubbleCap: CGFloat {
        #if os(macOS)
        if prefs.wideReplies { return columnWidth }
        return min(Ink.botBubble, max(320, columnWidth * 0.78))
        #else
        return .infinity
        #endif
    }

    // MARK: What the chat has to show

    /// Open approval requests, one card each below the rows.
    var approvals: [PendingCard] { chat.cards.filter { $0.method == "approval" } }

    var botDisplayName: String {
        let bot = chat.runtime.profiles.first { $0.name == chat.profileName }
        return bot?.shownName ?? chat.profileName
    }

    /// If the last turn hit a screen action that Hermes turned away because System control was
    /// off ("human_has_control"), and it is still off with nothing running, this is the tool
    /// row's id, so a card can offer to switch it on.
    var systemControlStop: String? {
        guard !chat.isRunning, !SystemControl.shared.isOn(chat.profileName) else { return nil }
        for item in chat.items.reversed() {
            if case .user = item.kind { return nil }
            guard case .tool(let tool) = item.kind, tool.name == "computer_use" else { continue }
            let report = [tool.resultText, tool.summary].compactMap { $0 }.joined(separator: " ")
            if report.contains("human_has_control") { return item.id }
        }
        return nil
    }

    /// Items that pass the person's display switches.
    var visibleItems: [TranscriptItem] {
        AutomatedReply.presentationItems(chat.items).filter(isShown)
    }

    private func isShown(_ item: TranscriptItem) -> Bool {
        switch item.kind {
        case .tool(let activity):
            if activity.crewNote != nil { return true }
            return prefs.showToolCalls && (!prefs.currentStepOnly || activity.status == .running)
        case .subagent: return prefs.showToolCalls
        case .system: return prefs.showSystemNotes
        default: return true
        }
    }

    static func isStreaming(_ item: TranscriptItem) -> Bool {
        if case .assistant(_, _, let live) = item.kind { return live }
        return false
    }

    var rows: [TranscriptRowModel] {
        TranscriptRowModel.build(visibleItems, foldSteps: prefs.foldsSteps)
    }

    /// The thread ends in a folded group of steps whose last call is still going. That group
    /// already shows the activity, so no typing bubble or status line is added.
    var liveRunAtEnd: Bool {
        guard prefs.foldsSteps, case .tool(let activity)? = visibleItems.last?.kind else { return false }
        return activity.delivery == nil && activity.status == .running
    }

    /// A reply that is still streaming brings its own typing bubble.
    var lastIsStreamingReply: Bool { chat.items.last.map(Self.isStreaming) ?? false }

    /// Name of the running tool for the dark typing bubble. The status line reads like
    /// "Running terminal…", and only "terminal" is wanted.
    var typingTool: String? {
        guard chat.botState == .usingTool, var line = chat.statusLine else { return nil }
        for lead in ["Running ", "Preparing "] { line = line.replacingOccurrences(of: lead, with: "") }
        return line.trimmingCharacters(in: ["…", " "])
    }
}
