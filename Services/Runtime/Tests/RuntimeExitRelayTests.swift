#if os(macOS)
import Foundation
import Testing

/// What turns the exit relay on and off, and what it tells the computer add-on and the app.
struct RuntimeExitRelayTests {
    private final class Switches: @unchecked Sendable {
        private let lock = NSLock()
        private var _network: ExitRelayPolicy.Network?
        var network: ExitRelayPolicy.Network? {
            get { lock.withLock { _network } }
            set { lock.withLock { _network = newValue } }
        }
    }

    private let loopback = ExitRelayPolicy.Network(interface: "lo0", address: [127, 0, 0, 1], mask: [255, 0, 0, 0])

    private func folder() throws -> URL {
        let path = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path)).appendingPathComponent("exit-relay-\(UUID().uuidString)/RuntimeService")
    }

    private func record(_ folder: URL) throws -> NollieExitRelayRecord {
        try JSONDecoder().decode(NollieExitRelayRecord.self, from: Data(contentsOf: folder.appendingPathComponent(RuntimeExitRelay.stateFile)))
    }

    private func controller(_ switches: Switches, folder: URL?) -> RuntimeExitRelay {
        RuntimeExitRelay(directory: folder, networks: { switches.network },
                         make: { ExitRelay(configuration: .init(network: $0, port: 0)) })
    }

    @Test func itRunsWheneverAComputerRunsWithOrWithoutAnExitNode() async throws {
        let switches = Switches()
        let folder = try folder()
        let relay = controller(switches, folder: folder)

        // No computer running: nothing to carry, nothing listening.
        #expect(await relay.check() == .idle)
        #expect(try record(folder).state == .idle)

        // A computer starts: the relay listens straight away. It never asks about an exit node, so
        // one turned on mid-task finds the computer already using the relay.
        switches.network = loopback
        #expect(await relay.check() == .on)
        let saved = try record(folder)
        #expect(saved == NollieExitRelayRecord(state: .on, port: Int(ExitRelayPolicy.port)))
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(RuntimeExitRelay.stateFile).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // Only the state and port: never an address, a host or a count.
        let text = try String(contentsOf: folder.appendingPathComponent(RuntimeExitRelay.stateFile), encoding: .utf8)
        #expect(!text.contains("127.0.0.1") && !text.contains("lo0"))
        // Still on at the next look, the same listener.
        #expect(await relay.check() == .on)

        // The last computer stops: so does the relay.
        switches.network = nil
        #expect(await relay.check() == .idle)
        #expect(try record(folder).state == .idle)
        switches.network = loopback
        #expect(await relay.check() == .on)
        await relay.close()
        #expect(try record(folder).state == .off)
    }

    @Test func anAddressItCannotUseMeansFailed() async throws {
        let switches = Switches()
        switches.network = ExitRelayPolicy.Network(interface: "bridge100", address: [192, 0, 2, 1], mask: [255, 255, 255, 0])
        let folder = try folder()
        let relay = controller(switches, folder: folder)
        #expect(await relay.check() == .failed)
        #expect(try record(folder).state == .failed)
        // The VM network moves to an address it can use: it starts there.
        switches.network = loopback
        #expect(await relay.check() == .on)
        await relay.close()
    }

    /// The relay runs without an exit node too; the card only ever shows with one.
    @Test func theCardShowsOnlyWhenTheRelayDoesNotCarryTheTraffic() {
        #expect(!NollieExitRelayState.showsExitNodeCard(exitNode: false, relay: "failed"))
        #expect(!NollieExitRelayState.showsExitNodeCard(exitNode: true, relay: "on"))
        #expect(!NollieExitRelayState.showsExitNodeCard(exitNode: true, relay: "idle"))
        #expect(NollieExitRelayState.showsExitNodeCard(exitNode: true, relay: "failed"))
        #expect(NollieExitRelayState.showsExitNodeCard(exitNode: true, relay: "off"))
        #expect(NollieExitRelayState.showsExitNodeCard(exitNode: true, relay: nil))
        #expect(NollieExitRelayState.showsExitNodeCard(exitNode: true, relay: "something new"))
    }
}
#endif
