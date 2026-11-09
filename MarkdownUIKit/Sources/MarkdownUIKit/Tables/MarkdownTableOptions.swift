//
//  MarkdownTableOptions.swift
//  MarkdownUIKit
//
//  How tables look and what a host does with them, as a value in `MarkdownStyle`.
//

import MarkdownCore
import UIKit

public struct MarkdownTableOptions {
    /// Lines and grounds.
    public enum Look: Equatable, Sendable {
        /// A line between rows, or none.
        case plain(showsRowSeparators: Bool = true)
        /// Lines round every cell and a ground per row, in GitHub's colours.
        case github
        /// Lines round every cell.
        case grid
    }

    /// A table's look beyond its markdown, for one that scrolls sideways. The defaults are the
    /// table as its markdown reads.
    public struct Appearance: Hashable {
        public enum Stripe: Hashable {
            /// The table's own, `markdownTableStripe`.
            case standard
            case none
            case color(UIColor)
        }

        /// The first row reads as a header; off, as a row like the rest.
        public var headerRow = true
        /// The first column's body cells read as headers, in bold.
        public var headerColumn = false
        public var stripe = Stripe.standard
        /// The system font's design, unless a cell has its own.
        public var fontDesign: UIFontDescriptor.SystemDesign?
        public var cells: [MarkdownTableCellPosition: CellLook] = [:]

        public init() {}
    }

    /// One cell's look; what's nil is the table's.
    public struct CellLook: Hashable {
        public enum Alignment: Hashable, Sendable { case leading, center, trailing, justified }

        public var alignment: Alignment?
        public var fontDesign: UIFontDescriptor.SystemDesign?
        /// Its ground, out to the middle of the space between it and its neighbours.
        public var fill: UIColor?
        /// Its text drawn as a tag in this colour.
        public var tag: UIColor?

        public init(alignment: Alignment? = nil, fontDesign: UIFontDescriptor.SystemDesign? = nil, fill: UIColor? = nil, tag: UIColor? = nil) {
            self.alignment = alignment
            self.fontDesign = fontDesign
            self.fill = fill
            self.tag = tag
        }
    }

    public var look = Look.plain()
    /// Wide tables scroll sideways: columns take their widths from `columnWidthBuckets`, and the
    /// header is in capitals. Off, columns share the width and text wraps.
    public var scrollsSideways = false
    /// The widest a cell's text sets its column, in a table that scrolls.
    public var cellMaxWidth: CGFloat = 300
    public var columnWidthBuckets: [CGFloat] = [80, 120, 160, 220, 300]

    public var headerFont = MarkdownTypography.Style(.subheadline, weight: .bold)
    public var bodyFont = MarkdownTypography.Style(.body)
    /// Room round a cell's text; nil is the look's. No leading room in a look with no lines, so a
    /// first column lines up with the text round the table.
    public var cellPadding: UIEdgeInsets?
    public var appearance = Appearance()
    /// A touched cell's text selects. Off, only a cell with a link takes a touch.
    public var cellsSelectable = true
    /// A header's `(...)` smaller and quieter.
    public var dimsHeaderParentheticals = false

    /// Under every row.
    public var rowBackground: UIColor?
    /// Drawn over each cell, in the current context, given the cell's rect.
    public var cellOverlay: (@MainActor (_ cell: CGRect) -> Void)?
    /// Draws what a cell's image says, in place of loading it.
    public var imageRenderer: (@MainActor (MarkdownImageRequest) -> UIView)?

    /// Told which cell a tap lands on.
    public var onCellTap: (@MainActor (MarkdownTableCellPosition) -> Void)?
    /// Cells a host shows its own view in, inside the cell's padding; it says its size in
    /// `sizeThatFits(_:)`.
    public var replacedCells: Set<MarkdownTableCellPosition> = []
    public var replacement: (@MainActor (MarkdownTableCellPosition) -> UIView?)?
    /// A view over the table, given where its cells are as their grounds draw them. Touches go
    /// through it.
    public var decoration: (@MainActor ([MarkdownTableCellPosition: CGRect]) -> UIView?)?
    /// How much of a revealing table shows: as wide as it is, down to the last row started. Nil
    /// once all of it shows.
    public var onRevealedExtent: (@MainActor (CGSize?) -> Void)?

    public init() {}
}

extension MarkdownTableOptions {
    /// What changes how cells' text is set.
    struct TextKey: Equatable {
        var scrolls: Bool
        var look: Look
        var header: MarkdownTypography.Style
        var body: MarkdownTypography.Style
        var appearance: Appearance
        var dims: Bool
        var padding: UIEdgeInsets?
        var replaced: Set<MarkdownTableCellPosition>
    }

    var textKey: TextKey {
        TextKey(scrolls: scrollsSideways, look: look, header: headerFont, body: bodyFont, appearance: appearance, dims: dimsHeaderParentheticals, padding: cellPadding, replaced: replacedCells)
    }
}
