import Foundation
import Observation
import WatchConnectivity
import WidgetKit

/// The Watch's side: the phone's last picture, and the way to ask it for a fresh one, to answer an
/// approval or to Stop. The Watch never decides on its own; the phone carries everything out and
/// checks its rules again.
@MainActor
@Observable
final class WatchModel: NSObject {
    static let shared = WatchModel()

    private(set) var snapshot: WatchWire.Snapshot?
    /// What the last answer or Stop came to, shown for a moment.
    private(set) var note: String?
    /// Cards being answered, and "stop" while a Stop travels.
    private(set) var sending: Set<String> = []
    /// The page to show: a card's id, `crewPage` or `nightPage`.
    var page: String = WatchModel.crewPage
    /// The phone could not be reached last time.
    private(set) var phoneAway = false

    nonisolated static let crewPage = "crew"
    nonisolated static let nightPage = "night"
    nonisolated static let stopKey = "stop"

    private var started = false
    private var noteClear: Task<Void, Never>?
    /// A card named by a notification's Allow once, to open once it arrives.
    private var wanted: Set<String> = []

    // MARK: Starting

    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        if let sample = WatchSamples.fromLaunch() {
            take(sample.snapshot, save: false)
            page = sample.page
            note = sample.note
            if sample.sendingStop { sending.insert(Self.stopKey) }
            return
        }
        #endif
        snapshot = WatchSnapshotStore.load()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: Asking the phone

    /// A fresh picture from the phone.
    func refresh() async {
        #if DEBUG
        if WatchSamples.active { return }
        #endif
        guard let reply = await send(.refresh) else { return }
        if let fresh = reply.snapshot { take(fresh) }
    }

    func answer(_ approval: WatchWire.Approval, _ choice: WatchWire.Choice) async {
        guard !sending.contains(approval.id) else { return }
        sending.insert(approval.id)
        defer { sending.remove(approval.id) }
        let answer = WatchWire.Answer(cardID: approval.id, requestID: approval.requestID, chatID: approval.chatID,
                                      profile: approval.profile, connectionID: approval.connectionID, choice: choice)
        guard let reply = await send(.answer(answer)) else { return show(WatchWords.phoneAway) }
        if let fresh = reply.snapshot { take(fresh) }
        show(reply.line)
    }

    func stop() async {
        guard !sending.contains(Self.stopKey) else { return }
        sending.insert(Self.stopKey)
        defer { sending.remove(Self.stopKey) }
        guard let reply = await send(.stop) else { return show(WatchWords.phoneAway) }
        if let fresh = reply.snapshot { take(fresh) }
        show(reply.line)
    }

    /// From the Stop control: show the crew, then Stop.
    func stopFromControl() {
        page = Self.crewPage
        Task { await stop() }
    }

    /// From a notification's Allow once: open that card once the phone has sent it.
    func open(card keys: [String]) {
        wanted = Set(keys.filter { !$0.isEmpty })
        openWanted()
        Task { await refresh() }
    }

    /// Deny on a notification shown here. The phone carries it out as its own notification's
    /// Deny. Out of reach, it goes once the phone is near: a late no is still a no.
    func denyFromNotification(_ details: [String: String]) {
        let request = WatchWire.Request.notificationDeny(details)
        let session = WCSession.default
        if session.activationState == .activated, session.isReachable {
            session.sendMessage(WatchWire.message(request), replyHandler: nil) { _ in
                WCSession.default.transferUserInfo(WatchWire.message(request))
            }
        } else {
            session.transferUserInfo(WatchWire.message(request))
        }
    }

    private func send(_ request: WatchWire.Request) async -> WatchWire.Reply? {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            phoneAway = true
            return nil
        }
        let message = WatchWire.message(request)
        let reply: WatchWire.Reply? = await withCheckedContinuation { done in
            session.sendMessage(message, replyHandler: { answer in
                done.resume(returning: try? WatchWire.reply(from: answer))
            }, errorHandler: { _ in
                done.resume(returning: nil)
            })
        }
        phoneAway = reply == nil
        return reply
    }

    // MARK: The picture

    private func take(_ fresh: WatchWire.Snapshot, save: Bool = true) {
        if let snapshot, snapshot.made > fresh.made { return }
        let helpersMoved = snapshot?.helpers != fresh.helpers || snapshot?.canStop != fresh.canStop
        let known = Set(snapshot?.approvals.map(\.id) ?? [])
        snapshot = fresh
        let onCard = page != Self.crewPage && page != Self.nightPage
        if !onCard, let new = fresh.approvals.first(where: { !known.contains($0.id) }) {
            // Something new waits: show it, unless a card is already open.
            page = new.id
        } else if page == Self.nightPage, fresh.night == nil {
            page = Self.crewPage
        } else if onCard, !fresh.approvals.contains(where: { $0.id == page }) {
            // The card on screen was answered: the next one, or the crew.
            page = fresh.approvals.first?.id ?? Self.crewPage
        }
        openWanted()
        guard save else { return }
        WatchSnapshotStore.save(fresh)
        if helpersMoved { WidgetCenter.shared.reloadAllTimelines() }
    }

    private func openWanted() {
        guard !wanted.isEmpty, let card = snapshot?.approvals.first(where: { wanted.contains($0.id) || wanted.contains($0.requestID) }) else { return }
        page = card.id
        wanted = []
    }

    private func show(_ line: String?) {
        note = line
        noteClear?.cancel()
        guard line != nil else { return }
        noteClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.note = nil
        }
    }

    /// Waits, a little, for what the phone is still delivering, so a background wake ends with it kept.
    func settle() async {
        start()
        let giveUp = Date().addingTimeInterval(10)
        while WCSession.default.hasContentPending, Date() < giveUp {
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Takes a picture that arrived in the background (application context or complication
    /// transfer).
    nonisolated fileprivate func arrived(_ message: [String: Any]) {
        guard let fresh = try? WatchWire.snapshot(from: message) else { return }
        Task { @MainActor in WatchModel.shared.take(fresh) }
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        guard state == .activated else { return }
        let context = session.receivedApplicationContext
        if !context.isEmpty { arrived(context) }
        Task { @MainActor in await WatchModel.shared.refresh() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        arrived(context)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        arrived(userInfo)
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in await WatchModel.shared.refresh() }
    }
}
