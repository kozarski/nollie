import Foundation

// The seams where a platform plugs into the core. The core calls these and never imports
// ActivityKit, UserNotifications or anything else that only one platform has.

/// Stands in where a platform shows no turn surface.
@MainActor
public final class NoTurnActivity: TurnActivityReporting {
    public nonisolated init() {}

    public func start(for chat: ChatSession) { _ = chat }
    public func end(for chat: ChatSession, phase: String) { _ = (chat, phase) }
    public func update(for chat: ChatSession, attention attentionNeeded: Bool, detail note: String?) { _ = chat }
}

/// Sends the gateway this device's push registration once the gateway's abilities are known.
@MainActor
public protocol PushRegistrationSyncing: AnyObject {
    /// This device answered an approval. Reports which device it was, letting the Companion withdraw
    /// the request on every other device while leaving this one alone.
    func noteAnswer(requestID: String, session: String, runtime: GatewayRuntime)
    /// This device just sent a prompt in `session`, so the gateway should know it is the one
    /// driving that chat. The Companion keeps a phone quiet if it asked to be while a Mac drives.
    func noteSend(session: String, runtime: GatewayRuntime)
    func syncRegistration(runtime: GatewayRuntime) async
}

/// Alerts for the foreground app: a card has come in, or a turn has ended.
public typealias CardNotifying = CardArrivalNotifying & TurnEndNotifying

/// The half of `CardNotifying` about cards.
@MainActor
public protocol CardArrivalNotifying: AnyObject {
    func cardArrived(_ card: PendingCard, chat: ChatSession)
    /// A card on this device was removed without an answer here, since another device answered it.
    /// Whatever was posted for it, like a notice with an Approve button, is now out of date.
    func cardSettled(_ card: PendingCard, chat: ChatSession)
}

/// The half of `CardNotifying` about turns.
@MainActor
public protocol TurnEndNotifying: AnyObject {
    func turnFinished(chat: ChatSession, error: String?)
}

/// Shows that a turn is under way: the bot's spinner and Live Activity on the phone, a menu bar
/// item on the Mac.
@MainActor
public protocol TurnActivityReporting: AnyObject {
    /// Puts the chat's cards on the surface as they stand, with the first one in `update`'s
    /// place and no alert of any kind (no Island expanding, no buzz). Used when a surface has
    /// just started or been handed over, and when the card it showed is gone but others
    /// remain. Each card already made its noise when it arrived.
    func showCards(for chat: ChatSession)
    func end(for chat: ChatSession, phase: String)
    func update(for chat: ChatSession, attention: Bool, detail: String?)
    func start(for chat: ChatSession)
}

// MARK: Defaults

// Most platforms care about only some of the calls above, so these have a quiet default.

extension PushRegistrationSyncing {
    public func noteAnswer(requestID: String, session: String, runtime: GatewayRuntime) {}
    public func noteSend(session: String, runtime: GatewayRuntime) {}
}

extension CardArrivalNotifying {
    public func cardSettled(_ card: PendingCard, chat: ChatSession) {}
}

extension TurnActivityReporting {
    /// For surfaces that never raise alerts themselves, like the Mac's menu bar item.
    public func showCards(for chat: ChatSession) {
        let hasCards = !chat.cards.isEmpty
        update(for: chat, attention: hasCards, detail: nil)
    }

    public func update(for chat: ChatSession, attention: Bool) {
        let noDetail: String? = nil
        update(for: chat, attention: attention, detail: noDetail)
    }
}
