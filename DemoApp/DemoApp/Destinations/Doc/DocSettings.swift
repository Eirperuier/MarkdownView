//
//  DocSettings.swift
//  DemoApp
//
//  What can be changed of what's selected, said once, four levels each answering one thing:
//  a target (what's selected) has pages (what's first, what's a level in, whether a touch
//  outside closes them), a page has sections (what belongs together), a section has rows,
//  and a row is one of three: keys, a line (its name, what sets it), or a list. A declaration
//  says only that; heights, gaps and lines between rows are DocFormatPage's, the same on every
//  page. A target the Mac's menus also read arranges the same keys for them (DocMenuTarget).
//

import DocKit
import FlooUIKit
import SwiftUI
import UIKit

/// One thing to press.
struct DocKey {
    enum Look {
        case symbol(String)
        case picture(UIImage)
        /// Its name in what it chooses; quiet for what's quieter on the page.
        case type(UIFont, isQuiet: Bool = false)
        /// Its name, plainly: what opens more.
        case label
        /// A quote's bar beside its name.
        case quote
        /// Its name in the box it's for.
        case box
        /// The colour there is, in a ring of colours; beside its name if it shows it.
        case colorRing(UIColor?)
        /// Its name (what's chosen now) on a key of its own: what opens the rest.
        case value
        /// A symbol beside its name, on one line.
        case labeled(String)
        /// A count between − and +.
        case count(Int, ClosedRange<Int>, set: @MainActor (Int) -> Void)
    }

    enum Action {
        case perform(@MainActor () -> Void)
        case open(DocPageID)
    }

    let id: String
    let title: String
    let look: Look
    var isOn = false
    var isEnabled = true
    var isMomentary = false
    /// Its name on a panel's tile, or only said.
    var showsTitle = true
    /// Its name as what it chooses really looks, where there's room to show it.
    var specimen: UIFont?
    var isDestructive = false
    /// Its colour while it's on; none, the accent.
    var tint: UIColor?
    let action: Action
}

/// The pages there are.
enum DocPageID: Hashable {
    /// What's used most of what's selected.
    case main
    case styles, colors, more, layout
    /// A cell's.
    case cellMain, cellFont, cellNumber, fill, stripe
    /// A collection's view's.
    case view, fields, groups, viewMore
    /// A chart's: what it measures, how it looks.
    case chartData, chartStyle
    /// A table's menu, and what's edited of it.
    case tableMenu, editTable
}

/// Things that each show or don't, dragged into an order.
struct DocSettingRow {
    let id: String
    let title: String
    var canMove = false
    let isOn: Bool
    var isEnabled = true
    let set: @MainActor (Bool) -> Void
}

struct DocSettingList {
    let rows: [DocSettingRow]
    /// One moved before another; none: to the end.
    var move: (@MainActor (String, String?) -> Void)?
}

/// Keys side by side in a row.
struct DocKeyGroup {
    enum Width {
        /// Sharing what's left in the row by this much.
        case share(CGFloat)
        case fixed(CGFloat)
    }

    let keys: [DocKey]
    /// One control, not keys apart.
    var isJoined = false
    var width = Width.share(1)
}

/// A row of a section.
enum DocPanelRow {
    case keys([DocKeyGroup])
    /// What it is on the left, what sets it on the right.
    case line(DocLine)
    case list(DocSettingList)

    static func tiles(_ keys: [DocKey], isJoined: Bool = false) -> DocPanelRow {
        .keys([DocKeyGroup(keys: keys, isJoined: isJoined)])
    }

    var keys: [DocKey] {
        if case .keys(let groups) = self { groups.flatMap(\.keys) } else { [] }
    }

    /// What decides the views it takes.
    var shape: [String] {
        switch self {
        case .keys(let groups): ["keys"] + groups.flatMap { $0.keys.map(\.id) }
        case .line(let line): line.shape
        case .list(let list): list.rows.map { DocPanelRow.listRow + $0.id }
        }
    }

    /// A list row's in a shape.
    static let listRow = "list:"
}

/// Rows that belong together.
struct DocPageSection {
    let rows: [DocPanelRow]

    init(_ rows: [DocPanelRow]) {
        self.rows = rows
    }

    init(lines: [DocLine]) {
        rows = lines.map(DocPanelRow.line)
    }
}

