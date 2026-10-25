#if os(macOS)
import Foundation

/// WebSocket frames between a linked phone and Hermes. The phone's frames are read in full,
/// unmasked and checked before anything reaches Hermes; Hermes's frames are passed through as
/// they come, with only their boundaries tracked so the door can add a reply of its own.
enum LinkDoorWebSocket {
    enum Failure: Error, Equatable, Sendable {
        case protocolError(String)
        case tooLarge

        /// RFC 6455 close codes: protocol error, or message too big.
        var closeCode: UInt16 { self == .tooLarge ? 1009 : 1002 }
    }

    enum Message: Equatable, Sendable {
        case text(Data)
        case binary(Data)
        case ping(Data)
        case pong(Data)
        case close(Data)
    }

    /// One frame, FIN set. Frames to Hermes are masked, as a client's must be.
    static func frame(opcode: UInt8, payload: Data, masked: Bool) -> Data {
        var out = Data([0x80 | (opcode & 0x0F)])
        let maskBit: UInt8 = masked ? 0x80 : 0
        switch payload.count {
        case 0..<126: out.append(maskBit | UInt8(payload.count))
        case 126...0xFFFF:
            out.append(maskBit | 126)
            out.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        default:
            out.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF)) }
        }
        guard masked else { out.append(payload); return out }
        let key = [UInt8](LinkDoorDevices.randomBytes(4))
        out.append(contentsOf: key)
        var bytes = [UInt8](payload)
        for index in bytes.indices { bytes[index] ^= key[index & 3] }
        out.append(contentsOf: bytes)
        return out
    }

    static func message(_ message: Message, masked: Bool) -> Data {
        switch message {
        case .text(let data): frame(opcode: 1, payload: data, masked: masked)
        case .binary(let data): frame(opcode: 2, payload: data, masked: masked)
        case .close(let data): frame(opcode: 8, payload: data, masked: masked)
        case .ping(let data): frame(opcode: 9, payload: data, masked: masked)
        case .pong(let data): frame(opcode: 10, payload: data, masked: masked)
        }
    }

    static func closePayload(_ code: UInt16, _ reason: String = "") -> Data {
        Data([UInt8(code >> 8), UInt8(code & 0xFF)]) + Data(reason.utf8.prefix(120))
    }

    /// Reads the phone's frames strictly: masked, no extension bits, known opcodes, minimal
    /// lengths, control frames whole and short, fragments only of one message at a time,
    /// text valid UTF-8, and nothing past the size limit.
    struct ClientReader: Sendable {
        let maximumMessage: Int
        private var buffer = Data()
        private var fragments = Data()
        private var fragmentOpcode: UInt8?

        init(maximumMessage: Int) { self.maximumMessage = maximumMessage }

        mutating func feed(_ data: Data) throws(Failure) -> [Message] {
            buffer.append(data)
            var out: [Message] = []
            while let message = try next() { out.append(message) }
            return out
        }

        private mutating func next() throws(Failure) -> Message? {
            while true {
                let bytes = buffer
                guard bytes.count >= 2 else { return nil }
                let first = bytes[bytes.startIndex], second = bytes[bytes.startIndex + 1]
                let fin = first & 0x80 != 0
                guard first & 0x70 == 0 else { throw .protocolError("extension bits") }
                let opcode = first & 0x0F
                guard second & 0x80 != 0 else { throw .protocolError("unmasked") }
                var length = UInt64(second & 0x7F)
                var offset = 2
                if length == 126 {
                    guard bytes.count >= 4 else { return nil }
                    length = UInt64(bytes[bytes.startIndex + 2]) << 8 | UInt64(bytes[bytes.startIndex + 3])
                    guard length >= 126 else { throw .protocolError("length") }
                    offset = 4
                } else if length == 127 {
                    guard bytes.count >= 10 else { return nil }
                    length = 0
                    for index in 2..<10 { length = length << 8 | UInt64(bytes[bytes.startIndex + index]) }
                    guard length >> 63 == 0, length > 0xFFFF else { throw .protocolError("length") }
                    offset = 10
                }
                let control = opcode & 0x08 != 0
                switch opcode {
                case 0, 1, 2, 8, 9, 10: break
                default: throw .protocolError("opcode")
                }
                if control { guard fin, length <= 125 else { throw .protocolError("control frame") } }
                guard length <= UInt64(maximumMessage), fragments.count + Int(length) <= maximumMessage else { throw .tooLarge }
                let total = offset + 4 + Int(length)
                guard bytes.count >= total else { return nil }
                let key = [UInt8](bytes[(bytes.startIndex + offset)..<(bytes.startIndex + offset + 4)])
                var payload = [UInt8](bytes[(bytes.startIndex + offset + 4)..<(bytes.startIndex + total)])
                for index in payload.indices { payload[index] ^= key[index & 3] }
                buffer = Data(bytes.dropFirst(total))

                if control {
                    switch opcode {
                    case 8: return .close(Data(payload))
                    case 9: return .ping(Data(payload))
                    default: return .pong(Data(payload))
                    }
                }
                if opcode == 0 {
                    guard fragmentOpcode != nil else { throw .protocolError("continuation") }
                } else {
                    guard fragmentOpcode == nil else { throw .protocolError("interleaved message") }
                    fragmentOpcode = opcode
                }
                fragments.append(contentsOf: payload)
                guard fin, let kind = fragmentOpcode else { continue }
                let whole = fragments
                fragments = Data()
                fragmentOpcode = nil
                if kind == 1 {
                    guard String(data: whole, encoding: .utf8) != nil else { throw .protocolError("text") }
                    return .text(whole)
                }
                return .binary(whole)
            }
        }
    }

    /// Follows Hermes's frames without holding them up: true at a point where a whole frame
    /// of the door's own can go to the phone without splitting one of Hermes's messages.
    struct ServerTracker: Sendable {
        private var header = Data()
        private var remaining: UInt64 = 0
        private var inMessage = false
        private(set) var closed = false

        var atBoundary: Bool { header.isEmpty && remaining == 0 && !inMessage }

        mutating func consume(_ data: Data) {
            var index = data.startIndex
            while index < data.endIndex {
                if remaining > 0 {
                    let take = Int(min(remaining, UInt64(data.endIndex - index)))
                    remaining -= UInt64(take)
                    index += take
                    continue
                }
                header.append(data[index])
                index += 1
                guard header.count >= 2 else { continue }
                let lengthByte = header[header.startIndex + 1] & 0x7F
                let masked = header[header.startIndex + 1] & 0x80 != 0
                let extra = lengthByte == 126 ? 2 : lengthByte == 127 ? 8 : 0
                let needed = 2 + extra + (masked ? 4 : 0)
                guard header.count >= needed else { continue }
                var length = UInt64(lengthByte)
                if extra > 0 {
                    length = 0
                    for offset in 0..<extra { length = length << 8 | UInt64(header[header.startIndex + 2 + offset]) }
                }
                let first = header[header.startIndex]
                let opcode = first & 0x0F
                if opcode & 0x08 == 0 { inMessage = first & 0x80 == 0 }
                if opcode == 8 { closed = true }
                remaining = length
                header = Data()
            }
        }
    }
}

