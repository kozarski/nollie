#if os(macOS)
import Foundation
import Network
import Testing

/// The door's live stream: its send gate, its answer to the upgrade, and the whole stream on
/// loopback, with a pretend Mac app as the provider and a phone written by hand.
struct LinkDoorLiveTests {
    // MARK: The send gate

    private func bytes(_ count: Int, _ tag: UInt8) -> Data { Data(repeating: tag, count: count) }

    @Test func oneVideoMessageIsInFlightAtATime() {
        let gate = GateProbe()
        let k1 = bytes(10, 1), d2 = bytes(5, 2), d3 = bytes(4, 3)
        #expect(gate.video(k1, keyframe: true) == .send(k1))
        #expect(gate.inFlight)
        #expect(gate.video(d2, keyframe: false) == .held)
        #expect(gate.videoTaken() == d2)
        #expect(gate.inFlight)
        #expect(gate.videoTaken() == nil)
        #expect(!gate.inFlight)
        #expect(gate.video(d3, keyframe: false) == .send(d3))
        #expect(!gate.takeKeyframeRequest())
        #expect(gate.second(heard: false) == .init(sent: 3, withheld: 0, taken: 15, waiting: 4, heard: false))
    }

    @Test func theNewestKeyframeTakesAWaitingFramesPlace() {
        let gate = GateProbe()
        let k1 = bytes(8, 1), k2 = bytes(8, 2), k3 = bytes(8, 3)
        #expect(gate.video(k1, keyframe: true) == .send(k1))
        #expect(gate.video(k2, keyframe: true) == .held)
        #expect(gate.video(k3, keyframe: true) == .held)
        #expect(gate.videoTaken() == k3)
        // A waiting delta gives way to a newer keyframe too, and nothing more is needed.
        let d4 = bytes(3, 4), k5 = bytes(9, 5)
        #expect(gate.video(d4, keyframe: false) == .held)
        #expect(gate.video(k5, keyframe: true) == .held)
        #expect(gate.videoTaken() == k5)
        #expect(gate.videoTaken() == nil)
        #expect(!gate.takeKeyframeRequest())
        let second = gate.second(heard: true)
        #expect(second.sent == 3 && second.withheld == 2 && second.heard)
    }

    @Test func aDroppedDeltaWithholdsTheRestUntilAKeyframeAndAsksOnce() {
        let gate = GateProbe()
        let k1 = bytes(10, 1), d2 = bytes(2, 2)
        #expect(gate.video(k1, keyframe: true) == .send(k1))
        #expect(gate.video(d2, keyframe: false) == .held)
        // A delta can't skip the one waiting before it.
        #expect(gate.video(bytes(2, 3), keyframe: false) == .withheld)
        #expect(gate.takeKeyframeRequest())
        #expect(gate.video(bytes(2, 4), keyframe: false) == .withheld)
        #expect(!gate.takeKeyframeRequest())
        #expect(gate.videoTaken() == d2)
        #expect(gate.videoTaken() == nil)
        // Even with the connection free, deltas wait for the keyframe.
        #expect(gate.video(bytes(2, 5), keyframe: false) == .withheld)
        #expect(!gate.takeKeyframeRequest())
        let k6 = bytes(10, 6), d7 = bytes(2, 7)
        #expect(gate.video(k6, keyframe: true) == .send(k6))
        #expect(gate.video(d7, keyframe: false) == .held)
        #expect(!gate.takeKeyframeRequest())
        #expect(gate.second(heard: false) == .init(sent: 3, withheld: 3, taken: 12, waiting: 12, heard: false))
        // The next gap asks again, once.
        #expect(gate.video(bytes(2, 8), keyframe: false) == .withheld)
        #expect(gate.takeKeyframeRequest())
        #expect(!gate.takeKeyframeRequest())
    }

