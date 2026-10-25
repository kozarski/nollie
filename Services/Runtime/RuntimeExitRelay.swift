#if os(macOS)
import Darwin
import Foundation

/// Turns the exit relay on and off by itself. It is on whenever a VM is running on Apple's VM
/// network, with or without an exit node, so a computer already has its settings when an exit
/// node is turned on mid-task; it stops when no VM runs. Its state goes to the app (Away from
/// home) and, through `RuntimeService/exit-relay.json`, to the computer add-on, which shows the
/// exit node card only when an exit node is on and the relay is off or failing. Nothing asks the
/// person.
actor RuntimeExitRelay {
    typealias Networks = @Sendable () async -> ExitRelayPolicy.Network?
    typealias Make = @Sendable (ExitRelayPolicy.Network) -> ExitRelay

    static let stateFile = NollieExitRelayRecord.fileName
    /// Often enough that the relay is up before a computer's desktop session starts. Each look
    /// reads this Mac's interfaces, and runs `ifconfig` only while a bridge exists.
    static let interval: Duration = .seconds(5)

    private let directory: URL?
    private let networks: Networks
    private let make: Make
    private var relay: ExitRelay?
    private var loop: Task<Void, Never>?
    private(set) var state: NollieExitRelayState = .off
    private var written: NollieExitRelayState?

    init(directory: URL?, networks: @escaping Networks = { await ExitRelayNetworks.current() },
         make: @escaping Make = { ExitRelay(configuration: .init(network: $0)) }) {
        self.directory = directory
        self.networks = networks
        self.make = make
    }

    /// Checks now and then every 5 seconds, until `close`.
    func run() {
        guard loop == nil else { return }
        write(.off)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Stops for good (Nollie is being removed or is gone).
    func close() {
        loop?.cancel()
        loop = nil
        relay?.stop()
        relay = nil
        state = .off
        write(.off)
    }

    /// One look: is a VM running on Apple's VM network?
    @discardableResult
    func check() async -> NollieExitRelayState {
        guard let network = await networks() else {
            stopRelay()
            return settle(.idle)
        }
        if let relay, relay.configuration.network != network { stopRelay() }
        if relay == nil {
            let made = make(network)
            do {
                try await made.start()
                relay = made
            } catch {
                made.stop()
                return settle(.failed)
            }
        }
        return settle(relay?.cannotConnect == true ? .failed : .on)
    }

    private func stopRelay() {
        relay?.stop()
        relay = nil
    }

    private func settle(_ new: NollieExitRelayState) -> NollieExitRelayState {
        state = new
        if written != new { write(new) }
        return new
    }

    /// `{"version": 1, "state": "on", "port": 47610}`: no address, host or count. Written whole
    /// and moved into place, private to this account.
    private func write(_ state: NollieExitRelayState) {
        guard let directory else { return }
        let record = NollieExitRelayRecord(state: state, port: Int(ExitRelayPolicy.port))
        guard let data = try? JSONEncoder().encode(record),
              (try? OwnedSetupFiles.createPrivateDirectory(directory)) != nil,
              let fd = try? OwnedSetupFiles.directory(directory) else { return }
        defer { Darwin.close(fd) }
        let temporary = ".\(Self.stateFile).\(UUID().uuidString)"
        guard (try? OwnedSetupFiles.writeNew(data, to: directory.appendingPathComponent(temporary))) != nil else { return }
        if renameat(fd, temporary, fd, Self.stateFile) == 0 {
            written = state
        } else {
            unlinkat(fd, temporary, 0)
        }
    }
}

/// Finds Apple's VM network on this Mac.
enum ExitRelayNetworks {
    static func current() async -> ExitRelayPolicy.Network? {
        let addresses = bridgeAddresses()
        guard !addresses.isEmpty else { return nil }
        var members: [String: [String]] = [:]
        for name in Set(addresses.map(\.interface)) where ExitRelayPolicy.isBridgeName(name) {
            guard let output = await TailscaleDetector.runTool(URL(fileURLWithPath: "/sbin/ifconfig"), [name]) else { continue }
            members[name] = ExitRelayPolicy.bridgeMembers(String(decoding: output, as: UTF8.self))
        }
        return ExitRelayPolicy.vmNetwork(addresses, members: members)
    }

    /// IPv4 addresses and masks of bridge interfaces that are up.
    static func bridgeAddresses() -> [ExitRelayPolicy.InterfaceAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [ExitRelayPolicy.InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            let name = String(cString: entry.pointee.ifa_name)
            guard flags & IFF_UP != 0, ExitRelayPolicy.isBridgeName(name),
                  let address = entry.pointee.ifa_addr, let mask = entry.pointee.ifa_netmask,
                  Int32(address.pointee.sa_family) == AF_INET else { continue }
            func bytes(_ pointer: UnsafeMutablePointer<sockaddr>) -> [UInt8] {
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inner in
                    withUnsafeBytes(of: inner.pointee.sin_addr) { Array($0) }
                }
            }
            result.append(.init(interface: name, address: bytes(address), mask: bytes(mask)))
        }
        return result
    }
}
#endif
