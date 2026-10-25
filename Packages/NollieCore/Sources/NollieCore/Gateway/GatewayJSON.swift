import Foundation

/// Any JSON value, kept exactly as it arrived. Used for frame envelopes, free-form contract fields and anything
/// a newer Hermes sends that this build has no type for.
public enum GatewayJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([GatewayJSON])
    case object([String: GatewayJSON])
}

// MARK: Looking inside

public extension GatewayJSON {
    /// The member of an object, if this is one and has it.
    subscript(key: String) -> GatewayJSON? { objectValue?[key] }

    /// The element of an array, if this is one and has that many.
    subscript(index: Int) -> GatewayJSON? {
        guard let items = arrayValue, items.indices ~= index else { return nil }
        return items[index]
    }

    var isNull: Bool { self == .null }

    var stringValue: String? {
        guard case .string(let text) = self else { return nil }
        return text
    }

    var boolValue: Bool? {
        guard case .bool(let flag) = self else { return nil }
        return flag
    }

    /// A whole number, from either kind of JSON number as long as nothing is lost.
    var intValue: Int? {
        switch self {
        case .integer(let whole): return whole
        case .number(let real): return Int(exactly: real)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .integer(let whole): return Double(whole)
        case .number(let real): return real
        default: return nil
        }
    }

    var objectValue: [String: GatewayJSON]? {
        guard case .object(let members) = self else { return nil }
        return members
    }

    var arrayValue: [GatewayJSON]? {
        guard case .array(let elements) = self else { return nil }
        return elements
    }
}

// MARK: Reading and writing

public extension GatewayJSON {
    /// Reads one JSON document.
    static func parse(_ data: Data) throws -> GatewayJSON {
        try JSONDecoder().decode(GatewayJSON.self, from: data)
    }

    /// A typed value as plain JSON.
    init(encoding value: some Encodable) throws {
        self = try Self.parse(JSONEncoder().encode(value))
    }

    /// Compact JSON with sorted keys, so equal values give equal bytes.
    func encoded() throws -> Data {
        let writer = JSONEncoder()
        writer.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try writer.encode(self)
    }

    /// This value read as a typed contract value.
    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: encoded())
    }
}

extension GatewayJSON: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let text = try? container.decode(String.self) { self = .string(text) }
        else if let flag = try? container.decode(Bool.self) { self = .bool(flag) }
        else if let whole = try? container.decode(Int.self) { self = .integer(whole) }
        else if let real = try? container.decode(Double.self) { self = .number(real) }
        else if let elements = try? container.decode([GatewayJSON].self) { self = .array(elements) }
        else { self = .object(try container.decode([String: GatewayJSON].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .string(let text): try container.encode(text)
        case .bool(let flag): try container.encode(flag)
        case .integer(let whole): try container.encode(whole)
        case .number(let real): try container.encode(real)
        case .array(let elements): try container.encode(elements)
        case .object(let members): try container.encode(members)
        }
    }
}

// MARK: Writing values as literals

extension GatewayJSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension GatewayJSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .integer(value) }
}

extension GatewayJSON: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension GatewayJSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension GatewayJSON: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension GatewayJSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: GatewayJSON...) { self = .array(elements) }
}

extension GatewayJSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral pairs: (String, GatewayJSON)...) {
        self = .object(pairs.reduce(into: [:]) { $0[$1.0] = $1.1 })
    }
}
