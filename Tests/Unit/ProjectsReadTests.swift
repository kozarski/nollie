import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Projects are read for one bot. If the person picks another bot while a read is out, the old bot's
/// answer is thrown away, and a refresh asked for meanwhile still happens.

/// A gateway that answers projects, trees and config per bot. A call can be made to wait for the test.
@MainActor private final class Shelf {
    private(set) var log: [String] = []
    private var hold: Set<String> = []
    private var parked: [String: CheckedContinuation<Void, Never>] = [:]
    /// What each bot's projects are called; a test changes it to show a newer answer.
    var names: [String: String] = ["alpha": "Alpha", "beta": "Beta"]

    func holdNext(_ call: String) { hold.insert(call) }
    func isWaiting(_ call: String) -> Bool { parked[call] != nil }
    func release(_ call: String) { parked.removeValue(forKey: call)?.resume() }
    func times(_ call: String) -> Int { log.filter { $0 == call }.count }

    func answer(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let bot = params["profile"]?.stringValue ?? "default"
        let call = method + ":" + bot
        log.append(call)
        if hold.remove(call) != nil { await withCheckedContinuation { parked[call] = $0 } }
        let name = names[bot] ?? bot
        switch method {
        case "projects.list":
            return ["projects": [["id": .string("p-" + bot), "name": .string(name)]], "active_id": nil]
        case "projects.tree":
            return ["projects": [["id": .string("p-" + bot), "session_ids": [.string("s-" + bot)]]]]
        case "config.get":
            return ["home": .string("/homes/" + bot)]
        default:
            return [:]
        }
    }
}

@MainActor private func runtime(on bot: String, shelf: Shelf) throws -> GatewayRuntime {
    let address = try GatewayURL.normalize("https://127.0.0.1:1")
    var link = GatewayConnection(name: "projects-\(bot)", gateway: address, authMode: .sessionToken)
    link.lastProfile = bot
    let made = GatewayRuntime(connection: link, store: ConnectionStore())
    made.socketEnabled = false
    made.gatewayStandIn = { method, params in try await shelf.answer(method, params) }
    made.projects.attach(made)
    return made
}

@MainActor private func pump(_ ready: () -> Bool) async {
    var turns = 0
    while !ready() && turns < 1000 {
        await Task.yield()
        turns += 1
    }
}

@MainActor @Suite struct ProjectsReadTests {
    @Test func aSwitchWhileTheListIsOutNeverKeepsTheOldBotsProjects() async throws {
        let shelf = Shelf()
        let rt = try runtime(on: "alpha", shelf: shelf)
        shelf.holdNext("projects.list:alpha")
        let first = Task { await rt.projects.refresh() }
        await pump { shelf.isWaiting("projects.list:alpha") }

        rt.selectedProfile = "beta"
        await rt.projects.refresh()
        #expect(rt.projects.projects.isEmpty)

        shelf.release("projects.list:alpha")
        await first.value
        #expect(rt.projects.projects.map(\.id) == ["p-beta"])
        #expect(rt.projects.membership == ["s-beta": "p-beta"])
        #expect(shelf.times("projects.tree:alpha") == 0, "the old bot's tree was never asked for")
        #expect(shelf.times("projects.list:beta") == 1 && shelf.times("projects.tree:beta") == 1)
    }

    @Test func aSwitchWhileTheTreeIsOutDropsTheOldBotsChats() async throws {
        let shelf = Shelf()
        let rt = try runtime(on: "alpha", shelf: shelf)
        shelf.holdNext("projects.tree:alpha")
        let first = Task { await rt.projects.refresh() }
        await pump { shelf.isWaiting("projects.tree:alpha") }
        try #require(rt.projects.projects.map(\.id) == ["p-alpha"])

        rt.selectedProfile = "beta"
        #expect(rt.projects.projects.isEmpty, "the new bot never shows the old bot's projects")
        #expect(rt.projects.membership.isEmpty)
        await rt.projects.refresh()

        shelf.release("projects.tree:alpha")
        await first.value
        #expect(rt.projects.projects.map(\.id) == ["p-beta"])
        #expect(rt.projects.membership == ["s-beta": "p-beta"], "no chat of the old bot is filed under the new one")
    }

    @Test func aRefreshAskedForWhileReadingStillHappens() async throws {
        let shelf = Shelf()
        let rt = try runtime(on: "alpha", shelf: shelf)
        shelf.holdNext("projects.list:alpha")
        let first = Task { await rt.projects.refresh() }
        await pump { shelf.isWaiting("projects.list:alpha") }

        shelf.names["alpha"] = "Alpha, renamed"
        await rt.projects.refresh()
        #expect(shelf.times("projects.list:alpha") == 1, "it waits for the read in progress")

        shelf.release("projects.list:alpha")
        await first.value
        #expect(shelf.times("projects.list:alpha") == 2)
        #expect(rt.projects.projects.map(\.name) == ["Alpha, renamed"])
    }

    @Test func aSlowOlderTreeNeverReplacesANewerOne() async throws {
        let shelf = Shelf()
        let rt = try runtime(on: "alpha", shelf: shelf)
        await rt.projects.refresh()
        shelf.holdNext("projects.tree:alpha")
        let older = Task { await rt.projects.refreshTree() }
        await pump { shelf.isWaiting("projects.tree:alpha") }
        await rt.projects.refreshTree()
        let newest = rt.projects.membership
        shelf.release("projects.tree:alpha")
        await older.value
        #expect(rt.projects.membership == newest)
    }

    @Test func theBotsHomeFolderIsKeptOnlyForTheBotThatWasAsked() async throws {
        let shelf = Shelf()
        let rt = try runtime(on: "alpha", shelf: shelf)
        shelf.holdNext("config.get:alpha")
        let first = Task { await rt.learnProfileHome() }
        await pump { shelf.isWaiting("config.get:alpha") }

        rt.selectedProfile = "beta"
        shelf.release("config.get:alpha")
        await first.value
        #expect(rt.profileHome == nil, "alpha's folder is not beta's")

        await rt.learnProfileHome()
        #expect(rt.profileHome == "/homes/beta")
    }

    @Test func switchingBotsClearsTheOldBotsHomeFolder() async throws {
        let shelf = Shelf()
        let rt = try runtime(on: "alpha", shelf: shelf)
        await rt.learnProfileHome()
        try #require(rt.profileHome == "/homes/alpha")
        rt.selectedProfile = "beta"
        #expect(rt.profileHome == nil)
    }
}