/// What a phone may ask Hermes over `/api/ws`: the JSON-RPC methods the app itself sends,
/// each checked. Anything else is answered by the door with an error and never forwarded.
enum LinkDoorRPC {
    enum Decision: Equatable, Sendable {
        case forward
        /// The door's own JSON-RPC error reply, as frame text for the phone.
        case refuse(Data)
    }

    static let refusedCode = 4403
    static let refusedMessage = "This can only be done on your Mac."

    /// Every method NollieCore and the app send, with the parameters a phone may use.
    /// `NollieLinkDoorTests` scans the app's source and fails when a method appears that is in
    /// neither this list nor `macOnly`.
    static let allowed: [String: @Sendable ([String: Any]) -> Bool] = [
        "ping": anything, "client.capabilities": anything,
        "session.create": anything, "session.resume": anything, "session.close": anything,
        // Read only: the events a session sent while the phone's socket was down.
        "session.events.since": anything,
        "session.interrupt": anything, "session.steer": anything, "session.title": anything,
        "session.usage": anything, "session.context_breakdown": anything, "session.workspace.move": anything,
        "prompt.submit": anything, "image.attach_bytes": anything, "pdf.attach": anything, "file.attach": anything,
        "approval.pending": anything, "approval.received": anything, "approval.respond": anything,
        "commands.catalog": anything, "profiles.list": anything,
        "projects.list": anything, "projects.tree": anything,
        // Per-chat choices only: model, reasoning effort and fast mode. Not auto-approve.
        "config.set": { ["model", "reasoning", "fast"].contains($0["key"] as? String ?? "") },
        "config.get": { ["profile", "project"].contains($0["key"] as? String ?? "") },
    ]

    /// Sent by the app, refused through the door: slash commands run the full command line
    /// (configuration, plugins, approval modes), so they stay on the Mac.
    static let macOnly: Set<String> = ["slash.exec", "command.dispatch"]

    private static let anything: @Sendable ([String: Any]) -> Bool = { _ in true }

    static func decide(_ text: Data) -> Decision {
        guard let object = try? JSONSerialization.jsonObject(with: text) as? [String: Any] else {
            return .refuse(error(id: nil))
        }
        let id = object["id"]
        guard id == nil || id is String || (id as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true else {
            return .refuse(error(id: nil))
        }
        guard let method = object["method"] else {
            // An answer to Hermes's own request (an approval card): an id and a result or error.
            let answers = (object["result"] != nil) != (object["error"] != nil)
            return id is String && answers && Set(object.keys).isSubset(of: ["jsonrpc", "id", "result", "error"])
                ? .forward : .refuse(error(id: id))
        }
        guard let name = method as? String, let check = allowed[name] else { return .refuse(error(id: id)) }
        let params = object["params"] ?? [String: Any]()
        guard let fields = params as? [String: Any], check(fields) else { return .refuse(error(id: id)) }
        return .forward
    }

    static func error(id: Any?) -> Data {
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(),
                                    "error": ["code": refusedCode, "message": refusedMessage]]
        return (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
    }
}
#endif
