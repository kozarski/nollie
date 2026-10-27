#if os(macOS)
import Foundation
import Network
import Testing
@testable import NollieCore

/// Papertrail's door from Nollie Runtime, compiled into this test bundle: the lines it writes into a
/// bot's Papertrail, who it writes nothing for, and the whole door on loopback.
struct PapertrailDoorTests {
    // MARK: The book

    private func setup() throws -> (home: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nollie-door-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("profiles/scout"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("profiles/moss"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("profiles/wren"), withIntermediateDirectories: true)
        return (home, { try? FileManager.default.removeItem(at: root) })
    }

    private func lines(_ botHome: URL) -> [[String: Any]] {
        let folder = botHome.appendingPathComponent("nollie-workflow/papertrail")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasSuffix(".jsonl") }.sorted().flatMap { name -> [[String: Any]] in
            let text = (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
    }

    @Test func routesFollowTheAddOnsRule() {
        let table: [String: String] = [
            "api.example.com": "online", "93.184.216.34": "online", "2606:4700::1": "online",
            "localhost": "mac", "127.0.0.1": "mac", "::1": "mac", "0.0.0.0": "mac",
            "192.168.1.9": "network", "10.0.0.2": "network", "172.20.1.1": "network", "100.100.1.1": "network",
            "169.254.1.1": "network", "fd7a:115c:a1e0::1": "network", "fe80::1": "network", "nas.local": "network",
            "printer": "network", "172.32.0.1": "online", "100.128.0.1": "online",
        ]
        for (host, route) in table { #expect(PapertrailDoorBook.route(host) == route, "\(host)") }
    }

    @Test func labelsNameABotAndAKind() {
        #expect(PapertrailDoorBook.label("scout.terminal")! == ("scout", "terminal"))
        #expect(PapertrailDoorBook.label("default.hermes")! == ("default", "hermes"))
        #expect(PapertrailDoorBook.label("scout.something")! == ("scout", "program"))
        #expect(PapertrailDoorBook.label("scout")! == ("scout", "program"))
        for bad in ["", "unplaced.program", "Scout!.hermes", "-x.hermes", ".hermes", String(repeating: "a", count: 65) + ".hermes"] {
            #expect(PapertrailDoorBook.label(bad) == nil, "\(bad)")
        }
    }

    @Test func privateBotsAreJudgedLikeTheAddOn() {
        #expect(PapertrailDoorBook.isPrivate("moss", list: []))
        #expect(PapertrailDoorBook.isPrivate("private", list: []))
        #expect(PapertrailDoorBook.isPrivate("moss-2", list: []))
        #expect(PapertrailDoorBook.isPrivate("old_private", list: []))
        #expect(PapertrailDoorBook.isPrivate("scout", list: ["scout"]))
        #expect(!PapertrailDoorBook.isPrivate("scout", list: ["wren"]))
        #expect(!PapertrailDoorBook.isPrivate("mossy", list: []))
    }

    @Test func aConnectionIsOneWordlessLineInTheBotsOwnPapertrail() throws {
        let (home, cleanup) = try setup()
        defer { cleanup() }
        let book = PapertrailDoorBook(home: home)
        let at = Date(timeIntervalSince1970: 1_792_504_000.1234)
        let line = try #require(book.write(bot: "scout", kind: "terminal", host: "github.com", port: 443, at: at))
        #expect(line == .init(at: 1_792_504_000.123, route: "online", kind: "terminal", host: "github.com", port: 443))
        book.write(bot: "default", kind: "hermes", host: "192.168.1.9", port: 8080, at: at)
        let written = lines(home.appendingPathComponent("profiles/scout"))
        #expect(written.count == 1)
        #expect(Set(written[0].keys) == ["v", "at", "route", "source", "kind", "host", "port"])
        #expect(written[0]["source"] as? String == "door")
        #expect(lines(home).first?["route"] as? String == "network")
        let folder = home.appendingPathComponent("profiles/scout/nollie-workflow/papertrail")
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.path).first { $0.hasSuffix(".jsonl") })
        let fileMode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file).path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
    }

    @Test func nothingIsWrittenForPrivateBotsLoopbackOrBotsThatDoNotExist() throws {
        let (home, cleanup) = try setup()
        defer { cleanup() }
        let book = PapertrailDoorBook(home: home)
        #expect(book.write(bot: "moss", kind: "hermes", host: "api.example.com", port: 443, at: Date()) == nil)
        #expect(book.write(bot: "scout", kind: "hermes", host: "localhost", port: 11434, at: Date()) == nil)
        #expect(book.write(bot: "ghost", kind: "hermes", host: "api.example.com", port: 443, at: Date()) == nil)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("profiles/moss/nollie-workflow").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("profiles/ghost").path))

        // The saved list counts, reread when it changes; a damaged list writes nothing for anyone.
        let list = home.appendingPathComponent("nollie-private-bots.json")
        try Data(#"{"version": 1, "profiles": ["wren"]}"#.utf8).write(to: list)
        #expect(book.write(bot: "wren", kind: "hermes", host: "api.example.com", port: 443, at: Date()) == nil)
        #expect(book.write(bot: "scout", kind: "hermes", host: "api.example.com", port: 443, at: Date()) != nil)
        try Data("{".utf8).write(to: list)
        #expect(book.write(bot: "scout", kind: "hermes", host: "api.example.com", port: 443, at: Date()) == nil)
        #expect(lines(home.appendingPathComponent("profiles/wren")).isEmpty)
    }

    @Test func aLinkedFolderIsNeverWrittenThrough() throws {
        let (home, cleanup) = try setup()
        defer { cleanup() }
        let elsewhere = home.deletingLastPathComponent().appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("profiles/scout/nollie-workflow"),
                                                   withDestinationURL: elsewhere)
        let book = PapertrailDoorBook(home: home)
        #expect(book.write(bot: "scout", kind: "hermes", host: "api.example.com", port: 443, at: Date()) == nil)
        #expect((try FileManager.default.contentsOfDirectory(atPath: elsewhere.path)).isEmpty)
    }