struct DocPanelPage {
    enum Content {
        case sections([DocPageSection])
        /// Not drawn as rows yet: floo's menu (the colour grids, a view's More).
        case menu([FlooMenuSection])
    }

    let id: DocPageID
    let content: Content
    /// What it's for is done with once the page is touched, and the touch does nothing else (a
    /// menu); otherwise it stays, what's behind it staying usable (settings of what's there).
    var closesOutside = false
    /// Choosing is all it's for: back to the page before.
    var returnsOnChoice = false

    init(_ id: DocPageID, closesOutside: Bool = false, returnsOnChoice: Bool = false, _ sections: [DocPageSection]) {
        self.id = id
        content = .sections(sections)
        self.closesOutside = closesOutside
        self.returnsOnChoice = returnsOnChoice
    }

    init(_ id: DocPageID, menu: [FlooMenuSection]) {
        self.id = id
        content = .menu(menu)
    }

    var sections: [DocPageSection] {
        if case .sections(let sections) = content { sections } else { [] }
    }
}

extension DocKey {
    @MainActor func press() {
        if case .perform(let perform) = action { perform() }
    }

    /// As a panel's tile.
    var tile: FlooMenuTile {
        var symbol: String?
        var image: UIImage?
        var font: UIFont?
        switch look {
        case .symbol(let name): symbol = name
        case .picture(let picture): image = picture
        case .type(let type, _): font = specimen ?? type
        case .labeled(let name): symbol = name
        case .quote: symbol = "text.quote"
        case .box: symbol = "square.text.square"
        case .label, .colorRing, .value, .count: break
        }
        let key = self
        return FlooMenuTile(title, symbol: symbol, image: image, font: font, showsTitle: showsTitle, isOn: isOn, isEnabled: isEnabled, isMomentary: isMomentary) { _ in key.press() }
    }
}

/// Something a panel changes.
@MainActor
protocol DocFormatTarget {
    var pages: [DocPanelPage] { get }
}

/// How the Mac's menus arrange the same things: format on a run of text, style on the look of a
/// block or cell, layout on the room it takes.
struct DocFormatSections {
    var style: [FlooMenuSection] = []
    var format: [FlooMenuSection] = []
    var layout: [FlooMenuSection] = []
}

/// A target the Mac's menus read too.
@MainActor
protocol DocMenuTarget: DocFormatTarget {
    var menu: DocFormatSections { get }
}

extension FlooMenuSection {
    /// Rows of keys as tiles.
    /// `live`: the keys as they are now, for a menu that stays open as one is pressed.
    static func keys(_ title: String? = nil, id: String, _ rows: [[DocKey]], live: @escaping @MainActor () -> [DocKey]) -> FlooMenuSection {
        FlooMenuSection(title, rows.enumerated().map { index, row in
            .tiles(row.map { key in
                var tile = key.tile
                tile.isOnNow = { live().first { $0.id == key.id }?.isOn ?? key.isOn }
                return tile
            }, title: rows.count == 1 ? id : "\(id)-\(index)")
        })
    }
}

/// The selected blocks, else the caret's. Shared settings stay, greyed where none of them
/// takes one (Craft's); a kind's own come only for it (a link's layout, an image's size).
@MainActor
struct DocSelectedBlocks: DocMenuTarget {
    let formatting: DocFormatting

    private var editor: DocEditor { formatting.editor }
    private var text: DocTextFormat { DocTextFormat(editor: editor, ranges: formatting.markRanges) }
    private var hasBlocks: Bool { !formatting.decorated.isEmpty }

    // MARK: Pages

    var pages: [DocPanelPage] {
        var pages = [
            mainPage,
            DocPanelPage(.colors, menu: [FlooMenuSection(nil, text.colorItems)]),
            DocPanelPage(.more, morePage),
            DocPanelPage(.layout, layoutPage),
        ]
        if hasBlocks {
            let styles = styleKeys
            pages.append(DocPanelPage(.styles, returnsOnChoice: true, [DocPageSection([.tiles(Array(styles.prefix(3))), .tiles(Array(styles.suffix(3)))])]))
        }
        return pages
    }

