import Foundation

/// Hermes's gateway contract as Swift. The types inside are generated from the contract by
/// `Tools/codegen/gateway_contract.py`; this file holds the hand-written pieces they build on.
/// See `Docs/specs/gateway-client.md`.
public enum GatewayWire {}

/// What every generated wire type is.
public typealias GatewayWireValue = Codable & Hashable & Sendable

/// A method a client calls, with the types of its params and result.
public struct GatewayCall<Params: Encodable & Sendable, Result: Decodable & Sendable>: Hashable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

/// A question Hermes asks the client (a server-to-client request), with the types of its params and answer.
public struct GatewayQuestion<Params: Decodable & Sendable, Answer: Encodable & Sendable>: Hashable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

/// An event type, with the type of its payload.
public struct GatewayEventKind<Payload: Decodable & Sendable>: Hashable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

/// A string enum from the contract that stays open: a value a newer Hermes adds decodes as itself instead of
/// failing, and `known` lists the values this build was generated with.
public protocol GatewayOpenEnum: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible
where RawValue == String {
    init(rawValue: String)
    static var known: [Self] { get }
}

extension GatewayOpenEnum {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
    public var isKnown: Bool { Self.known.contains(self) }
}
