import Foundation
import Testing
@testable import NollieCore

struct ConnectionReadinessTests {
    private static let ready = #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{}}}"#

    @Test func waitsPastUnrelatedFramesForReady() async throws {
        let fixture = ReadinessFrames([
            "not a gateway frame",
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"sessions.changed","payload":{}}}"#,
            #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
            Self.ready,
        ])
        let cancellations = ReadinessCancellation()
        let result = try await ConnectionTester.awaitGatewayReady(timeout: 1, receive: { try await fixture.receive() }, cancel: cancellations.cancel)
        #expect(result == "gateway.ready received")
        #expect(await fixture.received == 4)
        #expect(cancellations.count == 1)
    }

    @Test func gatewayErrorBeforeReadyFailsWithoutEchoingPayload() async {
        let fixture = ReadinessFrames([
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.error","payload":{"message":"private diagnostic fixture"}}}"#,
            Self.ready,
        ])
        do {
            _ = try await ConnectionTester.awaitGatewayReady(timeout: 1, receive: { try await fixture.receive() }, cancel: {})
            Issue.record("A gateway error was accepted as readiness.")
        } catch {
            #expect(error.localizedDescription.contains("before it was ready"))
            #expect(!error.localizedDescription.contains("private diagnostic fixture"))
        }
        #expect(await fixture.received == 1)
    }

    @Test func rpcErrorBeforeReadyFails() async {
        let fixture = ReadinessFrames([#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Startup failed"}}"#, Self.ready])
        await #expect(throws: RPCError.self) {
            _ = try await ConnectionTester.awaitGatewayReady(timeout: 1, receive: { try await fixture.receive() }, cancel: {})
        }
        #expect(await fixture.received == 1)
    }

    @Test func unrelatedFrameThenSilenceTimesOutAndCloses() async {
        let fixture = ReadinessFrames([#"{"method":"event","params":{"type":"heartbeat","payload":{}}}"#])
        let cancellations = ReadinessCancellation()
        do {
            _ = try await ConnectionTester.awaitGatewayReady(timeout: 0.02, receive: { try await fixture.receive() }, cancel: cancellations.cancel)
            Issue.record("A socket without gateway.ready passed.")
        } catch SocketError.timeout(let stage) {
            #expect(stage == "gateway.ready")
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(cancellations.count == 1)
    }

    @Test func socketCloseBeforeReadyRemainsFailure() async {
        do {
            _ = try await ConnectionTester.awaitGatewayReady(timeout: 1, receive: {
                throw SocketError.closed(code: 4401, reason: "credential rejected")
            }, cancel: {})
            Issue.record("A closed socket passed.")
        } catch SocketError.closed(let code, let reason) {
            #expect(code == 4401)
            #expect(reason == "credential rejected")
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func frameFloodCannotKeepProbeOpen() async {
        let fixture = ReadinessFrames(Array(repeating: "{}", count: 128) + [Self.ready])
        await #expect(throws: HermesAPIError.self) {
            _ = try await ConnectionTester.awaitGatewayReady(timeout: 1, receive: { try await fixture.receive() }, cancel: {})
        }
        #expect(await fixture.received == 128)
    }
}

private actor ReadinessFrames {
    private var frames: [String]
    private(set) var received = 0
    init(_ frames: [String]) { self.frames = frames }
    func receive() async throws -> String {
        guard !frames.isEmpty else {
            try await Task.sleep(for: .seconds(60))
            throw SocketError.notConnected
        }
        received += 1
        return frames.removeFirst()
    }
}

private final class ReadinessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func cancel() { lock.withLock { value += 1 } }
}
