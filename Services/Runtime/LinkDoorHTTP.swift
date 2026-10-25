#if os(macOS)
import Foundation

/// A deliberately small HTTP/1.1 reader for the Nollie Link door. It accepts one request
/// head per connection in origin form, with CRLF line endings, no folded headers, no request
/// bodies other than a single Content-Length, and no pipelining. Anything else is refused
/// before a byte reaches Hermes.
enum LinkDoorHTTP {
    struct Limits: Sendable {
        var head = 16 * 1024
        var line = 8 * 1024
        var target = 4 * 1024
        var headers = 64
        var body = 64 * 1024 * 1024
        static let request = Limits()
        static let response = Limits(head: 64 * 1024, line: 16 * 1024, target: 0, headers: 128, body: .max)
    }

    enum Failure: Error, Equatable, Sendable {
        /// More bytes are needed before the head is complete.
        case incomplete
        case headTooLarge, tooManyHeaders, bodyTooLarge
        case malformed(String)
        case unsupported(String)

        var status: Int {
            switch self {
            case .incomplete: 400
            case .headTooLarge, .tooManyHeaders: 431
            case .bodyTooLarge: 413
            case .malformed: 400
            case .unsupported: 501
            }
        }
    }

    struct Header: Equatable, Sendable {
        let name: String
        let value: String
        var key: String { name.lowercased() }
    }

    struct Request: Equatable, Sendable {
        let method: String
        let target: String
        let path: String
        let query: String?
        let headers: [Header]
        let contentLength: Int
        let isWebSocketUpgrade: Bool
        /// Bytes of the head, including the blank line.
        let headLength: Int

        func values(_ name: String) -> [String] {
            let key = name.lowercased()
            return headers.filter { $0.key == key }.map(\.value)
        }
        func value(_ name: String) -> String? { values(name).first }
        var queryItems: [(name: String, value: String?)] { LinkDoorHTTP.queryItems(query) }
    }

    struct Response: Equatable, Sendable {
        let status: Int
        let reason: String
        let headers: [Header]
        let headLength: Int
    }

