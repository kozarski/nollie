#if os(iOS)
import Foundation
import NollieCore

/// Who is working right now, as this iPhone or iPad sees it: one entry a bot, by the same rule the
/// bot rows use (a chat open here mid-reply, a Board card, a schedule's run, a chat the gateway's
/// record shows mid-turn, or a helper it handed work to). The chat list's bar and the Watch both show this, so they agree
/// with the rows. Private bots' work stays out.
@MainActor
enum CrewAtWork {
    struct Member: Equatable, Identifiable {
        var helper: WatchWire.Helper
        /// The chat to open for it: the one it is working in, or its main chat.
        var chatID: String?
        /// What it is doing, in its row's words ("Searching the web…", "Working on “Morning brief”").
        var step: String
        /// The schedule's run or Board card the gateway says it is on, when no chat here speaks for it.
        var work: GatewayWork? = nil
        var id: String { helper.profile }

        /// The step, with how long it has run when it is a schedule or a card: "Working on “Morning brief” · 4 min".
        func line(now: Date = Date()) -> String {
            guard work != nil else { return step }
            return step + " \u{00B7} " + HelperAtWorkWords.elapsed(since: helper.since, now: now)
        }
    }

    /// When each bot was first seen at work with nothing better to date it, so its place in the
    /// order and the Watch's picture hold still between looks.
    private static var firstSeen: [String: Date] = [:]

    /// The helpers at work, longest-running first.
    static func members(in runtime: GatewayRuntime?, now: Date = Date()) -> [Member] {
        guard let runtime else { return [] }
        let home = BotsHome.shared
        var names = runtime.profiles.map(\.name)
        for chat in runtime.chats where !names.contains(chat.profileName) { names.append(chat.profileName) }
        var found: [Member] = []
        var working: Set<String> = []
        for profile in names where !WatchLink.isPrivate(profile, on: runtime) {
            let entry = home.entry(runtime, profile)
            let presence = BotPresence(runtime: runtime, profile: profile, mainID: entry.storedID, remoteBusy: entry.busy, now: now)
            guard presence.working else { continue }
            let seenKey = runtime.connection.id.uuidString + "/" + profile
            working.insert(seenKey)
            // Several chats at once: the one using a computer speaks for the bot, then the one that began first.
            let began = { (chat: ChatSession) in chat.items.last(where: \.isPrompt)?.timestamp ?? .distantFuture }
            let chats = runtime.chats.filter { $0.profileName == profile && $0.isRunning }.sorted { began($0) < began($1) }
            let places = chats.compactMap { chat in BotComputerActivity.workPlace(in: chat.items, isRunning: true).map { (chat, $0) } }
            let live = places.first?.0 ?? chats.first ?? presence.live
            let work = places.first?.1
            // A schedule's run or a Board card speaks for the bot only when no chat open here does.
            let gateway = live == nil ? presence.gatewayWork : nil
            let since = work?.since ?? live?.items.last(where: \.isPrompt)?.timestamp ?? gateway?.since ?? firstSeen[seenKey] ?? now
            if firstSeen[seenKey] == nil { firstSeen[seenKey] = since }
            let name = runtime.profiles.first { $0.name == profile }?.shownName ?? ProfileInfo.shownName(of: profile)
            let avatar = CharacterDrawing.avatarName(BotAvatarStore.look(for: profile))
            var shown = presence
            shown.live = live
            found.append(Member(helper: WatchWire.Helper(profile: profile, name: name, avatar: avatar, place: work?.place, since: since,
                                                         work: work == nil ? gateway?.title : nil),
                                chatID: live?.storedID ?? entry.storedID,
                                step: work.map { WatchWords.doing($0.place) } ?? BotActivity.line(shown),
                                work: work == nil ? gateway : nil))
        }
        let prefix = runtime.connection.id.uuidString + "/"
        firstSeen = firstSeen.filter { !$0.key.hasPrefix(prefix) || working.contains($0.key) }
        return found.sorted { ($0.helper.since, $0.helper.name) < ($1.helper.since, $1.helper.name) }
    }

    /// The bar's words: "Scout is working", "3 helpers working".
    nonisolated static func headline(_ helpers: [WatchWire.Helper]) -> String {
        if helpers.count == 1, let only = helpers.first { return String(localized: "\(only.name) is working") }
        return WatchWords.count(helpers.count)
    }
}

extension TranscriptItem {
    /// Something the person wrote.
    var isPrompt: Bool {
        if case .user = kind { return true }
        return false
    }
}
#endif