    @Test func textIsNeverDroppedButOnlySoMuchMayWait() {
        let gate = GateProbe()
        #expect(gate.video(bytes(100, 1), keyframe: true) == .send(bytes(100, 1)))
        #expect(gate.video(bytes(50, 2), keyframe: false) == .held)
        for index in 0..<LinkDoorLiveGate.textLimit {
            #expect(gate.text(bytes(10, UInt8(index))) == .send(bytes(10, UInt8(index))))
        }
        #expect(gate.text(bytes(10, 99)) == .overflow)
        gate.textTaken()
        #expect(gate.text(bytes(10, 99)) == .send(bytes(10, 99)))
        #expect(gate.text(bytes(10, 100)) == .overflow)
        // Text never takes a video message's place.
        #expect(gate.videoTaken() == bytes(50, 2))
        let second = gate.second(heard: false)
        #expect(second.sent == 2 && second.withheld == 0)
        #expect(second.taken == 110 && second.waiting == 50 + 32 * 10)
    }

    @Test func eachSecondCountsWhatWasSentWithheldTakenAndWaiting() {
        let gate = GateProbe()
        _ = gate.video(bytes(1000, 1), keyframe: true)
        _ = gate.video(bytes(300, 2), keyframe: false)
        _ = gate.video(bytes(300, 3), keyframe: false)
        _ = gate.text(bytes(40, 4))
        gate.textTaken()
        let first = gate.second(heard: true)
        #expect(first == .init(sent: 1, withheld: 1, taken: 40, waiting: 1300, heard: true))
        #expect(String(decoding: first.json, as: UTF8.self)
                == #"{"type":"stats","sent":1,"withheld":1,"taken":40,"waiting":1300,"heard":true}"#)
        // A new second starts from nothing but what is still waiting.
        _ = gate.videoTaken()
        _ = gate.videoTaken()
        let next = gate.second(heard: false)
        #expect(next == .init(sent: 1, withheld: 0, taken: 1300, waiting: 0, heard: false))
        let quiet = gate.second(heard: false)
        #expect(String(decoding: quiet.json, as: UTF8.self)
                == #"{"type":"stats","sent":0,"withheld":0,"taken":0,"waiting":0,"heard":false}"#)
    }

    // MARK: The upgrade

