import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if os(macOS)
import SystemConfiguration
#endif

// Away from home: Nollie Link over Tailscale. This file is also compiled into Nollie Runtime
// (the door's helper), so it uses Foundation and Darwin only.

/// Tailscale's own address blocks and names, as Nollie Link tells them apart from a home network.
public enum NollieTailnet {
    /// 100.64.0.0/10, the block Tailscale gives each device.
    public static func isTailnetIPv4(_ bytes: [UInt8]) -> Bool {
        bytes.count == 4 && bytes[0] == 100 && (64...127).contains(bytes[1])
    }

    /// fd7a:115c:a1e0::/48, Tailscale's IPv6 block.
    public static func isTailnetIPv6(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 && Array(bytes.prefix(6)) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
    }

    /// True for a Tailscale address, or a MagicDNS name ending in `.ts.net`.
    public static func isTailnetHost(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if bare.hasSuffix(".ts.net") { return true }
        if let v4 = ipv4Bytes(bare) { return isTailnetIPv4(v4) }
        if let v6 = ipv6Bytes(bare) { return isTailnetIPv6(v6) }
        return false
    }

    public static func ipv4Bytes(_ text: String) -> [UInt8]? {
        guard text.split(separator: ".", omittingEmptySubsequences: false).count == 4 else { return nil }
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    public static func ipv6Bytes(_ text: String) -> [UInt8]? {
        guard text.contains(":"), !text.contains("%") else { return nil }
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    /// A host a Nollie Link code or a linked Mac may name: a private IPv4 address, a Tailscale IPv6
    /// address, or a `.local` or `.ts.net` name. Never a public address: the Mac only answers
    /// private networks, so a public one is a forgery.
    public static func validLinkHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        if let b = ipv4Bytes(host) {
            switch (b[0], b[1]) {
            case (10, _), (192, 168), (172, 16...31), (100, 64...127), (169, 254): return true
            default: return false
            }
        }
        if let b = ipv6Bytes(host) { return host == host.lowercased() && isTailnetIPv6(b) }
        let lowered = host.lowercased()
        guard lowered == host, lowered.hasSuffix(".local") || lowered.hasSuffix(".ts.net") else { return false }
        let labels = lowered.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
}

/// Tailscale on this Mac, as Nollie sees it: without admin rights and without any network call of
/// its own (only Tailscale's own command line, which asks the Tailscale app on this Mac).
public struct TailscaleStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// No Tailscale app or command line on this Mac.
        case missing
        /// Installed, but not on or not signed in.
        case stopped
        case running
    }

    public var state: State
    /// The MagicDNS name, like `studio.tail1234.ts.net`, when Tailscale gave one.
    public var name: String?
    /// This Mac's Tailscale addresses, IPv4 first.
    public var addresses: [String]
    /// This Mac sends its traffic through an exit node. Its own Tailscale addresses still answer.
    public var exitNode: Bool

    public init(state: State, name: String? = nil, addresses: [String] = [], exitNode: Bool = false) {
        self.state = state
        self.name = name
        self.addresses = addresses
        self.exitNode = exitNode
    }

    public static let missing = TailscaleStatus(state: .missing)

    /// Running, with a name or an address a phone can use.
    public var isReady: Bool { state == .running && (name != nil || !addresses.isEmpty) }

    /// The word the door sends a linked phone.
    public var word: String { isReady ? "ready" : state == .missing ? "missing" : "stopped" }

    /// `tailscale status --json`, read for this Mac's own entry only. Nil when it isn't that.
    public static func parse(_ json: Data) -> TailscaleStatus? {
        guard json.count <= 4 * 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let backend = root["BackendState"] as? String else { return nil }
        guard backend == "Running" else { return TailscaleStatus(state: .stopped) }
        let me = root["Self"] as? [String: Any] ?? [:]
        let ips = (me["TailscaleIPs"] as? [String]) ?? (root["TailscaleIPs"] as? [String]) ?? []
        let name = (me["DNSName"] as? String).flatMap(cleanName)
        let exit = root["ExitNodeStatus"].map { !($0 is NSNull) } ?? false
        return TailscaleStatus(state: .running, name: name, addresses: ordered(ips), exitNode: exit)
    }