    private var mainPage: DocPanelPage {
        let tools = DocPanelRow.keys([DocKeyGroup(keys: listKeys, isJoined: true, width: .share(4)), DocKeyGroup(keys: indentKeys, isJoined: true, width: .share(2))])
        guard hasBlocks else { return DocPanelPage(.main, [DocPageSection([tools])]) }
        let formatting = formatting
        let picked: UIColor? = if case .color(let token)? = formatting.color { UIColor(DocColors.swatch(token)) } else { nil }
        let short = styleKeys.filter { shortStyles.contains($0.id) }
        let moreStyles = DocKey(id: "more-styles", title: String(localized: "More…"), look: .label, isEnabled: formatting.takes(.textStyle), isMomentary: true, action: .open(.styles))
        let color = DocKey(id: "colors", title: String(localized: "Text Color"), look: .colorRing(picked), isEnabled: !formatting.markRanges.isEmpty, isMomentary: true, showsTitle: false, action: .open(.colors))
        let more = DocKey(id: "more", title: String(localized: "More"), look: .symbol("ellipsis"), isMomentary: true, showsTitle: false, action: .open(.more))
        return DocPanelPage(.main, [DocPageSection([
            .keys([DocKeyGroup(keys: short, width: .share(CGFloat(short.count))), DocKeyGroup(keys: [moreStyles])]),
            tools,
            .keys([
                DocKeyGroup(keys: decorationKeys, width: .share(2)),
                DocKeyGroup(keys: [color], width: .fixed(DocPanelRhythm.colorKey)),
                DocKeyGroup(keys: [more], width: .fixed(DocPanelRhythm.iconKey)),
            ]),
        ])])
    }

    private var morePage: [DocPageSection] {
        var sections = [DocPageSection([.tiles(text.selectionMarks, isJoined: true)])]
        if hasBlocks {
            sections.append(DocPageSection([.tiles(fontKeys)]))
            sections.append(DocPageSection([.tiles(DocFormatMenu.formatKeys(formatting, copies: formatting.decorated.count == 1))]))
        }
        return sections
    }

    /// Only what's selected has (a link's or a file's layout, an image's fit and size).
    private var layoutPage: [DocPageSection] {
        let image = [imageFitKeys, imageSizeKeys].filter { !$0.isEmpty }.map { DocKeyGroup(keys: $0, isJoined: true) }
        var rows: [DocPanelRow] = image.isEmpty ? [] : [.keys(image)]
        if !layoutKeys.isEmpty { rows.append(.tiles(layoutKeys, isJoined: true)) }
        return [DocPageSection(rows)]
    }

    // MARK: The Mac's menus

    var menu: DocFormatSections {
        var sections = DocFormatSections(format: text.menuFormatSections)
        let lists = FlooMenuSection.keys(id: "lists", [listKeys], live: { listKeys })
        let indent = FlooMenuSection.keys(id: "indent", [indentKeys], live: { indentKeys })
        if hasBlocks {
            let styles = styleKeys
            sections.style = [
                .keys(String(localized: "Text Style"), id: "text-style", [Array(styles.prefix(3)), Array(styles.suffix(3))], live: { styleKeys }),
                lists,
                indent,
                .keys(String(localized: "Decorations"), id: "decorations", [decorationKeys], live: { decorationKeys }),
                .keys(String(localized: "Font"), id: "font", [fontKeys], live: { fontKeys }),
            ]
        } else {
            sections.style = [lists, indent]
        }
        if !imageFitKeys.isEmpty { sections.layout.append(.keys(String(localized: "Image Display"), id: "image-fit", [imageFitKeys], live: { imageFitKeys })) }
        if !imageSizeKeys.isEmpty { sections.layout.append(.keys(String(localized: "Image Size"), id: "image-size", [imageSizeKeys], live: { imageSizeKeys })) }
        if !layoutKeys.isEmpty { sections.layout.append(.keys(String(localized: "Layout"), id: "layout", [layoutKeys], live: { layoutKeys })) }
        return sections
    }

    // MARK: Keys

    private var styleKeys: [DocKey] { DocFormatting.styles.map(styleKey) }

    private var listKeys: [DocKey] {
        let formatting = formatting
        return DocFormatting.lists.map { item in
            DocKey(id: item.id, title: item.title, look: .symbol(item.symbol), isOn: formatting.kindIsOn(item.kind), isEnabled: formatting.takes(.list), showsTitle: false,
                   action: .perform { formatting.toggleList(item.kind) })
        }
    }

