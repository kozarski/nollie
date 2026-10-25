#if os(macOS)
import Foundation
import Network

/// Rules for the exit relay: where it can listen, who can use it and where it can go.
///
/// The relay gives helpers' computers (VMs on Apple's NAT network) a way onto the internet while this
/// Mac routes all traffic through a Tailscale exit node. Their requests exit from the Mac like any
/// app's, so the exit node carries them. Nothing in here reads or stores the traffic.
enum ExitRelayPolicy {
    /// One fixed port, so a helper's computer always knows where to look.
    static let port: UInt16 = 47_610

    /// The web: 80 and 443, and the two common alternates. Everything else, mail (25, 465, 587)
    /// included, is refused: a computer of a helper's has no business sending mail or reaching
    /// other services from this Mac's address.
    static let allowedPorts: Set<UInt16> = [80, 443, 8080, 8443]

    // MARK: The VM network

    /// The Mac's side of Apple's VM network: a bridge (`bridge100`) with a VM's `vmenet` member,
    /// holding a private IPv4 address. The relay listens on that one address, never on all of them.
    struct Network: Equatable, Sendable {
        var interface: String
        var address: [UInt8]
        var mask: [UInt8]

        var prefixLength: Int { mask.reduce(0) { $0 + $1.nonzeroBitCount } }

        func contains(_ bytes: [UInt8]) -> Bool {
            guard bytes.count == 4 else { return false }
            return (0..<4).allSatisfy { bytes[$0] & mask[$0] == address[$0] & mask[$0] }
        }

        /// A VM's address on it: inside, and not the network, broadcast or the Mac's own address.
        func isGuest(_ bytes: [UInt8]) -> Bool {
            guard contains(bytes), bytes != address else { return false }
            let host = (0..<4).map { bytes[$0] & ~mask[$0] }
            let all = (0..<4).map { ~mask[$0] }
            return host != [0, 0, 0, 0] && host != all
        }
    }

    /// One IPv4 address on an interface, as `getifaddrs` gives it.
    struct InterfaceAddress: Equatable, Sendable {
        var interface: String
        var address: [UInt8]
        var mask: [UInt8]
    }

    /// The VM network, from this Mac's IPv4 addresses and each bridge's members. Only a bridge
    /// named `bridge<N>` with a `vmenet<N>` member counts: Internet Sharing's bridge (members like
    /// `en1`) does not, and neither do Wi-Fi, Ethernet, Tailscale or loopback. The address must be
    /// private (10/8, 172.16/12, 192.168/16) with a mask from /16 to /30.
    static func vmNetwork(_ addresses: [InterfaceAddress], members: [String: [String]]) -> Network? {
        for entry in addresses where isBridgeName(entry.interface) {
            guard entry.address.count == 4, entry.mask.count == 4, isContiguous(entry.mask),
                  (16...30).contains(entry.mask.reduce(0) { $0 + $1.nonzeroBitCount }),
                  isPrivateIPv4(entry.address),
                  members[entry.interface, default: []].contains(where: isVMMemberName) else { continue }
            return Network(interface: entry.interface, address: entry.address, mask: entry.mask)
        }
        return nil
    }

    static func isBridgeName(_ name: String) -> Bool { hasNumberedName(name, prefix: "bridge") }
    static func isVMMemberName(_ name: String) -> Bool { hasNumberedName(name, prefix: "vmenet") }

    private static func hasNumberedName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let digits = name.dropFirst(prefix.count)
        return (1...4).contains(digits.count) && digits.utf8.allSatisfy { (48...57).contains($0) }
    }

    /// `member: vmenet0 flags=3<LEARNING,DISCOVER>` lines of `ifconfig bridge100`.
    static func bridgeMembers(_ ifconfig: String) -> [String] {
        ifconfig.split(whereSeparator: \.isNewline).compactMap { line in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count >= 2, words[0] == "member:" else { return nil }
            return String(words[1])
        }
    }

    private static func isContiguous(_ mask: [UInt8]) -> Bool {
        let value = mask.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return value != 0 && (~value & (~value &+ 1)) == 0
    }

    static func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _), (172, 16...31), (192, 168): return true
        default: return false
        }
    }

    // MARK: Who may use it

    /// A VM on the network the relay listens on, and nothing else: not the Mac itself, not the
    /// home network, not Tailscale, not IPv6.
    static func allowsSource(_ endpoint: NWEndpoint, network: Network) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return network.isGuest(Array(address.rawValue))
        case .ipv6(let address):
            let bytes = Array(address.rawValue)
            guard bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF else { return false }
            return network.isGuest(Array(bytes[12..<16]))
        default: return false
        }
    }

    // MARK: Where it may go

    enum Refusal: Error, Equatable, Sendable {
        /// Not a web port.
        case port
        /// The name had no address, or one of its addresses is not on the public internet.
        case address
    }

    /// Every address must be public and not this Mac's own, or the whole name is refused: a name
    /// that answers with one public and one private address could be used to reach the private one.
    static func vet(_ addresses: [[UInt8]], own: [[UInt8]], network: Network?) -> Refusal? {
        guard !addresses.isEmpty else { return .address }
        for address in addresses {
            guard isPublic(address), !own.contains(address) else { return .address }
            if let network, network.contains(address) { return .address }
        }
        return nil
    }

    static func allowsPort(_ port: UInt16) -> Bool { allowedPorts.contains(port) }

    /// On the public internet. Refused: this network (0/8), private (10/8, 172.16/12, 192.168/16),
    /// CGNAT and Tailscale (100.64/10), loopback (127/8), link-local (169.254/16), protocol and
    /// documentation blocks, benchmarking (198.18/15), multicast and reserved (224/3 and up).
    static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _): return false
        case (100, 64...127, _): return false
        case (169, 254, _): return false
        case (172, 16...31, _): return false
        case (192, 0, 0), (192, 0, 2), (192, 88, 99), (192, 168, _): return false
        case (198, 18...19, _), (198, 51, 100), (203, 0, 113): return false
        case (224...255, _, _): return false
        default: return true
        }
    }

    /// Global unicast (2000::/3) only, minus documentation (2001:db8::/32) and the protocol block
    /// (2001::/23: Teredo, benchmarking, ORCHID). Addresses that carry an IPv4 address (mapped
    /// `::ffff:a.b.c.d`, 6to4 `2002::/16`, NAT64 `64:ff9b::/96`) are judged by that IPv4 address.
    /// Everything else is refused: loopback, unspecified, ULA (fc00::/7, Tailscale's included),
    /// link-local (fe80::/10), multicast (ff00::/8) and the rest.
    static func isPublicIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF { return isPublicIPv4(Array(b[12..<16])) }
        if Array(b[0..<12]) == [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0] { return isPublicIPv4(Array(b[12..<16])) }
        if b[0] == 0x20, b[1] == 0x02 { return isPublicIPv4(Array(b[2..<6])) }
        guard b[0] & 0xE0 == 0x20 else { return false }
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0D, b[3] == 0xB8 { return false }
        if b[0] == 0x20, b[1] == 0x01, b[2] & 0xFE == 0 { return false }
        return true
    }

    static func isPublic(_ bytes: [UInt8]) -> Bool {
        switch bytes.count {
        case 4: isPublicIPv4(bytes)
        case 16: isPublicIPv6(bytes)
        default: false
        }
    }
}
#endif
