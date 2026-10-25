import Foundation

/// The live picture of a helper's computer, as it travels over `GET /nollie/live` (version 1).
/// Binary messages are video frames; text messages are small JSON objects. Everything here is
/// pure: no I/O and no clock, and every decoder is strict, because the bytes come off a network.
public enum LiveWire {
    public static let version: UInt8 = 1
    public static let path = "/nollie/live"
    public static let headerSize = 20
    /// The biggest whole message either side accepts.
    public static let maximumMessage = 8 * 1024 * 1024
    public static let maximumServerText = 4096
    public static let maximumViewerText = 512
    public static let maximumSide = 8192
    public static let maximumParameterSets = 8
    public static let maximumParameterSet = 4096

    static let videoType: UInt8 = 1
    static let hevc: UInt8 = 1
    static let keyframeFlag: UInt8 = 1 << 0
    static let formatFlag: UInt8 = 1 << 1

    public enum Failure: Error, Equatable, Sendable {
        case tooLarge, truncated
        case unsupportedVersion(UInt8), notVideo(UInt8), unknownFlags(UInt8), unsupportedCodec(UInt8)
        /// A keyframe without its format, or a non-key frame with one.
        case formatMismatch
        case badSize, badParameterSets, badSample
        case notJSON, unknownType(String), badField(String)
    }

    /// The host's Unix time in microseconds, the clock every frame and beat is stamped with.
    public static func micros(_ date: Date = Date()) -> UInt64 {
        UInt64(max(0, (date.timeIntervalSince1970 * 1_000_000).rounded(.down)))
    }

    // MARK: Video

    /// One encoded HEVC frame. A keyframe carries the parameter sets (VPS, SPS, PPS) so a viewer
    /// can start from it; any other frame never does. The sample is the frame's NAL units, each
    /// behind a 4-byte big-endian length, as VideoToolbox makes them.
    public struct Video: Sendable, Equatable {
        public var keyframe: Bool
        public var sequence: UInt32
        public var captureMicros: UInt64
        public var width: Int
        public var height: Int
        public var parameterSets: [Data]?
        public var sample: Data

        public init(keyframe: Bool, sequence: UInt32, captureMicros: UInt64, width: Int, height: Int,
                    parameterSets: [Data]?, sample: Data) {
            self.keyframe = keyframe; self.sequence = sequence; self.captureMicros = captureMicros
            self.width = width; self.height = height; self.parameterSets = parameterSets; self.sample = sample
        }

        /// Whether `encode` makes a message `decodeVideo` takes back unchanged.
        public func validate() throws(Failure) {
            guard (1...maximumSide).contains(width), (1...maximumSide).contains(height) else { throw .badSize }
            guard keyframe == (parameterSets != nil) else { throw .formatMismatch }
            if let sets = parameterSets {
                guard (1...maximumParameterSets).contains(sets.count),
                      sets.allSatisfy({ (1...maximumParameterSet).contains($0.count) }) else { throw .badParameterSets }
            }
            _ = try nalUnits(sample)
            guard encodedSize <= maximumMessage else { throw .tooLarge }
        }

        var encodedSize: Int {
            headerSize + (parameterSets.map { 1 + $0.reduce(0) { $0 + 2 + $1.count } } ?? 0) + sample.count
        }
    }

    /// The binary message for one frame. The frame should pass `validate()`; `LiveEncoder` only
    /// makes frames that do.
    public static func encode(_ video: Video) -> Data {
        var out = Data(capacity: video.encodedSize)
        out.append(version)
        out.append(videoType)
        out.append((video.keyframe ? keyframeFlag : 0) | (video.parameterSets != nil ? formatFlag : 0))
        out.append(hevc)
        append(video.sequence, to: &out)
        append(video.captureMicros, to: &out)
        append(UInt16(clamping: video.width), to: &out)
        append(UInt16(clamping: video.height), to: &out)
        if let sets = video.parameterSets {
            out.append(UInt8(clamping: sets.count))
            for set in sets {
                append(UInt16(clamping: set.count), to: &out)
                out.append(set)
            }
        }
        out.append(video.sample)
        return out
    }

