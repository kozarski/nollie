import Foundation
import Testing
@testable import NollieCore

/// The live stream's wire: frames and messages round-trip, every malformed input is refused with
/// its own reason, and no mangled input ever crashes the decoder.
struct LiveWireTests {
    private static let sets = [Data([0x40, 0x01, 0x0C]), Data([0x42, 0x01, 0x01, 0x01]), Data([0x44, 0x01, 0xC1])]

    private static func units(_ units: [Data]) -> Data {
        var out = Data()
        for unit in units {
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(unit)
        }
        return out
    }

    private static let keyframe = LiveWire.Video(keyframe: true, sequence: 7, captureMicros: 1_729_500_000_123_456, width: 1280,
                                                 height: 800, parameterSets: sets,
                                                 sample: units([Data([0x26, 0x01, 0xAF, 0x09]), Data([0x4E, 0x01, 0x05])]))
    private static let delta = LiveWire.Video(keyframe: false, sequence: 8, captureMicros: 1_729_500_000_190_000, width: 1280,
                                              height: 800, parameterSets: nil, sample: units([Data([0x02, 0x01, 0xD0])]))

    // MARK: Video

    @Test func framesRoundTrip() throws {
        for video in [Self.keyframe, Self.delta] {
            let data = LiveWire.encode(video)
            #expect(try LiveWire.decodeVideo(data) == video)
            try video.validate()
        }
        let edges = LiveWire.Video(keyframe: false, sequence: .max, captureMicros: .max, width: 8192, height: 1,
                                   parameterSets: nil, sample: Self.units([Data(repeating: 0xAB, count: 70_000)]))
        #expect(try LiveWire.decodeVideo(LiveWire.encode(edges)) == edges)
    }

    @Test func theHeaderIsTwentyBigEndianBytes() {
        let data = LiveWire.encode(Self.keyframe)
        #expect(Array(data.prefix(20)) == [1, 1, 3, 1, 0, 0, 0, 7, 0x00, 0x06, 0x24, 0xF8, 0x99, 0x25, 0x7A, 0x40, 0x05, 0x00, 0x03, 0x20])
        // Then the count and each parameter set behind its u16 length.
        #expect(Array(data[20..<26]) == [3, 0, 3, 0x40, 0x01, 0x0C])
        #expect(LiveWire.encode(Self.delta)[2] == 0)
    }

    @Test func decodingWorksOnASliceOfABiggerBuffer() throws {
        var padded = Data([9, 9, 9])
        padded.append(LiveWire.encode(Self.keyframe))
        let slice = padded.dropFirst(3)
        #expect(slice.startIndex == 3)
        let video = try LiveWire.decodeVideo(slice)
        #expect(video == Self.keyframe)
        #expect(video.sample.startIndex == 0)
        #expect(try LiveWire.nalUnits(video.sample).map { Array($0) } == [[0x26, 0x01, 0xAF, 0x09], [0x4E, 0x01, 0x05]])
    }

    private func refused(_ data: Data) -> LiveWire.Failure? {
        do { _ = try LiveWire.decodeVideo(data); return nil } catch { return error }
    }

    private func patched(_ video: LiveWire.Video = keyframe, _ change: (inout [UInt8]) -> Void) -> Data {
        var bytes = Array(LiveWire.encode(video))
        change(&bytes)
        return Data(bytes)
    }

