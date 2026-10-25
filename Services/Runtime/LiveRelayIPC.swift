#if os(macOS)
import Foundation

/// The live picture's relay between Nollie.app and Nollie Runtime, on its own Mach service. The
/// app captures and encodes; the helper's Link door carries the result to a linked phone. Both
/// sides check every message here, so neither trusts what the other sends.
enum NollieLiveRelayConfiguration {
    static let machService = "com.coreykozarski.nollie.runtime.live"
    /// One encoded video frame, as the wire allows.
    static let videoLimit = 8 * 1024 * 1024
    /// A JSON message for the phone.
    static let textLimit = 4096
    /// An open request, and a message from the phone or the door for the host.
    static let requestLimit = 4096
    static let endReasons: Set<String> = ["stopped", "gone", "refused", "busy", "unavailable"]
}

/// What the helper offers the app.
@objc(NollieLiveRelayIPC) protocol NollieLiveRelayIPC {
    /// The app is here to host live pictures; the latest app to register is the one asked.
    func register(withReply: @escaping @Sendable (Bool) -> Void)
    /// One message for a stream's phone: text (a JSON object) or one encoded video frame.
    func push(stream: String, data: Data, isText: Bool, isKeyframe: Bool)
    /// Tells the phone why and closes its stream.
    func end(stream: String, reason: String)
}

/// What the app offers the helper.
@objc(NollieLiveHostIPC) protocol NollieLiveHostIPC {
    /// Opens a stream. The reply is a `NollieLiveRelayAnswer`.
    func open(request: Data, withReply: @escaping @Sendable (Data) -> Void)
    /// A keyframe request or report from the phone, or the door's stats for the second.
    func control(stream: String, message: Data)
    /// The phone left or the door closed the stream.
    func close(stream: String)
}

/// The helper's request for one stream. The helper names the stream, so the app never chooses
/// anything the helper then looks up.
struct NollieLiveRelayOpen: Codable, Equatable, Sendable {
    var version = 1
    var stream: String
    var profile: String
    var sessionID: String

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func decode(_ data: Data) -> Self? {
        guard data.count <= NollieLiveRelayConfiguration.requestLimit,
              let request = try? JSONDecoder().decode(Self.self, from: data), request.version == 1,
              NollieLiveRelay.isStreamID(request.stream),
              NollieLiveRelay.isIdentifier(request.profile), NollieLiveRelay.isIdentifier(request.sessionID) else { return nil }
        return request
    }
}

/// The app's answer to an open: the stream is on, or why not.
struct NollieLiveRelayAnswer: Codable, Equatable, Sendable {
    var version = 1
    var open: Bool
    var reason: String?

    static let opened = Self(open: true, reason: nil)
    static func ended(_ reason: String) -> Self { Self(open: false, reason: reason) }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func decode(_ data: Data) -> Self? {
        guard data.count <= NollieLiveRelayConfiguration.requestLimit,
              let answer = try? JSONDecoder().decode(Self.self, from: data), answer.version == 1 else { return nil }
        if answer.open { return answer.reason == nil ? answer : nil }
        return NollieLiveRelayConfiguration.endReasons.contains(answer.reason ?? "") ? answer : nil
    }
}

/// Streams the app was told to close, newest last, so an open that arrives after its own close
/// (the helper gave up waiting) is turned away. Only so many are kept: stream names never repeat.
struct NollieLiveRelayClosed: Sendable {
    static let limit = 64
    private(set) var streams: [String] = []

    mutating func insert(_ stream: String) {
        guard !streams.contains(stream) else { return }
        streams.append(stream)
        if streams.count > Self.limit { streams.removeFirst(streams.count - Self.limit) }
    }

    func contains(_ stream: String) -> Bool { streams.contains(stream) }
}

enum NollieLiveRelay {
    /// A stream is named by an uppercase UUID, as `UUID().uuidString` writes it.
    static func isStreamID(_ text: String) -> Bool {
        text.utf8.count == 36 && UUID(uuidString: text)?.uuidString == text
    }

    /// `[A-Za-z0-9][A-Za-z0-9_.-]{0,159}`, as the door and the preview check them.
    static func isIdentifier(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        func plain(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
        guard let first = bytes.first, plain(first), bytes.count <= 160 else { return false }
        return bytes.dropFirst().allSatisfy { plain($0) || $0 == 95 || $0 == 46 || $0 == 45 }
    }

    /// A message the app may push to a phone: a small JSON object, or a video frame that at least
    /// starts like one (version 1, video). The door relays it as it is.
    static func acceptsPush(_ data: Data, isText: Bool, isKeyframe: Bool) -> Bool {
        if isText {
            guard !isKeyframe, data.count <= NollieLiveRelayConfiguration.textLimit else { return false }
            return isJSONObject(data)
        }
        guard data.count >= 20, data.count <= NollieLiveRelayConfiguration.videoLimit else { return false }
        let start = data.startIndex
        let flags = data[start + 2]
        return data[start] == 1 && data[start + 1] == 1 && ((flags & 1) != 0) == isKeyframe
    }

    /// A message for the host: a JSON object no bigger than a request.
    static func acceptsControl(_ data: Data) -> Bool {
        data.count <= NollieLiveRelayConfiguration.requestLimit && isJSONObject(data)
    }

    static func isEndReason(_ reason: String) -> Bool { NollieLiveRelayConfiguration.endReasons.contains(reason) }

    private static func isJSONObject(_ data: Data) -> Bool {
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }
}
#endif