    public static func decodeVideo(_ data: Data) throws(Failure) -> Video {
        guard data.count <= maximumMessage else { throw .tooLarge }
        var reader = Reader(data)
        let v = try reader.byte()
        guard v == version else { throw .unsupportedVersion(v) }
        let type = try reader.byte()
        guard type == videoType else { throw .notVideo(type) }
        let flags = try reader.byte()
        guard flags & ~(keyframeFlag | formatFlag) == 0 else { throw .unknownFlags(flags) }
        let codec = try reader.byte()
        guard codec == hevc else { throw .unsupportedCodec(codec) }
        let sequence = try reader.uint32()
        let captureMicros = try reader.uint64()
        let width = Int(try reader.uint16()), height = Int(try reader.uint16())
        guard (1...maximumSide).contains(width), (1...maximumSide).contains(height) else { throw .badSize }
        let keyframe = flags & keyframeFlag != 0
        guard keyframe == (flags & formatFlag != 0) else { throw .formatMismatch }
        var parameterSets: [Data]?
        if keyframe {
            let count = Int(try reader.byte())
            guard (1...maximumParameterSets).contains(count) else { throw .badParameterSets }
            var sets: [Data] = []
            for _ in 0..<count {
                let length = Int(try reader.uint16())
                guard (1...maximumParameterSet).contains(length) else { throw .badParameterSets }
                sets.append(try reader.bytes(length))
            }
            parameterSets = sets
        }
        let sample = reader.rest()
        _ = try nalUnits(sample)
        return Video(keyframe: keyframe, sequence: sequence, captureMicros: captureMicros, width: width, height: height,
                     parameterSets: parameterSets, sample: sample)
    }

    /// The NAL units in a sample: one or more, each a u32 length (at least 1) and its bytes,
    /// exactly filling the sample.
    public static func nalUnits(_ sample: Data) throws(Failure) -> [Data] {
        var reader = Reader(sample)
        var units: [Data] = []
        repeat {
            guard let length = try? reader.uint32(), length >= 1, let unit = try? reader.bytes(Int(length)) else {
                throw .badSample
            }
            units.append(unit)
        } while !reader.isAtEnd
        return units
    }

    // MARK: Text

    public enum ComputerKind: String, Sendable { case space, mac }
    public enum LinkState: String, Sendable { case fine, behind, stalled }
    public enum Control: String, Sendable { case helper, you, someone }
    public enum EndReason: String, Sendable { case stopped, gone, refused, busy, unavailable }
    /// Why the host holds pictures back. `signIn`: Nollie is typing a saved sign-in, or did moments
    /// ago, so no picture is taken, kept or sent until it is over.
    public enum Hold: String, Sendable { case signIn = "sign_in" }
    /// What the viewer's device allows: Low Power Mode or a warm device asks for a lighter picture.
    public enum Limit: String, Sendable { case none, low, lowest }

