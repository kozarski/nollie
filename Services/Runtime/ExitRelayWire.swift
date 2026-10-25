#if os(macOS)
import Foundation
import Network

/// Where a helper's computer asked to go: a name to resolve on this Mac, or an address.
struct ExitRelayTarget: Equatable, Sendable {
    enum Host: Equatable, Sendable {
        case name(String)
        case address([UInt8])
    }
    var host: Host
    var port: UInt16

    /// A DNS name as a client may send it: letters, digits and hyphens in labels of 1 to 63,
    /// at most 253 in all, one trailing dot allowed. Lowercased. Anything else is not a name.
    static func name(_ text: Substring) -> String? {
        var name = text.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= 253 else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-",
                  label.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        }
        // All digits and dots is an address in disguise ("10.1", "2130706433"): never a name.
        guard !name.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return nil }
        return name
    }

    /// `host:port`, `[v6]:port`, or without a port when one is given. Userinfo, zones and
    /// percent escapes are refused.
    static func authority(_ text: Substring, defaultPort: UInt16?) -> ExitRelayTarget? {
        guard !text.isEmpty, text.utf8.count <= 262, !text.contains("@"), !text.contains("%") else { return nil }
        var hostPart: Substring
        var portPart: Substring?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            hostPart = text[text.index(after: text.startIndex)..<close]
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return nil }
                portPart = rest.dropFirst()
            }
            guard let v6 = IPv6Address(String(hostPart)), v6.interface == nil else { return nil }
            guard let port = parsePort(portPart, defaultPort: defaultPort) else { return nil }
            return ExitRelayTarget(host: .address(Array(v6.rawValue)), port: port)
        }
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return nil }
        hostPart = pieces[0]
        portPart = pieces.count == 2 ? pieces[1] : nil
        guard let port = parsePort(portPart, defaultPort: defaultPort) else { return nil }
        if let v4 = dottedQuad(hostPart) { return ExitRelayTarget(host: .address(v4), port: port) }
        guard let name = name(hostPart) else { return nil }
        return ExitRelayTarget(host: .name(name), port: port)
    }

    private static func parsePort(_ text: Substring?, defaultPort: UInt16?) -> UInt16? {
        guard let text else { return defaultPort }
        guard (1...5).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt16(text), value > 0 else { return nil }
        return value
    }

    /// Exactly four decimal parts of 0 to 255, no leading zeros (no octal tricks).
    static func dottedQuad(_ text: Substring) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.utf8.count), part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    /// The `Host` header value for a forwarded request.
    var hostHeader: String {
        let text: String
        switch host {
        case .name(let name): text = name
        case .address(let bytes) where bytes.count == 4: text = bytes.map(String.init).joined(separator: ".")
        case .address(let bytes): text = "[\(IPv6Address(Data(bytes)).map { "\($0)" } ?? "")]"
        }
        return port == 80 ? text : "\(text):\(port)"
    }
}

/// The HTTP side of the relay: `CONNECT host:port` (any TLS, the usual way to reach https) and a
/// plain `GET http://host/path` forward. One request head per connection, strict like the Link
/// door's reader, and small: 16 KiB, 64 headers.
enum ExitRelayHTTP {
    enum Kind: Equatable, Sendable {
        /// After the relay connects, it answers 200 and passes bytes both ways.
        case connect
        /// The head the upstream server gets, in origin form with `Connection: close`.
        case forward(Data)
    }

    struct Request: Equatable, Sendable {
        var kind: Kind
        var target: ExitRelayTarget
        var headLength: Int
    }

    static let limits = LinkDoorHTTP.Limits(head: 16 * 1024, line: 8 * 1024, target: 8 * 1024, headers: 64, body: .max)
    static let forwardMethods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]

    /// Headers between the client and the relay only, never passed on.
    static let hopHeaders: Set<String> = ["connection", "keep-alive", "proxy-connection", "proxy-authorization",
                                          "proxy-authenticate", "te", "trailer", "upgrade", "host"]

    static func parse(_ data: Data) throws(LinkDoorHTTP.Failure) -> Request {
        let (lines, headLength) = try LinkDoorHTTP.headLines(data, limits: limits)
        guard let first = lines.first else { throw .malformed("empty") }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw .malformed("request line") }
        let method = String(parts[0]), target = parts[1], version = parts[2]
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { throw .unsupported("version") }
        guard target.utf8.count <= limits.target else { throw .headTooLarge }
        let headers = try LinkDoorHTTP.parseHeaders(lines.dropFirst(), limits: limits)

        if method == "CONNECT" {
            guard let destination = ExitRelayTarget.authority(target, defaultPort: nil) else { throw .malformed("target") }
            return Request(kind: .connect, target: destination, headLength: headLength)
        }
        guard forwardMethods.contains(method) else { throw .unsupported("method") }
        // Absolute form, http only: https goes through CONNECT, and nothing else is spoken here.
        guard target.lowercased().hasPrefix("http://") else { throw .malformed("target") }
        let rest = target.dropFirst(7)
        guard rest.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), !rest.contains("#") else { throw .malformed("target") }
        let slash = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
        guard let destination = ExitRelayTarget.authority(rest[..<slash], defaultPort: 80) else { throw .malformed("target") }
        var path = String(rest[slash...])
        if path.isEmpty { path = "/" } else if path.hasPrefix("?") { path = "/" + path }

        let named = LinkDoorHTTP.tokens(headers.filter { $0.key == "connection" }.map(\.value))
        var forwarded = [LinkDoorHTTP.Header(name: "Host", value: destination.hostHeader)]
        forwarded += headers.filter { !hopHeaders.contains($0.key) && !named.contains($0.key) }
        forwarded.append(.init(name: "Connection", value: "close"))
        let head = LinkDoorHTTP.serializeRequest(method: method, target: path, headers: forwarded)
        return Request(kind: .forward(head), target: destination, headLength: headLength)
    }

    static let established = Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8)

    /// The relay's own short answers. Plain text, no detail about the destination.
    static func refusal(_ status: Int) -> Data {
        let message = switch status {
        case 403: "Nollie's relay only reaches websites on the internet."
        case 502: "Nollie's relay couldn't reach that website."
        case 503: "Nollie's relay is busy. Try again in a moment."
        default: "Nollie's relay couldn't read that request."
        }
        return LinkDoorHTTP.reply(status, message + "\n", contentType: "text/plain; charset=utf-8")
    }
}