    @Test func everyHeaderRuleIsChecked() {
        #expect(refused(Data()) == .truncated)
        let whole = LiveWire.encode(Self.keyframe)
        for length in 0..<LiveWire.headerSize { #expect(refused(whole.prefix(length)) == .truncated) }
        #expect(refused(patched { $0[0] = 2 }) == .unsupportedVersion(2))
        #expect(refused(patched { $0[0] = 0 }) == .unsupportedVersion(0))
        #expect(refused(patched { $0[1] = 2 }) == .notVideo(2))
        #expect(refused(patched { $0[2] = 0b111 }) == .unknownFlags(0b111))
        #expect(refused(patched { $0[2] = 0x80 | 3 }) == .unknownFlags(0x83))
        #expect(refused(patched { $0[3] = 2 }) == .unsupportedCodec(2))
        #expect(refused(patched { $0[3] = 0 }) == .unsupportedCodec(0))
        #expect(refused(patched { $0[16] = 0; $0[17] = 0 }) == .badSize)
        #expect(refused(patched { $0[18] = 0; $0[19] = 0 }) == .badSize)
        #expect(refused(patched { $0[16] = 0x20; $0[17] = 0x01 }) == .badSize)
        #expect(refused(patched { $0[18] = 0xFF; $0[19] = 0xFF }) == .badSize)
        // A keyframe without its format, and a non-key frame with one.
        #expect(refused(patched { $0[2] = 1 }) == .formatMismatch)
        #expect(refused(patched(Self.delta) { $0[2] = 1 }) == .formatMismatch)
        #expect(refused(patched(Self.delta) { $0[2] = 2 }) == .formatMismatch)
    }

    @Test func everyParameterSetRuleIsChecked() {
        #expect(refused(patched { $0[20] = 0 }) == .badParameterSets)
        #expect(refused(patched { $0[20] = 9 }) == .badParameterSets)
        #expect(refused(patched { $0[21] = 0; $0[22] = 0 }) == .badParameterSets)
        #expect(refused(patched { $0[21] = 0x10; $0[22] = 0x01 }) == .badParameterSets)
        #expect(refused(patched { $0[21] = 0x0F; $0[22] = 0xFF }) == .truncated)
        #expect(refused(LiveWire.encode(Self.keyframe).prefix(21)) == .truncated)
        let nine = LiveWire.Video(keyframe: true, sequence: 0, captureMicros: 0, width: 2, height: 2,
                                  parameterSets: Array(repeating: Data([1]), count: 9), sample: Self.units([Data([1])]))
        #expect(refused(LiveWire.encode(nine)) == .badParameterSets)
    }

    @Test func everySampleRuleIsChecked() throws {
        let header = LiveWire.encode(Self.delta).prefix(LiveWire.headerSize)
        func with(_ tail: [UInt8]) -> Data { header + Data(tail) }
        #expect(refused(with([])) == .badSample)
        #expect(refused(with([0, 0, 0, 0])) == .badSample)
        #expect(refused(with([0, 0, 0, 0, 7])) == .badSample)
        #expect(refused(with([0, 0, 0, 2, 7])) == .badSample)
        #expect(refused(with([0, 0, 0, 1, 7, 0, 0])) == .badSample)
        #expect(refused(with([0, 0, 0, 1, 7, 0, 0, 0, 0])) == .badSample)
        #expect(refused(with([0xFF, 0xFF, 0xFF, 0xFF, 7])) == .badSample)
        #expect(throws: LiveWire.Failure.badSample) { try LiveWire.nalUnits(Data()) }
        #expect(try LiveWire.nalUnits(Data([0, 0, 0, 1, 7, 0, 0, 0, 2, 8, 9])) == [Data([7]), Data([8, 9])])
    }

    @Test func messagesHaveASizeLimit() throws {
        let biggest = LiveWire.maximumMessage - LiveWire.headerSize - 4
        let atLimit = LiveWire.Video(keyframe: false, sequence: 1, captureMicros: 1, width: 4, height: 4, parameterSets: nil,
                                     sample: Self.units([Data(count: biggest)]))
        let encoded = LiveWire.encode(atLimit)
        #expect(encoded.count == LiveWire.maximumMessage)
        #expect(try LiveWire.decodeVideo(encoded) == atLimit)
        #expect(refused(encoded + Data([0])) == .tooLarge)
        var over = atLimit
        over.sample = Self.units([Data(count: biggest + 1)])
        #expect(throws: LiveWire.Failure.tooLarge) { try over.validate() }
    }

    @Test func validateMatchesWhatTheDecoderTakes() {
        var video = Self.keyframe
        video.parameterSets = nil
        #expect(throws: LiveWire.Failure.formatMismatch) { try video.validate() }
        video = Self.delta
        video.parameterSets = Self.sets
        #expect(throws: LiveWire.Failure.formatMismatch) { try video.validate() }
        video = Self.keyframe
        video.parameterSets = [Data()]
        #expect(throws: LiveWire.Failure.badParameterSets) { try video.validate() }
        video.parameterSets = [Data(count: 4097)]
        #expect(throws: LiveWire.Failure.badParameterSets) { try video.validate() }
        video = Self.delta
        video.width = 0
        #expect(throws: LiveWire.Failure.badSize) { try video.validate() }
        video.width = 8193
        #expect(throws: LiveWire.Failure.badSize) { try video.validate() }
        video = Self.delta
        video.sample = Data([0, 0, 0, 3, 1])
        #expect(throws: LiveWire.Failure.badSample) { try video.validate() }
    }

    // MARK: Text

    @Test func serverMessagesRoundTrip() throws {
        let messages: [LiveWire.ServerMessage] = [
            .hello(.init(kind: .space, computer: "Studio desktop", source: .init(width: 1280, height: 800))),
            .hello(.init(kind: .mac, computer: "Corey's Mac \u{1F600} \"quoted\"", source: .init(width: 1, height: 8192))),
            .beat(.init(micros: 1_729_500_000_000_000, fresh: true, link: .fine, level: 0, control: .helper)),
            .beat(.init(micros: 0, fresh: false, link: .stalled, level: 3, control: nil)),
            .beat(.init(micros: 5, fresh: true, link: .behind, level: 2, control: .someone)),
            .pointer(.init(x: 640, y: 400, at: 1_729_500_000.25)),
            .pointer(.init(x: 0, y: 8192, at: nil)),
            .pointer(.init(x: -40, y: 9000, at: 0)),
            .pointer(nil),
            .source(.init(width: 1440, height: 900)),
        ] + [LiveWire.EndReason.stopped, .gone, .refused, .busy, .unavailable].map { .end($0) }
        for message in messages {
            let text = message.encode()
            #expect(text.utf8.count <= LiveWire.maximumServerText)
            #expect(try LiveWire.ServerMessage.decode(text) == message, "\(text)")
        }
        #expect(LiveWire.ServerMessage.pointer(nil).encode() == #"{"type":"pointer","x":null,"y":null}"#)
        #expect(LiveWire.ServerMessage.end(.busy).encode() == #"{"reason":"busy","type":"end"}"#)
    }

    @Test func whateverIsEncodedDecodes() throws {
        func sent(_ message: LiveWire.ServerMessage) throws -> LiveWire.ServerMessage {
            let text = message.encode()
            #expect(text.utf8.count <= LiveWire.maximumServerText)
            return try LiveWire.ServerMessage.decode(text)
        }
        // A time that isn't one goes as null instead of stopping the app.
        for at in [Double.nan, .infinity, -.infinity, -1] {
            #expect(try sent(.pointer(.init(x: 3, y: 4, at: at))) == .pointer(.init(x: 3, y: 4, at: nil)))
        }
        #expect(try sent(.pointer(.init(x: -100_000, y: .max, at: 2))) == .pointer(.init(x: -8192, y: 16384, at: 2)))
        #expect(try sent(.beat(.init(micros: .max, fresh: true, link: .fine, level: 9, control: nil)))
                == .beat(.init(micros: 1 << 53, fresh: true, link: .fine, level: 3, control: nil)))
        #expect(try sent(.beat(.init(micros: 1, fresh: true, link: .fine, level: -2, control: nil)))
                == .beat(.init(micros: 1, fresh: true, link: .fine, level: 0, control: nil)))
        #expect(try sent(.source(.init(width: 0, height: 20_000))) == .source(.init(width: 1, height: 8192)))