    private var indentKeys: [DocKey] {
        let formatting = formatting
        return [
            DocKey(id: "outdent", title: String(localized: "Outdent"), look: .symbol("decrease.indent"), isEnabled: formatting.canIndent(-1), isMomentary: true, showsTitle: false,
                   action: .perform { formatting.indent(by: -1) }),
            DocKey(id: "indent", title: String(localized: "Indent"), look: .symbol("increase.indent"), isEnabled: formatting.canIndent(1), isMomentary: true, showsTitle: false,
                   action: .perform { formatting.indent(by: 1) }),
        ]
    }

    private var decorationKeys: [DocKey] {
        let formatting = formatting
        return [
            DocKey(id: "quote", title: String(localized: "Quote"), look: .quote, isOn: formatting.kindIsOn(.quote), isEnabled: formatting.takes(.quote),
                   action: .perform { formatting.toggleQuote() }),
            DocKey(id: "block", title: String(localized: "Block"), look: .box, isOn: formatting.isBoxed, isEnabled: formatting.takes(.box),
                   action: .perform { formatting.toggleBox() }),
        ]
    }

    /// Pressed again, the document's.
    private var fontKeys: [DocKey] {
        let formatting = formatting
        return Typeface.blockOrder.map { font in
            DocKey(id: font.rawValue, title: font.title, look: .type(DocCellLook.uiFont(font)), isOn: formatting.font == font, isEnabled: formatting.takes(.typeface),
                   specimen: FlooFormMetrics.isMacIdiom ? nil : DocCellLook.uiFont(font).withSize(17),
                   action: .perform { formatting.setFont(font) })
        }
    }

    /// The two most used, and the one the blocks have if it's another (Craft's).
    private var shortStyles: [String] {
        let common = DocFormatting.styles.filter { $0.kind == .heading(level: 3) || $0.kind == .paragraph }
        guard let current = DocFormatting.styles.first(where: { formatting.kindIsOn($0.kind) }), !common.contains(where: { $0.key == current.key }) else {
            return common.map(\.key)
        }
        return [current.key] + common.map(\.key)
    }

    private func styleKey(_ style: (key: String, title: String, size: CGFloat, weight: Font.Weight, kind: BlockKind)) -> DocKey {
        let formatting = formatting
        let weight: UIFont.Weight = style.weight == .bold ? .bold : style.weight == .semibold ? .semibold : .regular
        let size: CGFloat = FlooFormMetrics.isMacIdiom ? style.size : style.kind == .caption ? 15 : 17
        return DocKey(id: style.key, title: style.title, look: .type(.systemFont(ofSize: size, weight: weight), isQuiet: style.kind == .caption),
                      isOn: formatting.kindIsOn(style.kind), isEnabled: formatting.takes(.textStyle),
                      specimen: .systemFont(ofSize: Self.specimenSize(style.kind), weight: weight),
                      action: .perform { formatting.setTextStyle(style.kind) })
    }

    /// A text style's size where its name shows what it is: the page's own on a phone
    /// (title1, title2, title3, headline, body, a caption), scaled to a tile on the Mac.
    private static func specimenSize(_ kind: BlockKind) -> CGFloat {
        let mac = FlooFormMetrics.isMacIdiom
        return switch kind {
        case .heading(level: 1): mac ? 20 : 28
        case .heading(level: 2): mac ? 17 : 22
        case .heading(level: 3): mac ? 15 : 20
        case .caption: mac ? 11 : 13
        default: mac ? 13 : 17
        }
    }

    private var imageFitKeys: [DocKey] {
        let blocks = editor.blocks
        let fits = blocks.selectedImageFits
        guard !fits.isEmpty else { return [] }
        return [
            DocKey(id: "fit", title: String(localized: "Fit"), look: .symbol("arrow.down.and.line.horizontal.and.arrow.up"), isOn: fits == [.fit], action: .perform { blocks.setImage(fit: .fit) }),
            DocKey(id: "fill", title: String(localized: "Fill"), look: .symbol("square.arrowtriangle.4.outward"), isOn: fits == [.fill], action: .perform { blocks.setImage(fit: .fill) }),
        ]
    }

    private var imageSizeKeys: [DocKey] {
        let blocks = editor.blocks
        let sizes = blocks.selectedImageSizes
        guard !sizes.isEmpty else { return [] }
        return [
            DocKey(id: "auto", title: String(localized: "Auto"), look: .symbol("rectangle.center.inset.filled"), isOn: sizes == [.auto], action: .perform { blocks.setImage(size: .auto) }),
            DocKey(id: "large", title: String(localized: "Large"), look: .symbol("rectangle"), isOn: sizes == [.large], action: .perform { blocks.setImage(size: .large) }),
        ]
    }

