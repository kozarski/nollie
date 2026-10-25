#if os(macOS)
import Foundation
import Testing
@testable import Nollie
import NollieCore

/// What crosses between Nollie.app and Nollie Runtime for a live picture: every message is
/// checked on arrival, and anything too big, malformed or unexpected is turned away.
struct LiveRelayTests {
    private let stream = UUID().uuidString

    @Test func openRequestsAreStrict() throws {
        let good = NollieLiveRelayOpen(stream: stream, profile: "work", sessionID: "20261021_101500_ab12cd")
        #expect(NollieLiveRelayOpen.decode(good.encoded()) == good)
        var wrong = good
        wrong.version = 2
        #expect(NollieLiveRelayOpen.decode(wrong.encoded()) == nil)
        for (profile, session) in [("", "chat"), ("work", ""), ("../work", "chat"), ("work", "chat/1"), ("-work", "chat"),
                                   ("work", String(repeating: "a", count: 161)), ("wörk", "chat")] {
            #expect(NollieLiveRelayOpen.decode(NollieLiveRelayOpen(stream: stream, profile: profile, sessionID: session).encoded()) == nil)
        }
        for id in ["", "not-a-uuid", stream.lowercased(), stream + "0", "../" + stream] {
            #expect(NollieLiveRelayOpen.decode(NollieLiveRelayOpen(stream: id, profile: "work", sessionID: "chat").encoded()) == nil)
        }
        let padded = Data(#"{"version":1,"stream":"\#(stream)","profile":"work","sessionID":"chat","pad":"\#(String(repeating: "x", count: 4096))"}"#.utf8)
        #expect(NollieLiveRelayOpen.decode(padded) == nil)
        for junk in ["", "[]", "null", "{", #"{"version":1}"#, #"{"version":"1","stream":"\#(stream)","profile":"work","sessionID":"chat"}"#] {
            #expect(NollieLiveRelayOpen.decode(Data(junk.utf8)) == nil)
        }
    }

    @Test func answersAreOpenOrAKnownReason() {
        #expect(NollieLiveRelayAnswer.decode(NollieLiveRelayAnswer.opened.encoded()) == .opened)
        for reason in ["stopped", "gone", "refused", "busy", "unavailable"] {
            #expect(NollieLiveRelayAnswer.decode(NollieLiveRelayAnswer.ended(reason).encoded()) == .ended(reason))
        }
        #expect(NollieLiveRelayAnswer.decode(NollieLiveRelayAnswer.ended("because").encoded()) == nil)
        #expect(NollieLiveRelayAnswer.decode(NollieLiveRelayAnswer(open: true, reason: "busy").encoded()) == nil)
        #expect(NollieLiveRelayAnswer.decode(Data("{".utf8)) == nil)
        #expect(NollieLiveRelayAnswer.decode(Data(repeating: 32, count: 5000)) == nil)
    }

    @Test func pushesAreSmallTextOrWholeVideoFrames() {
        let hello = Data(LiveWire.ServerMessage.hello(.init(kind: .mac, computer: "This Mac", source: .init(width: 10, height: 10))).encode().utf8)
        #expect(NollieLiveRelay.acceptsPush(hello, isText: true, isKeyframe: false))
        #expect(!NollieLiveRelay.acceptsPush(hello, isText: true, isKeyframe: true))
        #expect(!NollieLiveRelay.acceptsPush(Data("not json".utf8), isText: true, isKeyframe: false))
        #expect(!NollieLiveRelay.acceptsPush(Data("[1]".utf8), isText: true, isKeyframe: false))
        #expect(!NollieLiveRelay.acceptsPush(Data([0xff, 0xfe]), isText: true, isKeyframe: false))
        let long = Data(#"{"type":"x","pad":"\#(String(repeating: "x", count: 4096))"}"#.utf8)
        #expect(!NollieLiveRelay.acceptsPush(long, isText: true, isKeyframe: false))

        let key = LiveWire.encode(LiveWire.Video(keyframe: true, sequence: 0, captureMicros: 1, width: 64, height: 40,
                                                 parameterSets: [Data([0x40, 1])], sample: Data([0, 0, 0, 1, 0x26])))
        let delta = LiveWire.encode(LiveWire.Video(keyframe: false, sequence: 1, captureMicros: 2, width: 64, height: 40,
                                                   parameterSets: nil, sample: Data([0, 0, 0, 1, 0x02])))
        #expect(NollieLiveRelay.acceptsPush(key, isText: false, isKeyframe: true))
        #expect(NollieLiveRelay.acceptsPush(delta, isText: false, isKeyframe: false))
        // The keyframe flag must match the frame's own, and a frame must look like one.
        #expect(!NollieLiveRelay.acceptsPush(key, isText: false, isKeyframe: false))
        #expect(!NollieLiveRelay.acceptsPush(delta, isText: false, isKeyframe: true))
        #expect(!NollieLiveRelay.acceptsPush(Data(repeating: 0, count: 19), isText: false, isKeyframe: false))
        var otherVersion = delta
        otherVersion[otherVersion.startIndex] = 2
        #expect(!NollieLiveRelay.acceptsPush(otherVersion, isText: false, isKeyframe: false))
        var tooBig = delta
        tooBig.append(Data(count: NollieLiveRelayConfiguration.videoLimit))
        #expect(!NollieLiveRelay.acceptsPush(tooBig, isText: false, isKeyframe: false))
    }

    @Test func controlFromThePhoneOrTheDoorIsReadStrictly() {
        #expect(LiveHost.input(Data(#"{"type":"keyframe"}"#.utf8)) == .viewer(.keyframe))
        #expect(LiveHost.input(Data(LiveWire.ViewerMessage.report(.init(beat: 5, got: 30, shown: 29, late: 1, limit: .low)).encode().utf8))
                == .viewer(.report(.init(beat: 5, got: 30, shown: 29, late: 1, limit: .low))))
        #expect(LiveHost.input(Data(#"{"type":"stats","sent":12,"withheld":3,"taken":40000,"waiting":800,"heard":true}"#.utf8))
                == .stats(LiveJudge.Second(sent: 12, withheld: 3, bytesTaken: 40000, bytesWaiting: 800, heard: true)))
        for bad in [#"{"type":"stats","sent":-1,"withheld":0,"taken":0,"waiting":0,"heard":true}"#,
                    #"{"type":"stats","sent":1.5,"withheld":0,"taken":0,"waiting":0,"heard":true}"#,
                    #"{"type":"stats","sent":true,"withheld":0,"taken":0,"waiting":0,"heard":true}"#,
                    #"{"type":"stats","sent":1,"withheld":0,"taken":0,"waiting":0}"#,
                    #"{"type":"report","t":0}"#, #"{"type":"hello"}"#, "[]", "", "{", "\u{0}"] {
            #expect(LiveHost.input(Data(bad.utf8)) == nil, "\(bad)")
        }
        let padded = Data(#"{"type":"keyframe","pad":"\#(String(repeating: "x", count: 4096))"}"#.utf8)
        #expect(LiveHost.input(padded) == nil)
        #expect(!NollieLiveRelay.acceptsControl(padded))
        #expect(NollieLiveRelay.acceptsControl(Data(#"{"type":"keyframe"}"#.utf8)))
        #expect(!NollieLiveRelay.acceptsControl(Data([0xc3, 0x28])))
    }

    @Test func streamNamesAreUUIDsAsTheHelperWritesThem() {
        #expect(NollieLiveRelay.isStreamID(stream))
        #expect(!NollieLiveRelay.isStreamID(stream.lowercased()))
        #expect(!NollieLiveRelay.isStreamID("{\(stream)}"))
        #expect(!NollieLiveRelay.isStreamID(""))
        #expect(NollieLiveRelay.isEndReason("busy") && !NollieLiveRelay.isEndReason("Busy"))
    }

    @Test func aCloseThatOvertakesItsOpenIsRemembered() {
        var closed = NollieLiveRelayClosed()
        closed.insert(stream)
        closed.insert(stream)
        #expect(closed.contains(stream) && closed.streams.count == 1)
        for _ in 0..<NollieLiveRelayClosed.limit { closed.insert(UUID().uuidString) }
        #expect(!closed.contains(stream), "Only the newest are kept")
        #expect(closed.streams.count == NollieLiveRelayClosed.limit)
    }

    @Test func theRuntimePackageCarriesTheLiveService() throws {
        let template = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Services/Runtime/com.coreykozarski.nollie.runtime.plist.template")
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: template), format: nil) as? [String: Any])
        #expect(plist["MachServices"] as? [String: Bool] == [NollieRuntimeIPCConfiguration.machService: true,
                                                             NollieLiveRelayConfiguration.machService: true])
    }
}
#endif
