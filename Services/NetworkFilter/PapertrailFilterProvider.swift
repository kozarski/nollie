#if os(macOS) && NOLLIE_NETWORK_FILTER
import Darwin
import Foundation
import Network
import NetworkExtension
import Security

/// Papertrail's network filter: a content filter system extension in the Direct edition. It sees each new
/// flow on the Mac and, while Nollie Runtime is subscribed with the switch on, reports every flow from
/// Hermes's process tree that did not go to loopback (so did not come through Papertrail's door), and drops
/// it when Refuse is on. Every other flow is allowed without a look at its bytes; none is ever read.
///
/// Built only with `NOLLIE_NETWORK_FILTER`, in a target that has the Network Extensions capability
/// (content filter, system extension). See Docs/specs/network-filter.md.
final class PapertrailFilterProvider: NEFilterDataProvider {
    private let reports = NetworkFilterReporter()

    override func startFilter(completionHandler: @escaping @Sendable (Error?) -> Void) {
        reports.listen()
        // Outbound flows only; the verdict narrows them to Hermes's tree.
        let outbound = NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0,
                                     protocol: .any, direction: .outbound)
        apply(NEFilterSettings(rules: [NEFilterRule(networkRule: outbound, action: .filterData)], defaultAction: .allow)) {
            completionHandler($0)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        reports.stop()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let state = reports.currentSwitch
        guard state.on, let socket = flow as? NEFilterSocketFlow, let token = flow.sourceAppAuditToken,
              token.count == MemoryLayout<audit_token_t>.size else { return .allow() }
        let pid = token.withUnsafeBytes { audit_token_to_pid($0.load(as: audit_token_t.self)) }
        let (host, port) = Self.remote(socket)
        let chain = ProcessTree.chain(from: pid)
        let verdict = NetworkFilterPolicy.verdict(chain: chain, remoteIsLoopback: NetworkFilterPolicy.isLoopback(host), switch: state)
        guard verdict != .allow else { return .allow() }
        reports.send(.init(at: Date().timeIntervalSince1970, pid: pid, program: ProcessTree.program(pid), host: host,
                           port: port, transport: socket.socketProtocol == IPPROTO_UDP ? "udp" : "tcp",
                           bot: ProcessTree.bot(chain: chain), refused: verdict == .refuse))
        return verdict == .refuse ? .drop() : .allow()
    }

    private static func remote(_ flow: NEFilterSocketFlow) -> (String, Int) {
        var port = 0
        var address = ""
        if case .hostPort(let host, let p)? = flow.remoteFlowEndpoint {
            port = Int(p.rawValue)
            switch host {
            case .name(let name, _): address = name
            case .ipv4(let v4): address = "\(v4)"
            case .ipv6(let v6): address = "\(v6)"
            @unknown default: address = ""
            }
        }
        // The name the program asked for, when the system knows it, says more than the address.
        if let name = flow.remoteHostname, !name.isEmpty, ExitRelayTarget.name(Substring(name)) != nil { address = name }
        return (address, port)
    }
}

/// Parents, signatures and labels, read from the kernel. Never a file of the process.
enum ProcessTree {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var runtimeSeen: [String: Bool] = [:]

    static func chain(from pid: Int32) -> [NetworkFilterPolicy.Ancestor] {
        var chain: [NetworkFilterPolicy.Ancestor] = []
        var current = pid
        while current > 1, chain.count < NetworkFilterPolicy.maximumDepth, let info = info(current) {
            let parent = Int32(info.kp_eproc.e_ppid)
            chain.append(.init(pid: current, parent: parent, isRuntime: isRuntime(current, started: info.kp_proc.p_un.__p_starttime)))
            if chain.last?.isRuntime == true { break }
            current = parent
        }
        return chain
    }

