//
//  DocFormats.swift
//  DemoApp
//
//  What a block, or a table's cell, lets the format panels change (Craft's): each kind
//  of block says which of the panels' settings it takes, and so does a cell. The Mac's
//  panel and the phone's sheet show and enable their sections from it, and act only on
//  what takes them. Craft's Format panel keeps its shared sections in place, greyed where
//  the selection doesn't take them, and adds a kind's own (an image's size and fit, a
//  link's layout); a cell has a panel of its own, only what a cell takes.
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

    /// What every block takes: a level, the box.
    static let block: DocFormats = [.indent, .box]
    /// What a block of text takes.
    static let text: DocFormats = [.block, .textStyle, .marks, .list, .quote, .color]
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
        case .code, .math, .divider, .card, .view, .database, .collection, .page: .block
        }
    }
}

/// A table's cell, as the format panels see it (Craft's Table Style is a cell's own
/// panel): a body cell of a text column takes marks and a colour on its text. What else
/// Craft's has (alignment, a fill, number formats) DocKit can't keep yet.
@MainActor
struct DocFormatCell: DocFormattable {
    let key: DocCellKey
    let tables: DocTableController

    var formats: DocFormats { tables.holdsText(key) ? [.marks, .color] : [] }

    /// The text selected in it, else all of it.
    var range: (block: DocBlockID, range: Range<Int>)? { tables.formatRange(key) }
}