/// The SOCKS5 side of the relay (RFC 1928): no authentication, CONNECT only. The listener is
/// reachable from the VM network alone, so a password would add nothing. BIND and UDP ASSOCIATE
/// are refused.
enum ExitRelaySOCKS {
    static let version: UInt8 = 5

    enum Failure: Error, Equatable, Sendable {
        case malformed
        /// A command other than CONNECT.
        case command
        case addressType
    }

    /// The client's greeting: how many bytes it took, and whether "no authentication" was offered.
    /// Nil until it has all arrived.
    static func greeting(_ data: Data) throws(Failure) -> (length: Int, noAuthentication: Bool)? {
        let bytes = [UInt8](data.prefix(258))
        guard let first = bytes.first else { return nil }
        guard first == version else { throw .malformed }
        guard bytes.count >= 2 else { return nil }
        let count = Int(bytes[1])
        guard count >= 1 else { throw .malformed }
        guard bytes.count >= 2 + count else { return nil }
        return (2 + count, bytes[2..<(2 + count)].contains(0))
    }

    /// The CONNECT request after the greeting. Nil until it has all arrived.
    static func request(_ data: Data) throws(Failure) -> (target: ExitRelayTarget, length: Int)? {
        let bytes = [UInt8](data.prefix(262))
        guard bytes.count >= 4 else {
            if let first = bytes.first, first != version { throw .malformed }
            return nil
        }
        guard bytes[0] == version, bytes[2] == 0 else { throw .malformed }
        guard bytes[1] == 1 else { throw .command }
        let host: ExitRelayTarget.Host
        let end: Int
        switch bytes[3] {
        case 1:
            end = 4 + 4
            guard bytes.count >= end + 2 else { return nil }
            host = .address(Array(bytes[4..<end]))
        case 4:
            end = 4 + 16
            guard bytes.count >= end + 2 else { return nil }
            host = .address(Array(bytes[4..<end]))
        case 3:
            guard bytes.count >= 5 else { return nil }
            let length = Int(bytes[4])
            guard length >= 1 else { throw .malformed }
            end = 5 + length
            guard bytes.count >= end + 2 else { return nil }
            let raw = bytes[5..<end]
            guard raw.allSatisfy({ (33...126).contains($0) }) else { throw .malformed }
            let text = String(decoding: raw, as: UTF8.self)
            if let v4 = ExitRelayTarget.dottedQuad(Substring(text)) {
                host = .address(v4)
            } else if let v6 = IPv6Address(text), v6.interface == nil, text.contains(":") {
                host = .address(Array(v6.rawValue))
            } else if let name = ExitRelayTarget.name(Substring(text)) {
                host = .name(name)
            } else {
                throw .malformed
            }
        default:
            throw .addressType
        }
        let port = UInt16(bytes[end]) << 8 | UInt16(bytes[end + 1])
        guard port > 0 else { throw .malformed }
        return (ExitRelayTarget(host: host, port: port), end + 2)
    }

    enum Reply: UInt8, Sendable {
        case succeeded = 0, generalFailure = 1, notAllowed = 2, hostUnreachable = 4, refused = 5
        case commandNotSupported = 7, addressTypeNotSupported = 8
    }

    static let chooseNoAuthentication = Data([version, 0])
    static let noAcceptableMethod = Data([version, 0xFF])

    /// A reply with an empty IPv4 bound address: the client has no use for the relay's own.
    static func reply(_ code: Reply) -> Data { Data([version, code.rawValue, 0, 1, 0, 0, 0, 0, 0, 0]) }
}
#endif
