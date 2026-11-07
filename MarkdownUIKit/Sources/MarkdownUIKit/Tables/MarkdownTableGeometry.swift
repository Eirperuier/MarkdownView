//
//  MarkdownTableGeometry.swift
//  MarkdownUIKit
//
//  Where a table's rows, columns and text go at a width. Each cell's text is measured once for
//  its content: with nothing wrapping, then only at a column narrower than that. A large table's
//  first measure goes across the cores while the main thread waits, so it costs that thread less.
//

import MarkdownCore
import UIKit

struct MarkdownTableMetrics {
    /// Room round a cell's text.
    let padding: UIEdgeInsets
    let columnSpacing: CGFloat
    /// How far past the cells a ground goes: to the middle of the space between columns.
    let groundOutset: (leading: CGFloat, trailing: CGFloat)
    /// The line between rows.
    let separator: CGFloat

    @MainActor
    init(options: MarkdownTableOptions) {
        if options.scrollsSideways {
            padding = options.cellPadding ?? UIEdgeInsets(top: 13, left: 0, bottom: 13, right: 8)
            columnSpacing = 20
            groundOutset = (leading: (padding.right + columnSpacing) / 2, trailing: (padding.right + columnSpacing) / 2 - padding.right)
            separator = 0
            return
        }
        columnSpacing = 0
        groundOutset = (0, 0)
        switch options.look {
        case .plain(let separators):
            let side: CGFloat = separators ? 8 : 16
            padding = options.cellPadding ?? UIEdgeInsets(top: side + 5, left: 0, bottom: side + 5, right: side)
            #if targetEnvironment(macCatalyst)
            separator = separators ? 1 : 0
            #else
            separator = separators ? 1 / markdownPixelScale : 0
            #endif
        case .github:
            // The lines go round each cell: its text keeps off them on both sides.
            padding = options.cellPadding ?? UIEdgeInsets(top: 6, left: 13, bottom: 6, right: 13)
            separator = 0
        case .grid:
            padding = options.cellPadding ?? UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            separator = 0
        }
    }

    /// A tag's room round its words.
    static let tagPadding = CGSize(width: 7, height: 2)
    static let tagCornerRadius: CGFloat = 5
    static let groundCornerRadius: CGFloat = 6
}

/// A table laid out at a width.
struct MarkdownTableGeometry {
    var width: CGFloat = 0
    var columnX: [CGFloat] = []
    var columnWidths: [CGFloat] = []
    var rowY: [CGFloat] = []
    var rowHeights: [CGFloat] = []
    var contentSize = CGSize.zero
    /// Each cell's text, by row and column.
    var textFrames: [[CGRect]] = []

    /// The rows meeting `y0...y1`.
    func rows(from y0: CGFloat, to y1: CGFloat) -> Range<Int> {
        guard !rowY.isEmpty else { return 0..<0 }
        var low = 0, high = rowY.count
        while low < high {
            let middle = (low + high) / 2
            if rowY[middle] + rowHeights[middle] < y0 { low = middle + 1 } else { high = middle }
        }
        let first = low
        high = rowY.count
        while low < high {
            let middle = (low + high) / 2
            if rowY[middle] <= y1 { low = middle + 1 } else { high = middle }
        }
        return first..<max(first, low)
    }

    /// Across its columns, and its row's height.
    func cellRect(_ cell: MarkdownTableCell) -> CGRect {
        let last = min(cell.position.column + cell.columnSpan, columnX.count) - 1
        let first = min(cell.position.column, columnX.count - 1)
        return CGRect(x: columnX[first], y: rowY[cell.position.row], width: columnX[last] + columnWidths[last] - columnX[first], height: rowHeights[cell.position.row])
    }
}

@MainActor
enum MarkdownTableMeasure {
    /// How text takes room. Text a text view shows is measured by it.
    private static let options: NSStringDrawingOptions = [.usesLineFragmentOrigin]
    private static let unlimited = CGFloat(10_000_000)

    /// A hair over a pixel doesn't count, as a layout gives text its width.
    private static var textWidthSlack: CGFloat { 0.05 / markdownPixelScale }

    /// Up to a pixel, less that hair.
    private static func textWidthCeil(_ width: CGFloat) -> CGFloat {
        ((width - textWidthSlack) * markdownPixelScale).rounded(.up) / markdownPixelScale
    }