    static func info(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// Nollie Runtime by its signature: the exact identifier and the team. Cached per process and start time.
    static func isRuntime(_ pid: Int32, started: timeval) -> Bool {
        let key = "\(pid)/\(started.tv_sec).\(started.tv_usec)"
        lock.lock()
        if let known = runtimeSeen[key] { lock.unlock(); return known }
        lock.unlock()
        var code: SecCode?
        var requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        let signed = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess
            && SecRequirementCreateWithString(NetworkFilterXPC.runtimeRequirement as CFString, [], &requirement) == errSecSuccess
            && code.map { SecCodeCheckValidity($0, [], requirement) == errSecSuccess } == true
        lock.lock()
        if runtimeSeen.count > 4096 { runtimeSeen.removeAll() }
        runtimeSeen[key] = signed
        lock.unlock()
        return signed
    }

    static func program(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return String((path.split(separator: "/").last ?? "").prefix(64))
    }

    /// The door label the process, or its nearest labelled parent below Nollie Runtime, started with.
    static func bot(chain: [NetworkFilterPolicy.Ancestor]) -> String {
        for ancestor in chain where !ancestor.isRuntime {
            if let arguments = arguments(ancestor.pid), let label = NetworkFilterPolicy.label(environment: arguments.environment) {
                return label.bot
            }
        }
        return ""
    }

    static func arguments(_ pid: Int32) -> NetworkFilterPolicy.Arguments? {
        var size = 0
        var name = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > 0, size < 1 << 20 else { return nil }
        var data = Data(count: size)
        let ok = data.withUnsafeMutableBytes { sysctl(&name, 3, $0.baseAddress, &size, nil, 0) == 0 }
        return ok ? NetworkFilterPolicy.arguments(data.prefix(size)) : nil
    }
}

/// The filter's Mach service: Nollie Runtime subscribes with the switch and gets reports back, batched.
final class NetworkFilterReporter: NSObject, NSXPCListenerDelegate, NetworkFilterService, @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NSXPCListener?
    private var subscriber: NSXPCConnection?
    private var state = NetworkFilterPolicy.Switch.off
    private var pending: [NetworkFilterPolicy.Event] = []
    private let queue = DispatchQueue(label: "com.coreykozarski.nollie.network-filter.reports")

    var currentSwitch: NetworkFilterPolicy.Switch { lock.lock(); defer { lock.unlock() }; return state }

    func listen() {
        let made = NSXPCListener(machServiceName: NetworkFilterPolicy.machService)
        made.delegate = self
        made.resume()
        lock.lock(); listener = made; lock.unlock()
    }

    func stop() {
        lock.lock()
        listener?.invalidate(); listener = nil
        subscriber?.invalidate(); subscriber = nil
        state = .off
        lock.unlock()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(NetworkFilterXPC.runtimeRequirement)
        connection.exportedInterface = NetworkFilterXPC.serviceInterface()
        connection.exportedObject = self
        connection.remoteObjectInterface = NetworkFilterXPC.reportsInterface()
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self else { return }
            self.lock.lock()
            // The subscriber gone: back to letting everything through.
            if self.subscriber === connection { self.subscriber = nil; self.state = .off }
            self.lock.unlock()
        }
        connection.resume()
        return true
    }

    func subscribe(_ switchData: Data, reply: @escaping (Bool) -> Void) {
        guard let connection = NSXPCConnection.current() else { reply(false); return }
        let wanted = NetworkFilterPolicy.Switch.read(switchData)
        lock.lock()
        if subscriber !== connection { subscriber?.invalidate() }
        subscriber = connection
        state = wanted
        lock.unlock()
        reply(true)
    }

    func send(_ event: NetworkFilterPolicy.Event) {
        queue.async { [self] in
            pending.append(event)
            guard pending.count == 1 else { return }
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in
                let batch = pending
                pending.removeAll()
                lock.lock(); let connection = subscriber; lock.unlock()
                guard let connection, let data = try? JSONEncoder().encode(batch) else { return }
                (connection.remoteObjectProxy as? NetworkFilterReports)?.deliver(data)
            }
        }
    }
}

@main enum PapertrailFilterMain {
    static func main() {
        autoreleasepool { NEProvider.startSystemExtensionMode() }
        dispatchMain()
    }
}
#endif