    private var layoutKeys: [DocKey] {
        let blocks = editor.blocks
        let layouts = blocks.selectedLayouts
        guard !layouts.isEmpty else { return [] }
        return DocLayout.allCases.map { layout in
            DocKey(id: "layout-\(layout.title)", title: layout.title, look: .picture(layout.style.picture), isOn: layouts == [layout], action: .perform { blocks.setLayout(layout) })
        }
    }
}

/// A table's cells (Craft's Table Style): their look, their text, and the table they make up.
@MainActor
struct DocSelectedCells: DocMenuTarget {
    let cell: DocFormatCell
    let formatting: DocFormatting

    private var text: DocTextFormat { DocTextFormat(editor: formatting.editor, ranges: formatting.markRanges) }

    var menu: DocFormatSections {
        DocFormatSections(style: style, format: text.menuFormatSections, layout: [])
    }

    /// What's of the whole table: how many rows and columns, its headers, its stripes.
    var tableSection: DocPageSection {
        let cell = cell
        let table = cell.table
        let size = cell.size
        let takes = formatting.takes(.table)
        return DocPageSection([
            .tiles([
                DocKey(id: "table-rows", title: String(localized: "Rows"), look: .count(size.rows, 1...999, set: { cell.resize(rows: $0) }), isEnabled: takes, action: .perform {}),
                DocKey(id: "table-columns", title: String(localized: "Columns"), look: .count(size.columns, 1...999, set: { cell.resize(columns: $0) }), isEnabled: takes, action: .perform {}),
            ]),
            .tiles([
                DocKey(id: "header-row", title: String(localized: "Header Row"), look: .labeled("rectangle.topthird.inset.filled"), isOn: table.hasHeaderRow, isEnabled: takes,
                       action: .perform { cell.setTable { $0.headerRow = !table.hasHeaderRow } }),
                DocKey(id: "header-column", title: String(localized: "Header Column"), look: .labeled("rectangle.leftthird.inset.filled"), isOn: table.hasHeaderColumn, isEnabled: takes,
                       action: .perform { cell.setTable { $0.headerColumn = !table.hasHeaderColumn } }),
            ]),
            .tiles([
                DocKey(id: "stripe", title: String(localized: "Alternating Row Color"), look: .colorRing(table.stripe.flatMap(DocColors.fill).map { UIColor($0) }),
                       isOn: table.stripe != TableStyle.noStripe, isEnabled: takes, action: .open(.stripe)),
            ]),
        ])
    }