    /// The cells it hasn't seen, with nothing wrapping. Together if there are many.
    static func prepareNaturalSizes(_ cells: [MarkdownTableCell]) {
        let waiting = cells.filter { $0.natural == nil && !$0.needsTextView }
        guard waiting.count >= 64 else { return }
        nonisolated(unsafe) let strings = waiting.map(\.drawing)
        let count = strings.count
        let results = UnsafeMutablePointer<CGSize>.allocate(capacity: count)
        results.initialize(repeating: .zero, count: count)
        nonisolated(unsafe) let output = results
        DispatchQueue.concurrentPerform(iterations: count) { index in
            // String measuring is safe off the main thread, and this text is shared by no one.
            output[index] = strings[index].boundingRect(with: CGSize(width: unlimited, height: unlimited), options: [.usesLineFragmentOrigin], context: nil).size
        }
        for index in 0..<count { waiting[index].natural = results[index] }
        results.deallocate()
    }

    static func natural(_ cell: MarkdownTableCell, host: (MarkdownTableCell) -> MarkdownTextHost?) -> CGSize {
        if let natural = cell.natural { return natural }
        let size: CGSize
        if cell.needsTextView, let host = host(cell) {
            size = host.textView.fittingSize(proposedWidth: unlimited, proposedHeight: nil)
        } else {
            size = cell.drawing.boundingRect(with: CGSize(width: unlimited, height: unlimited), options: options, context: nil).size
        }
        cell.natural = size
        return size
    }

