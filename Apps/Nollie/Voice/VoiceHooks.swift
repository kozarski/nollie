import SwiftUI
import NollieCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Voice in a chat that is on screen: reads each new reply aloud when that setting is on, and
/// stops reading when a new turn starts or the composer goes. Talk mode outlives the composer
/// while a question card takes its place, and ends itself when the chat is left.
struct VoiceHooks: ViewModifier {
    var chat: ChatSession
    @AppStorage(VoiceSettings.readAloudKey) private var readAloud = false
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: chat.isRunning) { was, now in turnChanged(was: was, now: now) }
            .onChange(of: scenePhase) { _, now in
                if now == .background {
                    TalkMode.shared.stop(in: chat)
                    stopReading()
                }
            }
            .onDisappear {
                if !TalkMode.shared.isOn(in: chat) { stopReading() }
            }
            #if DEBUG
            .task {
                if let phase = TalkMode.demoPhase { TalkMode.shared.pretend(phase, in: chat) }
            }
            #endif
    }

    private func stopReading() {
        ReplyVoice.shared.stop(for: chat.storedID, chat.profileName)
    }

    private func turnChanged(was: Bool, now: Bool) {
        // Talk mode reads its own replies.
        guard !TalkMode.shared.isOn(in: chat) else { return }
        if now {
            // A new message: the last reply has had its turn.
            stopReading()
            return
        }
        guard was, readAloud, !Self.screenReaderRunning else { return }
        let reply = SpokenReply.latestTurn(in: chat.items)
        guard !reply.isEmpty else { return }
        let key = chat.items.last { if case .assistant = $0.kind { true } else { false } }?.id ?? chat.storedID
        Task { await ReplyVoice.shared.speak(reply, key: key, owner: chat.storedID) }
    }

    /// VoiceOver already reads a reply as it arrives; a second voice over it helps nobody.
    private static var screenReaderRunning: Bool {
        #if os(macOS)
        NSWorkspace.shared.isVoiceOverEnabled
        #else
        UIAccessibility.isVoiceOverRunning
        #endif
    }
}
