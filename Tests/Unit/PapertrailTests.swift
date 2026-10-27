import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Papertrail: the add-on's week for one bot, read from the main bot's scope with `bot=`; its
/// labels and amounts; Today against the Mac's own midnight; and the tab private bots never get.
@MainActor
@Suite(.serialized) struct PapertrailTests {
    nonisolated private static let sample = #"""
    {
      "bot": "work", "days": 7, "now": 1760970000, "today_starts_at": 1760914800,
      "since": 1760396400, "recording_since": 1760396400,
      "stayed": {"today": 12, "window": 40}, "left": {"today": 3, "window": 9},
      "entries": [
        {"id": "t-42", "at": 1760969000, "started_at": 1760968900, "route": "online",
         "provider": "claude-subscription-direct", "provider_name": null, "host": null,
         "model": "claude-sonnet-5-5", "calls": 6, "helpers": ["title_generation"], "services": ["exa"],
         "input_tokens": 18000, "output_tokens": 900, "cache_read_tokens": 52000, "reasoning_tokens": 0,
         "searches": 2, "pages": 3, "images": 0},
        {"id": "t-7", "at": 1760500000, "route": "network", "provider": "custom", "host": "http://10.0.0.4:8080",
         "input_tokens": 400, "output_tokens": 20},
        {"id": "t-9", "at": 1760960000, "route": "online", "provider": null, "host": null, "model": null,
         "services": ["exa"], "searches": 1}
      ],
      "more": 0
    }
    """#

    @Test func theSpecSampleDecodes() throws {
        let trail = try JSONCoding.decoder.decode(Papertrail.self, from: Data(Self.sample.utf8))
        #expect(trail.isAnswer)
        #expect(trail.stayedCount == 40 && trail.leftCount == 9)
        // The network reply left this Mac but did not go online.
        #expect(trail.onlineCount == 8)
        #expect(trail.nextDayStartsAt == 1_761_001_200)
        #expect(trail.todayStartsAt == 1_760_914_800)
        let first = try #require(trail.entries?.first)
        #expect(first.id == "t-42")
        #expect(first.provider == "claude-subscription-direct")
        #expect(first.inputTokens == 18_000 && first.outputTokens == 900 && first.cacheReadTokens == 52_000)
        #expect(first.services == ["exa"] && first.helpers == ["title_generation"])
        #expect(first.routeLabel == "Claude plan")
        #expect(first.amountText == "19k tokens · 2 searches · 3 pages")
        // A sparse entry still decodes: only the id and the time are required.
        let sparse = try JSONCoding.decoder.decode(Papertrail.self, from: Data(#"{"entries":[{"id":"x","at":1}]}"#.utf8))
        #expect(sparse.entries?.first?.routeLabel == "Online")
        #expect(sparse.stayedCount == 0)
    }

    @Test func connectionsTheDoorSawNameEveryPlace() throws {
        let json = #"{"entries": [{"id": "t-1", "at": 1760969000, "route": "online", "provider": "anthropic", "calls": 2,"#
            + #" "input_tokens": 900, "output_tokens": 100, "why": {"origin": "chat", "messages": 3}, "connections": ["#
            + #"{"host": "api.anthropic.com", "port": 443, "kind": "model", "route": "online", "count": 2},"#
            + #"{"host": "pypi.org", "port": 443, "kind": "terminal", "route": "online", "count": 1}]},"#
            + #" {"id": "w-1", "at": 1760960000, "route": "online", "calls": 0, "connections": ["#
            + #"{"host": "code.example.com", "port": 443, "kind": "terminal", "route": "online", "count": 2}]},"#
            + #" {"id": "w-2", "at": 1760950000, "route": "network", "calls": 0, "connections": ["#
            + #"{"host": "192.168.1.20", "port": 8080, "kind": "mcp", "route": "network", "count": 1}]}]}"#
        let trail = try JSONCoding.decoder.decode(Papertrail.self, from: Data(json.utf8))
        let entries = try #require(trail.entries)
        let reply = entries[0], alone = entries[1], home = entries[2]
        #expect(reply.routeLabel == "Anthropic")
        #expect(reply.outsideHosts == ["api.anthropic.com", "pypi.org"])
        #expect(reply.amountText == "1k tokens · 3 connections")
        let why = reply.why(bot: "Scout")
        #expect(why.kept)
        #expect(why.sent == "What went: 3 messages (about 1k tokens). Connected to api.anthropic.com and pypi.org.")

        // Connections alone name the place, and who made them is the reason.
        #expect(alone.routeLabel == "code.example.com")
        #expect(alone.amountText == "2 connections")
        let aloneWhy = alone.why(bot: "Scout")
        #expect(aloneWhy.kept)
        #expect(aloneWhy.reason == "Scout ran a command that connected to code.example.com.")
        #expect(aloneWhy.sent == "Connected to code.example.com.")
        #expect(home.routeLabel == "Your network")
        #expect(home.why(bot: "Scout").reason == "Scout used a connected app that reached 192.168.1.20.")
    }

    @Test func manyPlacesAreNamedUpToSix() {
        var entry = Papertrail.Entry(id: "w", at: 1, route: "online")
        entry.connections = (1...8).map { .init(host: "h\($0).example", count: 1) }
        let sent = entry.why(bot: "Scout").sent ?? ""
        #expect(sent == "Connected to h1.example, h2.example, h3.example, h4.example, h5.example and 3 more.")
        #expect(Papertrail.connectionLine(kind: "hermes", host: "a.example", bot: "Nollie")
                == "Nollie connected to a.example by itself, outside a reply.")
        #expect(Papertrail.connectionLine(kind: "anything", host: "a.example", bot: "Nollie")
                == "A program Nollie started connected to a.example.")
        #expect(Papertrail.connectionLine(kind: "direct", host: "a.example", bot: "Nollie")
                == "A program Nollie started reached a.example directly.")
    }

    @Test func notesForTheIPhoneThroughICloudAreNamedAndNotCountedAsOnline() throws {
        let json = #"{"left": {"today": 2, "window": 2}, "entries": [{"id": "w-1", "at": 1760969000, "route": "icloud", "calls": 2,"#
            + #" "icloud_notes": 2, "why": {"origin": "chat"}}, {"id": "t-1", "at": 1760968000, "route": "online", "provider": "anthropic"}]}"#
        let trail = try JSONCoding.decoder.decode(Papertrail.self, from: Data(json.utf8))
        let note = try #require(trail.entries?.first)
        #expect(note.routeLabel == "Your iCloud")
        #expect(note.amountText == "2 notes to your iPhone")
        #expect(note.why(bot: "Scout").reason.contains("through your own iCloud"))
        #expect(trail.onlineCount == 1)
    }

    @Test func anEmptyAnswerIsNotPapertrail() throws {
        // An older gateway or the mock answers unknown routes with 200 and nothing in it.
        let empty = try JSONCoding.decoder.decode(Papertrail.self, from: Data("{}".utf8))
        #expect(!empty.isAnswer)
    }

    @Test func routesReadAsShortNames() {
        typealias E = Papertrail.Entry
        #expect(E(id: "a", at: 0, provider: "claude-subscription-direct").routeLabel == "Claude plan")
        #expect(E(id: "a", at: 0, provider: "openai-codex").routeLabel == "ChatGPT plan")
        #expect(E(id: "a", at: 0, provider: "openrouter").routeLabel == "OpenRouter")
        #expect(E(id: "a", at: 0, provider: "nous").routeLabel == "Nous Portal")
        #expect(E(id: "a", at: 0, provider: "Anthropic").routeLabel == "Anthropic")
        // Unknown: Hermes's own name, then the host, then just Online.
        #expect(E(id: "a", at: 0, provider: "acme", providerName: "Acme Cloud", host: "https://api.acme.example").routeLabel == "Acme Cloud")
        #expect(E(id: "a", at: 0, provider: "acme", host: "https://api.acme.example:8443").routeLabel == "api.acme.example")
        #expect(E(id: "a", at: 0, provider: "acme").routeLabel == "Online")
        // Another machine on the network, whatever its provider.
        #expect(E(id: "a", at: 0, route: "network", provider: "openai", host: "http://10.0.0.4:8080").routeLabel == "Your network")
        // Only a search left: the service, else the web.
        #expect(E(id: "a", at: 0, services: ["exa"], searches: 2).routeLabel == "Exa")
        #expect(E(id: "a", at: 0, services: ["someone-new"], searches: 1).routeLabel == "Web")
        #expect(E(id: "a", at: 0, pages: 2).routeLabel == "Web")
        #expect(E(id: "a", at: 0, images: 1).routeLabel == "Online")
        // A model on your network with a search that went online: the search names it, not the machine.
        #expect(E(id: "a", at: 0, provider: "custom", host: "http://192.168.1.40:8080", services: ["exa"], searches: 2).routeLabel == "Exa")
        #expect(E(id: "a", at: 0, provider: "custom", host: "http://100.101.7.3:8080", pages: 1).routeLabel == "Web")
        #expect(E(id: "a", at: 0, provider: "custom", host: "http://studio.local:8080", images: 1).routeLabel == "Online")
        #expect(E(id: "a", at: 0, provider: "custom", host: "https://8.8.8.8", searches: 1).routeLabel == "8.8.8.8")
    }

    @Test func networkHostsReadLikeTheRouteRule() {
        for host in ["127.0.0.1", "10.0.0.4", "172.20.1.1", "192.168.1.40", "169.254.3.3", "100.64.0.1", "100.127.9.9",
                     "::1", "[fd7a:115c::1]", "fe80::1", "studio.local", "nas", "localhost"] {
            #expect(Papertrail.isNetworkHost(host), "\(host)")
        }
        for host in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "api.openai.com", "2606:4700::1", "10.0.0.300", "1.2.3.4.5"] {
            #expect(!Papertrail.isNetworkHost(host), "\(host)")
        }
    }

    @Test func amountsRoundAndCountWhatLeft() {
        typealias E = Papertrail.Entry
        #expect(Papertrail.rounded(999) == "999")
        #expect(Papertrail.rounded(1_234) == "1.2k")
        #expect(Papertrail.rounded(1_000) == "1k")
        #expect(Papertrail.rounded(18_000) == "18k")
        #expect(Papertrail.rounded(9_960) == "10k")
        #expect(Papertrail.rounded(999_600) == "1M")
        #expect(Papertrail.rounded(1_400_000) == "1.4M")
        #expect(Papertrail.rounded(18_000, spoken: true) == "18 thousand")
        // Tokens are what was sent and what came back; cache reads are not counted again.
        let reply = E(id: "a", at: 0, inputTokens: 17_600, outputTokens: 400, searches: 2, pages: 3)
        #expect(reply.amountText == "18k tokens · 2 searches · 3 pages")
        #expect(reply.spokenAmount == "18 thousand tokens, 2 searches, 3 pages")
        #expect(E(id: "a", at: 0, images: 1).amountText == "1 picture")
        #expect(E(id: "a", at: 0, searches: 1, pages: 1).amountText == "1 search · 1 page")
        #expect(E(id: "a", at: 0, calls: 2).amountText == "2 requests")
        #expect(E(id: "a", at: 0).amountText.isEmpty)
    }

    @Test func todayStartsAtTheMacsMidnight() throws {
        let trail = try JSONCoding.decoder.decode(Papertrail.self, from: Data(Self.sample.utf8))
        let (today, earlier) = trail.split(now: Date(timeIntervalSince1970: 1_760_970_000))
        #expect(today.map(\.id) == ["t-42", "t-9"], "newest first")
        #expect(earlier.map(\.id) == ["t-7"])
        // Without the Mac's midnight, this device's.
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_760_970_000)
        let midnight = calendar.startOfDay(for: now).timeIntervalSince1970
        let local = Papertrail(todayStartsAt: nil, entries: [.init(id: "a", at: midnight + 1), .init(id: "b", at: midnight - 1)])
        let split = local.split(now: now, calendar: calendar)
        #expect(split.today.map(\.id) == ["a"] && split.earlier.map(\.id) == ["b"])
        // A read from yesterday, still open after the Mac's midnight: yesterday's rows move to Earlier.
        let stale = Papertrail(todayStartsAt: 1_000_000, entries: [.init(id: "y", at: 1_000_100), .init(id: "t", at: 1_086_500)])
        let moved = stale.split(now: Date(timeIntervalSince1970: 1_086_600))
        #expect(moved.today.map(\.id) == ["t"] && moved.earlier.map(\.id) == ["y"])
    }

    @Test func aClockChangeDayKeepsTodayUntilTheMacsOwnMidnight() throws {
        // 1 Nov 2026 in Los Angeles: clocks go back at 02:00, so the day runs 25 hours.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let tomorrow = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        let late = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 22, minute: 30)))
        #expect(tomorrow.timeIntervalSince(today) == 90_000)
        let trail = Papertrail(todayStartsAt: today.timeIntervalSince1970, tomorrowStartsAt: tomorrow.timeIntervalSince1970,
                               entries: [.init(id: "late", at: late.timeIntervalSince1970)])
        let split = trail.split(now: late.addingTimeInterval(600), calendar: calendar)
        #expect(split.today.map(\.id) == ["late"], "a 22:30 row is still today on a 25-hour day")
        #expect(trail.nextDayStartsAt == tomorrow.timeIntervalSince1970)
        let after = trail.split(now: tomorrow.addingTimeInterval(60), calendar: calendar)
        #expect(after.today.isEmpty && after.earlier.map(\.id) == ["late"])
    }

    @Test func aTodayRowFromAnotherDayHereNamesItsDay() {
        // The Mac's today can be the phone's yesterday in another time zone.
        let old = Date().addingTimeInterval(-3 * 86_400).timeIntervalSince1970
        #expect(PapertrailView.time(old, today: true) == PapertrailView.time(old, today: false))
        let now = Date().timeIntervalSince1970
        #expect(PapertrailView.time(now, today: true) != PapertrailView.time(now, today: false))
    }

    @Test func todayHasOneAnswer() throws {
        let trail = try JSONCoding.decoder.decode(Papertrail.self, from: Data(Self.sample.utf8))
        let now = Date(timeIntervalSince1970: 1_760_970_000)
        let today = PapertrailToday(trail, now: now)
        #expect(today.left == 3 && today.online == 3)
        #expect(today.headline == "Went online 3 times today")
        #expect(!today.allOneRoute, "Claude plan and Exa")
        #expect(PapertrailToday.wentOnline(1) == "Went online once today")
        // Read before the Mac's midnight, shown after it: today starts empty, not with yesterday's count.
        #expect(PapertrailToday(trail, now: Date(timeIntervalSince1970: 1_761_001_300)).headline == "Nothing left your Mac today")
        let midnight = 1_760_914_800.0
        #expect(PapertrailToday(Papertrail(todayStartsAt: midnight, entries: []), now: now).headline == "Nothing left your Mac today")
        let network = Papertrail(todayStartsAt: midnight, entries: [.init(id: "n", at: midnight + 10, route: "network")])
        let networkToday = PapertrailToday(network, now: now)
        #expect(networkToday.left == 1 && networkToday.online == 0)
        #expect(networkToday.headline == "Stayed on your network today")
    }

    @Test func privateBotsHaveNoPapertrailTab() {
        #expect(ProfileTab.available(withChat: false).contains(.papertrail))
        #expect(!ProfileTab.available(withChat: true, privateBot: true).contains(.papertrail))
        let tabs = ProfileTab.available(withChat: false)
        #expect(tabs.firstIndex(of: .papertrail) == tabs.firstIndex(of: .model).map { $0 + 1 }, "right after Model")
        #expect(ProfileTab.papertrail.title == "Papertrail")
    }

    // MARK: The read

    private func api() throws -> HermesAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PapertrailStub.self]
        return HermesAPI(gateway: try GatewayURL.normalize("https://papertrail.invalid/hermes"),
                         signer: RequestSigner(authMode: .sessionToken, sessionToken: "papertrail-test-token"),
                         urlSession: URLSession(configuration: configuration))
    }

    @Test func theReadAsksTheMainScopeForOneBot() async throws {
        PapertrailStub.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/hermes/api/plugins/nollie-workflow/papertrail")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "bot", value: "work")))
            #expect(query.contains(URLQueryItem(name: "days", value: "7")))
            #expect(!query.contains { $0.name == "profile" }, "the workflow routes refuse other profiles")
            #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "papertrail-test-token")
            return (200, Data(Self.sample.utf8))
        }
        defer { PapertrailStub.reset() }
        let result = try await Papertrail.load(bot: "work", api: try api())
        guard case .on(let trail) = result else { Issue.record("expected Papertrail, got \(result)"); return }
        #expect(trail.entries?.count == 3)
    }

    @Test func missingOffAndPrivateAreTold() async throws {
        defer { PapertrailStub.reset() }
        PapertrailStub.handler = { _ in (404, Data(#"{"detail":"Papertrail is not on for this bot."}"#.utf8)) }
        #expect(try await Papertrail.load(bot: "work", api: try api()) == .off)
        PapertrailStub.handler = { _ in (200, Data("{}".utf8)) }
        #expect(try await Papertrail.load(bot: "work", api: try api()) == .off)
        PapertrailStub.handler = { _ in (403, Data(#"{"detail":"Papertrail is not kept for private bots."}"#.utf8)) }
        #expect(try await Papertrail.load(bot: "hidden", api: try api()) == .privateBot)
        // A Link door from before the Papertrail rule refuses the route too: a failed read, not a private bot.
        PapertrailStub.handler = { _ in (403, Data(#"{"detail":"This can only be changed on your Mac."}"#.utf8)) }
        await #expect(throws: HermesAPIError.self) { try await Papertrail.load(bot: "default", api: try api()) }
        PapertrailStub.handler = { _ in (503, Data(#"{"detail":"Not now."}"#.utf8)) }
        await #expect(throws: HermesAPIError.self) { try await Papertrail.load(bot: "work", api: try api()) }
    }

    @Test func aFailedReadKeepsWhatWasShown() async throws {
        let connection = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://papertrail.invalid/hermes"), authMode: .sessionToken)
        let runtime = GatewayRuntime(connection: connection, store: ConnectionStore())
        let model = PapertrailModel(api: try api())
        defer { PapertrailStub.reset() }
        PapertrailStub.handler = { _ in (503, Data(#"{"detail":"Not now."}"#.utf8)) }
        #expect(await model.load(bot: "work", runtime: runtime) == false)
        #expect(model.state == .failed)
        PapertrailStub.handler = { _ in (200, Data(Self.sample.utf8)) }
        #expect(await model.load(bot: "work", runtime: runtime))
        guard case .on = model.state else { Issue.record("expected Papertrail"); return }
        PapertrailStub.handler = { _ in (503, Data(#"{"detail":"Not now."}"#.utf8)) }
        #expect(await model.load(bot: "work", runtime: runtime) == false)
        guard case .on = model.state else { Issue.record("the week on show was dropped"); return }
        // Another bot starts over.
        PapertrailStub.handler = { _ in (404, Data(#"{"detail":"No such bot."}"#.utf8)) }
        #expect(await model.load(bot: "home", runtime: runtime))
        #expect(model.state == .off)
    }
}

private final class PapertrailStub: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data)?)?

    static func reset() { handler = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let (status, data) = Self.handler?(request) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