    /// Its text's size in `width`, up to a pixel, as a layout gives it.
    static func size(_ cell: MarkdownTableCell, width: CGFloat, host: (MarkdownTableCell) -> MarkdownTextHost?) -> CGSize {
        if let wrapped = cell.wrapped, wrapped.width == width { return wrapped.size }
        let natural = natural(cell, host: host)
        let raw: CGSize
        if natural.width <= width + textWidthSlack {
            raw = natural
        } else if cell.needsTextView, let host = host(cell) {
            raw = host.textView.fittingSize(proposedWidth: width, proposedHeight: nil)
        } else {
            raw = cell.drawing.boundingRect(with: CGSize(width: width, height: unlimited), options: options, context: nil).size
        }
        // A designed face's line is its own ascent and descent, past what string measuring says.
        var height = raw.height
        if cell.string.length > 0, let font = cell.string.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
            height = max(height, font.ascender - font.descender)
        }
        let size = CGSize(width: min(textWidthCeil(raw.width), max(width, 0)), height: markdownPixelCeil(height))
        cell.wrapped = (width, size)
        return size
    }

    static func geometry(
        content: MarkdownTableContent,
        options: MarkdownTableOptions,
        metrics: MarkdownTableMetrics,
        width: CGFloat,
        isRightToLeft: Bool,
        host: (MarkdownTableCell) -> MarkdownTextHost?,
        replaced: (MarkdownTableCell) -> UIView?
    ) -> MarkdownTableGeometry {
        var result = MarkdownTableGeometry()
        result.width = width
        let columns = content.columnCount
        guard columns > 0 else { return result }
        prepareNaturalSizes(content.flat)
        let side = metrics.padding.left + metrics.padding.right
        func extra(_ cell: MarkdownTableCell) -> CGSize {
            cell.tag == nil ? .zero : CGSize(width: MarkdownTableMetrics.tagPadding.width * 2, height: MarkdownTableMetrics.tagPadding.height * 2)
        }
        func naturalWidth(_ cell: MarkdownTableCell) -> CGFloat {
            if let view = replaced(cell) { return view.sizeThatFits(CGSize(width: unlimited, height: unlimited)).width }
            return textWidthCeil(natural(cell, host: host).width) + extra(cell).width
        }

        // Columns.
        var widths: [CGFloat]
        if options.scrollsSideways {
            let buckets = MarkdownTableColumns.normalizedBuckets(options.columnWidthBuckets, cellMaxWidth: options.cellMaxWidth)
            var ideals = [CGFloat](repeating: 0, count: columns)
            for cell in content.flat where cell.position.column < columns {
                let ideal = MarkdownTableColumns.snapped(min(naturalWidth(cell) + side, options.cellMaxWidth), buckets: buckets, cellMaxWidth: options.cellMaxWidth)
                ideals[cell.position.column] = max(ideals[cell.position.column], ideal)
            }
            widths = MarkdownTableColumns.stretched(ideals, spacing: metrics.columnSpacing, toFill: width)
        } else {
            // Text beside a spacer takes any width; centred text as much as it needs.
            var minimums = [CGFloat](repeating: side, count: columns)
            var maximums = [CGFloat](repeating: 0, count: columns)
            for cell in content.flat where cell.position.column < columns && cell.columnSpan == 1 {
                let column = cell.position.column
                let most = cell.alignment == .center ? naturalWidth(cell) + side : .greatestFiniteMagnitude
                maximums[column] = max(maximums[column], most)
                minimums[column] = max(minimums[column], side)
            }
            for column in 0..<columns where maximums[column] < minimums[column] { maximums[column] = .greatestFiniteMagnitude }
            widths = MarkdownTableColumns.sharing(width, minimums: minimums, maximums: maximums, pixelScale: markdownPixelScale)
        }
        var x: CGFloat = 0
        var columnX = [CGFloat](repeating: 0, count: columns)
        for column in 0..<columns {
            columnX[column] = x
            x += widths[column] + metrics.columnSpacing
        }
        let contentWidth = max(x - metrics.columnSpacing, 0)
        if isRightToLeft {
            let room = max(contentWidth, width)
            for column in 0..<columns { columnX[column] = room - columnX[column] - widths[column] }
        }
        result.columnX = columnX
        result.columnWidths = widths

        // Rows, then each cell's text in its row.
        var y: CGFloat = 0
        let vertical = metrics.padding.top + metrics.padding.bottom
        result.rowY.reserveCapacity(content.rows.count)
        result.rowHeights.reserveCapacity(content.rows.count)
        var sizes: [[CGSize]] = []
        sizes.reserveCapacity(content.rows.count)
        for (index, row) in content.rows.enumerated() {
            var height: CGFloat = 0
            var rowSizes: [CGSize] = []
            rowSizes.reserveCapacity(row.count)
            for cell in row {
                let column = min(cell.position.column, columns - 1)
                let last = min(column + cell.columnSpan, columns) - 1
                let across = columnX[last] + widths[last] - columnX[column]
                let room = max(0, abs(across) - side - extra(cell).width)
                var size: CGSize
                if let view = replaced(cell) {
                    size = view.sizeThatFits(CGSize(width: room, height: unlimited))
                } else {
                    size = self.size(cell, width: room, host: host)
                }
                size.width += extra(cell).width
                size.height += extra(cell).height
                rowSizes.append(size)
                height = max(height, size.height + vertical)
            }
            sizes.append(rowSizes)
            if index > 0, metrics.separator > 0 { y += metrics.separator }
            result.rowY.append(y)
            result.rowHeights.append(height)
            y += height
        }
        result.contentSize = CGSize(width: max(contentWidth, width), height: y)

        result.textFrames.reserveCapacity(content.rows.count)
        let scrolls = options.scrollsSideways
        for (rowIndex, row) in content.rows.enumerated() {
            var frames: [CGRect] = []
            frames.reserveCapacity(row.count)
            let top = result.rowY[rowIndex]
            let height = result.rowHeights[rowIndex]
            for (index, cell) in row.enumerated() {
                let size = sizes[rowIndex][index]
                let rect = result.cellRect(cell)
                let boxWidth = size.width + side
                var leftEdge: CGFloat
                let alignment = isRightToLeft ? (cell.alignment == .leading ? .trailing : cell.alignment == .trailing ? .leading : .center) : cell.alignment
                switch alignment {
                case .leading: leftEdge = rect.minX
                case .center: leftEdge = rect.minX + (rect.width - boxWidth) / 2
                case .trailing: leftEdge = rect.maxX - boxWidth
                }
                leftEdge += isRightToLeft ? metrics.padding.right : metrics.padding.left
                let originY = scrolls ? top + metrics.padding.top : top + (height - size.height) / 2
                frames.append(CGRect(x: markdownPixelRound(leftEdge), y: markdownPixelRound(originY), width: size.width, height: size.height))
            }
            result.textFrames.append(frames)
        }
        return result
    }
}
