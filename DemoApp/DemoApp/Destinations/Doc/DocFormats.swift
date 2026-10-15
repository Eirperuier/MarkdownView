//
//  DocFormats.swift
//  DemoApp
//
//  What a block, or a table's cell, lets the format panels change (Craft's): each kind
//  of block says which of the panels' settings it takes, and so does a cell. The Mac's
//  panel and the phone's sheet show and enable their sections from it, and act only on
//  what takes them. Craft's Format panel keeps its shared sections in place, greyed where
//  the selection doesn't take them, and adds a kind's own (an image's size and fit, a
//  link's layout); a cell has a panel of its own (Craft's Table Style), only what a cell
//  and its table take.
//

import DocKit

/// The settings the format panels offer.
struct DocFormats: OptionSet, Hashable {
    let rawValue: Int

    /// The six text styles (titles and content).
    static let textStyle = DocFormats(rawValue: 1 << 0)
    /// Bold, italic, strikethrough and code on its text.
    static let marks = DocFormats(rawValue: 1 << 1)
    /// The lists (to-do, toggle, bulleted, numbered).
    static let list = DocFormats(rawValue: 1 << 2)
    /// A level in or out.
    static let indent = DocFormats(rawValue: 1 << 3)
    /// The quote's bar (a kind of text block here).
    static let quote = DocFormats(rawValue: 1 << 4)
    /// The grey box.
    static let box = DocFormats(rawValue: 1 << 5)
    /// Its text's colour.
    static let color = DocFormats(rawValue: 1 << 6)
    /// A link's or a file's layout.
    static let layout = DocFormats(rawValue: 1 << 7)
    /// An image's size and fit.
    static let image = DocFormats(rawValue: 1 << 8)
    /// Where a cell's text sits: left, centred, right, justified.
    static let alignment = DocFormats(rawValue: 1 << 9)
    /// A block's or a cell's typeface.
    static let typeface = DocFormats(rawValue: 1 << 10)
    /// How a number in a cell reads (number, percent, currency).
    static let numberFormat = DocFormats(rawValue: 1 << 11)
    /// A cell's fill.
    static let fill = DocFormats(rawValue: 1 << 12)
    /// Its table's: its size, its header row and column, its rows' stripe.
    static let table = DocFormats(rawValue: 1 << 13)

    /// What every block takes: a level, the box.
    static let block: DocFormats = [.indent, .box]
    /// What a block of text takes.
    static let text: DocFormats = [.block, .textStyle, .marks, .list, .quote, .color, .typeface]
}

/// Something the format panels change, and what it takes.
@MainActor
protocol DocFormattable {
    var formats: DocFormats { get }
}

extension BlockKind: DocFormattable {
    /// Code and maths are text without marks or styles: their source is what they show.
    var formats: DocFormats {
        switch self {
        case .paragraph, .heading, .listItem, .quote, .caption: .text
        case .image: DocFormats.block.union(.image)
        case .link, .file: DocFormats.block.union(.layout)
        // A table's typeface is its cells' (theirs over it).
        case .database: DocFormats.block.union(.typeface)
        case .code, .math, .divider, .card, .view, .collection, .page: .block
        }
    }
}

/// A table's cell, as the format panels see it (Craft's Table Style is a cell's own
/// panel): any body cell takes an alignment, a typeface, a fill and its table's settings;
/// a text or number column's a number format; a text column's marks and a colour on its text.
@MainActor
struct DocFormatCell: DocFormattable {
    let key: DocCellKey
    let tables: DocTableController

    var formats: DocFormats {
        guard tables.isEditable, key.row != nil else { return [] }
        var formats: DocFormats = [.alignment, .typeface, .fill, .table]
        if tables.holdsNumbers(key) { formats.insert(.numberFormat) }
        if tables.holdsText(key) { formats.formUnion([.marks, .color]) }
        return formats
    }

    /// The text selected in it, else all of it.
    var range: (block: DocBlockID, range: Range<Int>)? { tables.formatRange(key) }

    var style: CellStyle { tables.cellStyle(key) }
    var table: DocKit.TableStyle { tables.tableStyle(key.block) }
    var size: (rows: Int, columns: Int) { tables.size(of: key.block) }

    func setStyle(_ change: (inout CellStyle) -> Void) { tables.setCellStyle(key, change) }
    func setTable(_ change: (inout DocKit.TableStyle) -> Void) { tables.setTableStyle(key.block, change) }
    func resize(rows: Int? = nil, columns: Int? = nil) { tables.resize(key, rows: rows, columns: columns) }

    /// A setting pressed again goes back to the table's (Craft's alignment keys).
    func toggle(_ alignment: CellAlignment) {
        setStyle { $0.alignment = $0.alignment == alignment ? nil : alignment }
    }
}
