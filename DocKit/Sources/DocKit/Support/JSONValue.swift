// Copied from floo Wire (Packages/Core/Sources/Wire/JSONValue.swift).
// Delete this copy when DocKit moves into Core.

/// Any JSON value, for payloads whose shape is only known at runtime (card
/// data). Never use `[String: Any]` instead.
///
/// JSON has a single number type, so numbers compare by value: `.int(1)`
/// equals `.double(1.0)`. Decoding yields `.int` whenever the value is integral.
public enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Hashable {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.int(let a), .int(let b)): a == b
        case (.double(let a), .double(let b)): a == b
        case (.int(let a), .double(let b)), (.double(let b), .int(let a)): Double(exactly: a) == b
        case (.string(let a), .string(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a == b
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let value): hasher.combine(value)
        case .int(let value): hasher.combine(value)
        case .double(let value):
            // Integral doubles hash like the equal .int, keeping == and hash consistent.
            if let integral = Int64(exactly: value) { hasher.combine(integral) } else { hasher.combine(value) }
        case .string(let value): hasher.combine(value)
        case .array(let value): hasher.combine(value)
        case .object(let value): hasher.combine(value)
        }
    }
}

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var intValue: Int64? {
        guard case .int(let value) = self else { return nil }
        return value
    }

    /// Integers widen to Double; other cases are nil.
    public var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        default: nil
        }
    }

    public var isNull: Bool { self == .null }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = Self.attempt(Bool.self, from: container) {
            self = .bool(value)
        } else if let value = Self.attempt(Int64.self, from: container) {
            self = .int(value)
        } else if let value = Self.attempt(Double.self, from: container) {
            self = .double(value)
        } else if let value = Self.attempt(String.self, from: container) {
            self = .string(value)
        } else if let value = Self.attempt([JSONValue].self, from: container) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Probing each JSON type in turn is how single-value decoding works; a
    /// mismatch is expected, not an error.
    private static func attempt<T: Decodable>(_ type: T.Type, from container: any SingleValueDecodingContainer) -> T? {
        try? container.decode(type)  // type mismatch → try the next JSON type
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}
