// Copied from floo Wire (Packages/Core/Sources/Wire/Identifier.swift).
// Delete this copy when DocKit moves into Core.
#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

/// A typed identifier: a `DocID` can never be passed where a `DocBlockID` is
/// expected. Encoded as a lowercase UUID string.
///
/// New identifiers are UUIDv7 (RFC 9562): the leading 48 bits are a Unix
/// millisecond timestamp, so they sort by creation time and keep Postgres
/// B-tree inserts local.
public struct Identifier<Tag>: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init?(_ string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.rawValue = uuid
    }

    public static func generate(at time: Timestamp = .now) -> Self {
        var generator = SystemRandomNumberGenerator()
        return generate(at: time, using: &generator)
    }

    public static func generate(at time: Timestamp, using generator: inout some RandomNumberGenerator) -> Self {
        let millis = UInt64(clamping: time.millisecondsSince1970) & 0xFFFF_FFFF_FFFF
        var bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: millis >> (8 * (5 - index)))
        }
        bytes[6] = 0x70 | (bytes[6] & 0x0F)  // version 7
        bytes[8] = 0x80 | (bytes[8] & 0x3F)  // RFC 9562 variant
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &uuid) { $0.copyBytes(from: bytes) }
        return Self(rawValue: UUID(uuid: uuid))
    }

    public var description: String { rawValue.uuidString.lowercased() }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension Identifier: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let id = Self(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid identifier \(string)")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Identifiers encode as UUID strings, so keyed by them dictionaries become
/// JSON objects (`[ColumnID: CellValue]`) instead of key/value arrays.
extension Identifier: CodingKeyRepresentable {
    public var codingKey: any CodingKey { DocCodingKey(stringValue: description) }

    public init?<T>(codingKey: T) where T: CodingKey {
        self.init(codingKey.stringValue)
    }
}

private struct DocCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Phantom tags that give each identifier its own type.
public enum DocTag {
    public enum Doc {}
    public enum Block {}
    public enum Database {}
    public enum Column {}
    public enum Row {}
    public enum Option {}
    public enum CollectionView {}
    public enum Client {}
    public enum Operation {}
}

public typealias DocID = Identifier<DocTag.Doc>
/// One block within a doc: stable for the block's lifetime.
public typealias DocBlockID = Identifier<DocTag.Block>
public typealias DatabaseID = Identifier<DocTag.Database>
public typealias ColumnID = Identifier<DocTag.Column>
public typealias RowID = Identifier<DocTag.Row>
public typealias OptionID = Identifier<DocTag.Option>
public typealias CollectionViewID = Identifier<DocTag.CollectionView>
/// A device or agent run writing to a doc.
public typealias DocClientID = Identifier<DocTag.Client>
/// Idempotency key: the same submission is never applied twice.
public typealias DocOperationID = Identifier<DocTag.Operation>
