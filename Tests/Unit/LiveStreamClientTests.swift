import Foundation
import Network
import Synchronization
import Testing
@testable import NollieCore

/// The live picture's network client against a small WebSocket server on loopback: what it asks
/// for, what it hands on and in what order, and how each kind of ending is told apart.
@Suite(.timeLimit(.minutes(1)))
struct LiveStreamClientTests {
    private static let video = LiveWire.Video(keyframe: true, sequence: 7, captureMicros: 1_000_000, width: 64, height: 48,
                                              parameterSets: [Data([0x40, 0x01]), Data([0x42, 0x01]), Data([0x44, 0x01])],
                                              sample: Data([0, 0, 0, 2, 0x26, 0x01]))
    private static let hello = LiveWire.ServerMessage.hello(.init(kind: .space, computer: "Studio desktop",
                                                                  source: .init(width: 1280, height: 800)))
    private static let beat = LiveWire.ServerMessage.beat(.init(micros: 5_000_000, fresh: true, link: .fine, level: 1, control: .helper))
    private static let pointer = LiveWire.ServerMessage.pointer(.init(x: 211, y: 284, at: 1.5))

    private func client(_ port: Int, token: String = "live-test-token", readDelay: TimeInterval = 0) throws -> LiveStreamClient {
        let gateway = try GatewayURL.normalize("http://127.0.0.1:\(port)/hermes")
        // No test here is about the hello deadline, so it is far off: five seconds was reached by a busy device while
        // the hello was still on its way, and the feed closed as unavailable.
        return LiveStreamClient(target: .init(gateway: gateway, profile: "work", sessionID: "live-session", token: token),
                                helloTimeout: 60, readDelay: readDelay)
    }

    /// Everything the feed says, as short words, up to and including its close.
    private func words(_ feed: LiveStreamClient, until: ((String) -> Void)? = nil) async -> [String] {
        var said: [String] = []
        for await event in feed.events {
            let word: String
            switch event {
            case .message(.hello(let hello)): word = "hello \(hello.computer) \(hello.source.width)x\(hello.source.height)"
            case .message(.beat(let beat)): word = "beat \(beat.micros)"
            case .message(.pointer(let spot)): word = "pointer \(spot.map { "\($0.x),\($0.y)" } ?? "none")"
            case .message(.source(let size)): word = "source \(size.width)x\(size.height)"
            case .message(.end(let reason)): word = "end \(reason.rawValue)"
            case .video(let video, _): word = "video \(video.sequence)\(video == Self.video ? "" : " changed")"
            case .closed(.ended(let reason)): word = "closed ended \(reason.rawValue)"
            case .closed(let close): word = "closed \(close)"
            }
            said.append(word)
            until?(word)
        }
        return said
    }

    @Test func askingCarriesTheChatAndTheTokenOnlyInAHeader() async throws {
        let server = try await PlainHTTPServer.start()
        defer { server.stop() }
        let said = await words(try client(server.port))
        // Not a socket: the picture isn't there, and the app keeps its snapshots.
        #expect(said == ["closed unavailable"])
        let head = try #require(server.heads.first)
        let lines = head.split(separator: "\r\n").map(String.init)
        #expect(lines.first == "GET /hermes/nollie/live?profile=work&session_id=live-session HTTP/1.1")
        #expect(lines.contains { $0.lowercased() == "x-hermes-session-token: live-test-token" })
        #expect(lines.contains { $0.lowercased() == "upgrade: websocket" })
        #expect(!head.contains("token="), "The credential never travels in the address")
        #expect(!head.lowercased().contains("sec-websocket-extensions"))
    }