    /// When the command line can't be asked (the Mac App Store app may refuse it): an address in
    /// Tailscale's blocks on this Mac means it is on, though without a name.
    public static func fromInterfaces(_ addresses: [String], installed: Bool) -> TailscaleStatus {
        let found = ordered(addresses)
        if !found.isEmpty { return TailscaleStatus(state: .running, addresses: found) }
        return TailscaleStatus(state: installed ? .stopped : .missing)
    }

    /// A MagicDNS name a phone will accept: lowercase, no final dot, under `.ts.net`.
    public static func cleanName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard name.hasSuffix(".ts.net"), NollieTailnet.validLinkHost(name) else { return nil }
        return name
    }

    /// Tailscale addresses only, IPv4 before IPv6, each once.
    static func ordered(_ addresses: [String]) -> [String] {
        let v4 = addresses.filter { NollieTailnet.ipv4Bytes($0).map(NollieTailnet.isTailnetIPv4) ?? false }
        let v6 = addresses.map { $0.lowercased() }.filter { NollieTailnet.ipv6Bytes($0).map(NollieTailnet.isTailnetIPv6) ?? false }
        var seen = Set<String>()
        return (v4 + v6).filter { seen.insert($0).inserted }
    }
}

/// Where a linked phone may look for this Mac.
public enum NollieLinkHosts {
    public static let maximum = 8

    /// Home addresses and the Bonjour name first, then, only while away from home is on, the
    /// tailnet: a name typed in by the person, the MagicDNS name and the Tailscale addresses.
    /// A code carries IPv4 only, so phones with an older Nollie can still read it; a linked phone
    /// gets the IPv6 address too when it asks.
    public static func make(lan: [String], localName: String?, tailscale: TailscaleStatus, manual: String?,
                            away: Bool, forCode: Bool) -> [String] {
        var tailnet: [String] = []
        if away {
            if let manual { tailnet.append(manual) }
            if let name = tailscale.name { tailnet.append(name) }
            let addresses = tailscale.state == .running ? tailscale.addresses : []
            tailnet += addresses.filter { !forCode || NollieTailnet.ipv4Bytes($0) != nil }
        }
        var seen = Set<String>()
        tailnet = Array(tailnet.filter { NollieTailnet.validLinkHost($0) && seen.insert($0).inserted }.prefix(4))
        let local = localName.map { [$0] } ?? []
        let home = lan.filter { !NollieTailnet.isTailnetHost($0) && NollieTailnet.validLinkHost($0) && seen.insert($0).inserted }
        let room = max(0, maximum - tailnet.count - local.count)
        return Array(home.prefix(min(4, room))) + local + tailnet
    }
}

/// What the door tells a linked phone after it connects: where to find the Mac next time, whether
/// away from home is on, and whether Tailscale is ready on the Mac.
public struct NollieLinkHostsReply: Codable, Equatable, Sendable {
    public var hosts: [String]
    public var away: Bool
    /// "ready", "stopped" or "missing".
    public var tailscale: String

    public init(hosts: [String], away: Bool, tailscale: String) {
        self.hosts = hosts
        self.away = away
        self.tailscale = tailscale
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)) ?? Data(#"{"away":false,"hosts":[],"tailscale":"missing"}"#.utf8)
    }

    /// A strict read: valid hosts only, each once, at most eight; anything else is dropped.
    public static func decode(_ data: Data) -> NollieLinkHostsReply? {
        guard data.count <= 4096, let reply = try? JSONDecoder().decode(Self.self, from: data),
              ["ready", "stopped", "missing"].contains(reply.tailscale) else { return nil }
        var seen = Set<String>()
        let hosts = reply.hosts.filter { NollieTailnet.validLinkHost($0) && seen.insert($0).inserted }
        return NollieLinkHostsReply(hosts: Array(hosts.prefix(NollieLinkHosts.maximum)), away: reply.away, tailscale: reply.tailscale)
    }
}

/// How a linked phone reaches its Mac right now.
public enum NollieLinkReach: String, Equatable, Sendable {
    /// On the Mac's home network.
    case home
    /// Through Tailscale.
    case tailnet
    /// The Mac can't be reached: only iCloud alerts get through, if they are on.
    case away
}

