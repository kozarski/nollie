import Foundation

/// JSON whose shape isn't known ahead of time, such as the params and results of JSON-RPC calls.
public enum JSONValue: Codable, Hashable, Sendable, CustomStringConvertible {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    // MARK: Coding

    public init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        // Bool goes before Double so that true and false are not read as numbers.
        let attempts: [() -> JSONValue?] = [
            { box.decodeNil() ? .some(.null) : .none },
            { (try? box.decode(Bool.self)).map(JSONValue.bool) },
            { (try? box.decode(Double.self)).map(JSONValue.number) },
            { (try? box.decode(String.self)).map(JSONValue.string) },
            { (try? box.decode([JSONValue].self)).map(JSONValue.array) },
            { (try? box.decode([String: JSONValue].self)).map(JSONValue.object) },
        ]
        for attempt in attempts {
            if let found = attempt() { self = found; return }
        }
        throw DecodingError.dataCorruptedError(in: box, debugDescription: "Not JSON")
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null: try single.encodeNil()
        case .bool(let flag): try single.encode(flag)
        case .string(let text): try single.encode(text)
        case .array(let items): try single.encode(items)
        case .object(let fields): try single.encode(fields)
        case .number(let number):
            // Whole numbers go out without a decimal point, as long as a double holds them exactly.
            if let whole = Self.exactInteger(number) { try single.encode(whole) } else { try single.encode(number) }
        }
    }

    private static func exactInteger(_ number: Double) -> Int64? {
        let limit = 9_007_199_254_740_992.0
        guard number == number.rounded(), abs(number) < limit else { return nil }
        return Int64(number)
    }

    // MARK: Reading

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    public subscript(index: Int) -> JSONValue? {
        guard let items = arrayValue else { return nil }
        return items.indices.contains(index) ? items[index] : nil
    }

    public var isNull: Bool {
        switch self {
        case .null: true
        default: false
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let text): text
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        switch self {
        case .array(let items): items
        default: nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        switch self {
        case .object(let fields): fields
        default: nil
        }
    }

    /// A number, or text that reads as one.
    public var doubleValue: Double? {
        if case .number(let number) = self { return number }
        if case .string(let text) = self { return Double(text) }
        return nil
    }

    public var intValue: Int? {
        guard let real = doubleValue else { return nil }
        return Int(real)
    }

    /// A flag, a number (nonzero is true), or text saying true, 1, yes or on.
    public var boolValue: Bool? {
        switch self {
        case .bool(let flag): return flag
        case .number(let number): return number != 0
        case .string(let text): return Self.truthyWords.contains(text.lowercased())
        default: return nil
        }
    }

    private static let truthyWords: Set<String> = ["true", "1", "yes", "on"]

    // MARK: Showing

    /// Something readable for a screen: text as is, numbers without a needless ".0", and
    /// nested values pretty printed.
    public var displayText: String {
        switch self {
        case .null: return ""
        case .bool(let flag): return flag ? "true" : "false"
        case .string(let text): return text
        case .number(let number): return Self.exactInteger(number).map(String.init) ?? String(number)
        case .array, .object: return prettyPrinted
        }
    }

    public var prettyPrinted: String {
        let writer = JSONEncoder()
        writer.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let bytes = try? writer.encode(self) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    public var description: String { prettyPrinted }

    /// A value Foundation APIs accept, e.g. for notification userInfo.
    public var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let flag): return flag
        case .number(let number): return number
        case .string(let text): return text
        case .array(let items): return items.map(\.foundationValue)
        case .object(let fields): return fields.mapValues(\.foundationValue)
        }
    }

    // MARK: Converting

    /// Reads this value as `T`, with snake_case keys turned into camelCase.
    public func decode<T>(_ type: T.Type = T.self) throws -> T where T: Decodable {
        let bytes = try JSONEncoder().encode(self)
        return try JSONCoding.decoder.decode(T.self, from: bytes)
    }

    /// Turns any Encodable into a JSONValue, with camelCase keys written as snake_case.
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONCoding.encoder.encode(value))
    }

    /// From plain Foundation values (strings, numbers, arrays, dictionaries).
    public init(any raw: Any) {
        switch raw {
        case let text as String: self = .string(text)
        case let flag as Bool: self = .bool(flag)
        case let whole as Int: self = .number(Double(whole))
        case let real as Double: self = .number(real)
        case let items as [Any]: self = .array(items.map { JSONValue(any: $0) })
        case let fields as [String: Any]: self = .object(fields.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }
}

// MARK: Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral pairs: (String, JSONValue)...) {
        // A key given twice keeps its last value.
        var fields: [String: JSONValue] = [:]
        for (key, value) in pairs { fields[key] = value }
        self = .object(fields)
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    /// The same fields without the nulls, so a strict server never sees an explicit null for
    /// something optional.
    var compactingNulls: [String: JSONValue] { compactMapValues { $0.isNull ? nil : $0 } }
}

/// The coders every gateway call shares. The gateway speaks snake_case, the app camelCase.
public enum JSONCoding {
    public static let decoder = prepared(JSONDecoder()) { $0.keyDecodingStrategy = .convertFromSnakeCase }
    public static let encoder = prepared(JSONEncoder()) { $0.keyEncodingStrategy = .convertToSnakeCase }

    private static func prepared<Coder>(_ coder: Coder, _ setUp: (Coder) -> Void) -> Coder {
        setUp(coder)
        return coder
    }
}