    static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]

    // MARK: Requests

    static func parseRequest(_ data: Data, limits: Limits = .request) throws(Failure) -> Request {
        let (lines, headLength) = try headLines(data, limits: limits)
        guard let first = lines.first else { throw .malformed("empty") }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw .malformed("request line") }
        let method = String(parts[0]), target = String(parts[1]), version = String(parts[2])
        guard version == "HTTP/1.1" else { throw .unsupported("version") }
        guard methods.contains(method) else { throw .unsupported("method") }
        guard !target.isEmpty, target.utf8.count <= limits.target else { throw .headTooLarge }
        let (path, query) = try parseTarget(target)
        let headers = try parseHeaders(lines.dropFirst(), limits: limits)

        func all(_ name: String) -> [String] { headers.filter { $0.key == name }.map(\.value) }
        let hosts = all("host")
        guard hosts.count == 1, !hosts[0].isEmpty, hosts[0].utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw .malformed("host") }
        guard all("transfer-encoding").isEmpty else { throw .unsupported("transfer-encoding") }
        let lengths = all("content-length")
        guard lengths.count <= 1 else { throw .malformed("content-length") }
        var length = 0
        if let raw = lengths.first {
            guard !raw.isEmpty, raw.utf8.count <= 12, raw.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(raw) else {
                throw .malformed("content-length")
            }
            guard value <= limits.body else { throw .bodyTooLarge }
            length = value
        }
        if ["GET", "HEAD", "DELETE"].contains(method), length > 0 { throw .malformed("body") }
        guard all("expect").isEmpty else { throw .unsupported("expect") }

        let upgrades = all("upgrade")
        var websocket = false
        if !upgrades.isEmpty {
            guard upgrades.count == 1, upgrades[0].lowercased() == "websocket", method == "GET", length == 0,
                  tokens(all("connection")).contains("upgrade"),
                  all("sec-websocket-version") == ["13"],
                  all("sec-websocket-key").count == 1,
                  let key = Data(base64Encoded: all("sec-websocket-key")[0]), key.count == 16 else {
                throw .malformed("upgrade")
            }
            websocket = true
        }
        return Request(method: method, target: target, path: path, query: query, headers: headers,
                       contentLength: length, isWebSocketUpgrade: websocket, headLength: headLength)
    }

    /// Origin-form only: a decoded path without dot segments, empty segments, backslashes,
    /// control characters or encoded separators, and an optional query with valid escapes.
    static func parseTarget(_ target: String) throws(Failure) -> (path: String, query: String?) {
        guard target.hasPrefix("/"), !target.contains("#") else { throw .malformed("target") }
        guard target.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 0x5C && $0 != 0x22 && $0 != 0x3C && $0 != 0x3E }) else {
            throw .malformed("target")
        }
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(pieces[0])
        let query = pieces.count == 2 ? String(pieces[1]) : nil
        guard let path = rawPath.removingPercentEncoding, validEscapes(rawPath) else { throw .malformed("path") }
        let lowered = rawPath.lowercased()
        guard !lowered.contains("%2f"), !lowered.contains("%5c"), !lowered.contains("%00"), !lowered.contains("%2e") else {
            throw .malformed("path")
        }
        guard path.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 }) else { throw .malformed("path") }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { throw .malformed("path") }
        if path != "/" { guard !segments.contains(where: \.isEmpty) else { throw .malformed("path") } }
        if let query { guard validEscapes(query) else { throw .malformed("query") } }
        return (path, query)
    }

    // MARK: Responses

    static func parseResponse(_ data: Data, limits: Limits = .response) throws(Failure) -> Response {
        let (lines, headLength) = try headLines(data, limits: limits)
        guard let first = lines.first else { throw .malformed("empty") }
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "HTTP/1.1" || parts[0] == "HTTP/1.0",
              parts[1].utf8.count == 3, let status = Int(parts[1]), (100...599).contains(status) else {
            throw .malformed("status line")
        }
        let headers = try parseHeaders(lines.dropFirst(), limits: limits)
        return Response(status: status, reason: parts.count == 3 ? String(parts[2]) : "", headers: headers, headLength: headLength)
    }

    // MARK: Writing

    static func serializeRequest(method: String, target: String, headers: [Header]) -> Data {
        var text = "\(method) \(target) HTTP/1.1\r\n"
        for header in headers { text += "\(header.name): \(header.value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    static func serializeResponse(status: Int, reason: String, headers: [Header]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for header in headers { text += "\(header.name): \(header.value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// A short, complete reply the door writes itself, then closes.
    static func reply(_ status: Int, _ message: String, contentType: String = "application/json") -> Data {
        let body: Data
        if contentType == "application/json" {
            body = (try? JSONSerialization.data(withJSONObject: ["detail": message])) ?? Data()
        } else {
            body = Data(message.utf8)
        }
        var head = serializeResponse(status: status, reason: reason(status), headers: [
            Header(name: "Content-Type", value: contentType),
            Header(name: "Content-Length", value: String(body.count)),
            Header(name: "Cache-Control", value: "no-store"),
            Header(name: "Connection", value: "close"),
        ])
        head.append(body)
        return head
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 408: "Request Timeout"
        case 410: "Gone"
        case 413: "Content Too Large"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    // MARK: Pieces

    static func tokens(_ values: [String]) -> Set<String> {
        Set(values.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    static func queryItems(_ query: String?) -> [(name: String, value: String?)] {
        guard let query, !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[0])
            let value = parts.count == 2 ? (String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[1])) : nil
            return (name, value)
        }
    }

    private static func validEscapes(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25 {
                guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else { return false }
                index += 3
            } else { index += 1 }
        }
        return true
    }
    private static func isHex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }

    /// Splits the head at the first CRLF CRLF. Bare LF or CR, NUL and non-ASCII header bytes are refused.
    static func headLines(_ data: Data, limits: Limits) throws(Failure) -> ([Substring], Int) {
        let bytes = [UInt8](data.prefix(limits.head + 4))
        var end: Int?
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 13, bytes[index + 1] == 10, bytes[index + 2] == 13, bytes[index + 3] == 10 { end = index; break }
            index += 1
        }
        guard let end else {
            if bytes.count > limits.head { throw .headTooLarge }
            // A lone LF or CR anywhere in what arrived is refused at once, not waited out.
            if let bad = invalidLineEnding(bytes) { throw .malformed(bad) }
            throw .incomplete
        }
        guard end + 4 <= limits.head else { throw .headTooLarge }
        let head = Array(bytes[0..<end])
        if let bad = invalidLineEnding(head + [13, 10]) { throw .malformed(bad) }
        guard head.allSatisfy({ $0 == 9 || $0 == 13 || $0 == 10 || (32...126).contains($0) }) else { throw .malformed("bytes") }
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard lines.allSatisfy({ $0.utf8.count <= limits.line }) else { throw .headTooLarge }
        return (lines, end + 4)
    }

    private static func invalidLineEnding(_ bytes: [UInt8]) -> String? {
        for (index, byte) in bytes.enumerated() {
            if byte == 10, index == 0 || bytes[index - 1] != 13 { return "line ending" }
            if byte == 13, index + 1 < bytes.count, bytes[index + 1] != 10 { return "line ending" }
            if byte == 0 { return "bytes" }
        }
        return nil
    }

    private static let tokenBytes: Set<UInt8> = Set(Array("!#$%&'*+-.^_`|~".utf8) + Array(48...57) + Array(65...90) + Array(97...122))

    static func parseHeaders(_ lines: ArraySlice<Substring>, limits: Limits) throws(Failure) -> [Header] {
        guard lines.count <= limits.headers else { throw .tooManyHeaders }
        var headers: [Header] = []
        for line in lines {
            guard let first = line.utf8.first, first != 32, first != 9 else { throw .malformed("folded header") }
            guard let colon = line.firstIndex(of: ":") else { throw .malformed("header") }
            let name = line[line.startIndex..<colon]
            guard !name.isEmpty, name.utf8.allSatisfy({ tokenBytes.contains($0) }) else { throw .malformed("header name") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { throw .malformed("header value") }
            headers.append(Header(name: String(name), value: value))
        }
        return headers
    }
}
#endif