    /// The first: the marks, not a level in, a cell's text being what's edited; the alignment;
    /// the font and the number format, each saying what it is now; the fill and the text's colour.
    /// What's of the whole table is Edit Table's (`tableSection`).
    var pages: [DocPanelPage] {
        let cell = cell
        let formatting = formatting
        let style = cell.style
        let table = cell.table
        let size = cell.size
        let takes = formatting.takes(.table)
        let color: UIColor? = if case .color(let token)? = formatting.color { UIColor(DocColors.swatch(token)) } else { nil }
        let fonts: [Typeface?] = [nil] + Typeface.allCases
        let fontKeys = fonts.map { font in
            DocKey(id: "font-\(font?.rawValue ?? "default")", title: font?.title ?? String(localized: "Default"),
                   look: .type(font.map { DocCellLook.uiFont($0).withSize(DocPanelRhythm.text) } ?? .systemFont(ofSize: DocPanelRhythm.text)), isOn: style.font == font,
                   specimen: font.map { DocCellLook.uiFont($0).withSize(DocPanelRhythm.text) } ?? .systemFont(ofSize: DocPanelRhythm.text),
                   action: .perform { cell.setFont(font) })
        }
        let setNumber = { (format: CellNumberFormat?) in cell.setStyle(.numberFormat) { $0.number = format } }
        let number = { (id: String, title: String, format: CellNumberFormat?) in
            DocKey(id: id, title: title, look: .type(.systemFont(ofSize: DocPanelRhythm.text)), isOn: style.number == format, action: .perform { setNumber(format) })
        }
        let currencies = CellNumberFormat.currencies
        let alignment = CellAlignment.allCases.map { alignment in
            DocKey(id: "align-\(alignment.rawValue)", title: alignment.title, look: .symbol(alignment.symbol), isOn: style.alignment == alignment,
                   isEnabled: formatting.takes(.alignment), showsTitle: false, action: .perform { cell.toggle(alignment) })
        }
        let openers = [
            DocKey(id: "cell-font", title: style.font?.title ?? String(localized: "Default Font"), look: .value, isOn: style.font != nil,
                   isEnabled: formatting.takes(.typeface), action: .open(.cellFont)),
            DocKey(id: "cell-number", title: style.number?.title ?? String(localized: "Plain Text"), look: .value, isOn: style.number != nil,
                   isEnabled: formatting.takes(.numberFormat), action: .open(.cellNumber)),
        ]
        let more = [
            DocKey(id: "cell-fill", title: String(localized: "Fill"), look: .colorRing(style.fill.flatMap(DocColors.fill).map { UIColor($0) }), isOn: style.fill != nil,
                   isEnabled: formatting.takes(.fill), action: .open(.fill)),
            DocKey(id: "cell-text", title: String(localized: "Text"), look: .colorRing(color), isOn: formatting.color != nil,
                   isEnabled: formatting.takes(.color) && !formatting.markRanges.isEmpty, action: .open(.colors)),
        ]
        let numbers = [
            number("number-plain", String(localized: "Plain Text"), nil),
            number("number-number", CellNumberFormat.number.title, .number),
            number("number-percent", CellNumberFormat.percent.title, .percent),
        ]
        return [
            DocPanelPage(.cellMain, [DocPageSection([.tiles(text.selectionMarks, isJoined: true), .tiles(alignment, isJoined: true), .tiles(openers), .tiles(more)])]),
            DocPanelPage(.cellFont, returnsOnChoice: true, [DocPageSection([.tiles(Array(fontKeys.prefix(3))), .tiles(Array(fontKeys.suffix(2)))])]),
            DocPanelPage(.cellNumber, returnsOnChoice: true, [DocPageSection([.tiles(numbers), .tiles(currencies.map { number("number-\($0)", $0, .currency(code: $0)) })])]),
            DocPanelPage(.colors, menu: [FlooMenuSection(nil, text.colorItems)]),
            DocPanelPage(.fill, menu: [FlooMenuSection(nil, [DocFormatMenu.fills("fills", current: style.fill) { token in cell.setStyle(.fill) { $0.fill = token } }])]),
            DocPanelPage(.stripe, menu: [FlooMenuSection(nil, [DocFormatMenu.fills("stripes", current: table.stripe, none: TableStyle.noStripe) { token in cell.setTable { $0.stripe = token } }])]),
        ]
    }

    private var style: [FlooMenuSection] {
        let cell = cell
        let formatting = formatting
        let style = cell.style
        let fonts: [Typeface?] = [nil] + Typeface.allCases
        return [
            FlooMenuSection(String(localized: "Text Style"), [
                .docKeys("cell-alignment", CellAlignment.allCases.map { alignment in
                    var tile = FlooMenuTile(alignment.title, symbol: alignment.symbol, showsTitle: false, isOn: style.alignment == alignment, isEnabled: formatting.takes(.alignment)) { _ in
                        cell.toggle(alignment)
                    }
                    tile.isOnNow = { cell.style.alignment == alignment }
                    return tile
                }),
                .choice(String(localized: "Font"), options: fonts.map { $0?.title ?? String(localized: "Default Font") },
                        selected: fonts.firstIndex(of: style.font), isEnabled: formatting.takes(.typeface)) { cell.setFont(fonts[$0]) },
                .submenu(String(localized: "Cell Format"), subtitle: style.number?.title ?? String(localized: "Plain Text"),
                         isEnabled: formatting.takes(.numberFormat), DocFormatMenu.numbers(style.number) { format in
                    cell.setStyle(.numberFormat) { $0.number = format }
                }),
            ]),
            FlooMenuSection(String(localized: "Cell Style"), [
                .docColor(String(localized: "Cell Fill Color"), picked: style.fill.flatMap(DocColors.fill), isEnabled: formatting.takes(.fill),
                          [.init([DocFormatMenu.fills("fills", current: style.fill) { token in cell.setStyle(.fill) { $0.fill = token } }])]),
            ]),
        ]
    }
}
