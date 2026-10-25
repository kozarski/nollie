import Foundation
import NollieCore

/// The Mac's live hosts: one per chat, shared by everyone watching it. The Mac's own Watch screen
/// opens one in-process; a linked iPhone opens one through Nollie Runtime. The center picks the
/// source: Nollie Computer's window when its task is this chat's, else the helper's own computer
/// through this Mac's own gateway.
@MainActor
final class LiveHostCenter {
    static let shared = LiveHostCenter()
    /// Pictures from at most this many chats at once.
    static let maximumHosts = 2

    enum Opened {
        case attached(LiveHost, LiveHost.ViewerID)
        case ended(LiveWire.EndReason)
    }

    private var hosts: [LiveHost.Key: LiveHost] = [:]

    var isPrivate: (String) -> Bool = ComputerOtherControl.isPrivate
    /// Where a chat's pictures come from, or why there are none.
    var chooseSource: @MainActor (_ profile: String, _ sessionID: String) async -> Result<any LiveSource, LiveHostRefusal> = LiveHostCenter.source
    var environment = LiveHost.Environment()

    var count: Int { hosts.count }

    /// Sets the Mac's Watch screen up to play this Mac's own host, for chats on its own runtime.
    static func install() {
        LiveFeedRouter.local = { connection, profile, sessionID in
            LiveHostCenter.shared.localFeed(connection: connection, profile: profile, sessionID: sessionID)
        }
    }

    /// The in-process feed for a chat on this Mac's own runtime, or nil for any other gateway.
    func localFeed(connection: GatewayConnection, profile: String, sessionID: String) -> (any LiveFeed)? {
        guard Self.isOwnRuntime(connection) else { return nil }
        let feed = LiveLocalFeed()
        Task {
            // Closed before its host was found: nobody is watching.
            guard !feed.isClosed else { return }
            switch await open(profile: profile, sessionID: sessionID, viewer: feed, judged: false) {
            case .attached(let host, let id): feed.connect(host, id: id)
            case .ended(.unavailable): feed.unavailable()
            case .ended(let reason): feed.end(reason)
            }
        }
        return feed
    }

    /// Adds a viewer to the chat's host, starting one if needed.
    func open(profile: String, sessionID: String, viewer: any LiveHostViewer, judged: Bool) async -> Opened {
        guard NollieLiveRelay.isIdentifier(profile), NollieLiveRelay.isIdentifier(sessionID) else { return .ended(.refused) }
        // A private bot's chats are never read or shown.
        if isPrivate(profile) { return .ended(.refused) }
        let key = LiveHost.Key(profile: profile, sessionID: sessionID)
        if let joined = join(key, viewer: viewer, judged: judged) { return joined }
        guard hosts.count < Self.maximumHosts else { return .ended(.busy) }
        let source: any LiveSource
        switch await chooseSource(profile, sessionID) {
        case .success(let chosen): source = chosen
        case .failure(let refusal): return .ended(refusal.reason)
        }
        // Another viewer may have started this chat's host while its source was found.
        if let joined = join(key, viewer: viewer, judged: judged) { return joined }
        guard hosts.count < Self.maximumHosts else { return .ended(.busy) }
        let host = LiveHost(key: key, source: source, environment: environment) { [weak self] host in
            Task { @MainActor in self?.finished(host) }
        }
        hosts[key] = host
        guard case .viewer(let id) = host.attach(viewer, judged: judged) else { return .ended(.unavailable) }
        return .attached(host, id)
    }

    /// The chat's running host with this viewer added, or nil when there is none to join.
    private func join(_ key: LiveHost.Key, viewer: any LiveHostViewer, judged: Bool) -> Opened? {
        guard let host = hosts[key] else { return nil }
        switch host.attach(viewer, judged: judged) {
        case .viewer(let id): return .attached(host, id)
        case .full: return .ended(.busy)
        case .ended:
            hosts[key] = nil
            return nil
        }
    }

    /// Ends every stream, as when Nollie quits.
    func stopAll(_ reason: LiveWire.EndReason = .gone) {
        for host in hosts.values { host.stop(reason) }
        hosts = [:]
    }

    private func finished(_ host: LiveHost) {
        if hosts[host.key] === host { hosts[host.key] = nil }
    }

    // MARK: Sources

    /// Nollie Computer's window when its running task is this chat's; otherwise the helper's own
    /// computer, asked through this Mac's own gateway.
    static func source(profile: String, sessionID: String) async -> Result<any LiveSource, LiveHostRefusal> {
        if await ComputerCenter.shared.isTaskChat(profile: profile, sessionID: sessionID) {
            return .success(LiveWindowSource(profile: profile, sessionID: sessionID))
        }
        guard let runtime = AppModel.shared.runtime, isOwnRuntime(runtime.connection) else { return .failure(.init(reason: .unavailable)) }
        return .success(LivePreviewSource(api: runtime.api, profile: profile, sessionID: sessionID))
    }

    /// This Mac's own Nollie Runtime, on loopback: never a remote gateway, a linked Mac or the demo.
    static func isOwnRuntime(_ connection: GatewayConnection) -> Bool {
        connection.managedInstallationID != nil && connection.linkedMac == nil && !DemoMode.isOn
            && GatewayConnection.isManagedLoopbackEndpoint(connection.gateway.base)
    }
}

/// Why a chat has no live picture here.
struct LiveHostRefusal: Error, Equatable {
    var reason: LiveWire.EndReason
}
