import Foundation
import Testing
@testable import NollieCore

/// Away from home over Tailscale, without a network: telling tailnet hosts apart, reading
/// Tailscale's status from fixtures, what a phone is given, what it keeps, and the order it tries.
struct NollieLinkAwayTests {
    private let pin = Data(repeating: 7, count: 32)

    static func fixture(_ name: String) throws -> Data {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Tailscale")
        return try Data(contentsOf: folder.appendingPathComponent("tailscale-\(name).json"))
    }

    // MARK: Hosts

    @Test func tailnetHostsAreToldApart() {
        for host in ["studio.tail1234.ts.net", "100.64.0.1", "100.101.102.103", "100.127.255.254", "fd7a:115c:a1e0::1234:5678", "[fd7a:115c:a1e0::1]"] {
            #expect(NollieTailnet.isTailnetHost(host), "\(host)")
        }
        for host in ["studio.local", "192.168.1.20", "10.0.0.5", "100.63.0.1", "100.128.0.1", "fd00::1", "fe80::1", "8.8.8.8", "ts.net.evil.test"] {
            #expect(!NollieTailnet.isTailnetHost(host), "\(host)")
        }
    }

    @Test func aLinkMayNameTailscalesIPv6ButNoOtherPublicOrScopedAddress() {
        #expect(NollieLinkOffer.validHost("fd7a:115c:a1e0::1234:5678"))
        #expect(NollieLinkOffer.validHost("studio.tail1234.ts.net"))
        #expect(NollieLinkOffer.validHost("100.101.102.103"))
        for bad in ["FD7A:115C:A1E0::1", "fd00::1", "fe80::1%en0", "2001:db8::1", "[fd7a:115c:a1e0::1]", "8.8.8.8",
                    "100.128.0.1", "01.2.3.4", "1.2.3", "Studio.local", "-a.ts.net", "ts.net"] {
            #expect(!NollieLinkOffer.validHost(bad), "\(bad)")
        }
    }

