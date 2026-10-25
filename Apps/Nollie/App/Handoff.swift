import SwiftUI
import NollieCore

/// Chat handoff. Whichever chat is on screen is advertised to the person's other devices (Dock
/// on Mac, app switcher on iPhone); picking it there opens the identical chat. The OS carries
/// this between devices on a single iCloud account, with no Nollie server in the path.
@MainActor
enum ChatHandoff {
    nonisolated static let activityType = Keychain.baseBundleID + ".chat"

    private enum Key {
        static let session = "session", profile = "profile", gateway = "gateway"
    }

    /// Describes a chat for the system to offer elsewhere. The gateway goes by its address,
    /// because the same saved gateway has a different id on each device.
    static func fill(_ activity: NSUserActivity, chat: ChatSession) {
        activity.title = chat.title
        activity.userInfo = [
            Key.session: chat.storedID,
            Key.profile: chat.profileName,
            Key.gateway: chat.runtime.connection.gateway.description,
        ]
        activity.requiredUserInfoKeys = [Key.session]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
    }

    /// Opens the chat an activity describes, switching to its gateway first when that is another
    /// saved one. Nothing happens when this device never saved that gateway.
    static func open(_ activity: NSUserActivity, model: AppModel) {
        let info = activity.userInfo
        guard let session = info?[Key.session] as? String, !session.isEmpty else { return }
        let profile = info?[Key.profile] as? String
        let gateway = info?[Key.gateway] as? String
        guard let link = link(session: session, profile: profile) else { return }

        if gateway == nil || gateway == model.runtime?.connection.gateway.description {
            model.open(link)
        } else if let saved = model.store.connections.first(where: { $0.gateway.description == gateway }) {
            Task {
                await model.activate(saved)
                model.open(link)
            }
        }
    }

    /// The link that opens a chat inside the app.
    private static func link(session: String, profile: String?) -> URL? {
        var parts = URLComponents(string: "nollie://chat")
        parts?.path = "/" + session
        if let profile, !profile.isEmpty {
            parts?.queryItems = [URLQueryItem(name: "profile", value: profile)]
        }
        return parts?.url
    }
}

/// Advertises the chat on screen to other devices. Nothing goes out for a new chat until its
/// first message, because only then does it have a stored id.
private struct OffersChat: ViewModifier {
    let chat: ChatSession

    func body(content: Content) -> some View {
        content.userActivity(ChatHandoff.activityType, isActive: chat.storedID != "") {
            ChatHandoff.fill($0, chat: chat)
        }
    }
}

/// Opens a chat another device handed over.
private struct ContinuesChat: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.onContinueUserActivity(ChatHandoff.activityType) {
            ChatHandoff.open($0, model: model)
        }
    }
}

extension View {
    func handsOff(_ chat: ChatSession) -> some View { modifier(OffersChat(chat: chat)) }
    func continuesHandoff(_ model: AppModel) -> some View { modifier(ContinuesChat(model: model)) }
}