    @Test func eventsArriveInTheOrderTheyWereSent() async throws {
        let server = try await LiveSocketServer.start { socket in
            socket.text(Self.hello)
            socket.text(Self.beat)
            socket.text(Self.pointer)
            socket.binary(LiveWire.encode(Self.video))
            socket.text(#"{"type":"news","what":"a newer host says more"}"#)
            socket.text(.source(.init(width: 640, height: 400)))
            socket.text(.pointer(nil))
            socket.text(.end(.stopped))
            socket.closeSoon()
        }
        defer { server.stop() }
        let said = await words(try client(server.port))
        #expect(said == ["hello Studio desktop 1280x800", "beat 5000000", "pointer 211,284", "video 7", "source 640x400",
                         "pointer none", "end stopped", "closed ended stopped"])
        #expect(server.headers.contains { $0.name.lowercased() == "x-hermes-session-token" && $0.value == "live-test-token" })
    }

    @Test func aHostThatCantStreamSaysWhyBeforeHello() async throws {
        let server = try await LiveSocketServer.start { socket in
            socket.text(.end(.unavailable))
            socket.close()
        }
        defer { server.stop() }
        #expect(await words(try client(server.port)) == ["end unavailable", "closed ended unavailable"])
    }

    @Test func anEndRightBeforeTheCloseIsNeverLost() async throws {
        let server = try await LiveSocketServer.start { socket in
            socket.text(Self.hello)
            socket.text(.end(.stopped))
            socket.close()
        }
        defer { server.stop() }
        // The end and the connection's own ending arrive together: the reason must win every time, even when the
        // device is too busy to hand back the last read at once (run it under load to see that).
        for _ in 0..<40 {
            let said = await words(try client(server.port))
            #expect(said == ["hello Studio desktop 1280x800", "end stopped", "closed ended stopped"])
        }
    }

    /// A device too busy to get to each read for a second and a half still hears why the stream ended. It used to
    /// close the feed one second after the connection went, read or no read, and a busy phone said "dropped".
    @Test func aBusyDeviceStillHearsTheEnd() async throws {
        let server = try await LiveSocketServer.start { socket in
            socket.text(Self.hello)
            socket.text(.end(.stopped))
            socket.close()
        }
        defer { server.stop() }
        for _ in 0..<4 {
            let said = await words(try client(server.port, readDelay: 1.5))
            #expect(said == ["hello Studio desktop 1280x800", "end stopped", "closed ended stopped"])
        }
    }

    @Test func aReaderThatFallsBehindGetsTheNewestPictureNotABacklog() async throws {
        @Sendable func frame(_ sequence: UInt32, key: Bool = false) -> Data {
            var video = Self.video
            video.sequence = sequence
            if !key {
                video.keyframe = false
                video.parameterSets = nil
            }
            return LiveWire.encode(video)
        }
        let server = try await LiveSocketServer.start { socket in
            socket.text(Self.hello)
            socket.binary(frame(0, key: true))
            for sequence in 1...9 { socket.binary(frame(UInt32(sequence))) }
            socket.queue.asyncAfter(deadline: .now() + 0.6) {
                socket.binary(frame(10, key: true))
                socket.binary(frame(11))
            }
        }
        defer { server.stop() }
        let feed = try client(server.port)
        // Busy for a while before reading anything.
        try await Task.sleep(for: .milliseconds(300))
        let said = await words(feed) { word in
            guard word.hasPrefix("video 11") else { return }
            feed.send(.report(.init(beat: 0, got: 4, shown: 4, late: 0, limit: .none)))
            feed.queueCancel(after: 0.2)
        }
        let frames = said.filter { $0.hasPrefix("video") }.map { $0.split(separator: " ")[1] }
        #expect(frames == ["0", "1", "10", "11"], "Two frames wait; the rest drop until the next keyframe")
        let texts = await server.waitForTexts(2).compactMap { try? LiveWire.ViewerMessage.decode($0) }
        #expect(texts.first == .keyframe, "Dropping asks for a keyframe, once")
        #expect(texts.dropFirst().first == .report(.init(beat: 0, got: 12, shown: 4, late: 8, limit: .none)),
                "Frames dropped here are reported late")
    }

    @Test func refusedUpgradeIsUnavailable() async throws {
        let server = try await LiveSocketServer.start(refuse: true) { _ in }
        defer { server.stop() }
        #expect(await words(try client(server.port)) == ["closed unavailable"])
    }

    @Test func nothingListeningIsUnavailable() async throws {
        let server = try await PlainHTTPServer.start()
        let port = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await words(try client(port)) == ["closed unavailable"])
    }

    @Test func aServerLostAfterHelloIsDropped() async throws {
        let server = try await LiveSocketServer.start { socket in
            socket.text(Self.hello)
            socket.text(Self.beat)
            socket.queue.asyncAfter(deadline: .now() + 0.2) { socket.drop() }
        }
        defer { server.stop() }
        #expect(await words(try client(server.port)) == ["hello Studio desktop 1280x800", "beat 5000000", "closed dropped"])
    }

    @Test func videoBeforeHelloIsIgnoredAndBadVideoAsksForAKeyframe() async throws {
        let server = try await LiveSocketServer.start { socket in
            socket.binary(LiveWire.encode(Self.video))
            socket.text(Self.hello)
            var unknownCodec = LiveWire.encode(Self.video)
            unknownCodec[3] = 9
            socket.binary(unknownCodec)
            socket.binary(LiveWire.encode(Self.video))
        }
        defer { server.stop() }
        let feed = try client(server.port)
        let said = await words(feed) { word in if word.hasPrefix("video") { feed.cancel() } }
        #expect(said == ["hello Studio desktop 1280x800", "video 7", "closed cancelled"])
        #expect(await server.waitForTexts(1) == [#"{"type":"keyframe"}"#])
    }

    @Test func viewerMessagesTravelAsText() async throws {
        let server = try await LiveSocketServer.start { socket in socket.text(Self.hello) }
        defer { server.stop() }
        let feed = try client(server.port)
        let report = LiveWire.ViewerMessage.report(.init(beat: 5_000_000, got: 12, shown: 11, late: 1, limit: .low))
        let reader = Task {
            await words(feed) { word in
                guard word.hasPrefix("hello") else { return }
                feed.send(.keyframe)
                feed.send(report)
            }
        }
        let texts = await server.waitForTexts(2)
        #expect(texts.compactMap { try? LiveWire.ViewerMessage.decode($0) } == [.keyframe, report])
        #expect(server.binaryCount == 0)
        feed.cancel()
        #expect(await reader.value == ["hello Studio desktop 1280x800", "closed cancelled"])
    }

    @Test func cancellingClosesTheServerSide() async throws {
        let server = try await LiveSocketServer.start { socket in socket.text(Self.hello) }
        defer { server.stop() }
        let feed = try client(server.port)
        let said = await words(feed) { word in if word.hasPrefix("hello") { feed.cancel() } }
        #expect(said == ["hello Studio desktop 1280x800", "closed cancelled"])
        #expect(await server.waitUntilClosed())
        feed.send(.keyframe)
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.texts.isEmpty, "Nothing is sent once the feed has closed")
    }

    @Test func cancellingTheReaderCancelsTheFeed() async throws {
        let server = try await LiveSocketServer.start { socket in socket.text(Self.hello) }
        defer { server.stop() }
        let feed = try client(server.port)
        let reader = Task { await words(feed) }
        try await Task.sleep(for: .milliseconds(300))
        reader.cancel()
        _ = await reader.value
        #expect(await server.waitUntilClosed())
    }

    @Test func withoutATargetItClosesAtOnce() async {
        #expect(await words(LiveStreamClient(target: nil)) == ["closed unavailable"])
        let https = LiveStreamClient.Target(url: URL(string: "https://example.invalid/nollie/live")!, token: "t")
        #expect(await words(LiveStreamClient(target: https)) == ["closed unavailable"], "Only socket addresses are opened")
        let tokenless = LiveStreamClient.Target(url: URL(string: "ws://127.0.0.1:1/nollie/live")!, token: "")
        #expect(await words(LiveStreamClient(target: tokenless)) == ["closed unavailable"])
    }

    #if os(macOS)
    /// Through this Mac's real Nollie Link door, over pinned TLS 1.3: the door's own socket
    /// answer works with the client, both ways, and a door with another key is never trusted.
    @Test func theDoorsStreamPlaysThroughThePinnedClient() async throws {
        let controls = DoorTestBox<[String]>([])
        let asked = DoorTestBox(0)
        let fixture = try await DoorFixture.start {
            $0.liveProvider = { _, sink in
                asked.withLock { $0 += 1 }
                sink.send(Data(Self.hello.encode().utf8), isText: true, isKeyframe: false)
                sink.send(LiveWire.encode(Self.video), isText: false, isKeyframe: true)
                return LinkDoorLiveFeed(control: { data in controls.withLock { $0.append(String(decoding: data, as: UTF8.self)) } },
                                        close: {})
            }
        }
        defer { fixture.stop() }
        let door = fixture.door
        let linked = try door.devices.claim(secret: door.devices.makeOffer().secret, name: "Phone")
        try await door.refresh()
        let port = Int(try #require(door.port))
        func target(pin: Data) throws -> LiveStreamClient.Target {
            .init(gateway: try GatewayURL.normalize("https://127.0.0.1:\(port)"), profile: "career", sessionID: "s1",
                  token: linked.credential, pin: pin)
        }

        let stranger = LiveStreamClient(target: try target(pin: Data(repeating: 7, count: 32)), helloTimeout: 5)
        #expect(await words(stranger) == ["closed unavailable"], "Another key is never trusted")
        #expect(asked.withLock { $0 } == 0)

        let feed = LiveStreamClient(target: try target(pin: door.identity.pin), helloTimeout: 5)
        let said = await words(feed) { word in
            guard word.hasPrefix("video") else { return }
            feed.send(.keyframe)
            feed.queueCancel(after: 0.3)
        }
        #expect(said == ["hello Studio desktop 1280x800", "video 7", "closed cancelled"])
        #expect(controls.withLock { $0 }.contains(#"{"type":"keyframe"}"#))
        #expect(await NollieLinkDoorTests.eventually { door.liveStreams(for: linked.device.id) == 0 })
        #expect(fixture.hermes.requests.isEmpty)
    }
    #endif

    @Test func linkedMacsArePinnedAndEverythingIsMarkedAsVideo() throws {
        let gateway = try GatewayURL.normalize("https://192.168.1.20:52000")
        let target = LiveStreamClient.Target(gateway: gateway, profile: "work", sessionID: "s", token: "t", pin: Data(repeating: 1, count: 32))
        #expect(target.url.absoluteString == "wss://192.168.1.20:52000/nollie/live?profile=work&session_id=s")
        let parameters = LiveStreamClient.parameters(for: target)
        #expect(parameters.serviceClass == .interactiveVideo)
        #expect(!parameters.includePeerToPeer)
        let stack = parameters.defaultProtocolStack
        #expect(stack.applicationProtocols.first is NWProtocolWebSocket.Options)
        #expect(stack.applicationProtocols.contains { $0 is NWProtocolTLS.Options })
        #expect((stack.transportProtocol as? NWProtocolTCP.Options)?.noDelay == true)
        let plain = LiveStreamClient.parameters(for: .init(gateway: try GatewayURL.normalize("http://127.0.0.1:9139"), profile: "p",
                                                           sessionID: "s", token: "t"))
        #expect(!plain.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options })
    }
}