    @Test func tailnetHostsGoOutOnlyWhileAwayIsOn() {
        let ready = TailscaleStatus(state: .running, name: "studio.tail1234.ts.net",
                                    addresses: ["100.101.102.103", "fd7a:115c:a1e0::1234:5678"])
        let lan = ["192.168.1.20", "10.0.0.5", "100.101.102.103"]
        #expect(NollieLinkHosts.make(lan: lan, localName: "studio.local", tailscale: ready, manual: nil, away: false, forCode: true)
                == ["192.168.1.20", "10.0.0.5", "studio.local"])
        // The code carries IPv4 only, so an older phone still reads it; a linked phone also gets IPv6.
        #expect(NollieLinkHosts.make(lan: lan, localName: "studio.local", tailscale: ready, manual: nil, away: true, forCode: true)
                == ["192.168.1.20", "10.0.0.5", "studio.local", "studio.tail1234.ts.net", "100.101.102.103"])
        #expect(NollieLinkHosts.make(lan: lan, localName: "studio.local", tailscale: ready, manual: nil, away: true, forCode: false).last
                == "fd7a:115c:a1e0::1234:5678")
        // A name typed in comes first; Tailscale off adds no addresses; never more than eight.
        let many = (1...9).map { "192.168.1.\($0)" }
        let typed = NollieLinkHosts.make(lan: many, localName: "studio.local", tailscale: TailscaleStatus(state: .stopped),
                                         manual: "studio.tail1234.ts.net", away: true, forCode: false)
        #expect(typed.count <= NollieLinkHosts.maximum && typed.last == "studio.tail1234.ts.net")
        #expect(NollieLinkHosts.make(lan: many, localName: "studio.local", tailscale: ready, manual: nil, away: true, forCode: false).count == 8)
        let offer = try? NollieLinkOffer(macName: "Studio", pin: pin, port: 52_345,
                                         hosts: NollieLinkHosts.make(lan: lan, localName: "studio.local", tailscale: ready, manual: nil, away: true, forCode: true),
                                         installTag: "0123456789abcdef", secret: Data(repeating: 1, count: 32), expiresAt: Date().addingTimeInterval(60))
        #expect(offer != nil)
    }

    @Test func theDoorsAnswerIsReadStrictly() {
        let good = Data(#"{"away":true,"hosts":["192.168.1.20","8.8.8.8","studio.tail1234.ts.net","studio.tail1234.ts.net"],"tailscale":"ready"}"#.utf8)
        #expect(NollieLinkHostsReply.decode(good) == NollieLinkHostsReply(hosts: ["192.168.1.20", "studio.tail1234.ts.net"], away: true, tailscale: "ready"))
        #expect(NollieLinkHostsReply.decode(Data(#"{"away":true,"hosts":[],"tailscale":"maybe"}"#.utf8)) == nil)
        #expect(NollieLinkHostsReply.decode(Data(#"{"hosts":[]}"#.utf8)) == nil)
        #expect(NollieLinkHostsReply.decode(Data(repeating: 32, count: 5000)) == nil)
        let reply = NollieLinkHostsReply(hosts: ["10.0.0.5"], away: false, tailscale: "missing")
        #expect(NollieLinkHostsReply.decode(reply.encoded()) == reply)
    }

    @Test func aLinkedMacKeepsWhatItsDoorSaid() throws {
        let link = LinkedMac(macName: "Studio", pin: pin, port: 52_345, hosts: ["192.168.1.20"], installTag: "0123456789abcdef", deviceID: UUID())
        #expect(link.away == nil && !link.awayReady)
        let next = link.updating(with: NollieLinkHostsReply(hosts: ["192.168.1.20", "studio.tail1234.ts.net"], away: true, tailscale: "ready"))
        #expect(next.hosts == ["192.168.1.20", "studio.tail1234.ts.net"] && next.awayReady)
        // Nothing to go on keeps the old list.
        #expect(next.updating(with: NollieLinkHostsReply(hosts: [], away: false, tailscale: "missing")).hosts == next.hosts)
        // Saved before away from home: still decodes.
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(link)) as! [String: Any]
        object.removeValue(forKey: "away")
        object.removeValue(forKey: "tailscale")
        #expect(try JSONDecoder().decode(LinkedMac.self, from: JSONSerialization.data(withJSONObject: object)) == link)
    }

    // MARK: Tailscale's status

    @Test func statusFixturesRead() throws {
        let running = try #require(TailscaleStatus.parse(try Self.fixture("running")))
        #expect(running == TailscaleStatus(state: .running, name: "studio.tail1234.ts.net",
                                           addresses: ["100.101.102.103", "fd7a:115c:a1e0::1234:5678"], exitNode: false))
        #expect(running.isReady && running.word == "ready")
        let exit = try #require(TailscaleStatus.parse(try Self.fixture("exit-node")))
        #expect(exit.exitNode && exit.isReady && exit.name == "studio.tail1234.ts.net")
        #expect(TailscaleStatus.parse(try Self.fixture("stopped")) == TailscaleStatus(state: .stopped))
        #expect(TailscaleStatus.parse(try Self.fixture("needs-login"))?.word == "stopped")
        #expect(TailscaleStatus.parse(Data("not json".utf8)) == nil)
        #expect(TailscaleStatus.missing.word == "missing")
        // A name outside ts.net (a self-hosted control server) is left out; the addresses still work.
        #expect(TailscaleStatus.cleanName("studio.example.com.") == nil)
        #expect(TailscaleStatus.cleanName("Studio.Tail1234.ts.net.") == "studio.tail1234.ts.net")
    }

    // MARK: Finding the Mac

    private func link(_ hosts: [String]) -> LinkedMac {
        LinkedMac(macName: "Studio", pin: pin, port: 52_345, hosts: hosts, installTag: "0123456789abcdef", deviceID: UUID())
    }

    private func resolver(answering: Set<String>, bonjour: String?, slow: Set<String> = [], asked: AwayTestBox<[String]>,
                          pins: AwayTestBox<[Data]>) -> NollieLinkResolver {
        NollieLinkResolver(probe: { host, port, pin in
            asked.withLock { $0.append(host) }
            pins.withLock { $0.append(pin) }
            if slow.contains(host) { try? await Task.sleep(for: .seconds(2)) }
            return port == 52_345 && answering.contains(host)
        }, discover: { tag, pin in
            asked.withLock { $0.append("bonjour:" + tag) }
            pins.withLock { $0.append(pin) }
            return bonjour
        })
    }

    @Test func atHomeTheLastAddressAndBonjourComeFirst() async {
        let asked = AwayTestBox<[String]>([]), pins = AwayTestBox<[Data]>([])
        let mac = link(["192.168.1.20", "studio.local", "studio.tail1234.ts.net", "100.101.102.103"])
        #expect(await resolver(answering: ["192.168.1.20", "100.101.102.103"], bonjour: nil, asked: asked, pins: pins)
            .resolve(mac, lastGood: "192.168.1.20") == "192.168.1.20")
        #expect(asked.withLock { $0 } == ["192.168.1.20"])
        asked.withLock { $0 = [] }
        #expect(await resolver(answering: ["100.101.102.103"], bonjour: "192.168.1.77", asked: asked, pins: pins)
            .resolve(mac, lastGood: "10.0.0.9") == "192.168.1.77")
        #expect(asked.withLock { $0 } == ["10.0.0.9", "bonjour:0123456789abcdef"])
    }

    @Test(.timeLimit(.minutes(1))) func awayWithNoBonjourAnswerTheTailnetGoesFirstAndWaitsForNoHomeAddress() async {
        let asked = AwayTestBox<[String]>([]), pins = AwayTestBox<[Data]>([])
        let mac = link(["192.168.1.20", "studio.local", "studio.tail1234.ts.net", "100.101.102.103"])
        let started = Date()
        // The home address hangs, as one does on a phone's mobile data; the tailnet answers.
        let found = await resolver(answering: ["studio.tail1234.ts.net"], bonjour: nil, slow: ["192.168.1.20", "studio.local"],
                                   asked: asked, pins: pins).resolve(mac, lastGood: nil)
        #expect(found == "studio.tail1234.ts.net")
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(asked.withLock { $0 }.first == "bonjour:0123456789abcdef")
        // When both answer, the tailnet wins: it is first in line away from home.
        let both = await resolver(answering: ["192.168.1.20", "100.101.102.103"], bonjour: nil, asked: asked, pins: pins).resolve(mac, lastGood: nil)
        #expect(both == "100.101.102.103")
    }

    @Test func behindAnExitNodeTheLastTailnetAddressSkipsBonjour() async {
        let asked = AwayTestBox<[String]>([]), pins = AwayTestBox<[Data]>([])
        let mac = link(["192.168.1.20", "studio.local", "studio.tail1234.ts.net", "100.101.102.103"])
        let found = await resolver(answering: ["100.101.102.103"], bonjour: "192.168.1.20", asked: asked, pins: pins)
            .resolve(mac, lastGood: "studio.tail1234.ts.net")
        #expect(found == "100.101.102.103")
        #expect(!asked.withLock { $0 }.contains { $0.hasPrefix("bonjour:") })
        #expect(Set(asked.withLock { $0 }) == ["studio.tail1234.ts.net", "100.101.102.103"])
        // Back home with the tailnet down: Bonjour, then the home addresses.
        asked.withLock { $0 = [] }
        #expect(await resolver(answering: ["studio.local"], bonjour: nil, asked: asked, pins: pins)
            .resolve(mac, lastGood: "100.101.102.103") == "studio.local")
    }

    @Test func everyPathChecksThePin() async {
        let asked = AwayTestBox<[String]>([]), pins = AwayTestBox<[Data]>([])
        let mac = link(["192.168.1.20", "studio.tail1234.ts.net"])
        // A host that answers with another key fails its probe and is never used.
        #expect(await resolver(answering: [], bonjour: nil, asked: asked, pins: pins).resolve(mac, lastGood: "100.101.102.103") == nil)
        #expect(await resolver(answering: [], bonjour: nil, asked: asked, pins: pins).resolve(mac, lastGood: "192.168.1.20") == nil)
        #expect(!pins.withLock { $0 }.isEmpty)
        #expect(pins.withLock { $0 }.allSatisfy { $0 == pin })
    }

    #if os(macOS)
    // MARK: Detecting Tailscale on the Mac

    private func detector(tools: Set<String>, app: Bool, status: String?, interfaces: [NollieLinkInterfaces.Entry] = [],
                          primary: String? = "en0") throws -> TailscaleDetector {
        let output = try status.map { try Self.fixture($0) }
        return TailscaleDetector(exists: { url in url == TailscaleDetector.app ? app : tools.contains(url.path) },
                                 run: { tool, arguments in
                                     #expect(arguments == ["status", "--json"])
                                     return tools.contains(tool.path) ? output : nil
                                 },
                                 interfaces: { interfaces }, primaryInterface: { primary })
    }

    private let appTool = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    @Test func notInstalled() async throws {
        let found = try await detector(tools: [], app: false, status: nil, interfaces: [.init("en0", "192.168.1.20")]).detect()
        #expect(found == .missing && found.word == "missing")
    }

    @Test func installedButNotRunning() async throws {
        #expect(try await detector(tools: [appTool], app: true, status: "stopped").detect().word == "stopped")
        #expect(try await detector(tools: [appTool], app: true, status: "needs-login").detect().word == "stopped")
        // The command line won't answer (the Mac App Store app may refuse it) and no address is up.
        #expect(try await detector(tools: [], app: true, status: nil).detect().word == "stopped")
    }

    @Test func runningWithItsName() async throws {
        let found = try await detector(tools: [appTool], app: true, status: "running").detect()
        #expect(found.isReady && found.name == "studio.tail1234.ts.net" && !found.exitNode)
        // Homebrew's command line counts too.
        #expect(try await detector(tools: ["/opt/homebrew/bin/tailscale"], app: false, status: "running").detect().isReady)
        // No command line, an address on Tailscale's interface: running, without a name.
        let local = try await detector(tools: [], app: true, status: nil,
                                       interfaces: [.init("en0", "192.168.1.20"), .init("utun4", "100.101.102.103")]).detect()
        #expect(local == TailscaleStatus(state: .running, addresses: ["100.101.102.103"]))
    }

    @Test func exitNodeOnTheMac() async throws {
        #expect(try await detector(tools: [appTool], app: true, status: "exit-node").detect().exitNode)
        #expect(try await !detector(tools: [appTool], app: true, status: "running").detect().exitNode)
        // Without the command line: the default route on Tailscale's interface says so.
        let tunnel = [NollieLinkInterfaces.Entry("en0", "192.168.1.20"), .init("utun4", "100.101.102.103")]
        #expect(try await detector(tools: [], app: true, status: nil, interfaces: tunnel, primary: "utun4").detect().exitNode)
        #expect(try await !detector(tools: [], app: true, status: nil, interfaces: tunnel, primary: "en0").detect().exitNode)
        // Another VPN's tunnel is not Tailscale's exit node.
        #expect(try await !detector(tools: [], app: false, status: nil, interfaces: [.init("utun2", "10.8.0.2")], primary: "utun2").detect().exitNode)
    }
    #endif
}

/// A locked value that escaping test closures may share.
final class AwayTestBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