    public struct PixelSize: Sendable, Equatable, Hashable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) { self.width = width; self.height = height }
    }

    public struct Hello: Sendable, Equatable {
        public var kind: ComputerKind
        public var computer: String
        /// The picture's own pixel size: the space pointer spots are in, not the coded size.
        public var source: PixelSize
        public init(kind: ComputerKind, computer: String, source: PixelSize) {
            self.kind = kind; self.computer = computer; self.source = source
        }
    }

    public struct Beat: Sendable, Equatable {
        public var micros: UInt64
        /// The source is being watched and the shown picture is current.
        public var fresh: Bool
        public var link: LinkState
        public var level: Int
        public var control: Control?
        /// Pictures are held back, and why. A held beat is never fresh. Left out on the wire when nil.
        public var hold: Hold?
        public init(micros: UInt64, fresh: Bool, link: LinkState, level: Int, control: Control?, hold: Hold? = nil) {
            self.micros = micros; self.fresh = fresh && hold == nil; self.link = link; self.level = level; self.control = control
            self.hold = hold
        }
    }

    /// Where the helper's pointer is, in source pixels. On a single window it is often outside
    /// the picture; viewers hide a spot off the picture.
    public struct Pointer: Sendable, Equatable {
        public var x: Int
        public var y: Int
        /// When it last moved, in Unix seconds.
        public var at: Double?
        public init(x: Int, y: Int, at: Double?) { self.x = x; self.y = y; self.at = at }
    }

    public struct Report: Sendable, Equatable {
        /// The latest beat's time, echoed, or 0 before any beat.
        public var beat: UInt64
        public var got: Int
        public var shown: Int
        public var late: Int
        public var limit: Limit
        public init(beat: UInt64, got: Int, shown: Int, late: Int, limit: Limit) {
            self.beat = beat; self.got = got; self.shown = shown; self.late = late; self.limit = limit
        }
    }

    public enum ServerMessage: Sendable, Equatable {
        case hello(Hello)
        case beat(Beat)
        /// nil clears the pointer.
        case pointer(Pointer?)
        case source(PixelSize)
        case end(EndReason)

        /// Always something `decode` takes: out-of-range numbers are clamped, a missing or
        /// impossible time is sent as null and a long computer name is cut short to fit.
        public func encode() -> String {
            switch self {
            case .hello(let hello):
                func text(_ name: String) -> String {
                    json(["type": "hello", "v": Int(version), "kind": hello.kind.rawValue, "computer": name, "source": side(hello.source)])
                }
                let unnamed = text("").utf8.count
                var name = hello.computer
                while true {
                    let written = text(name)
                    let over = written.utf8.count - maximumServerText
                    if over <= 0 || name.isEmpty { return written }
                    // Characters cost what they cost on average so far, escapes included.
                    let average = Double(written.utf8.count - unnamed) / Double(name.count)
                    name.removeLast(min(name.count, max(1, Int((Double(over) / average).rounded(.up)))))
                }
            case .beat(let beat):
                var fields: [String: Any] = ["type": "beat", "t": clamped(beat.micros), "fresh": beat.fresh && beat.hold == nil,
                                             "link": beat.link.rawValue, "level": clamped(beat.level, levelRange),
                                             "control": beat.control?.rawValue ?? NSNull()]
                if let hold = beat.hold { fields["hold"] = hold.rawValue }
                return json(fields)
            case .pointer(let pointer?):
                let at = pointer.at.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                return json(["type": "pointer", "x": clamped(pointer.x, pointerRange), "y": clamped(pointer.y, pointerRange),
                             "at": at ?? NSNull()])
            case .pointer(nil):
                return json(["type": "pointer", "x": NSNull(), "y": NSNull()])
            case .source(let size):
                var fields = side(size)
                fields["type"] = "source"
                return json(fields)
            case .end(let reason):
                return json(["type": "end", "reason": reason.rawValue])
            }
        }

        public static func decode(_ text: String) throws(Failure) -> ServerMessage {
            let fields = try object(text, limit: maximumServerText)
            switch try string(fields, "type") {
            case "hello":
                guard try integer(fields, "v", 0...255) == Int(version) else { throw .badField("v") }
                guard let source = fields["source"] as? [String: Any] else { throw .badField("source") }
                return .hello(Hello(kind: try value(fields, "kind"), computer: try string(fields, "computer"),
                                    source: PixelSize(width: try integer(source, "w", 1...maximumSide),
                                                      height: try integer(source, "h", 1...maximumSide))))
            case "beat":
                let beat = Beat(micros: UInt64(try integer(fields, "t", microsRange)), fresh: try bool(fields, "fresh"),
                                link: try value(fields, "link"), level: try integer(fields, "level", levelRange),
                                control: try optionalValue(fields, "control"), hold: try optionalValue(fields, "hold"))
                // A held picture is never current: a beat that says both is refused.
                guard !(beat.hold != nil && fields["fresh"] as? Bool == true) else { throw .badField("fresh") }
                return .beat(beat)
            case "pointer":
                let x = fields["x"], y = fields["y"]
                if isNull(x), isNull(y) { return .pointer(nil) }
                let at = try optionalNumber(fields, "at")
                guard at.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw .badField("at") }
                return .pointer(Pointer(x: try integer(fields, "x", pointerRange), y: try integer(fields, "y", pointerRange), at: at))
            case "source":
                return .source(PixelSize(width: try integer(fields, "w", 1...maximumSide), height: try integer(fields, "h", 1...maximumSide)))
            case "end":
                return .end(try value(fields, "reason"))
            case let other:
                throw .unknownType(other)
            }
        }
    }

    public enum ViewerMessage: Sendable, Equatable {
        case keyframe
        case report(Report)

        public func encode() -> String {
            switch self {
            case .keyframe:
                return json(["type": "keyframe"])
            case .report(let report):
                return json(["type": "report", "t": clamped(report.beat), "got": clamped(report.got, countRange),
                             "shown": clamped(report.shown, countRange), "late": clamped(report.late, countRange),
                             "limit": report.limit.rawValue])
            }
        }

        public static func decode(_ text: String) throws(Failure) -> ViewerMessage {
            let fields = try object(text, limit: maximumViewerText)
            switch try string(fields, "type") {
            case "keyframe":
                return .keyframe
            case "report":
                return .report(Report(beat: UInt64(try integer(fields, "t", microsRange)), got: try integer(fields, "got", countRange),
                                      shown: try integer(fields, "shown", countRange), late: try integer(fields, "late", countRange),
                                      limit: try value(fields, "limit")))
            case let other:
                throw .unknownType(other)
            }
        }
    }

    /// A second's frame counts: generous, but a number no real stream reaches.
    static let countRange = 0...100_000
    static let levelRange = 0...3
    /// Pointer spots, in source pixels, reach a picture's width past either edge.
    static let pointerRange = -maximumSide...(2 * maximumSide)

    static func clamped(_ value: Int, _ range: ClosedRange<Int>) -> Int { min(max(value, range.lowerBound), range.upperBound) }
    static func clamped(_ micros: UInt64) -> Int { Int(min(micros, UInt64(microsRange.upperBound))) }
    static func side(_ size: PixelSize) -> [String: Any] {
        ["w": clamped(size.width, 1...maximumSide), "h": clamped(size.height, 1...maximumSide)]
    }

    // MARK: Pieces

    static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    /// Reads big-endian fields off the front of some bytes, whatever their indices.
    struct Reader {
        let data: Data
        var offset: Int

        init(_ data: Data) { self.data = data; offset = data.startIndex }

        var isAtEnd: Bool { offset == data.endIndex }

        mutating func bytes(_ count: Int) throws(Failure) -> Data {
            guard count >= 0, data.endIndex - offset >= count else { throw .truncated }
            defer { offset += count }
            return data.subdata(in: offset..<offset + count)
        }

        mutating func byte() throws(Failure) -> UInt8 {
            guard offset < data.endIndex else { throw .truncated }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func uint16() throws(Failure) -> UInt16 { try integer() }
        mutating func uint32() throws(Failure) -> UInt32 { try integer() }
        mutating func uint64() throws(Failure) -> UInt64 { try integer() }

        private mutating func integer<T: FixedWidthInteger>() throws(Failure) -> T {
            let size = MemoryLayout<T>.size
            guard data.endIndex - offset >= size else { throw .truncated }
            var value: T = 0
            for index in offset..<offset + size { value = value << 8 | T(data[index]) }
            offset += size
            return value
        }

        mutating func rest() -> Data {
            defer { offset = data.endIndex }
            return data.subdata(in: offset..<data.endIndex)
        }
    }

    static func json(_ fields: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ text: String, limit: Int) throws(Failure) -> [String: Any] {
        guard text.utf8.count <= limit else { throw .tooLarge }
        guard let fields = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { throw .notJSON }
        return fields
    }

    static func isNull(_ value: Any?) -> Bool { value is NSNull }

    static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    static func string(_ fields: [String: Any], _ key: String) throws(Failure) -> String {
        guard let value = fields[key] as? String else { throw .badField(key) }
        return value
    }

    static func bool(_ fields: [String: Any], _ key: String) throws(Failure) -> Bool {
        guard let number = fields[key] as? NSNumber, isBool(number) else { throw .badField(key) }
        return number.boolValue
    }

    /// A whole number in range. JSON true/false and fractions never count. Ranges stay within
    /// 2^53, where every whole number is exact as a Double.
    static func integer(_ fields: [String: Any], _ key: String, _ range: ClosedRange<Int>) throws(Failure) -> Int {
        guard let number = fields[key] as? NSNumber, !isBool(number) else { throw .badField(key) }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(range.lowerBound), double <= Double(range.upperBound) else { throw .badField(key) }
        return Int(double)
    }

    /// Unix microseconds: good until the year 2255.
    static let microsRange = 0...(1 << 53)

    static func optionalNumber(_ fields: [String: Any], _ key: String) throws(Failure) -> Double? {
        guard let raw = fields[key], !isNull(raw) else { return nil }
        guard let number = raw as? NSNumber, !isBool(number) else { throw .badField(key) }
        return number.doubleValue
    }

    static func value<T: RawRepresentable>(_ fields: [String: Any], _ key: String) throws(Failure) -> T where T.RawValue == String {
        guard let raw = fields[key] as? String, let value = T(rawValue: raw) else { throw .badField(key) }
        return value
    }

    static func optionalValue<T: RawRepresentable>(_ fields: [String: Any], _ key: String) throws(Failure) -> T? where T.RawValue == String {
        guard let raw = fields[key], !isNull(raw) else { return nil }
        guard let string = raw as? String, let value = T(rawValue: string) else { throw .badField(key) }
        return value
    }
}
