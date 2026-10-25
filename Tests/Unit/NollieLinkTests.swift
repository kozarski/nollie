import Foundation
import Testing
@testable import NollieCore

/// The phone's side of Nollie Link, without a network: the QR offer, finding the Mac and how a
/// linked connection signs its requests. The door itself is covered in NollieLinkDoorTests.
struct NollieLinkTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let pin = Data(repeating: 7, count: 32)
    private let secret = Data((0..<32).map { UInt8($0) })

    private func offer(name: String = "Studio Mac", hosts: [String] = ["192.168.1.20", "studio.local"],
                       port: Int = 52_345, expires: TimeInterval = 120) throws -> NollieLinkOffer {
        try NollieLinkOffer(macName: name, pin: pin, port: port, hosts: hosts, installTag: "0123456789abcdef",
                            secret: secret, expiresAt: now.addingTimeInterval(expires), now: now)
    }

    @Test func offerRoundTripsThroughItsUniversalLink() throws {
        let made = try offer()
        let link = made.urlString
        #expect(link.hasPrefix("https://nollie.app/pair#"))
        // Everything after the fragment marker stays on the device that opens the link.
        #expect(made.url.query == nil)
        #expect(made.url.path == "/pair")
        let parsed = try NollieLinkOffer.parse(link, now: now)
        #expect(parsed == made)
        #expect(parsed.secret == secret)
        #expect(!String(describing: parsed).contains(NollieLinkOffer.base64URL(secret)))
        #expect(!"\(parsed)".contains("Studio"))
    }

    @Test func offerRejectsTamperingAndOtherCodes() throws {
        let link = try offer().urlString
        let fragment = String(link.dropFirst(NollieLinkOffer.prefix.count))
        let bad = [
            "", "nollie://pair#" + fragment, "http://nollie.app/pair#" + fragment, "https://nollie.app.evil.test/pair#" + fragment,
            "https://nollie.app/pair?x=1#" + fragment, "https://nollie.app/other#" + fragment, "https://nollie.app/pair#",
            "https://nollie.app/pair#" + fragment + "!", "https://nollie.app:444/pair#" + fragment,
            "https://user@nollie.app/pair#" + fragment, String(repeating: "a", count: 3000),
        ]
        for raw in bad { #expect(throws: NollieLinkError.invalidOffer) { try NollieLinkOffer.parse(raw, now: now) } }

        func encode(_ object: [String: Any]) -> String {
            NollieLinkOffer.prefix + NollieLinkOffer.base64URL(try! JSONSerialization.data(withJSONObject: object))
        }
        let good: [String: Any] = ["v": 1, "n": "Studio Mac", "k": NollieLinkOffer.base64URL(pin), "p": 52_345,
                                   "h": ["192.168.1.20"], "t": "0123456789abcdef", "s": NollieLinkOffer.base64URL(secret),
                                   "e": Int(now.timeIntervalSince1970) + 60]
        #expect(try NollieLinkOffer.parse(encode(good), now: now).hosts == ["192.168.1.20"])
        var extra = good; extra["x"] = 1
        var version = good; version["v"] = 2
        var shortPin = good; shortPin["k"] = NollieLinkOffer.base64URL(Data(repeating: 1, count: 16))
        var shortSecret = good; shortSecret["s"] = NollieLinkOffer.base64URL(Data(repeating: 1, count: 31))
        var lowPort = good; lowPort["p"] = 80
        var tag = good; tag["t"] = "ABCDEF0123456789"
        var name = good; name["n"] = "Mac\u{202E}cam"
        var noHosts = good; noHosts["h"] = [String]()
        var missing = good; missing.removeValue(forKey: "s")
        for object in [extra, version, shortPin, shortSecret, lowPort, tag, name, noHosts, missing] {
            #expect(throws: NollieLinkError.invalidOffer) { try NollieLinkOffer.parse(encode(object), now: now) }
        }
    }

    @Test func offerExpiresAndRefusesFarFutureCodes() throws {
        #expect(throws: NollieLinkError.expired) { try offer(expires: -61) }
        _ = try offer(expires: -30)  // a phone clock a little ahead of the Mac's still reads it
        #expect(throws: NollieLinkError.invalidOffer) { try offer(expires: 601) }
        let link = try offer().urlString
        #expect(throws: NollieLinkError.expired) { try NollieLinkOffer.parse(link, now: now.addingTimeInterval(200)) }
    }

    @Test func offerHostsArePrivateOnly() {
        for host in ["10.0.0.4", "172.20.1.1", "192.168.0.2", "100.101.102.103", "169.254.3.4", "studio.local",
                     "corey-mac.tail1234.ts.net"] {
            #expect(NollieLinkOffer.validHost(host), "\(host)")
        }
        for host in ["8.8.8.8", "127.0.0.1", "0.0.0.0", "172.32.0.1", "100.128.0.1", "example.com", "Studio.local",
                     "studio.local.evil.com", "-bad.local", "a..local", "10.0.0", "1.2.3.4.5", "studio .local", "", "::1"] {
            #expect(!NollieLinkOffer.validHost(host), "\(host)")
        }
        #expect(throws: NollieLinkError.invalidOffer) { try offer(hosts: ["8.8.8.8"]) }
        #expect(throws: NollieLinkError.invalidOffer) { try offer(hosts: Array(repeating: "10.0.0.1", count: 2)) }
    }

    @Test func missingPinFallsBackToSystemTrustAndMissingTrustIsRefused() {
        #expect(NollieLinkPin.disposition(for: nil, pin: nil) == .performDefaultHandling)
        #expect(NollieLinkPin.disposition(for: nil, pin: pin) == .cancelAuthenticationChallenge)
    }

    /// One pin per address, owned by one saved connection: replaced by a newer link, gone
    /// when that connection is removed, never added to.
    @Test func savedLinksReplaceAndForgetTheirPins() {
        let trust = GatewayTrust()
        let first = UUID(), second = UUID()
        let other = Data(repeating: 8, count: 32)
        #expect(trust.pin(host: "192.168.1.20", port: 52_345) == nil)
        trust.register(LinkedMac(macName: "Studio", pin: pin, port: 52_345, hosts: ["192.168.1.20"], installTag: "0123456789abcdef",
                                 deviceID: UUID()), hosts: ["10.0.0.9"], owner: first)
        #expect(trust.pin(host: "192.168.1.20", port: 52_345) == pin)
        #expect(trust.pin(host: "[10.0.0.9]", port: 52_345) == pin)
        #expect(trust.pin(host: "192.168.1.20", port: 443) == nil)
        // A Mac linked later at the same address takes it over; the old pin no longer passes.
        trust.register(pin: other, host: "192.168.1.20", port: 52_345, owner: second)
        #expect(trust.pin(host: "192.168.1.20", port: 52_345) == other)
        trust.forget(owner: first)
        #expect(trust.pin(host: "10.0.0.9", port: 52_345) == nil)
        #expect(trust.pin(host: "192.168.1.20", port: 52_345) == other)
        trust.forget(owner: second)
        #expect(trust.pin(host: "192.168.1.20", port: 52_345) == nil)
        trust.register(pin: Data(repeating: 1, count: 31), host: "10.0.0.10", port: 52_345, owner: first)
        #expect(trust.pin(host: "10.0.0.10", port: 52_345) == nil)
    }

    @Test func resolverTriesLastGoodThenBonjourThenCodeAddresses() async {
        let link = LinkedMac(macName: "Studio", pin: pin, port: 52_345, hosts: ["192.168.1.20", "10.0.0.5", "studio.local"],
                             installTag: "0123456789abcdef", deviceID: UUID())
        let asked = LinkTestBox<[String]>([])
        func resolver(answering: Set<String>, bonjour: String?) -> NollieLinkResolver {
            NollieLinkResolver(probe: { host, port, pin in
                asked.withLock { $0.append(host) }
                return port == 52_345 && pin == self.pin && answering.contains(host)
            }, discover: { tag, _ in
                asked.withLock { $0.append("bonjour:" + tag) }
                return bonjour
            })
        }
        #expect(await resolver(answering: ["10.0.0.5"], bonjour: nil).resolve(link, lastGood: "10.0.0.5") == "10.0.0.5")
        #expect(asked.withLock { $0 } == ["10.0.0.5"])

        asked.withLock { $0 = [] }
        #expect(await resolver(answering: [], bonjour: "192.168.1.77").resolve(link, lastGood: "10.0.0.5") == "192.168.1.77")
        #expect(asked.withLock { $0 } == ["10.0.0.5", "bonjour:0123456789abcdef"])

        asked.withLock { $0 = [] }
        let found = await resolver(answering: ["studio.local", "10.0.0.5"], bonjour: nil).resolve(link, lastGood: "192.168.1.20")
        #expect(found == "10.0.0.5")  // the code's order, not whichever answered first
        #expect(Set(asked.withLock { $0 }) == ["192.168.1.20", "bonjour:0123456789abcdef", "10.0.0.5", "studio.local"])

        #expect(await resolver(answering: [], bonjour: "fe80::1%en0").resolve(link, lastGood: nil) == nil)
    }

    @Test func linkedConnectionSendsItsCredentialOnEveryRequest() {
        let linked = RequestSigner(authMode: .sessionToken, secrets: .init(sessionToken: "device", linkedDevice: true))
        #expect(linked.publicHeaders[RequestSigner.sessionTokenHeader] == "device")
        var request = URLRequest(url: URL(string: "https://192.168.1.20:52345/api/status")!)
        linked.apply(to: &request, includeCredential: false)
        #expect(request.value(forHTTPHeaderField: RequestSigner.sessionTokenHeader) == "device")
        let ordinary = RequestSigner(authMode: .sessionToken, secrets: .init(sessionToken: "token"))
        #expect(ordinary.publicHeaders[RequestSigner.sessionTokenHeader] == nil)
    }

    @Test func linkedEndpointMovesOnlyWithinItsOwnDoor() throws {
        let link = LinkedMac(macName: "Studio", pin: pin, port: 52_345, hosts: ["192.168.1.20"], installTag: "0123456789abcdef", deviceID: UUID())
        let connection = GatewayConnection(name: "Studio", gateway: try link.gateway(host: "192.168.1.20"), authMode: .sessionToken, linkedMac: link)
        #expect(connection.gateway.description == "https://192.168.1.20:52345")
        #expect(connection.updatingLinkedEndpoint(try link.gateway(host: "10.0.0.5"))?.gateway.host == "10.0.0.5")
        #expect(connection.updatingLinkedEndpoint(try GatewayURL.normalize("https://10.0.0.5:443")) == nil)
        #expect(connection.updatingLinkedEndpoint(try GatewayURL.normalize("http://10.0.0.5:52345")) == nil)
        var plain = connection
        plain.linkedMac = nil
        #expect(plain.updatingLinkedEndpoint(try link.gateway(host: "10.0.0.5")) == nil)
        // Saved metadata from before Nollie Link still decodes.
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(connection)) as! [String: Any]
        object.removeValue(forKey: "linkedMac")
        let old = try JSONDecoder().decode(GatewayConnection.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.linkedMac == nil)
        let secrets = try JSONDecoder().decode(GatewaySecrets.self, from: Data(#"{"sessionToken":"t","access":{"clientId":"","clientSecret":""}}"#.utf8))
        #expect(secrets.linkedDevice == nil)
    }
}

/// A locked value that escaping test closures may share.
private final class LinkTestBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
