// Copied from floo Wire (Packages/Core/Sources/Wire/Timestamp.swift).
// Delete this copy when DocKit moves into Core.
#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

/// A point in time on the wire: integer milliseconds since the Unix epoch.
/// Unambiguous across languages and time zones, unlike date strings.
public struct Timestamp: Hashable, Comparable, Sendable, Codable {
    public let millisecondsSince1970: Int64

    public init(millisecondsSince1970: Int64) {
        self.millisecondsSince1970 = millisecondsSince1970
    }

    public init(_ date: Date) {
        millisecondsSince1970 = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    public static var now: Timestamp { Timestamp(Date()) }

    public var date: Date { Date(timeIntervalSince1970: Double(millisecondsSince1970) / 1000) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.millisecondsSince1970 < rhs.millisecondsSince1970
    }

    public init(from decoder: any Decoder) throws {
        millisecondsSince1970 = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(millisecondsSince1970)
    }
}