    @Test func dayFilesOlderThanThirtyFiveDaysGo() throws {
        let (home, cleanup) = try setup()
        defer { cleanup() }
        let folder = home.appendingPathComponent("profiles/scout/nollie-workflow/papertrail")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let old = PapertrailDoorBook.day(now.addingTimeInterval(-40 * 86_400))
        let kept = PapertrailDoorBook.day(now.addingTimeInterval(-30 * 86_400))
        for day in [old, kept] { try Data("{}\n".utf8).write(to: folder.appendingPathComponent(day + ".jsonl")) }
        PapertrailDoorBook(home: home, clock: { now }).write(bot: "scout", kind: "hermes", host: "a.example", port: 443, at: now)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(!names.contains(old + ".jsonl"))
        #expect(names.contains(kept + ".jsonl"))
    }

    // MARK: The door

    private func basic(_ user: String, _ password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    @Test func credentialsAreReadFromBasicProxyAuthorization() throws {
        let parsed = try #require(PapertrailDoorRequest.basic(basic("scout.mcp", "s3cret:with:colons")))
        #expect(parsed.user == "scout.mcp" && parsed.password == "s3cret:with:colons")
        #expect(PapertrailDoorRequest.basic("Bearer abc") == nil)
        #expect(PapertrailDoorRequest.basic("Basic !!!") == nil)
        #expect(PapertrailDoorRequest.basic(nil) == nil)
        let head = Data("CONNECT a.example:443 HTTP/1.1\r\nProxy-Authorization: \(basic("a.b", "c"))\r\n\r\n".utf8)
        #expect(try PapertrailDoorRequest.authorization(head) == basic("a.b", "c"))
    }

    @Test func aConnectionWithTheSecretIsPassedOnAndNoted() async throws {
        let (home, cleanup) = try setup()
        defer { cleanup() }
        let book = PapertrailDoorBook(home: home)
        let door = PapertrailDoor(book: book, secret: String(repeating: "ab", count: 32))
        let port = Int(try await door.start())
        defer { door.stop() }
        let upstream = try await DoorEcho.start()
        defer { upstream.stop() }

        // Loopback is passed through and not noted: it never left this Mac.
        let tunnel = "CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\nProxy-Authorization: \(basic("scout.terminal", door.secret))\r\n\r\nhello"
        let answer = try await DoorClient.exchange(port, Data(tunnel.utf8), until: "HTTP/1.1 200 Connection established\r\n\r\nhello")
        #expect(answer == "HTTP/1.1 200 Connection established\r\n\r\nhello")
        #expect(upstream.connections == 1)

        // A place off this Mac is noted before it is tried, even when it can't be reached.
        let away = "CONNECT nowhere.invalid:443 HTTP/1.1\r\nProxy-Authorization: \(basic("scout.mcp", door.secret))\r\n\r\n"
        let refused = try await DoorClient.exchange(port, Data(away.utf8), timeout: 20)
        #expect(refused.hasPrefix("HTTP/1.1 502 "))
        book.flush()
        let written = lines(home.appendingPathComponent("profiles/scout"))
        #expect(written.count == 1)
        #expect(written.first?["host"] as? String == "nowhere.invalid")
        #expect(written.first?["kind"] as? String == "mcp")
        #expect(written.first?["port"] as? Int == 443)
    }

    @Test func withoutTheSecretNothingPasses() async throws {
        let (home, cleanup) = try setup()
        defer { cleanup() }
        let door = PapertrailDoor(book: PapertrailDoorBook(home: home))
        let port = Int(try await door.start())
        defer { door.stop() }
        let upstream = try await DoorEcho.start()
        defer { upstream.stop() }
        for authorization in ["", "Proxy-Authorization: \(basic("scout.hermes", "wrong"))\r\n",
                              "Proxy-Authorization: \(basic("scout.hermes", String(door.secret.dropLast())))\r\n"] {
            let request = "CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\n\(authorization)\r\n"
            let answer = try await DoorClient.exchange(port, Data(request.utf8))
            #expect(answer.hasPrefix("HTTP/1.1 407 "), "\(answer)")
            #expect(answer.contains("Proxy-Authenticate: Basic"))
        }
        #expect(upstream.connections == 0)
        #expect(door.counts.refusedSecret == 3)
    }

    @Test func plainHTTPLeavesWithoutTheCredentials() async throws {
        let (home, cleanup) = try setup()
        defer { cleanup() }
        let door = PapertrailDoor(book: PapertrailDoorBook(home: home))
        let port = Int(try await door.start())
        defer { door.stop() }
        let upstream = try await DoorEcho.start()
        defer { upstream.stop() }
        let request = "GET http://127.0.0.1:\(upstream.port)/x HTTP/1.1\r\nHost: a\r\nProxy-Authorization: \(basic("default.hermes", door.secret))\r\nUser-Agent: t\r\n\r\n"
        let answer = try await DoorClient.exchange(port, Data(request.utf8))
        #expect(answer.hasPrefix("HTTP/1.1 200 OK"))
        #expect(answer.contains("GET /x HTTP/1.1\r\nHost: 127.0.0.1:\(upstream.port)\r\nUser-Agent: t\r\nConnection: close\r\n\r\n"))
        #expect(!answer.contains("Proxy-Authorization") && !answer.contains(door.secret))
    }

    @Test func privateAndUnplacedConnectionsPassWithoutALine() async throws {
        let (home, cleanup) = try setup()
        defer { cleanup() }
        let book = PapertrailDoorBook(home: home)
        let door = PapertrailDoor(book: book)
        let port = Int(try await door.start())
        defer { door.stop() }
        for label in ["moss.hermes", "unplaced.program"] {
            let request = "CONNECT nowhere.invalid:443 HTTP/1.1\r\nProxy-Authorization: \(basic(label, door.secret))\r\n\r\n"
            let answer = try await DoorClient.exchange(port, Data(request.utf8), timeout: 20)
            #expect(answer.hasPrefix("HTTP/1.1 502 "), "\(label)")
        }
        book.flush()
        #expect(lines(home.appendingPathComponent("profiles/moss")).isEmpty)
        #expect(lines(home).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("profiles/moss/nollie-workflow").path))
    }

    @Test func malformedRequestsAreAnsweredAndClosed() async throws {
        let door = PapertrailDoor(book: nil)
        let port = Int(try await door.start())
        defer { door.stop() }
        let answer = try await DoorClient.exchange(port, Data("NONSENSE\r\n\r\n".utf8))
        #expect(answer.hasPrefix("HTTP/1.1 400 "))
        #expect(door.counts.malformed == 1)
    }
}

private final class DoorBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

/// Answers a plain HTTP request with what it received; echoes anything else.
private final class DoorEcho: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "nollie.tests.door-echo")
    private let count = DoorBox(0)
    private(set) var port = 0
    var connections: Int { count.withLock { $0 } }

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> DoorEcho {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let echo = DoorEcho(listener: try NWListener(using: parameters))
        echo.listener.newConnectionHandler = { [weak echo] connection in echo?.serve(connection) }
        echo.port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let once = DoorBox(Optional(continuation))
            echo.listener.stateUpdateHandler = { [weak echo] state in
                switch state {
                case .ready: once.withLock { $0?.resume(returning: Int(echo?.listener.port?.rawValue ?? 0)); $0 = nil }
                case .failed(let error): once.withLock { $0?.resume(throwing: error); $0 = nil }
                default: break
                }
            }
            echo.listener.start(queue: echo.queue)
        }
        return echo
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        count.withLock { $0 += 1 }
        connection.start(queue: queue)
        read(connection)
    }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let text = String(decoding: data, as: UTF8.self)
                if text.hasPrefix("GET ") {
                    let reply = "HTTP/1.1 200 OK\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n" + text
                    connection.send(content: Data(reply.utf8), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
            if complete || error != nil { connection.cancel() } else { self.read(connection) }
        }
    }
}

/// A plain TCP client standing in for a program Hermes started.
private enum DoorClient {
    static func exchange(_ port: Int, _ data: Data, until: String? = nil, timeout: TimeInterval = 5) async throws -> String {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let queue = DispatchQueue(label: "nollie.tests.door-client")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = DoorBox(Optional(continuation))
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.withLock { $0?.resume(); $0 = nil }
                case .failed(let error), .waiting(let error): once.withLock { $0?.resume(throwing: error); $0 = nil }
                default: break
                }
            }
            connection.start(queue: queue)
        }
        defer { connection.cancel() }
        connection.send(content: data, completion: .contentProcessed { _ in })
        let wanted = until.map { Data($0.utf8) }
        let bytes = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            let state = DoorBox((Optional(continuation), Data()))
            @Sendable func finish() { state.withLock { $0.0?.resume(returning: $0.1); $0.0 = nil } }
            @Sendable func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                    let done = state.withLock { value -> Bool in
                        if let data { value.1.append(data) }
                        if let wanted, value.1 == wanted { return true }
                        return complete || error != nil
                    }
                    if done { finish() } else { read() }
                }
            }
            read()
            queue.asyncAfter(deadline: .now() + timeout) { finish() }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
#endif
