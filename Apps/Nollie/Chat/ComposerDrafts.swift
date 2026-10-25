import Foundation
import NollieCore

/// Text typed but not sent. It is held for each chat, so stepping out and back in does not lose it.
@MainActor
enum ComposerDrafts {
    private static func slot(_ chat: ChatSession) -> String { "composerDraft." + chat.storedID }

    static func load(for chat: ChatSession) -> String? {
        UserDefaults.standard.string(forKey: slot(chat)).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func save(_ text: String, for chat: ChatSession) {
        UserDefaults.standard.set(text.isEmpty ? nil : text, forKey: slot(chat))
    }
}