    private func upgrade(_ target: String) throws -> LinkDoorHTTP.Request {
        try LinkDoorHTTP.parseRequest(Data(("GET \(target) HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            + "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n").utf8))
    }

    @Test func theDoorAnswersTheUpgradeAndChecksWhichChat() throws {
        // RFC 6455's own example.
        #expect(LinkDoorLive.acceptValue("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        let device = UUID()
        guard case .accept(let head, let request) = LinkDoorLive.upgrade(try upgrade("/nollie/live?profile=career&session_id=20261021_101500_ab.c-d"), device: device) else {
            Issue.record("refused a good upgrade")
            return
        }
        #expect(request == LinkDoorLiveRequest(profile: "career", sessionID: "20261021_101500_ab.c-d", deviceID: device))
        let text = String(decoding: head, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n") && text.hasSuffix("\r\n\r\n"))
        #expect(text.contains("Upgrade: websocket\r\n") && text.contains("Connection: Upgrade\r\n"))
        #expect(text.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
        #expect(!text.lowercased().contains("extensions") && !text.lowercased().contains("protocol:"))

        let long = "a" + String(repeating: "b", count: 159)
        for good in ["/nollie/live?session_id=s1&profile=default&token=abc", "/nollie/live?profile=\(long)&session_id=S", "/nollie/live?profile=%41&session_id=1"] {
            guard case .accept = LinkDoorLive.upgrade(try upgrade(good), device: device) else { Issue.record("refused: \(good)"); continue }
        }
        let bad = [
            "/nollie/live", "/nollie/live?profile=default", "/nollie/live?session_id=s1",
            "/nollie/live?profile=default&profile=default&session_id=s1", "/nollie/live?profile=default&session_id=s1&session_id=s2",
            "/nollie/live?profile=&session_id=s1", "/nollie/live?profile&session_id=s1", "/nollie/live?profile=default&session_id=",
            "/nollie/live?profile=.hidden&session_id=s1", "/nollie/live?profile=-x&session_id=s1", "/nollie/live?profile=_x&session_id=s1",
            "/nollie/live?profile=a%2Fb&session_id=s1", "/nollie/live?profile=a+b&session_id=s1", "/nollie/live?profile=a%00&session_id=s1",
            "/nollie/live?profile=caf%C3%A9&session_id=s1", "/nollie/live?profile=a&session_id=..", "/nollie/live?profile=a&session_id=s/1",
            "/nollie/live?profile=a\(long)&session_id=s1", "/nollie/live?profile=a&session_id=s1&fresh=1",
            "/nollie/live?Profile=a&session_id=s1", "/nollie/live?profile=a&session_id=s1&token=a&token=b",
        ]
        for target in bad {
            guard case .refuse(let reply) = LinkDoorLive.upgrade(try upgrade(target), device: device) else { Issue.record("accepted: \(target)"); continue }
            #expect(String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 400 "), "\(target)")
        }
        // Encoded separators never become a path, and a slash at the end is no route.
        for target in ["/nollie%2flive", "/nollie/live%2F", "/nollie/live/", "/nollie/./live"] {
            #expect(throws: LinkDoorHTTP.Failure.self, "\(target)") { try upgrade(target) }
        }
    }

    @Test func onlyKeyframeAndReportComeFromThePhone() {
        #expect(LinkDoorLive.phoneMessageType(Data(#"{"type":"keyframe"}"#.utf8)) == "keyframe")
        #expect(LinkDoorLive.phoneMessageType(Data(#"{"type":"report","t":0,"got":12,"shown":12,"late":0,"limit":"none"}"#.utf8)) == "report")
        for text in [#"{"type":"hello"}"#, #"{"type":"stats"}"#, #"{"type":"end","reason":"stopped"}"#, #"{"type":1}"#, "{}",
                     #"[{"type":"keyframe"}]"#, #""keyframe""#, "keyframe", "", #"{"type":"KEYFRAME"}"#] {
            #expect(LinkDoorLive.phoneMessageType(Data(text.utf8)) == nil, "\(text)")
        }
        #expect(String(decoding: LinkDoorLive.endMessage("gone"), as: UTF8.self) == #"{"type":"end","reason":"gone"}"#)
        #expect(String(decoding: LinkDoorLive.endMessage("\"},{\"x"), as: UTF8.self) == #"{"type":"end","reason":"unavailable"}"#)
        #expect(LinkDoorLive.closeCode("stopped") == 1000 && LinkDoorLive.closeCode("refused") == 1008)
        #expect(LinkDoorLive.closeCode("unavailable") == 1013 && LinkDoorLive.closeCode("busy") == 1013)
    }

    // MARK: The whole stream

    private static let hello = #"{"type":"hello","v":1,"kind":"mac","computer":"Studio desktop","source":{"w":1280,"h":800}}"#

    private func linked(_ fixture: DoorFixture) async throws -> (port: Int, credential: String, device: UUID) {
        let door = fixture.door
        let linked = try door.devices.claim(secret: door.devices.makeOffer().secret, name: "Phone")
        try await door.refresh()
        return (Int(try #require(door.port)), linked.credential, linked.device.id)
    }

    @Test(.timeLimit(.minutes(1))) func strangersAreTurnedAwayAndTheProviderIsNeverAsked() async throws {
        let provider = FakeLiveProvider(.feed)
        let fixture = try await DoorFixture.start { $0.liveProvider = provider.provider }
        defer { fixture.stop() }
        let (port, credential, _) = try await linked(fixture)
        let pin = fixture.door.identity.pin
        let query = "/nollie/live?profile=default&session_id=s1"
        for (target, presented) in [(query, nil), (query, String(repeating: "0", count: 64)),
                                    (query + "&token=" + String(repeating: "1", count: 64), nil)] as [(String, String?)] {
            let phone = try await LiveDoorPhone.open(port: port, pin: pin, target: target, credential: presented)
            defer { phone.cancel() }
            #expect(phone.head.hasPrefix("HTTP/1.1 401 "), "\(phone.head)")
        }
        // Linked, but asking wrongly: a bad query, a plain GET, a path the door doesn't own.
        for target in ["/nollie/live?profile=default", "/nollie/live?profile=default&session_id=s1&x=1"] {
            let phone = try await LiveDoorPhone.open(port: port, pin: pin, target: target, credential: credential)
            defer { phone.cancel() }
            #expect(phone.head.hasPrefix("HTTP/1.1 400 "), "\(target)")
        }
        let wrongPath = try await LiveDoorPhone.open(port: port, pin: pin, target: "/api/nollie/live?profile=default&session_id=s1", credential: credential)
        defer { wrongPath.cancel() }
        #expect(wrongPath.head.hasPrefix("HTTP/1.1 403 "))
        let plain = "GET /nollie/live?profile=default&session_id=s1 HTTP/1.1\r\nHost: h\r\nX-Hermes-Session-Token: \(credential)\r\n\r\n"
        #expect(try await RawTLS.exchange(port: port, pin: pin, send: Data(plain.utf8)).hasPrefix("HTTP/1.1 403 "))
        #expect(provider.requests.isEmpty)
        #expect(fixture.hermes.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aLinkedPhoneGetsTheProvidersMessagesIntact() async throws {
        let keyframe = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let delta = Data((0..<200).map { UInt8($0) })
        let provider = FakeLiveProvider(.feed, opening: [(Data(Self.hello.utf8), true, false), (keyframe, false, true), (delta, false, false)])
        let fixture = try await DoorFixture.start { $0.liveProvider = provider.provider }
        defer { fixture.stop() }
        let (port, credential, device) = try await linked(fixture)
        // The credential as the `token` query, as a client that can't set headers sends it.
        let phone = try await LiveDoorPhone.open(port: port, pin: fixture.door.identity.pin,
                                                 target: "/nollie/live?profile=career&session_id=s1&token=\(credential)", credential: nil)
        defer { phone.cancel() }
        #expect(phone.head.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        #expect(phone.head.contains("Sec-WebSocket-Accept: \(LinkDoorLive.acceptValue(phone.key))\r\n"))
        #expect(!phone.head.lowercased().contains("sec-websocket-extensions"))
        #expect(try await phone.next() == .text(Self.hello))
        #expect(try await phone.next() == .binary(keyframe))
        #expect(try await phone.next() == .binary(delta))
        #expect(provider.requests == [LinkDoorLiveRequest(profile: "career", sessionID: "s1", deviceID: device)])
        #expect(fixture.door.liveStreams(for: device) == 1)

        // The phone's keyframe request and report reach the provider as sent, and the next
        // second's stats say a report was heard.
        let report = #"{"type":"report","t":0,"got":2,"shown":2,"late":0,"limit":"none"}"#
        phone.send(text: #"{"type":"keyframe"}"#)
        phone.send(text: report)
        #expect(await NollieLinkDoorTests.eventually { provider.controls(0).contains(report) })
        #expect(provider.controls(0).filter { !$0.hasPrefix(#"{"type":"stats""#) } == [#"{"type":"keyframe"}"#, report])
        #expect(await NollieLinkDoorTests.eventually(seconds: 4) { provider.controls(0).contains { $0.hasPrefix(#"{"type":"stats""#) && $0.hasSuffix(#""heard":true}"#) } })
        #expect(await NollieLinkDoorTests.eventually(seconds: 4) { provider.controls(0).contains(#"{"type":"stats","sent":0,"withheld":0,"taken":0,"waiting":0,"heard":false}"#) })

        // Pings are answered by the door.
        phone.send(LinkDoorWebSocket.frame(opcode: 9, payload: Data([7, 8]), masked: true))
        #expect(try await phone.next() == .pong(Data([7, 8])))

        // Binary from the phone ends the stream: 1003, and the feed is closed once.
        phone.send(LinkDoorWebSocket.frame(opcode: 2, payload: Data([1, 2, 3]), masked: true))
        #expect(try await phone.closeCode() == 1003)
        #expect(await NollieLinkDoorTests.eventually { provider.closes(0) == 1 })
        #expect(await NollieLinkDoorTests.eventually { fixture.door.liveStreams(for: device) == 0 })
        #expect(fixture.hermes.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func whatComesBeforeTheFeedOpensStillReachesIt() async throws {
        // The provider sends a keyframe too big to be taken at once and deltas behind it, then
        // waits before answering. The door must ask for a keyframe, and pass on the phone's
        // report, once the feed is there.
        let keyframe = Data(repeating: 7, count: LinkDoorLive.videoLimit)
        let delta = Data([1, 2, 3])
        let held = DoorTestBox(true)
        let provider = FakeLiveProvider(.feed, opening: [(keyframe, false, true), (delta, false, false), (delta, false, false), (delta, false, false)],
                                        answerHeld: held)
        let fixture = try await DoorFixture.start { $0.liveProvider = provider.provider }
        defer { fixture.stop() }
        let (port, credential, _) = try await linked(fixture)
        let phone = try await LiveDoorPhone.open(port: port, pin: fixture.door.identity.pin,
                                                 target: "/nollie/live?profile=default&session_id=s1", credential: credential)
        defer { phone.cancel() }
        #expect(phone.head.hasPrefix("HTTP/1.1 101 "))
        let report = #"{"type":"report","t":0,"got":0,"shown":0,"late":0,"limit":"none"}"#
        phone.send(text: report)
        try await Task.sleep(for: .milliseconds(300))
        held.withLock { $0 = false }
        #expect(await NollieLinkDoorTests.eventually { provider.controls(0).contains(report) })
        #expect(provider.controls(0).filter { !$0.hasPrefix(#"{"type":"stats""#) } == [#"{"type":"keyframe"}"#, report])
        #expect(try await phone.next() == .binary(keyframe))
        #expect(try await phone.next() == .binary(delta))
        #expect(fixture.hermes.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func phoneTextMustBeSmallAndKnown() async throws {
        let provider = FakeLiveProvider(.feed, opening: [(Data(Self.hello.utf8), true, false)])
        let fixture = try await DoorFixture.start { $0.liveProvider = provider.provider }
        defer { fixture.stop() }
        let (port, credential, _) = try await linked(fixture)
        let oversized = #"{"type":"report","pad":""# + String(repeating: "x", count: 600) + #""}"#
        let cases: [(String, Data)] = [
            ("oversized", LinkDoorWebSocket.frame(opcode: 1, payload: Data(oversized.utf8), masked: true)),
            ("unknown type", LinkDoorWebSocket.frame(opcode: 1, payload: Data(#"{"type":"hello"}"#.utf8), masked: true)),
            ("not JSON", LinkDoorWebSocket.frame(opcode: 1, payload: Data("keyframe".utf8), masked: true)),
            ("a call", LinkDoorWebSocket.frame(opcode: 1, payload: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8), masked: true)),
        ]
        for (index, (name, frame)) in cases.enumerated() {
            let phone = try await LiveDoorPhone.open(port: port, pin: fixture.door.identity.pin,
                                                     target: "/nollie/live?profile=default&session_id=s1", credential: credential)
            defer { phone.cancel() }
            #expect(try await phone.next() == .text(Self.hello), "\(name)")
            phone.send(frame)
            #expect(try await phone.closeCode() == 1008, "\(name)")
            #expect(await NollieLinkDoorTests.eventually { provider.closes(index) == 1 }, "\(name)")
            #expect(!provider.controls(index).contains { !$0.hasPrefix(#"{"type":"stats""#) }, "\(name)")
        }
        // An unmasked frame is a protocol error.
        let phone = try await LiveDoorPhone.open(port: port, pin: fixture.door.identity.pin,
                                                 target: "/nollie/live?profile=default&session_id=s1", credential: credential)
        defer { phone.cancel() }
        _ = try await phone.next()
        phone.send(LinkDoorWebSocket.frame(opcode: 1, payload: Data(#"{"type":"keyframe"}"#.utf8), masked: false))
        #expect(try await phone.closeCode() == 1002)
        #expect(fixture.hermes.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func removeCutsTheLiveStreamWithinASecond() async throws {
        let provider = FakeLiveProvider(.feed, opening: [(Data(Self.hello.utf8), true, false)])
        let fixture = try await DoorFixture.start { $0.liveProvider = provider.provider }
        defer { fixture.stop() }
        let (port, credential, device) = try await linked(fixture)
        let phone = try await LiveDoorPhone.open(port: port, pin: fixture.door.identity.pin,
                                                 target: "/nollie/live?profile=default&session_id=s1", credential: credential)
        defer { phone.cancel() }
        #expect(try await phone.next() == .text(Self.hello))
        #expect(await NollieLinkDoorTests.eventually { provider.hasFeed(0) })
        let removedAt = ContinuousClock.now
        #expect(try fixture.door.remove(device))
        while let frame = try await phone.next() { Issue.record("still open: \(frame)") }
        #expect(ContinuousClock.now - removedAt < .seconds(1))
        #expect(provider.closes(0) == 1)
        #expect(fixture.door.liveStreams(for: device) == 0)
        // What the provider sends now goes nowhere.
        provider.sink(0)?.send(Data([1]), isText: false, isKeyframe: true)
        #expect(fixture.hermes.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aSecondStreamFromTheSameDeviceReplacesTheFirst() async throws {
        let provider = FakeLiveProvider(.feed, opening: [(Data(Self.hello.utf8), true, false)])
        let fixture = try await DoorFixture.start { $0.liveProvider = provider.provider }
        defer { fixture.stop() }
        let (port, credential, device) = try await linked(fixture)
        let pin = fixture.door.identity.pin
        let first = try await LiveDoorPhone.open(port: port, pin: pin, target: "/nollie/live?profile=default&session_id=s1", credential: credential)
        defer { first.cancel() }
        #expect(try await first.next() == .text(Self.hello))
        let second = try await LiveDoorPhone.open(port: port, pin: pin, target: "/nollie/live?profile=career&session_id=s2", credential: credential)
        defer { second.cancel() }
        #expect(try await second.next() == .text(Self.hello))
        while try await first.next() != nil {}
        #expect(await NollieLinkDoorTests.eventually { provider.closes(0) == 1 })
        #expect(fixture.door.liveStreams(for: device) == 1)
        #expect(provider.requests.map(\.sessionID) == ["s1", "s2"])

        // The newer one carries on, and ends when the door stops.
        second.send(text: #"{"type":"keyframe"}"#)
        #expect(await NollieLinkDoorTests.eventually { provider.controls(1).contains(#"{"type":"keyframe"}"#) })
        fixture.door.stop()
        while try await second.next() != nil {}
        #expect(await NollieLinkDoorTests.eventually { provider.closes(1) == 1 })
        #expect(provider.closes(0) == 1)
        #expect(fixture.hermes.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func streamsEndWithAReasonWhenThereIsNoPicture() async throws {
        // No provider: unavailable, try again later.
        let none = try await DoorFixture.start()
        defer { none.stop() }
        let (port, credential, _) = try await linked(none)
        let alone = try await LiveDoorPhone.open(port: port, pin: none.door.identity.pin,
                                                 target: "/nollie/live?profile=default&session_id=s1", credential: credential)
        defer { alone.cancel() }
        #expect(alone.head.hasPrefix("HTTP/1.1 101 "))
        #expect(try await alone.next() == .text(#"{"type":"end","reason":"unavailable"}"#))
        #expect(try await alone.next() == .close(1013))
        #expect(none.hermes.requests.isEmpty)

        // A provider that refuses (a private bot, another chat) says so; one with nothing to give is unavailable.
        for (mode, reason, code) in [(FakeLiveProvider.Mode.refuse, "refused", UInt16(1008)), (.nothing, "unavailable", 1013)] {
            let provider = FakeLiveProvider(mode)
            let fixture = try await DoorFixture.start { $0.liveProvider = provider.provider }
            defer { fixture.stop() }
            let (port, credential, _) = try await linked(fixture)
            let phone = try await LiveDoorPhone.open(port: port, pin: fixture.door.identity.pin,
                                                     target: "/nollie/live?profile=private&session_id=s1", credential: credential)
            defer { phone.cancel() }
            #expect(try await phone.next() == .text(#"{"type":"end","reason":"\#(reason)"}"#))
            #expect(try await phone.next() == .close(code))
            #expect(provider.requests.count == 1)
            #expect(fixture.hermes.requests.isEmpty)
        }

        // The provider ends a stream it opened: the phone hears why, and the feed is closed.
        let provider = FakeLiveProvider(.feed, opening: [(Data(Self.hello.utf8), true, false)])
        let fixture = try await DoorFixture.start { $0.liveProvider = provider.provider }
        defer { fixture.stop() }
        let (livePort, liveCredential, _) = try await linked(fixture)
        for (sent, heard, code) in [("stopped", "stopped", UInt16(1000)), ("sideways", "unavailable", 1013)] {
            let index = provider.requests.count
            let phone = try await LiveDoorPhone.open(port: livePort, pin: fixture.door.identity.pin,
                                                     target: "/nollie/live?profile=default&session_id=s1", credential: liveCredential)
            defer { phone.cancel() }
            #expect(try await phone.next() == .text(Self.hello))
            #expect(await NollieLinkDoorTests.eventually { provider.hasFeed(index) })
            provider.sink(index)?.end(reason: sent)
            #expect(try await phone.next() == .text(#"{"type":"end","reason":"\#(heard)"}"#))
            #expect(try await phone.next() == .close(code))
            #expect(await NollieLinkDoorTests.eventually { provider.closes(index) == 1 })
        }
        #expect(fixture.hermes.requests.isEmpty)
    }
}

// MARK: Fixtures

/// The gate behind a reference, so each step can sit inside an expectation.
private final class GateProbe {
    private var gate = LinkDoorLiveGate()
    var inFlight: Bool { gate.inFlight }
    func video(_ data: Data, keyframe: Bool) -> LinkDoorLiveGate.Decision { gate.video(data, keyframe: keyframe) }
    func videoTaken() -> Data? { gate.videoTaken() }
    func text(_ data: Data) -> LinkDoorLiveGate.Decision { gate.text(data) }
    func textTaken() { gate.textTaken() }
    func takeKeyframeRequest() -> Bool { gate.takeKeyframeRequest() }
    func second(heard: Bool) -> LinkDoorLiveGate.Second { gate.second(heard: heard) }
}

/// A pretend Mac app: opens a feed (or refuses), sends what the test gave it, and notes what
/// the door hands back.
private final class FakeLiveProvider: @unchecked Sendable {
    enum Mode { case feed, refuse, nothing }
    private struct Stream {
        let request: LinkDoorLiveRequest
        let sink: LinkDoorLiveSink
        var controls: [String] = []
        var closes = 0
        var fed = false
    }
    private let mode: Mode
    private let opening: [(Data, Bool, Bool)]
    /// While true, the provider has sent its opening messages but not yet answered.
    private let answerHeld: DoorTestBox<Bool>?
    private let streams = DoorTestBox<[Stream]>([])

    init(_ mode: Mode, opening: [(Data, Bool, Bool)] = [], answerHeld: DoorTestBox<Bool>? = nil) {
        self.mode = mode
        self.opening = opening
        self.answerHeld = answerHeld
    }

    var provider: LinkDoor.LiveProvider { { [self] request, sink in await open(request, sink) } }
    var requests: [LinkDoorLiveRequest] { streams.withLock { $0.map(\.request) } }
    func controls(_ index: Int) -> [String] { streams.withLock { index < $0.count ? $0[index].controls : [] } }
    func closes(_ index: Int) -> Int { streams.withLock { index < $0.count ? $0[index].closes : 0 } }
    func hasFeed(_ index: Int) -> Bool { streams.withLock { index < $0.count && $0[index].fed } }
    func sink(_ index: Int) -> LinkDoorLiveSink? { streams.withLock { index < $0.count ? $0[index].sink : nil } }

    private func open(_ request: LinkDoorLiveRequest, _ sink: LinkDoorLiveSink) async -> LinkDoorLiveFeed? {
        let index = streams.withLock { $0.append(Stream(request: request, sink: sink)); return $0.count - 1 }
        switch mode {
        case .refuse:
            sink.end(reason: "refused")
            return nil
        case .nothing:
            return nil
        case .feed:
            for (data, isText, isKeyframe) in opening { sink.send(data, isText: isText, isKeyframe: isKeyframe) }
            while answerHeld?.withLock({ $0 }) == true { try? await Task.sleep(for: .milliseconds(10)) }
            streams.withLock { $0[index].fed = true }
            let streams = self.streams
            return LinkDoorLiveFeed(control: { data in streams.withLock { $0[index].controls.append(String(decoding: data, as: UTF8.self)) } },
                                    close: { streams.withLock { $0[index].closes += 1 } })
        }
    }
}

/// A phone's live socket over pinned TLS, written by hand so every byte can be checked.
private final class LiveDoorPhone: @unchecked Sendable {
    enum Frame: Equatable { case text(String), binary(Data), ping(Data), pong(Data), close(UInt16?) }
    let connection: NWConnection
    let key = LinkDoorDevices.randomBytes(16).base64EncodedString()
    private(set) var head = ""
    private var buffer = Data()

    private init(_ connection: NWConnection) { self.connection = connection }

    /// Sends the upgrade, offering compression the door must not agree, and reads the answer's head.
    static func open(port: Int, pin: Data, target: String, credential: String?) async throws -> LiveDoorPhone {
        let phone = LiveDoorPhone(try await RawTLS.open(port: port, pin: pin))
        var lines = ["GET \(target) HTTP/1.1", "Host: 127.0.0.1:\(port)", "Upgrade: websocket", "Connection: Upgrade",
                     "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: \(phone.key)",
                     "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits"]
        if let credential { lines.append("X-Hermes-Session-Token: \(credential)") }
        phone.send(Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
        while phone.buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard let more = try await phone.receive() else { break }
            phone.buffer.append(more)
        }
        if let end = phone.buffer.range(of: Data("\r\n\r\n".utf8)) {
            phone.head = String(decoding: phone.buffer[..<end.upperBound], as: UTF8.self)
            phone.buffer = Data(phone.buffer[end.upperBound...])
        } else {
            phone.head = String(decoding: phone.buffer, as: UTF8.self)
        }
        return phone
    }

    func send(_ data: Data) { connection.send(content: data, completion: .contentProcessed { _ in }) }
    func send(text: String) { send(LinkDoorWebSocket.frame(opcode: 1, payload: Data(text.utf8), masked: true)) }
    func cancel() { connection.cancel() }

    /// The next whole frame from the door, or nil once the connection has gone.
    func next() async throws -> Frame? {
        while true {
            if let frame = parse() { return frame }
            guard let more = try await receive() else { return nil }
            buffer.append(more)
        }
    }

    /// Reads past anything still arriving until the door's close frame, and gives its code.
    func closeCode() async throws -> UInt16? {
        while let frame = try await next() {
            if case .close(let code) = frame { return code }
        }
        return nil
    }

    private func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, _, _ in
                continuation.resume(returning: data?.isEmpty == false ? data : nil)
            }
        }
    }

    /// Server frames: whole (FIN), unmasked, no extension bits.
    private func parse() -> Frame? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        #expect(bytes[0] & 0xF0 == 0x80, "FIN set, no extension bits")
        #expect(bytes[1] & 0x80 == 0, "unmasked")
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
            offset = 10
        }
        guard bytes.count >= offset + length else { return nil }
        let payload = Data(bytes[offset..<(offset + length)])
        buffer = Data(bytes[(offset + length)...])
        switch bytes[0] & 0x0F {
        case 1: return .text(String(decoding: payload, as: UTF8.self))
        case 2: return .binary(payload)
        case 9: return .ping(payload)
        case 10: return .pong(payload)
        case 8: return .close(payload.count >= 2 ? UInt16(payload[0]) << 8 | UInt16(payload[1]) : nil)
        default:
            Issue.record("unknown opcode \(bytes[0] & 0x0F)")
            return nil
        }
    }
}
#endif
