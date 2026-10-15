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

/// Table cells, as the format panels see them (Craft's Table Style is the cells' own
/// panel): the edited one, its row or column picked by its bar, or the whole table
/// selected. Any of them takes an alignment, a typeface, a fill and its table's settings;
/// a text or number column's body cell a number format; a text column's marks and a
/// colour on its text. A setting goes on the cells that take it, all in one step.
@MainActor
struct DocFormatCell: DocFormattable {
    enum Scope: Equatable {
        case cell
        case line(DocTableLine)
        case table
    }

    /// The edited cell (the whole table's: its first).
    let key: DocCellKey
    let scope: Scope
    let tables: DocTableController

    var cells: [DocCellKey] { tables.cells(scope, of: key) }

    var formats: DocFormats {
        cells.reduce(into: DocFormats()) { $0.formUnion(Self.formats(of: $1, in: tables)) }
    }

    static func formats(of key: DocCellKey, in tables: DocTableController) -> DocFormats {
        guard tables.isRestylable else { return [] }
        var formats: DocFormats = [.alignment, .typeface, .fill, .table]
        guard key.row != nil else { return formats }
        switch tables.columnType(key) {
        case .text?: formats.formUnion([.numberFormat, .marks, .color])
        case .number?: formats.insert(.numberFormat)
        default: break
        }
        return formats
    }

    /// The text selected in the edited cell, else all of each cell's.
    var ranges: [(block: DocBlockID, range: Range<Int>)] { cells.compactMap(tables.formatRange) }

    /// What the cells share (a setting they differ in: none); a cell's typeface is its
    /// table's when it has none of its own. The whole table's typeface is the table's.
    var style: CellStyle {
        let font = tables.demo.doc.block(key.block)?.font
        let all = cells.map { tables.cellStyle($0) }
        func shared<Value: Equatable>(_ value: (CellStyle) -> Value?) -> Value? {
            guard let first = all.first.flatMap(value), all.allSatisfy({ value($0) == first }) else { return nil }
            return first
        }
        let fonts: [Typeface?] = all.map { $0.font ?? font }
        let sharedFont = fonts.first.flatMap { first in fonts.allSatisfy { $0 == first } ? first : nil }
        return CellStyle(alignment: shared(\.alignment), font: sharedFont, number: shared(\.number), fill: shared(\.fill))
    }

    var table: DocKit.TableStyle { tables.tableStyle(key.block) }
    var size: (rows: Int, columns: Int) { tables.size(of: key.block) }

    /// `change` on each cell that takes `format`.
    func setStyle(_ format: DocFormats, _ change: (inout CellStyle) -> Void) {
        tables.setCellStyles(cells.filter { Self.formats(of: $0, in: tables).contains(format) }, change)
    }

    func setTable(_ change: (inout DocKit.TableStyle) -> Void) { tables.setTableStyle(key.block, change) }
    func resize(rows: Int? = nil, columns: Int? = nil) { tables.resize(key, rows: rows, columns: columns) }

    /// A setting pressed again goes back to the table's (Craft's alignment keys).
    func toggle(_ alignment: CellAlignment) {
        let next = style.alignment == alignment ? nil : alignment
        setStyle(.alignment) { $0.alignment = next }
    }

    /// The cells' own typeface; the whole table's is the table's, the cells' own going.
    func setFont(_ font: Typeface?) {
        if scope == .table {
            tables.setTableFont(key.block, font)
        } else {
            setStyle(.typeface) { $0.font = font }
        }
    }
}
