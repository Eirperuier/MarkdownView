//
//  MarkdownTableLogic.swift
//  MarkdownCore
//
//  What a table works out without drawing anything: how wide its columns are, where a frontier
//  is among its cells, what a header's parentheticals are. Both renderers use it.
//

import Foundation

/// A table cell's position: row 0 is the header, body rows start at 1.
public struct MarkdownTableCellPosition: Hashable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

public enum MarkdownTableColumns {
    /// The widths a column may have, the widest being a cell's widest. Fixed widths keep columns
    /// steady while a table streams.
    public static func normalizedBuckets(_ buckets: [CGFloat], cellMaxWidth: CGFloat) -> [CGFloat] {
        let valid = buckets.filter { $0.isFinite && $0 > 0 }.map { min($0, cellMaxWidth) }
        let sorted = Set(valid + [cellMaxWidth]).sorted()
        return sorted.isEmpty ? [cellMaxWidth] : sorted
    }

    /// The smallest bucket that holds `width`.
    public static func snapped(_ width: CGFloat, buckets: [CGFloat], cellMaxWidth: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return buckets.first ?? cellMaxWidth }
        let clamped = min(width, cellMaxWidth)
        return buckets.first { $0 >= clamped } ?? cellMaxWidth
    }

    /// Columns too narrow for their room share what's left by how wide they are.
    public static func stretched(_ ideals: [CGFloat], spacing: CGFloat, toFill width: CGFloat) -> [CGFloat] {
        let sum = ideals.reduce(0, +)
        let total = sum + spacing * CGFloat(max(ideals.count - 1, 0))
        guard total < width, width > 0, sum > 0 else { return ideals }
        let excess = width - total
        return ideals.map { $0 + excess * ($0 / sum) }
    }

    /// Columns laid out as a stack lays out its views: the least flexible first, each offered an
    /// equal share of what's left and taking it within its limits. On the pixel grid: a share is
    /// a whole number of pixels, ties to even, so what one column rounds up the rest make up.
    public static func sharing(_ width: CGFloat, minimums: [CGFloat], maximums: [CGFloat], pixelScale: CGFloat) -> [CGFloat] {
        let order = minimums.indices.sorted { lhs, rhs in
            let left = maximums[lhs] - minimums[lhs], right = maximums[rhs] - minimums[rhs]
            return left == right ? lhs < rhs : left < right
        }
        var result = [CGFloat](repeating: 0, count: minimums.count)
        var remaining = width
        for (position, index) in order.enumerated() {
            let share = remaining / CGFloat(order.count - position)
            let snapped = (share * pixelScale).rounded(.toNearestOrEven) / pixelScale
            result[index] = min(max(snapped, minimums[index]), maximums[index])
            remaining -= result[index]
        }
        return result
    }
}

/// Where a cell is in the text a reveal counts.
public struct MarkdownTableRevealSpan: Equatable, Sendable {
    public var offset: Int
    public var count: Int
    public var end: Int { offset + count }

    public init(offset: Int, count: Int) {
        self.offset = offset
        self.count = count
    }
}

public enum MarkdownTableRevealSearch {
    /// The last cell starting at or before `revealed`.
    public static func lastCell(startingAtOrBefore revealed: Int, in spans: [MarkdownTableRevealSpan]) -> Int? {
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].offset <= revealed { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? low - 1 : nil
    }

    /// The first cell ending after `threshold`; the count of them if none does.
    public static func firstCell(endingAfter threshold: Int, in spans: [MarkdownTableRevealSpan]) -> Int {
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].end > threshold { high = middle } else { low = middle + 1 }
        }
        return low
    }
}

public enum MarkdownTableParentheticals {
    /// Every outermost `(...)` or `（...）`, brackets in. Nested ones close with their outermost.
    public static func ranges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var depth = 0
        var open: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "(" || character == "（" {
                if depth == 0 { open = index }
                depth += 1
            } else if character == ")" || character == "）", depth > 0 {
                depth -= 1
                if depth == 0, let start = open {
                    ranges.append(start..<next)
                    open = nil
                }
            }
            index = next
        }
        return ranges
    }
}