/// A WebSocket server on loopback, written with Network's own WebSocket support. Each test
/// scripts what it says once the viewer connects.
final class LiveSocketServer: Sendable {
    final class Socket: Sendable {
        let connection: NWConnection
        let queue: DispatchQueue
        init(connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }

        func text(_ message: LiveWire.ServerMessage) { text(message.encode()) }
        func text(_ text: String) { send(Data(text.utf8), opcode: .text) }
        func binary(_ data: Data) { send(data, opcode: .binary) }
        /// A close frame straight after whatever came before, as the door sends one.
        func close() { send(nil, opcode: .close) }
        /// A close frame a moment later. Network's own WebSocket client can lose messages still
        /// waiting to be read when a close arrives right behind a long run of them, so a test of
        /// ordering gives them time to be read first.
        func closeSoon() { queue.asyncAfter(deadline: .now() + 0.1) { [self] in close() } }
        /// Gone without a word, as a server that crashed.
        func drop() { connection.forceCancel() }

        private func send(_ data: Data?, opcode: NWProtocolWebSocket.Opcode) {
            let context = NWConnection.ContentContext(identifier: "live", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    private let listener: NWListener
    let queue = DispatchQueue(label: "nollie.tests.live-socket")
    private let state = Mutex(Seen())
    let port: Int

    struct Seen {
        var headers: [(name: String, value: String)] = []
        var texts: [String] = []
        var binaries = 0
        var closed = false
    }

    var headers: [(name: String, value: String)] { state.withLock { $0.headers } }
    var texts: [String] { state.withLock { $0.texts } }
    var binaryCount: Int { state.withLock { $0.binaries } }

    private init(listener: NWListener, port: Int) { self.listener = listener; self.port = port }

    static func start(refuse: Bool = false, script: @escaping @Sendable (Socket) -> Void) async throws -> LiveSocketServer {
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        let seen = LiveTestBox<[(name: String, value: String)]>([])
        socket.setClientRequestHandler(DispatchQueue(label: "nollie.tests.live-socket.request")) { _, headers in
            seen.withLock { $0 = headers }
            return NWProtocolWebSocket.Response(status: refuse ? .reject : .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let found = LiveTestBox<LiveSocketServer?>(nil)
        let port = try await LivePorts.ready(listener, queue: DispatchQueue(label: "nollie.tests.live-socket.listener")) { connection in
            guard let server = found.withLock({ $0 }) else { connection.cancel(); return }
            connection.stateUpdateHandler = { [weak server] state in
                switch state {
                case .ready:
                    server?.state.withLock { $0.headers = seen.withLock { $0 } }
                    script(Socket(connection: connection, queue: server?.queue ?? .main))
                    server?.read(connection)
                case .failed, .cancelled: server?.state.withLock { $0.closed = true }
                default: break
                }
            }
            connection.start(queue: server.queue)
        }
        let server = LiveSocketServer(listener: listener, port: port)
        found.withLock { $0 = server }
        return server
    }

    func stop() { listener.cancel() }

    private func read(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            guard error == nil, let metadata, metadata.opcode != .close else {
                state.withLock { $0.closed = true }
                connection.cancel()
                return
            }
            state.withLock { seen in
                if metadata.opcode == .text { seen.texts.append(String(decoding: content ?? Data(), as: UTF8.self)) }
                if metadata.opcode == .binary { seen.binaries += 1 }
            }
            read(connection)
        }
    }

    func waitForTexts(_ count: Int) async -> [String] {
        for _ in 0..<200 where texts.count < count { try? await Task.sleep(for: .milliseconds(10)) }
        return texts
    }

    func waitUntilClosed() async -> Bool {
        for _ in 0..<200 where !state.withLock({ $0.closed }) { try? await Task.sleep(for: .milliseconds(10)) }
        return state.withLock { $0.closed }
    }
}

/// A plain HTTP server that writes down each request head and answers 404, like a gateway
/// with no live picture.
final class PlainHTTPServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "nollie.tests.plain-http")
    private let seen = Mutex<[String]>([])
    let port: Int
    var heads: [String] { seen.withLock { $0 } }

    private init(listener: NWListener, port: Int) { self.listener = listener; self.port = port }

    static func start() async throws -> PlainHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let found = LiveTestBox<PlainHTTPServer?>(nil)
        let port = try await LivePorts.ready(listener, queue: DispatchQueue(label: "nollie.tests.plain-http.listener")) { connection in
            guard let server = found.withLock({ $0 }) else { connection.cancel(); return }
            connection.start(queue: server.queue)
            server.read(connection, Data())
        }
        let server = PlainHTTPServer(listener: listener, port: port)
        found.withLock { $0 = server }
        return server
    }

    func stop() { listener.cancel() }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if error == nil && !complete { read(connection, buffer) } else { connection.cancel() }
                return
            }
            seen.withLock { $0.append(String(decoding: buffer[..<end.upperBound], as: UTF8.self)) }
            let reply = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// A lock around a value, for handlers that run on Network's queues.
final class LiveTestBox<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<T>(_ body: (inout Value) -> T) -> T { mutex.withLock { body(&$0) } }
}

extension LiveStreamClient {
    /// Cancels a little later, so what was just sent has time to go.
    func queueCancel(after seconds: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { self.cancel() }
    }
}

enum LivePorts {
    /// Starts a listener and waits for its port. Connections that arrive before the caller is
    /// ready are turned away by `accept`.
    static func ready(_ listener: NWListener, queue: DispatchQueue,
                      accept: @escaping @Sendable (NWConnection) -> Void) async throws -> Int {
        listener.newConnectionHandler = accept
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let once = LiveTestBox<CheckedContinuation<Int, Error>?>(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.withLock { $0?.resume(returning: Int(listener.port?.rawValue ?? 0)); $0 = nil }
                case .failed(let error): once.withLock { $0?.resume(throwing: error); $0 = nil }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
}
