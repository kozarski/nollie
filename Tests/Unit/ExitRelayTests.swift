#if os(macOS)
import Foundation
import Network
import Testing
@testable import NollieCore

/// The exit relay from Nollie Runtime, compiled into this test bundle: where it listens, who may
/// use it, where it may go, its two small parsers, and the whole relay on loopback in front of a
/// fake website.
struct ExitRelayTests {
    private func v4(_ text: String) -> [UInt8] { Array(IPv4Address(text)!.rawValue) }
    private func v6(_ text: String) -> [UInt8] { Array(IPv6Address(text)!.rawValue) }
    private let vm = ExitRelayPolicy.Network(interface: "bridge100", address: [192, 168, 64, 1], mask: [255, 255, 255, 0])

    // MARK: Destinations

    @Test func everyPrivateIPv4RangeIsRefused() {
        let refused = ["0.0.0.0", "0.1.2.3", "10.0.0.1", "10.255.255.255", "100.64.0.1", "100.100.100.100",
                       "100.127.255.255", "127.0.0.1", "127.255.0.1", "169.254.169.254", "169.254.0.1",
                       "172.16.0.1", "172.20.1.1", "172.31.255.255", "192.0.0.1", "192.0.2.1", "192.88.99.1",
                       "192.168.0.1", "192.168.64.1", "198.18.0.1", "198.19.255.255", "198.51.100.1", "203.0.113.1",
                       "224.0.0.1", "239.255.255.250", "240.0.0.1", "255.255.255.255"]
        for address in refused { #expect(!ExitRelayPolicy.isPublic(v4(address)), "\(address) passed") }
        let allowed = ["1.1.1.1", "8.8.8.8", "93.184.216.34", "100.63.255.255", "100.128.0.1", "169.253.255.255",
                       "172.15.255.255", "172.32.0.1", "192.167.255.255", "192.169.0.1", "198.17.255.255",
                       "198.20.0.1", "223.255.255.254"]
        for address in allowed { #expect(ExitRelayPolicy.isPublic(v4(address)), "\(address) refused") }
    }

    @Test func everyPrivateIPv6RangeIsRefusedAndMappedAddressesAreJudgedAsIPv4() {
        let refused = ["::", "::1", "::ffff:10.0.0.1", "::ffff:127.0.0.1", "::ffff:192.168.64.1", "::ffff:100.64.0.1",
                       "::ffff:169.254.169.254", "::127.0.0.1", "fc00::1", "fd00::1", "fd7a:115c:a1e0::1", "fe80::1",
                       "febf::1", "ff02::1", "ff0e::1", "2001:db8::1", "2001::1", "2001:1ff::1", "64:ff9b::a00:1",
                       "64:ff9b::7f00:1", "2002:a00:1::1", "2002:c0a8:4001::1", "100::1", "4000::1", "e000::1"]
        for address in refused { #expect(!ExitRelayPolicy.isPublic(v6(address)), "\(address) passed") }
        let allowed = ["2606:4700:4700::1111", "2001:4860:4860::8888", "2a00:1450:4009::1", "::ffff:1.1.1.1",
                       "64:ff9b::101:101", "2002:101:101::1", "3fff::1"]
        for address in allowed { #expect(ExitRelayPolicy.isPublic(v6(address)), "\(address) refused") }
        #expect(!ExitRelayPolicy.isPublic([]))
        #expect(!ExitRelayPolicy.isPublic([1, 1, 1]))
    }

    @Test func aNameIsRefusedWhenAnyOfItsAddressesIsPrivate() {
        let refusal = ExitRelayPolicy.Refusal.address
        #expect(ExitRelayPolicy.vet([v4("93.184.216.34")], own: [], network: vm) == nil)
        #expect(ExitRelayPolicy.vet([v4("93.184.216.34"), v6("2606:4700:4700::1111")], own: [], network: vm) == nil)
        #expect(ExitRelayPolicy.vet([v4("93.184.216.34"), v4("10.0.0.5")], own: [], network: vm) == refusal)
        #expect(ExitRelayPolicy.vet([v4("10.0.0.5"), v4("93.184.216.34")], own: [], network: vm) == refusal)
        #expect(ExitRelayPolicy.vet([v6("2606:4700:4700::1111"), v6("::ffff:192.168.1.1")], own: [], network: vm) == refusal)
        #expect(ExitRelayPolicy.vet([v4("1.1.1.1"), v6("fe80::1")], own: [], network: vm) == refusal)
        #expect(ExitRelayPolicy.vet([v4("1.1.1.1"), v4("127.0.0.1")], own: [], network: vm) == refusal)
        #expect(ExitRelayPolicy.vet([], own: [], network: vm) == refusal)
        // This Mac's own public address is refused like any of its own.
        #expect(ExitRelayPolicy.vet([v4("81.2.69.160")], own: [v4("81.2.69.160")], network: vm) == refusal)
        #expect(ExitRelayPolicy.vet([v4("81.2.69.160")], own: [v4("81.2.69.161")], network: vm) == nil)
    }

    @Test func onlyWebPortsAreAllowed() {
        for port: UInt16 in [80, 443, 8080, 8443] { #expect(ExitRelayPolicy.allowsPort(port)) }
        for port: UInt16 in [0, 21, 22, 23, 25, 53, 110, 143, 465, 587, 993, 3306, 5432, 6379, 9119, 47_610, 65_535] {
            #expect(!ExitRelayPolicy.allowsPort(port), "\(port) allowed")
        }
    }

    // MARK: Where it listens and who may use it

    @Test func itListensOnlyOnTheVMBridge() {
        typealias Entry = ExitRelayPolicy.InterfaceAddress
        let mask24: [UInt8] = [255, 255, 255, 0]
        let lan = Entry(interface: "en0", address: [192, 168, 1, 20], mask: mask24)
        let tailscale = Entry(interface: "utun4", address: [100, 101, 102, 103], mask: [255, 255, 255, 255])
        let sharing = Entry(interface: "bridge101", address: [192, 168, 2, 1], mask: mask24)
        let bridge = Entry(interface: "bridge100", address: [192, 168, 64, 1], mask: mask24)
        let members = ["bridge100": ["vmenet0"], "bridge101": ["en1"]]

        #expect(ExitRelayPolicy.vmNetwork([lan, tailscale, sharing, bridge], members: members) == vm)
        // No VM running: no bridge with a vmenet member, so nowhere to listen.
        #expect(ExitRelayPolicy.vmNetwork([lan, tailscale, sharing], members: members) == nil)
        #expect(ExitRelayPolicy.vmNetwork([bridge], members: [:]) == nil)
        #expect(ExitRelayPolicy.vmNetwork([bridge], members: ["bridge100": ["en5", "vmenetX"]]) == nil)
        // Never Wi-Fi, Ethernet or Tailscale, even with a member list that claims a VM.
        #expect(ExitRelayPolicy.vmNetwork([lan, tailscale], members: ["en0": ["vmenet0"], "utun4": ["vmenet0"]]) == nil)
        // A bridge with a public, unspecified or odd address or mask is not the VM network.
        for odd in [Entry(interface: "bridge100", address: [8, 8, 8, 1], mask: mask24),
                    Entry(interface: "bridge100", address: [0, 0, 0, 0], mask: mask24),
                    Entry(interface: "bridge100", address: [100, 64, 0, 1], mask: mask24),
                    Entry(interface: "bridge100", address: [192, 168, 64, 1], mask: [255, 255, 255, 255]),
                    Entry(interface: "bridge100", address: [10, 0, 0, 1], mask: [255, 0, 0, 0]),
                    Entry(interface: "bridge100", address: [192, 168, 64, 1], mask: [255, 0, 255, 0])] {
            #expect(ExitRelayPolicy.vmNetwork([odd], members: members) == nil, "\(odd)")
        }
        #expect(ExitRelayPolicy.isBridgeName("bridge100") && !ExitRelayPolicy.isBridgeName("bridge") && !ExitRelayPolicy.isBridgeName("bridge1x"))
        #expect(ExitRelayPolicy.isVMMemberName("vmenet12") && !ExitRelayPolicy.isVMMemberName("vmenet") && !ExitRelayPolicy.isVMMemberName("xvmenet0"))
    }

    @Test func bridgeMembersAreReadFromIfconfig() {
        let text = """
        bridge100: flags=8a63<UP,BROADCAST,SMART,RUNNING,ALLMULTI,SIMPLEX,MULTICAST> mtu 1500
        \toptions=3<RXCSUM,TXCSUM>
        \tether 3e:a6:f6:0e:5a:64
        \tinet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255
        \tConfiguration:
        \t\tid 0:0:0:0:0:0 priority 0 hellotime 0 fwddelay 0
        \tmember: vmenet0 flags=3<LEARNING,DISCOVER>
        \t        ifmaxaddr 0 port 22 priority 0 path cost 0
        \tmember: vmenet1 flags=3<LEARNING,DISCOVER>
        \tstatus: active
        """
        #expect(ExitRelayPolicy.bridgeMembers(text) == ["vmenet0", "vmenet1"])
        #expect(ExitRelayPolicy.bridgeMembers("member:") == [])
        #expect(ExitRelayPolicy.bridgeMembers("") == [])
    }

    @Test func onlyVMsOnItsNetworkMayUseIt() {
        func source(_ host: NWEndpoint.Host) -> Bool { ExitRelayPolicy.allowsSource(.hostPort(host: host, port: 50_000), network: vm) }
        #expect(source(.ipv4(IPv4Address("192.168.64.2")!)))
        #expect(source(.ipv4(IPv4Address("192.168.64.254")!)))
        #expect(source(.ipv6(IPv6Address("::ffff:192.168.64.3")!)))
        // The Mac itself, the network and broadcast addresses, and everything outside.
        for refused in ["192.168.64.1", "192.168.64.0", "192.168.64.255", "192.168.65.2", "192.168.1.20", "10.0.0.2",
                        "100.101.102.103", "127.0.0.1", "8.8.8.8"] {
            #expect(!source(.ipv4(IPv4Address(refused)!)), "\(refused) allowed")
        }
        for refused in ["fe80::1", "::1", "fd7a:115c:a1e0::1", "2606:4700:4700::1111", "::ffff:192.168.65.3"] {
            #expect(!source(.ipv6(IPv6Address(refused)!)), "\(refused) allowed")
        }
        #expect(!source(.name("guest.local", nil)))
        #expect(!ExitRelayPolicy.allowsSource(.service(name: "x", type: "_http._tcp", domain: "local.", interface: nil), network: vm))
    }

    @Test func itCannotListenOnAnAddressThisMacDoesNotHave() async {
        let elsewhere = ExitRelayPolicy.Network(interface: "bridge100", address: [192, 0, 2, 1], mask: [255, 255, 255, 0])
        let relay = ExitRelay(configuration: .init(network: elsewhere, port: 0))
        await #expect(throws: (any Error).self) { try await relay.start() }
        #expect(!relay.isListening)
        relay.stop()
    }

    // MARK: HTTP parser

    private func head(_ lines: [String], body: String = "") -> Data {
        Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    @Test func httpReadsConnectAndForwardRequests() throws {
        let connect = try ExitRelayHTTP.parse(head(["CONNECT example.com:443 HTTP/1.1", "Host: example.com:443"]))
        #expect(connect.kind == .connect)
        #expect(connect.target == ExitRelayTarget(host: .name("example.com"), port: 443))
        let literal = try ExitRelayHTTP.parse(head(["CONNECT 93.184.216.34:443 HTTP/1.1"]))
        #expect(literal.target == ExitRelayTarget(host: .address([93, 184, 216, 34]), port: 443))
        let six = try ExitRelayHTTP.parse(head(["CONNECT [2606:4700:4700::1111]:443 HTTP/1.1"]))
        #expect(six.target == ExitRelayTarget(host: .address(v6("2606:4700:4700::1111")), port: 443))
        let upper = try ExitRelayHTTP.parse(head(["CONNECT Example.COM.:8443 HTTP/1.0"]))
        #expect(upper.target == ExitRelayTarget(host: .name("example.com"), port: 8443))

        let forward = try ExitRelayHTTP.parse(head(["GET http://example.com/a/b?c=1 HTTP/1.1", "Host: wrong.example",
                                                    "Proxy-Connection: keep-alive", "Proxy-Authorization: Basic eDp5",
                                                    "Connection: keep-alive, X-Secret", "X-Secret: 1", "Keep-Alive: 5",
                                                    "Accept: */*"], body: "extra"))
        #expect(forward.target == ExitRelayTarget(host: .name("example.com"), port: 80))
        guard case .forward(let data) = forward.kind else { Issue.record("not a forward"); return }
        #expect(String(decoding: data, as: UTF8.self) == "GET /a/b?c=1 HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\nConnection: close\r\n\r\n")
        let rootless = try ExitRelayHTTP.parse(head(["POST http://example.com:8080?q HTTP/1.1", "Content-Length: 0"]))
        guard case .forward(let posted) = rootless.kind else { Issue.record("not a forward"); return }
        #expect(String(decoding: posted, as: UTF8.self).hasPrefix("POST /?q HTTP/1.1\r\nHost: example.com:8080\r\n"))
        #expect(forward.headLength == head(["GET http://example.com/a/b?c=1 HTTP/1.1", "Host: wrong.example",
                                            "Proxy-Connection: keep-alive", "Proxy-Authorization: Basic eDp5",
                                            "Connection: keep-alive, X-Secret", "X-Secret: 1", "Keep-Alive: 5",
                                            "Accept: */*"]).count)
    }

    /// Each of these must be refused, and with the right kind of answer.
    @Test func httpRefusesMalformedCorpus() {
        let corpus: [(String, Data, Int)] = [
            ("bare LF", Data("CONNECT a.com:443 HTTP/1.1\n\n".utf8), 400),
            ("no port", head(["CONNECT example.com HTTP/1.1"]), 400),
            ("port zero", head(["CONNECT example.com:0 HTTP/1.1"]), 400),
            ("port too big", head(["CONNECT example.com:65536 HTTP/1.1"]), 400),
            ("port sign", head(["CONNECT example.com:+443 HTTP/1.1"]), 400),
            ("two ports", head(["CONNECT example.com:443:1 HTTP/1.1"]), 400),
            ("userinfo", head(["CONNECT user@example.com:443 HTTP/1.1"]), 400),
            ("escape", head(["CONNECT exa%6dple.com:443 HTTP/1.1"]), 400),
            ("zone", head(["CONNECT [fe80::1%en0]:443 HTTP/1.1"]), 400),
            ("v4 in brackets", head(["CONNECT [1.1.1.1]:443 HTTP/1.1"]), 400),
            ("octal", head(["CONNECT 0177.0.0.1:443 HTTP/1.1"]), 400),
            ("decimal address", head(["CONNECT 2130706433:443 HTTP/1.1"]), 400),
            ("short address", head(["CONNECT 127.1:443 HTTP/1.1"]), 400),
            ("empty label", head(["CONNECT a..com:443 HTTP/1.1"]), 400),
            ("hyphen label", head(["CONNECT -a.com:443 HTTP/1.1"]), 400),
            ("long label", head(["CONNECT \(String(repeating: "a", count: 64)).com:443 HTTP/1.1"]), 400),
            ("space in name", head(["CONNECT a b.com:443 HTTP/1.1"]), 400),
            ("origin form", head(["GET /index.html HTTP/1.1", "Host: example.com"]), 400),
            ("https forward", head(["GET https://example.com/ HTTP/1.1"]), 400),
            ("other scheme", head(["GET ftp://example.com/ HTTP/1.1"]), 400),
            ("forward userinfo", head(["GET http://u:p@example.com/ HTTP/1.1"]), 400),
            ("fragment", head(["GET http://example.com/#x HTTP/1.1"]), 400),
            ("no host", head(["GET http:///x HTTP/1.1"]), 400),
            ("trace", head(["TRACE http://example.com/ HTTP/1.1"]), 501),
            ("lowercase method", head(["connect example.com:443 HTTP/1.1"]), 501),
            ("http2", head(["CONNECT example.com:443 HTTP/2.0"]), 501),
            ("extra space", head(["CONNECT  example.com:443 HTTP/1.1"]), 400),
            ("folded header", head(["CONNECT example.com:443 HTTP/1.1", " folded"]), 400),
            ("bad header name", head(["CONNECT example.com:443 HTTP/1.1", "Bad Name: x"]), 400),
            ("NUL", Data("CONNECT a.com:443 HTTP/1.1\r\nX: \u{0}\r\n\r\n".utf8), 400),
            ("non-ASCII", Data("CONNECT a.com:443 HTTP/1.1\r\nX: é\r\n\r\n".utf8), 400),
            ("too many headers", head(["CONNECT a.com:443 HTTP/1.1"] + (0..<65).map { "X-\($0): y" }), 431),
            ("head too large", head(["CONNECT a.com:443 HTTP/1.1", "X: " + String(repeating: "a", count: 17_000)]), 431),
            ("line too long", head(["CONNECT a.com:443 HTTP/1.1", "X: " + String(repeating: "a", count: 9_000)]), 431),
        ]
        for (name, data, status) in corpus {
            do throws(LinkDoorHTTP.Failure) {
                _ = try ExitRelayHTTP.parse(data)
                Issue.record("\(name) was accepted")
            } catch {
                #expect(error.status == status, "\(name): \(error)")
                #expect(error != .incomplete, "\(name) waited for more")
            }
        }
    }

    @Test func httpWaitsForTheWholeHeadAndNeverMore() {
        let full = head(["CONNECT example.com:443 HTTP/1.1", "Host: example.com:443", "User-Agent: test"])
        for cut in 0..<full.count {
            do throws(LinkDoorHTTP.Failure) {
                _ = try ExitRelayHTTP.parse(full.prefix(cut))
                Issue.record("accepted \(cut) bytes")
            } catch {
                #expect(error == .incomplete, "\(cut) bytes: \(error)")
            }
        }
        // An endless head is cut off at the limit rather than waited for.
        do throws(LinkDoorHTTP.Failure) {
            _ = try ExitRelayHTTP.parse(Data(("CONNECT a.com:443 HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)).utf8))
            Issue.record("accepted an endless head")
        } catch { #expect(error == .headTooLarge) }
    }

    @Test func httpSurvivesRandomAndMutatedInput() {
        var generator = SeededBytes(seed: 0x5EED)
        let valid = Array(head(["CONNECT example.com:443 HTTP/1.1", "Host: example.com:443"]))
        var accepted = 0
        for round in 0..<4000 {
            var bytes: [UInt8]
            if round % 2 == 0 {
                bytes = (0..<generator.next(upTo: 300)).map { _ in UInt8(generator.next(upTo: 256)) }
            } else {
                bytes = valid
                for _ in 0..<(1 + generator.next(upTo: 4)) {
                    let at = generator.next(upTo: bytes.count)
                    switch generator.next(upTo: 3) {
                    case 0: bytes[at] = UInt8(generator.next(upTo: 256))
                    case 1: bytes.remove(at: at)
                    default: bytes.insert(UInt8(generator.next(upTo: 256)), at: at)
                    }
                }
            }
            do throws(LinkDoorHTTP.Failure) {
                let request = try ExitRelayHTTP.parse(Data(bytes))
                accepted += 1
                #expect(request.target.port > 0)
                if case .name(let name) = request.target.host { #expect(ExitRelayTarget.name(Substring(name)) == name) }
            } catch {}
        }
        #expect(accepted < 4000)
    }

    // MARK: SOCKS parser

    @Test func socksReadsGreetingAndConnect() throws {
        #expect(try ExitRelaySOCKS.greeting(Data()) == nil)
        #expect(try ExitRelaySOCKS.greeting(Data([5])) == nil)
        #expect(try ExitRelaySOCKS.greeting(Data([5, 2, 0])) == nil)
        #expect(try ExitRelaySOCKS.greeting(Data([5, 2, 2, 0]))! == (4, true))
        #expect(try ExitRelaySOCKS.greeting(Data([5, 1, 2]))! == (3, false))

        let domain = Data([5, 1, 0, 3, 11] + Array("example.com".utf8) + [1, 187])
        for cut in 0..<domain.count { #expect(try ExitRelaySOCKS.request(domain.prefix(cut)) == nil, "\(cut) bytes") }
        let parsed = try #require(try ExitRelaySOCKS.request(domain + Data([9, 9])))
        #expect(parsed.target == ExitRelayTarget(host: .name("example.com"), port: 443))
        #expect(parsed.length == domain.count)

        let four = try #require(try ExitRelaySOCKS.request(Data([5, 1, 0, 1, 1, 1, 1, 1, 0, 80])))
        #expect(four.target == ExitRelayTarget(host: .address([1, 1, 1, 1]), port: 80))
        let six = try #require(try ExitRelaySOCKS.request(Data([5, 1, 0, 4] + v6("2606:4700:4700::1111") + [1, 187])))
        #expect(six.target == ExitRelayTarget(host: .address(v6("2606:4700:4700::1111")), port: 443))
        // A name that is really an address is judged as one.
        let disguised = try #require(try ExitRelaySOCKS.request(Data([5, 1, 0, 3, 8] + Array("10.0.0.1".utf8) + [1, 187])))
        #expect(disguised.target.host == .address([10, 0, 0, 1]))
        let mapped = try #require(try ExitRelaySOCKS.request(Data([5, 1, 0, 3, 3] + Array("::1".utf8) + [1, 187])))
        #expect(mapped.target.host == .address(v6("::1")))
    }

    @Test func socksRefusesWhatItDoesNotSpeak() {
        func request(_ bytes: [UInt8]) -> ExitRelaySOCKS.Failure? {
            do throws(ExitRelaySOCKS.Failure) { _ = try ExitRelaySOCKS.request(Data(bytes)); return nil } catch { return error }
        }
        #expect(request([5, 2, 0, 1, 1, 1, 1, 1, 0, 80]) == .command)        // BIND
        #expect(request([5, 3, 0, 1, 1, 1, 1, 1, 0, 80]) == .command)        // UDP ASSOCIATE
        #expect(request([5, 1, 0, 9, 1, 1, 1, 1, 0, 80]) == .addressType)
        #expect(request([5, 1, 1, 1, 1, 1, 1, 1, 0, 80]) == .malformed)      // reserved byte
        #expect(request([4, 1, 0, 1, 1, 1, 1, 1, 0, 80]) == .malformed)      // SOCKS4
        #expect(request([4]) == .malformed)
        #expect(request([5, 1, 0, 1, 1, 1, 1, 1, 0, 0]) == .malformed)       // port 0
        #expect(request([5, 1, 0, 3, 0, 0, 80]) == .malformed)               // empty name
        #expect(request([5, 1, 0, 3, 3] + Array("a b".utf8) + [0, 80]) == .malformed)
        #expect(request([5, 1, 0, 3, 4] + [0xC3, 0xA9, 0x61, 0x61] + [0, 80]) == .malformed)
        #expect(request([5, 1, 0, 3, 5] + Array("a..bc".utf8) + [0, 80]) == .malformed)
        do throws(ExitRelaySOCKS.Failure) { _ = try ExitRelaySOCKS.greeting(Data([4, 1, 0])); Issue.record("SOCKS4 greeted") } catch {}
        do throws(ExitRelaySOCKS.Failure) { _ = try ExitRelaySOCKS.greeting(Data([5, 0])); Issue.record("no methods greeted") } catch {}
        #expect(ExitRelaySOCKS.reply(.notAllowed) == Data([5, 2, 0, 1, 0, 0, 0, 0, 0, 0]))
    }

    @Test func socksSurvivesRandomInput() {
        var generator = SeededBytes(seed: 0xB0B)
        for _ in 0..<4000 {
            var bytes: [UInt8] = [5]
            bytes += (0..<generator.next(upTo: 270)).map { _ in UInt8(generator.next(upTo: 256)) }
            do throws(ExitRelaySOCKS.Failure) {
                if let found = try ExitRelaySOCKS.request(Data(bytes)) {
                    #expect(found.target.port > 0 && found.length <= bytes.count)
                }
                _ = try ExitRelaySOCKS.greeting(Data(bytes))
            } catch {}
        }
    }

    // MARK: The whole relay

    @Test func connectReachesTheAllowedUpstreamByAddressAndByName() async throws {
        let fixture = try await RelayFixture.start()
        defer { fixture.stop() }
        let port = fixture.upstream.port
        let byAddress = try await RelayClient.exchange(fixture.port, Data("CONNECT 127.0.0.1:\(port) HTTP/1.1\r\nHost: x\r\n\r\nhello".utf8),
                                                       until: "HTTP/1.1 200 Connection established\r\n\r\nhello")
        #expect(byAddress == "HTTP/1.1 200 Connection established\r\n\r\nhello")
        let byName = try await RelayClient.exchange(fixture.port, Data("CONNECT upstream.test:\(port) HTTP/1.1\r\n\r\nagain".utf8),
                                                    until: "HTTP/1.1 200 Connection established\r\n\r\nagain")
        #expect(byName.hasSuffix("again"))
        #expect(fixture.upstream.connections == 2)
        #expect(fixture.relay.counts.served == 2)
    }

    @Test func refusedDestinationsNeverOpenAConnection() async throws {
        let fixture = try await RelayFixture.start()
        defer { fixture.stop() }
        let port = fixture.upstream.port
        let refused = ["10.0.0.1:443", "192.168.64.1:443", "169.254.169.254:80", "[::1]:\(port)", "[fe80::1]:443",
                       "[::ffff:127.0.0.1]:\(port)", "127.0.0.1:\(port + 1)", "mixed.test:443", "private.test:443",
                       "localhost.test:\(port)", "nowhere.test:443", "1.1.1.1:25", "1.1.1.1:22"]
        for target in refused {
            let answer = try await RelayClient.exchange(fixture.port, Data("CONNECT \(target) HTTP/1.1\r\n\r\n".utf8))
            #expect(answer.hasPrefix("HTTP/1.1 403 "), "\(target): \(answer)")
            #expect(!answer.contains(target.split(separator: ":")[0]), "the answer named the destination")
        }
        #expect(fixture.upstream.connections == 0)
        #expect(fixture.relay.counts.refusedDestinations == refused.count)
        #expect(fixture.relay.counts.served == 0)
    }

    @Test func plainHTTPIsForwardedInOriginFormWithoutProxyHeaders() async throws {
        let fixture = try await RelayFixture.start()
        defer { fixture.stop() }
        let port = fixture.upstream.port
        let request = "GET http://127.0.0.1:\(port)/hello?x=1 HTTP/1.1\r\nHost: elsewhere.example\r\nProxy-Authorization: Basic eDp5\r\nProxy-Connection: keep-alive\r\nUser-Agent: test\r\n\r\n"
        let answer = try await RelayClient.exchange(fixture.port, Data(request.utf8))
        #expect(answer.hasPrefix("HTTP/1.1 200 OK"))
        #expect(answer.contains("GET /hello?x=1 HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUser-Agent: test\r\nConnection: close\r\n\r\n"))
        #expect(!answer.contains("Proxy-") && !answer.contains("elsewhere"))
    }

    @Test func socksConnectsAndRefusesLikeHTTP() async throws {
        let fixture = try await RelayFixture.start()
        defer { fixture.stop() }
        let port = fixture.upstream.port
        let hi = UInt8(port >> 8), lo = UInt8(port & 0xFF)
        let ok = try await RelayClient.exchangeBytes(fixture.port, Data([5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, hi, lo] + Array("ping".utf8)), count: 2 + 10 + 4)
        #expect(Array(ok) == [5, 0, 5, 0, 0, 1, 0, 0, 0, 0, 0, 0] + Array("ping".utf8))
        // Split into single bytes, it still works.
        let slow = try await RelayClient.exchangeBytes(fixture.port, Data([5, 1, 0, 5, 1, 0, 3, 13] + Array("upstream.test".utf8) + [hi, lo]),
                                                       count: 12, oneByteAtATime: true)
        #expect(Array(slow) == [5, 0, 5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        let privateName = try await RelayClient.exchangeBytes(fixture.port, Data([5, 1, 0, 5, 1, 0, 3, 10] + Array("mixed.test".utf8) + [1, 187]), count: 12)
        #expect(Array(privateName) == [5, 0, 5, 2, 0, 1, 0, 0, 0, 0, 0, 0])
        let bind = try await RelayClient.exchangeBytes(fixture.port, Data([5, 1, 0, 5, 2, 0, 1, 1, 1, 1, 1, 0, 80]), count: 12)
        #expect(Array(bind) == [5, 0, 5, 7, 0, 1, 0, 0, 0, 0, 0, 0])
        let udp = try await RelayClient.exchangeBytes(fixture.port, Data([5, 1, 0, 5, 3, 0, 1, 1, 1, 1, 1, 0, 80]), count: 12)
        #expect(Array(udp) == [5, 0, 5, 7, 0, 1, 0, 0, 0, 0, 0, 0])
        let password = try await RelayClient.exchangeBytes(fixture.port, Data([5, 1, 2]), count: 2)
        #expect(Array(password) == [5, 0xFF])
        #expect(fixture.upstream.connections == 2)
    }

    @Test func malformedAndOversizedRequestsAreAnsweredAndClosed() async throws {
        let fixture = try await RelayFixture.start()
        defer { fixture.stop() }
        let garbage = try await RelayClient.exchange(fixture.port, Data("HELLO\r\n\r\n".utf8))
        #expect(garbage.hasPrefix("HTTP/1.1 400 "))
        let huge = try await RelayClient.exchange(fixture.port, Data(("CONNECT a.com:443 HTTP/1.1\r\nX: " + String(repeating: "a", count: 40_000)).utf8))
        #expect(huge.hasPrefix("HTTP/1.1 431 "))
        #expect(fixture.relay.counts.malformed == 2)
        #expect(fixture.upstream.connections == 0)
    }

    @Test func theMacItselfAndOtherSourcesAreTurnedAway() async throws {
        // A real relay's rule: the listener's own address is not a VM. Loopback here is the Mac.
        let fixture = try await RelayFixture.start(loopbackClients: false)
        defer { fixture.stop() }
        let answer = try await RelayClient.exchange(fixture.port, Data("CONNECT 127.0.0.1:\(fixture.upstream.port) HTTP/1.1\r\n\r\n".utf8))
        #expect(answer.isEmpty)
        #expect(fixture.relay.counts.refusedSources == 1)
        #expect(fixture.upstream.connections == 0)
    }

    @Test func quietConnectionsAndSlowRequestsAreClosed() async throws {
        let fixture = try await RelayFixture.start { $0.idleTimeout = 0.4; $0.setupTimeout = 0.4 }
        defer { fixture.stop() }
        let start = Date()
        let slow = try await RelayClient.exchange(fixture.port, Data("CONNECT 127.0.0.1:1".utf8), timeout: 5)
        #expect(slow.isEmpty && Date().timeIntervalSince(start) < 4)
        let quiet = try await RelayClient.exchange(fixture.port, Data("CONNECT 127.0.0.1:\(fixture.upstream.port) HTTP/1.1\r\n\r\n".utf8), timeout: 5)
        #expect(quiet == "HTTP/1.1 200 Connection established\r\n\r\n")
        #expect(Date().timeIntervalSince(start) < 8)
        #expect(fixture.relay.counts.open == 0)
    }

    @Test func tooManyConnectionsAreRefused() async throws {
        let fixture = try await RelayFixture.start { $0.maximumConnections = 2 }
        defer { fixture.stop() }
        let first = try await RelayClient.open(fixture.port)
        let second = try await RelayClient.open(fixture.port)
        defer { first.cancel(); second.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        let third = try await RelayClient.exchange(fixture.port, Data("CONNECT 127.0.0.1:\(fixture.upstream.port) HTTP/1.1\r\n\r\n".utf8))
        #expect(third.isEmpty)
        #expect(fixture.relay.counts.refusedBusy == 1)
    }

    @Test func repeatedUpstreamFailuresMeanItCannotConnect() async throws {
        // The allowed upstream is closed: every attempt fails.
        let fixture = try await RelayFixture.start(upstreamOpen: false)
        defer { fixture.stop() }
        for _ in 0..<3 {
            let answer = try await RelayClient.exchange(fixture.port, Data("CONNECT 127.0.0.1:\(fixture.upstream.port) HTTP/1.1\r\n\r\n".utf8))
            #expect(answer.hasPrefix("HTTP/1.1 502 "))
        }
        #expect(fixture.relay.cannotConnect)
        #expect(fixture.relay.counts.upstreamFailures == 3)
    }
}

// MARK: Fixtures

/// A deterministic byte source for the fuzz-style tests.
private struct SeededBytes {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(upTo bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return bound <= 0 ? 0 : Int((state >> 33) % UInt64(bound))
    }
}

private final class RelayBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

/// A relay on 127.0.0.1 in front of a fake website. The test allowance lets loopback clients in
/// and lets exactly the fake website's address and port through; names resolve from a fixed table.
private struct RelayFixture {
    let relay: ExitRelay
    let upstream: FakeWebsite
    let port: Int

    static func start(loopbackClients: Bool = true, upstreamOpen: Bool = true,
                      tune: (inout ExitRelay.Configuration) -> Void = { _ in }) async throws -> RelayFixture {
        let upstream = try await FakeWebsite.start()
        if !upstreamOpen { upstream.stop() }
        let loopback = ExitRelayPolicy.Network(interface: "lo0", address: [127, 0, 0, 1], mask: [255, 0, 0, 0])
        var configuration = ExitRelay.Configuration(network: loopback, port: 0)
        configuration.testLoopbackClients = loopbackClients
        configuration.testUpstream = ([127, 0, 0, 1], UInt16(upstream.port))
        tune(&configuration)
        let names: [String: [[UInt8]]] = [
            "upstream.test": [[127, 0, 0, 1]],
            "mixed.test": [[93, 184, 216, 34], [10, 0, 0, 5]],
            "private.test": [[192, 168, 1, 1]],
            "localhost.test": [Array(IPv6Address("::1")!.rawValue), [127, 0, 0, 1]],
        ]
        let relay = ExitRelay(configuration: configuration, resolver: { name, _ in names[name] }, ownAddresses: { [] })
        let port = try await relay.start()
        return RelayFixture(relay: relay, upstream: upstream, port: Int(port))
    }

    func stop() {
        relay.stop()
        upstream.stop()
    }
}

/// Answers a plain HTTP request with what it received; echoes anything else.
private final class FakeWebsite: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "nollie.tests.fake-website")
    private let count = RelayBox(0)
    private(set) var port = 0
    var connections: Int { count.withLock { $0 } }

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> FakeWebsite {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let fake = FakeWebsite(listener: try NWListener(using: parameters))
        fake.listener.newConnectionHandler = { [weak fake] connection in fake?.serve(connection) }
        fake.port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let once = RelayBox(Optional(continuation))
            fake.listener.stateUpdateHandler = { [weak fake] state in
                switch state {
                case .ready: once.withLock { $0?.resume(returning: Int(fake?.listener.port?.rawValue ?? 0)); $0 = nil }
                case .failed(let error): once.withLock { $0?.resume(throwing: error); $0 = nil }
                default: break
                }
            }
            fake.listener.start(queue: fake.queue)
        }
        return fake
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

/// A plain TCP client standing in for a helper's computer.
private enum RelayClient {
    static func open(_ port: Int) async throws -> NWConnection {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let queue = DispatchQueue(label: "nollie.tests.relay-open")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWConnection, Error>) in
            let once = RelayBox(Optional(continuation))
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.withLock { $0?.resume(returning: connection); $0 = nil }
                case .failed(let error), .waiting(let error): once.withLock { $0?.resume(throwing: error); $0 = nil }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Sends, then reads until the relay closes, `until` has arrived, or the timeout.
    static func exchange(_ port: Int, _ data: Data, until: String? = nil, timeout: TimeInterval = 5) async throws -> String {
        let bytes = try await exchangeBytes(port, data, count: nil, until: until.map { Data($0.utf8) }, timeout: timeout)
        return String(decoding: bytes, as: UTF8.self)
    }

    static func exchangeBytes(_ port: Int, _ data: Data, count: Int?, until: Data? = nil, oneByteAtATime: Bool = false,
                              timeout: TimeInterval = 5) async throws -> Data {
        let connection = try await open(port)
        defer { connection.cancel() }
        let queue = DispatchQueue(label: "nollie.tests.relay-exchange")
        if oneByteAtATime {
            for byte in data {
                connection.send(content: Data([byte]), completion: .contentProcessed { _ in })
                try await Task.sleep(for: .milliseconds(5))
            }
        } else {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            let state = RelayBox((Optional(continuation), Data()))
            @Sendable func finish() { state.withLock { $0.0?.resume(returning: $0.1); $0.0 = nil } }
            @Sendable func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                    let done = state.withLock { value -> Bool in
                        if let data { value.1.append(data) }
                        if let count, value.1.count >= count { return true }
                        if let until, value.1 == until { return true }
                        return complete || error != nil
                    }
                    if done { finish() } else { read() }
                }
            }
            read()
            queue.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }
}
#endif
