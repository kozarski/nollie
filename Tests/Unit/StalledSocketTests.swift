import Foundation
import Network
import Testing
@testable import NollieCore

/// A gateway socket that goes silent without ever closing, which is how the socket of a suspended
/// app looks once the phone's radio dropped it. The timeouts have to fire; otherwise the heartbeat
/// never counts the connection as lost, so every resume and send hangs forever (testers who returned
/// to a long turn saw the app frozen, 1.4 builds 7 and 8).
///
/// These talk to a WebSocket listener of their own on the loopback. It finishes the handshake,
/// says whatever it was told to say, and after that stays silent.
@Suite struct StalledSocketTests {
    /// Accepts WebSocket connections, greets each one with `greeting` if there is one, and never replies.
    final class QuietListener: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "nollie.tests.quiet-listener")
        private var open: [NWConnection] = []
        private(set) var port: UInt16 = 0

        init(greeting: String?, fixedPort: UInt16? = nil) throws {
            let parameters = NWParameters.tcp
            let websocket = NWProtocolWebSocket.Options()
            websocket.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
            let wanted = fixedPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
            let made = try NWListener(using: parameters, on: wanted)
            listener = made

            let started = DispatchSemaphore(value: 0)
            made.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed: started.signal()
                default: break
                }
            }
            made.newConnectionHandler = { [queue] connection in
                queue.async { self.open.append(connection) }
                connection.stateUpdateHandler = { state in
                    guard case .ready = state, let greeting else { return }
                    let frame = NWProtocolWebSocket.Metadata(opcode: .text)
                    let context = NWConnection.ContentContext(identifier: "hello", metadata: [frame])
                    connection.send(content: Data(greeting.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
                }
                // Discard whatever the client writes; this keeps the stream moving.
                func swallow() { connection.receiveMessage { _, _, _, error in if error == nil { swallow() } } }
                connection.start(queue: queue)
                swallow()
            }
            made.start(queue: queue)
            _ = started.wait(timeout: .now() + 5)
            port = made.port?.rawValue ?? 0
        }

        func shutDown() {
            listener.cancel()
            queue.sync { open.forEach { $0.cancel() } }
        }
    }

    /// The gateway's own hello, so the socket counts itself ready.
    static let hello = #"{"method":"event","jsonrpc":"2.0","params":{"payload":{},"session_id":"","type":"gateway.ready"}}"#

    /// A socket pointed at the loopback listener, with no one listening for what it says.
    static func socket(on port: UInt16) -> GatewaySocket {
        let address = URL(string: "ws://127.0.0.1:\(port)/api/ws")!
        return GatewaySocket(urlProvider: { (address, [:]) }, onEvent: { _ in }, onState: { _ in },
                             onServerRequest: { _ in nil }, onReconnected: {})
    }

    private func readySocket(_ listener: QuietListener) async throws -> GatewaySocket {
        let socket = Self.socket(on: listener.port)
        await socket.connect()
        try await socket.waitUntilReady(timeout: 10)
        return socket
    }

    @Test func aCallToASilentSocketTimesOut() async throws {
        let listener = try QuietListener(greeting: Self.hello)
        defer { listener.shutDown() }
        #expect(listener.port != 0)
        let socket = try await readySocket(listener)
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: SocketError.self) { _ = try await socket.call("ping", params: [:], timeout: 1) }
        #expect(start.duration(to: clock.now) < .seconds(5))
        await socket.disconnect()
    }

    @Test func waitingForAHelloThatNeverComesTimesOut() async throws {
        let listener = try QuietListener(greeting: nil)
        defer { listener.shutDown() }
        let socket = Self.socket(on: listener.port)
        await socket.connect()
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: SocketError.self) { try await socket.waitUntilReady(timeout: 1) }
        #expect(start.duration(to: clock.now) < .seconds(5))
        await socket.disconnect()
    }

    @Test func returningToASilentSocketTearsItDown() async throws {
        let listener = try QuietListener(greeting: Self.hello)
        defer { listener.shutDown() }
        let socket = try await readySocket(listener)
        #expect(await socket.state == .open)
        let clock = ContinuousClock()
        let start = clock.now
        await socket.checkAlive(timeout: 1)
        #expect(await socket.state != .open, "the socket stayed open although no ping was answered")
        #expect(start.duration(to: clock.now) < .seconds(5))
        await socket.disconnect()
    }

    @Test func cancellingACallEndsItAtOnce() async throws {
        let listener = try QuietListener(greeting: Self.hello)
        defer { listener.shutDown() }
        let socket = try await readySocket(listener)
        let clock = ContinuousClock()
        let start = clock.now
        let pending = Task { try await socket.call("session.resume", params: [:], timeout: 120) }
        try await Task.sleep(nanoseconds: 200_000_000)
        pending.cancel()
        await #expect(throws: Error.self) { _ = try await pending.value }
        #expect(start.duration(to: clock.now) < .seconds(5))
        await socket.disconnect()
    }
}

/// Opening a connection while the route is still being set up: the socket retries swiftly and
/// quietly, and ends up connected one or two seconds after the gateway can be reached.
@Suite struct EarlyRetryTests {
    @Test func retriesStartQuickAndThenBackOff() {
        let delays = [1: 1.0, 2: 1, 3: 1, 4: 2, 5: 4, 8: 30, 40: 30]
        for (attempt, delay) in delays { #expect(GatewaySocket.retryDelay(attempt: attempt) == delay, "attempt \(attempt)") }
    }

    @Test func aGatewayThatTurnsUpSecondsLaterIsReachedQuickly() async throws {
        // Pick a free port by taking one and releasing it.
        let scout = try StalledSocketTests.QuietListener(greeting: nil)
        let port = scout.port
        scout.shutDown()
        try await Task.sleep(for: .milliseconds(300))

        let socket = StalledSocketTests.socket(on: port)
        let clock = ContinuousClock()
        let launched = clock.now
        await socket.connect()
        // For 2.5 seconds the gateway refuses connections, after which it starts to listen.
        try await Task.sleep(for: .milliseconds(2500))
        let listener = try StalledSocketTests.QuietListener(greeting: StalledSocketTests.hello, fixedPort: port)
        defer { listener.shutDown() }

        let appeared = clock.now
        var connected = false
        while appeared.duration(to: clock.now) < .seconds(6) {
            if await socket.state == .open { connected = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let waited = appeared.duration(to: clock.now)
        #expect(connected, "still not connected \(launched.duration(to: clock.now)) after launch")
        #expect(waited < .seconds(3), "took \(waited) once the gateway was up")
        await socket.disconnect()
    }
}
