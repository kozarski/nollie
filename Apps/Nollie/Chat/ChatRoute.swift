import Foundation
import NollieCore

/// Names the chat screen to show: a stored chat by id, or a new one.
struct ChatRoute: Hashable {
    var storedID: String? = nil
    var title: String? = nil
    /// The bot whose gateway holds the chat; the screen switches to it before opening.
    var profile: String? = nil
    /// Text typed into the compose sheet; it is sent once the chat has opened.
    var initialText: String? = nil
    /// Files chosen in the compose sheet, staged and sent along with that first message.
    var initialAttachments = [AttachmentPreview]()
    /// Set when a "Messaged X" notice opens somebody else's chat: transcript only.
    var readOnly = false
    /// Set when this is a bot's main chat (`AppModel.openMainChat`); the default bot's shows Nollie's cards.
    var isMain = false
    /// Folder on the gateway that a brand-new chat starts in.
    var cwd: String? = nil
    /// Makes two otherwise equal "new chat" routes differ, so the Mac replaces the open chat each time.
    var token: UUID? = nil
    var connectionID: UUID? = nil
}