#if os(macOS)
/// Finds Tailscale on this Mac: its command line inside the app (standalone or Mac App Store) or
/// from Homebrew, asked for `status --json`; failing that, a Tailscale address on this Mac.
public struct TailscaleDetector: Sendable {
    public static let app = URL(fileURLWithPath: "/Applications/Tailscale.app")
    public static let tools = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ].map { URL(fileURLWithPath: $0) }

    public var exists: @Sendable (URL) -> Bool
    /// Runs a tool and returns what it printed, or nil when it failed or took too long.
    public var run: @Sendable (_ tool: URL, _ arguments: [String]) async -> Data?
    public var interfaces: @Sendable () -> [NollieLinkInterfaces.Entry]
    /// The interface the Mac's default route uses now (`State:/Network/Global/IPv4`).
    public var primaryInterface: @Sendable () -> String?

    public init(exists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                run: @escaping @Sendable (URL, [String]) async -> Data? = { await TailscaleDetector.runTool($0, $1) },
                interfaces: @escaping @Sendable () -> [NollieLinkInterfaces.Entry] = { NollieLinkInterfaces.addresses() },
                primaryInterface: @escaping @Sendable () -> String? = { NollieLinkInterfaces.primary() }) {
        self.exists = exists
        self.run = run
        self.interfaces = interfaces
        self.primaryInterface = primaryInterface
    }

    public func detect() async -> TailscaleStatus {
        let tools = Self.tools.filter(exists)
        let installed = exists(Self.app) || !tools.isEmpty
        let entries = interfaces()
        var local = TailscaleStatus.fromInterfaces(entries.map(\.address), installed: installed)
        // The default route on Tailscale's own interface: everything leaves through an exit node.
        let routed = primaryInterface().map { primary in
            primary.hasPrefix("utun") && entries.contains { $0.interface == primary && NollieTailnet.isTailnetHost($0.address) }
        } ?? false
        local.exitNode = local.state == .running && routed
        for tool in tools {
            guard let output = await run(tool, ["status", "--json"]), var status = TailscaleStatus.parse(output) else { continue }
            if status.state == .running, status.addresses.isEmpty { status.addresses = local.addresses }
            status.exitNode = status.state == .running && (status.exitNode || routed)
            return status
        }
        return local
    }

    /// At most three seconds and a megabyte of output, with a plain environment.
    public static func runTool(_ tool: URL, _ arguments: [String]) async -> Data? {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let reader = Task.detached { () -> Data in
            var data = Data()
            while let chunk = try? output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                data.append(chunk)
                if data.count > 1_048_576 { break }
            }
            return data
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if process.isRunning { process.terminate(); reader.cancel(); return nil }
        let data = await reader.value
        return process.terminationStatus == 0 && data.count <= 1_048_576 ? data : nil
    }
}

/// This Mac's addresses on active interfaces.
public enum NollieLinkInterfaces {
    public struct Entry: Equatable, Sendable {
        public var interface: String
        public var address: String
        public var bytes: [UInt8]

        public init(interface: String, address: String, bytes: [UInt8]) {
            self.interface = interface
            self.address = address
            self.bytes = bytes
        }

        /// From a written address, for fixtures.
        public init(_ interface: String, _ address: String) {
            self.init(interface: interface, address: address,
                      bytes: NollieTailnet.ipv4Bytes(address) ?? NollieTailnet.ipv6Bytes(address) ?? [])
        }
    }

    /// The interface macOS sends the default IPv4 route through now.
    public static func primary() -> String? {
        guard let value = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return value["PrimaryInterface"] as? String
    }

    public static func addresses() -> [Entry] {
        var result: [Entry] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin_addr) { Array($0) }
                }
                result.append(Entry(interface: name, address: bytes.map(String.init).joined(separator: "."), bytes: bytes))
            case AF_INET6:
                var raw = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let bytes = withUnsafeBytes(of: raw) { Array($0) }
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &raw, &text, socklen_t(text.count)) != nil else { continue }
                result.append(Entry(interface: name, address: String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), bytes: bytes))
            default: continue
            }
        }
        return result
    }
}
#endif