        for name in [String(repeating: "a", count: 5000), String(repeating: "\u{1F600}", count: 3000),
                     String(repeating: "\u{1}", count: 2000), String(repeating: "e\u{301}\u{302}", count: 2000)] {
            guard case .hello(let hello) = try sent(.hello(.init(kind: .mac, computer: name, source: .init(width: 10, height: 10)))) else {
                Issue.record("not a hello"); continue
            }
            #expect(!hello.computer.isEmpty)
            #expect(name.hasPrefix(hello.computer))
            #expect(hello.computer.count > 400)
        }

        let report = LiveWire.Report(beat: .max, got: -1, shown: 1_000_000, late: 5, limit: .low)
        #expect(try LiveWire.ViewerMessage.decode(LiveWire.ViewerMessage.report(report).encode())
                == .report(.init(beat: 1 << 53, got: 0, shown: 100_000, late: 5, limit: .low)))
    }

    @Test func aBeatSaysWhenPicturesAreHeldBackForASignIn() throws {
        let held = LiveWire.ServerMessage.beat(.init(micros: 9, fresh: false, link: .fine, level: 1, control: .helper, hold: .signIn))
        #expect(held.encode() == #"{"control":"helper","fresh":false,"hold":"sign_in","level":1,"link":"fine","t":9,"type":"beat"}"#)
        #expect(try LiveWire.ServerMessage.decode(held.encode()) == held)
        // Never current while held, however it was made; and a beat without a hold says nothing about one.
        #expect(LiveWire.Beat(micros: 1, fresh: true, link: .fine, level: 0, control: nil, hold: .signIn).fresh == false)
        #expect(!LiveWire.ServerMessage.beat(.init(micros: 1, fresh: true, link: .fine, level: 0, control: nil)).encode().contains("hold"))
        let beat = #"{"type":"beat","t":5,"fresh":false,"link":"fine","level":0,"control":null,"hold":"sign_in"}"#
        guard case .beat(let decoded) = try LiveWire.ServerMessage.decode(beat) else { Issue.record("not a beat"); return }
        #expect(decoded.hold == .signIn && !decoded.fresh)
        #expect(try LiveWire.ServerMessage.decode(beat.replacingOccurrences(of: #","hold":"sign_in""#, with: #","hold":null"#))
                == .beat(.init(micros: 5, fresh: false, link: .fine, level: 0, control: nil)))
        func refuses(_ text: String) -> LiveWire.Failure? {
            do { _ = try LiveWire.ServerMessage.decode(text); return nil } catch { return error }
        }
        #expect(refuses(beat.replacingOccurrences(of: "false", with: "true")) == .badField("fresh"), "held and current at once")
        #expect(refuses(beat.replacingOccurrences(of: #""sign_in""#, with: #""typing""#)) == .badField("hold"))
        #expect(refuses(beat.replacingOccurrences(of: #""sign_in""#, with: "true")) == .badField("hold"))
        #expect(refuses(beat.replacingOccurrences(of: #""sign_in""#, with: #""SIGN_IN""#)) == .badField("hold"))
    }

    @Test func serverMessagesAsTheSpecWritesThem() throws {
        #expect(try LiveWire.ServerMessage.decode(#"{"type":"hello","v":1,"kind":"space","computer":"Studio desktop","source":{"w":1280,"h":800}}"#)
                == .hello(.init(kind: .space, computer: "Studio desktop", source: .init(width: 1280, height: 800))))
        #expect(try LiveWire.ServerMessage.decode(#"{"type":"beat","t":1729500000000000,"fresh":true,"link":"behind","level":1,"control":"you"}"#)
                == .beat(.init(micros: 1_729_500_000_000_000, fresh: true, link: .behind, level: 1, control: .you)))
        #expect(try LiveWire.ServerMessage.decode(#"{"type":"beat","t":1,"fresh":false,"link":"fine","level":0,"control":null}"#)
                == .beat(.init(micros: 1, fresh: false, link: .fine, level: 0, control: nil)))
        #expect(try LiveWire.ServerMessage.decode(#"{"type":"pointer","x":12,"y":34,"at":null}"#) == .pointer(.init(x: 12, y: 34, at: nil)))
        #expect(try LiveWire.ServerMessage.decode(#"{"type":"pointer","x":12,"y":34,"at":1729500000}"#)
                == .pointer(.init(x: 12, y: 34, at: 1_729_500_000)))
        #expect(try LiveWire.ServerMessage.decode(#"{"type":"source","w":1440,"h":900}"#) == .source(.init(width: 1440, height: 900)))
        // Unknown fields are ignored, so a newer host can add some.
        #expect(try LiveWire.ServerMessage.decode(#"{"type":"end","reason":"gone","why":"lid closed","extra":[1,2]}"#) == .end(.gone))
    }

    private func serverRefuses(_ text: String) -> LiveWire.Failure? {
        do { _ = try LiveWire.ServerMessage.decode(text); return nil } catch { return error }
    }

    @Test func badServerMessagesAreRefused() {
        #expect(serverRefuses("") == .notJSON)
        #expect(serverRefuses("not json") == .notJSON)
        #expect(serverRefuses("[1,2]") == .notJSON)
        #expect(serverRefuses(#""hello""#) == .notJSON)
        #expect(serverRefuses("{}") == .badField("type"))
        #expect(serverRefuses(#"{"type":1}"#) == .badField("type"))
        #expect(serverRefuses(#"{"type":"video"}"#) == .unknownType("video"))
        #expect(serverRefuses(#"{"type":"HELLO"}"#) == .unknownType("HELLO"))
        let hello = #"{"type":"hello","v":1,"kind":"space","computer":"x","source":{"w":10,"h":10}}"#
        #expect(serverRefuses(hello) == nil)
        #expect(serverRefuses(hello.replacingOccurrences(of: #""v":1"#, with: #""v":2"#)) == .badField("v"))
        #expect(serverRefuses(hello.replacingOccurrences(of: #""v":1,"#, with: "")) == .badField("v"))
        #expect(serverRefuses(hello.replacingOccurrences(of: #""space""#, with: #""vm""#)) == .badField("kind"))
        #expect(serverRefuses(hello.replacingOccurrences(of: #""x""#, with: "7")) == .badField("computer"))
        #expect(serverRefuses(hello.replacingOccurrences(of: #""w":10"#, with: #""w":0"#)) == .badField("w"))
        #expect(serverRefuses(hello.replacingOccurrences(of: #""w":10"#, with: #""w":8193"#)) == .badField("w"))
        #expect(serverRefuses(hello.replacingOccurrences(of: #""w":10"#, with: #""w":10.5"#)) == .badField("w"))
        #expect(serverRefuses(hello.replacingOccurrences(of: #""w":10"#, with: #""w":"10""#)) == .badField("w"))
        #expect(serverRefuses(hello.replacingOccurrences(of: #""w":10"#, with: #""w":true"#)) == .badField("w"))
        #expect(serverRefuses(hello.replacingOccurrences(of: #"{"w":10,"h":10}"#, with: "null")) == .badField("source"))
        let beat = #"{"type":"beat","t":5,"fresh":true,"link":"fine","level":0,"control":null}"#
        #expect(serverRefuses(beat) == nil)
        #expect(serverRefuses(beat.replacingOccurrences(of: #""level":0"#, with: #""level":4"#)) == .badField("level"))
        #expect(serverRefuses(beat.replacingOccurrences(of: #""level":0"#, with: #""level":-1"#)) == .badField("level"))
        #expect(serverRefuses(beat.replacingOccurrences(of: "true", with: "1")) == .badField("fresh"))
        #expect(serverRefuses(beat.replacingOccurrences(of: #""fine""#, with: #""slow""#)) == .badField("link"))
        #expect(serverRefuses(beat.replacingOccurrences(of: "null", with: #""nobody""#)) == .badField("control"))
        #expect(serverRefuses(beat.replacingOccurrences(of: #""t":5"#, with: #""t":-5"#)) == .badField("t"))
        #expect(serverRefuses(beat.replacingOccurrences(of: #""t":5"#, with: #""t":1e300"#)) == .badField("t"))
        #expect(serverRefuses(#"{"type":"pointer","x":null,"y":4}"#) == .badField("x"))
        #expect(serverRefuses(#"{"type":"pointer","x":4}"#) == .badField("y"))
        #expect(serverRefuses(#"{"type":"pointer","x":-1,"y":4}"#) == nil)
        #expect(serverRefuses(#"{"type":"pointer","x":-8193,"y":4}"#) == .badField("x"))
        #expect(serverRefuses(#"{"type":"pointer","x":1,"y":16385}"#) == .badField("y"))
        #expect(serverRefuses(#"{"type":"pointer","x":1,"y":4,"at":-3}"#) == .badField("at"))
        #expect(serverRefuses(#"{"type":"pointer","x":1,"y":4,"at":"now"}"#) == .badField("at"))
        #expect(serverRefuses(#"{"type":"source","w":0,"h":4}"#) == .badField("w"))
        #expect(serverRefuses(#"{"type":"end","reason":"bye"}"#) == .badField("reason"))
        #expect(serverRefuses(#"{"type":"end"}"#) == .badField("reason"))
        let long = #"{"type":"end","reason":"gone","pad":""# + String(repeating: "a", count: 4096) + #""}"#
        #expect(serverRefuses(long) == .tooLarge)
    }

    @Test func viewerMessagesRoundTripAndStaySmall() throws {
        let messages: [LiveWire.ViewerMessage] = [
            .keyframe,
            .report(.init(beat: 1_729_500_000_000_000, got: 30, shown: 29, late: 1, limit: .none)),
            .report(.init(beat: 0, got: 0, shown: 0, late: 0, limit: .low)),
            .report(.init(beat: 9_007_199_254_740_992, got: 100_000, shown: 100_000, late: 100_000, limit: .lowest)),
        ]
        for message in messages {
            let text = message.encode()
            #expect(text.utf8.count <= LiveWire.maximumViewerText)
            #expect(try LiveWire.ViewerMessage.decode(text) == message, "\(text)")
        }
        #expect(LiveWire.ViewerMessage.keyframe.encode() == #"{"type":"keyframe"}"#)
    }

    private func viewerRefuses(_ text: String) -> LiveWire.Failure? {
        do { _ = try LiveWire.ViewerMessage.decode(text); return nil } catch { return error }
    }

    @Test func badViewerMessagesAreRefused() {
        let report = #"{"type":"report","t":0,"got":3,"shown":2,"late":1,"limit":"none"}"#
        #expect(viewerRefuses(report) == nil)
        #expect(viewerRefuses(#"{"type":"keyframe","please":true}"#) == nil)
        #expect(viewerRefuses(#"{"type":"ping"}"#) == .unknownType("ping"))
        #expect(viewerRefuses(#"{"type":"hello"}"#) == .unknownType("hello"))
        #expect(viewerRefuses("keyframe") == .notJSON)
        #expect(viewerRefuses(report.replacingOccurrences(of: #""got":3"#, with: #""got":-3"#)) == .badField("got"))
        #expect(viewerRefuses(report.replacingOccurrences(of: #""got":3"#, with: #""got":100001"#)) == .badField("got"))
        #expect(viewerRefuses(report.replacingOccurrences(of: #""shown":2"#, with: #""shown":2.5"#)) == .badField("shown"))
        #expect(viewerRefuses(report.replacingOccurrences(of: #""late":1"#, with: #""late":false"#)) == .badField("late"))
        #expect(viewerRefuses(report.replacingOccurrences(of: #""none""#, with: #""medium""#)) == .badField("limit"))
        #expect(viewerRefuses(report.replacingOccurrences(of: #","limit":"none""#, with: "")) == .badField("limit"))
        let padded = #"{"type":"keyframe","pad":""# + String(repeating: "a", count: 500) + #""}"#
        #expect(padded.utf8.count > 512)
        #expect(viewerRefuses(padded) == .tooLarge)
    }

    // MARK: Fuzz

    /// SplitMix64: small, seeded, the same on every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static func mutate(_ bytes: [UInt8], _ random: inout Seeded) -> [UInt8] {
        var bytes = bytes
        for _ in 0..<Int.random(in: 1...4, using: &random) {
            switch Int.random(in: 0..<6, using: &random) {
            case 0 where !bytes.isEmpty:
                bytes[Int.random(in: 0..<bytes.count, using: &random)] = UInt8.random(in: 0...255, using: &random)
            case 1 where !bytes.isEmpty:
                let index = Int.random(in: 0..<bytes.count, using: &random)
                bytes[index] ^= 1 << UInt8.random(in: 0..<8, using: &random)
            case 2 where !bytes.isEmpty:
                bytes.removeLast(Int.random(in: 1...bytes.count, using: &random))
            case 3:
                bytes.insert(UInt8.random(in: 0...255, using: &random), at: Int.random(in: 0...bytes.count, using: &random))
            case 4 where !bytes.isEmpty:
                bytes.remove(at: Int.random(in: 0..<bytes.count, using: &random))
            default:
                bytes += (0..<Int.random(in: 1...8, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) }
            }
        }
        return bytes
    }

    @Test func mangledFramesNeverCrashAndAnythingAcceptedIsExact() {
        var random = Seeded(state: 0x5EED_0F11_7E57)
        let seeds = [Self.keyframe, Self.delta].map { Array(LiveWire.encode($0)) }
        var accepted = 0
        for round in 0..<20_000 {
            let input = Data(Self.mutate(seeds[round % seeds.count], &random))
            guard let video = try? LiveWire.decodeVideo(input) else { continue }
            accepted += 1
            // Whatever the decoder takes is a valid frame that encodes back to the same bytes.
            #expect((try? video.validate()) != nil)
            #expect(LiveWire.encode(video) == input)
        }
        #expect(accepted > 0)
    }

    @Test func mangledTextNeverCrashes() throws {
        var random = Seeded(state: 42)
        let seeds = [
            LiveWire.ServerMessage.hello(.init(kind: .mac, computer: "Studio", source: .init(width: 1280, height: 800))).encode(),
            LiveWire.ServerMessage.beat(.init(micros: 99, fresh: true, link: .behind, level: 2, control: .you)).encode(),
            LiveWire.ServerMessage.pointer(.init(x: 3, y: 4, at: 5.5)).encode(),
            LiveWire.ViewerMessage.report(.init(beat: 99, got: 3, shown: 2, late: 1, limit: .low)).encode(),
        ].map { Array($0.utf8) }
        for round in 0..<20_000 {
            let text = String(decoding: Self.mutate(seeds[round % seeds.count], &random), as: UTF8.self)
            if let message = try? LiveWire.ServerMessage.decode(text) {
                #expect(try LiveWire.ServerMessage.decode(message.encode()) == message)
            }
            if let message = try? LiveWire.ViewerMessage.decode(text) {
                #expect(try LiveWire.ViewerMessage.decode(message.encode()) == message)
            }
        }
    }
}
