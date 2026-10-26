//
//  MarkdownTableAppearance.swift
//  MarkdownView
//
//  How a host's table looks beyond what its markdown says (a document's table settings,
//  Craft's Table Style): whether its first row and first column read as headers, the
//  colour of every other row, its typeface, and each cell's own alignment, typeface and fill.
//

import SwiftUI

/// A table's look beyond its markdown. The defaults are the table as its markdown reads.
public struct MarkdownTableAppearance: Hashable, Sendable {
    /// Every other body row's background.
    public enum Stripe: Hashable, Sendable {
        /// The table's own light stripe.
        case standard
        /// None: every row the same.
        case none
        /// This colour, as it is.
        case color(Color)
    }

    /// The first row (the column names) reads as a header; off, as a row like the rest.
    public var headerRow: Bool
    /// The first column's body cells read as headers too, in bold.
    public var headerColumn: Bool
    public var stripe: Stripe
    /// The system font's design for its cells' text, unless a cell has its own.
    public var fontDesign: Font.Design?
    /// Cells with a look of their own, by where they are (row 0 is the first row).
    public var cells: [MarkdownTableCellPosition: MarkdownTableCellAppearance]

    public init(headerRow: Bool = true, headerColumn: Bool = false, stripe: Stripe = .standard, fontDesign: Font.Design? = nil,
                cells: [MarkdownTableCellPosition: MarkdownTableCellAppearance] = [:]) {
        self.headerRow = headerRow
        self.headerColumn = headerColumn
        self.stripe = stripe
        self.fontDesign = fontDesign
        self.cells = cells
    }
}

/// One cell's look; what's nil is the table's.
public struct MarkdownTableCellAppearance: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable {
        case leading, center, trailing
        /// Lines filling the cell's width; a cell that reads as plain text (not yet
        /// selectable) sets it leading.
        case justified
    }

    public var alignment: Alignment?
    /// The system font's design for the cell's text.
    public var fontDesign: Font.Design?
    /// The cell's background, out to the middle of the space between it and its
    /// neighbours.
    public var fill: Color?
    /// The cell's text drawn as a tag in this colour (a database's option).
    public var tag: Color?

    public init(alignment: Alignment? = nil, fontDesign: Font.Design? = nil, fill: Color? = nil, tag: Color? = nil) {
        self.alignment = alignment
        self.fontDesign = fontDesign
        self.fill = fill
        self.tag = tag
    }
}

extension EnvironmentValues {
    @Entry var markdownTableAppearance = MarkdownTableAppearance()
}

extension View {
    /// How the tables MarkdownView renders here look beyond their markdown (scrollable
    /// tables only).
    nonisolated public func markdownTableAppearance(_ appearance: MarkdownTableAppearance) -> some View {
        environment(\.markdownTableAppearance, appearance)
    }
}
