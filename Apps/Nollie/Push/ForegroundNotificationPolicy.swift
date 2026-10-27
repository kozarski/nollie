import Foundation
import UserNotifications
import NollieCore

/// Only the conversation actually on screen can replace an incoming alert.
@MainActor
enum ForegroundNotificationPolicy {
    struct VisibleConversation {
        let connection: GatewayConnection
        let profile: String
        let sessionIDs: Set<String>
    }

    struct Context {
        var connections: [GatewayConnection]
        var visible: VisibleConversation?
        var isConversationObscured = false
    }

    static func context(_ model: AppModel?) -> Context {
        guard let model else { return Context(connections: [], visible: nil) }
        var context = Context(connections: model.store.connections, visible: nil,
                              isConversationObscured: model.visibleChatIsObscured || model.botSheet != nil)
        guard LocalNotifier.isForeground, !model.lock.isLocked, model.selectedTab == .chats,
              let chat = model.visibleChat, model.runtime === chat.runtime else { return context }
        let sessions = [chat.storedID, model.visibleChatID, model.visibleChatRequestedID]
            .compactMap { $0 }.filter { !$0.isEmpty }
        context.visible = VisibleConversation(connection: chat.runtime.connection, profile: chat.profileName,
                                              sessionIDs: Set(sessions))
        return context
    }

    static func options(event: CloudAlertEvent?, context: Context) -> UNNotificationPresentationOptions {
        guard let event else { return [.list] }
        if event.kind == .test { return [.banner, .sound, .list] }
        // A helper started using the Mac: worth a look on the iPhone even with the app open. The
        // Mac it is about already shows the task, so there it only goes to the list.
        if event.kind == .computerStarted { return DeviceWords.isMac ? [.list] : [.banner, .list] }
        // The weekly note has no chat of its own to be read in, so it shows even with the app open.
        if event.kind == .weeklyNote { return [.banner, .list] }
        guard let target = event.target, target.isValid else { return [.list] }
        let route = PendingRoute(connectionID: target.connectionID, gatewayFingerprint: target.gatewayFingerprint,
                                 gatewayIdentity: target.gatewayIdentity, storedSessionID: target.sessionID,
                                 profile: target.profile)
        return options(route: route, context: context)
    }

    static func options(route: PendingRoute?, isTest: Bool = false, context: Context) -> UNNotificationPresentationOptions {
        if isTest { return [.banner, .sound, .list] }
        // An unidentified foreground update stays in Notification Center without interrupting.
        guard let route, let destination = NotificationNavigation.connection(for: route, among: context.connections) else {
            return [.list]
        }
        if let visible = context.visible,
           NotificationNavigation.connection(for: route, among: [visible.connection])?.id == visible.connection.id,
           isReading(connectionID: destination.id, profile: route.profile ?? "default",
                     sessionID: route.storedSessionID, context: context) {
            return []
        }
        return [.banner, .sound, .list]
    }

    /// Clearing delivered alerts follows the same rule as replacing a new foreground alert.
    static func isReading(connectionID: UUID, profile: String, sessionID: String, context: Context) -> Bool {
        guard !context.isConversationObscured, let visible = context.visible else { return false }
        return visible.connection.id == connectionID && visible.profile == profile && visible.sessionIDs.contains(sessionID)
    }
}

/// CloudKit can outlive cancellation. A late lookup must not hold the system's presentation callback.
@MainActor
enum ForegroundNotificationLookup {
    static func resolve(load: @escaping @MainActor @Sendable () async -> CloudAlertEvent?,
                        waitForTimeout: @escaping @MainActor @Sendable () async throws -> Void = {
                            try await Task.sleep(for: .seconds(2))
                        }) async -> CloudAlertEvent? {
        await Pending().value(load: load, waitForTimeout: waitForTimeout)
    }

    @MainActor
    private final class Pending {
        private var continuation: CheckedContinuation<CloudAlertEvent?, Never>?
        private var lookup: Task<Void, Never>?
        private var timeout: Task<Void, Never>?

        func value(load: @escaping @MainActor @Sendable () async -> CloudAlertEvent?,
                   waitForTimeout: @escaping @MainActor @Sendable () async throws -> Void) async -> CloudAlertEvent? {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    guard !Task.isCancelled else { finish(nil); return }
                    lookup = Task { [weak self] in
                        let event = await load()
                        self?.finish(event)
                    }
                    timeout = Task { [weak self] in
                        do { try await waitForTimeout() } catch { return }
                        self?.finish(nil)
                    }
                }
            } onCancel: {
                Task { @MainActor in self.finish(nil) }
            }
        }

        private func finish(_ event: CloudAlertEvent?) {
            guard let continuation else { return }
            self.continuation = nil
            lookup?.cancel(); lookup = nil
            timeout?.cancel(); timeout = nil
            continuation.resume(returning: event)
        }
    }
}
