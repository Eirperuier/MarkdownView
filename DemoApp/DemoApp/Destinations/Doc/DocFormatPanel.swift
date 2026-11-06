//
//  DocFormatPanel.swift
//  DemoApp
//
//  The Mac's format panel: Craft's sections (the text styles as tiles, marks, lists
//  and indent as segments, the quote and the box as decorations, the colours, the
//  typefaces), floo's menu panel opened from the bar's Aa. It acts on the
//  selected blocks, or the block the cursor is in; marks on the selected text, or on the
//  selected blocks' text, and so does the colour. What the blocks take (DocFormattable)
//  decides: the shared sections stay, greyed where none of them takes one, and a kind's
//  own come after (a link's layout, an image's size and fit). In a table, the panel is
//  the cells' (Craft's Table Style): the table's size and headers, then the sections the
//  cell menu's Format shows (its text, its number format, its colours), whose choices
//  and palettes open as the menu's next level.
//

import FlooUIKit
import SwiftUI
import DocKit

private typealias Tokens = DocTokens
private typealias Metrics = DocTokens.Component.FormatPanel

/// The editor's selection, observable.
@MainActor
@Observable
final class DocCursor {
    var selection: DocSelection?
}

/// The format panels' state.
@MainActor
@Observable
final class DocPanels {
    /// The Mac's format panel (-docFormat YES opens with it).
    var showsFormat = UserDefaults.standard.bool(forKey: "docFormat")
    /// The phone's format sheet and its page, over the selected blocks.
    var sheetPage: DocFormatSheetPage?
    /// What Copy Format took, for Paste Format.
    var copiedFormat: DocCopiedFormat?
}

/// The format panel's sections: the blocks', or the cells'. Read inside a view's body,
/// so the panel follows the document and the selection.
@MainActor
struct DocFormatMenu {
    let editor: DocEditor

    private var formatting: DocFormatting { DocFormatting(editor: editor) }

    var sections: [FlooMenuSection] {
        let formatting = formatting
        if let cell = formatting.cell { return Self.tableSections(cell, formatting) + Self.cellSections(cell, formatting) }
        return blockSections(formatting)
    }

    // MARK: Blocks

    private func blockSections(_ formatting: DocFormatting) -> [FlooMenuSection] {
        let decorated = formatting.decorated
        var sections: [FlooMenuSection] = []
        // Text first offers its kinds; a link, file or image its layout, after the
        // segments (as Craft orders them).
        // Text styles: how big a block's text is (Craft's six, ⌃1–⌃6).
        if !decorated.isEmpty {
            sections.append(.init(String(localized: "Titles"), [.tiles(DocFormatting.styles.prefix(3).map { styleTile($0, formatting) }, title: "titles")]))
            sections.append(.init(String(localized: "Content"), [.tiles(DocFormatting.styles.suffix(3).map { styleTile($0, formatting) }, title: "content")]))
        }
        sections.append(.init(segments(formatting)))
        if formatting.takes(.layout) {
            sections.append(.init(String(localized: "Layout"), [.tiles(DocLayout.allCases.map { layout in
                FlooMenuTile(layout.title, image: ImageRenderer(content: layout.style.pictureImage).uiImage, isOn: editor.blocks.selectedLayouts == [layout]) { [editor] _ in
                    editor.blocks.setLayout(layout)
                }
            }, title: "layout")]))
        }
        if formatting.takes(.image) {
            let sizes = editor.blocks.selectedImageSizes
            let fits = editor.blocks.selectedImageFits
            sections.append(.init(String(localized: "Image Size"), [.tiles([
                FlooMenuTile(String(localized: "Auto"), symbol: "rectangle.center.inset.filled", isOn: sizes == [.auto]) { [editor] _ in editor.blocks.setImage(size: .auto) },
                FlooMenuTile(String(localized: "Large"), symbol: "rectangle", isOn: sizes == [.large]) { [editor] _ in editor.blocks.setImage(size: .large) },
            ], title: "image-size")]))
            sections.append(.init(String(localized: "Image Display"), [.tiles([
                FlooMenuTile(String(localized: "Fill"), symbol: "square.arrowtriangle.4.outward", isOn: fits == [.fill]) { [editor] _ in editor.blocks.setImage(fit: .fill) },
                FlooMenuTile(String(localized: "Fit"), symbol: "arrow.down.and.line.horizontal.and.arrow.up", isOn: fits == [.fit]) { [editor] _ in editor.blocks.setImage(fit: .fit) },
            ], title: "image-fit")]))
        }
        // Decorations (Craft's): the quote, its bar at the left (Craft's Focus; a kind
        // of text block here), and the grey box any blocks can sit in.
        if !decorated.isEmpty {
            sections.append(.init(String(localized: "Decorations"), [.tiles([
                FlooMenuTile(String(localized: "Quote"), symbol: "text.quote", isOn: formatting.kindIsOn(.quote), isEnabled: formatting.takes(.quote)) { _ in
                    formatting.toggleQuote()
                },
                FlooMenuTile(String(localized: "Block"), symbol: "square.text.square", isOn: formatting.isBoxed, isEnabled: formatting.takes(.box)) { _ in
                    formatting.toggleBox()
                },
            ], title: "decorations")]))
        }
        if !decorated.isEmpty || formatting.takes(.color) {
            sections.append(.init(String(localized: "Color"), [
                Self.textColors("color", formatting, none: Tokens.ColorRole.Surface.canvas, isEnabled: !formatting.markRanges.isEmpty),
            ]))
        }
        // The blocks' typeface (Craft's Font): pressed again, the document's.
        if !decorated.isEmpty {
            sections.append(.init(String(localized: "Font"), [.tiles(Typeface.blockOrder.map { font in
                FlooMenuTile(font.title, font: DocCellLook.uiFont(font), isOn: formatting.font == font, isEnabled: formatting.takes(.typeface)) { _ in
                    formatting.setFont(font)
                }
            }, title: "font")]))
        }
        return sections
    }

    private func segments(_ formatting: DocFormatting) -> [FlooMenuItem] {
        let hasText = !formatting.markRanges.isEmpty
        return [
            .docKeys("marks", DocTextFormat.marks.map { item in
                FlooMenuTile(item.title, symbol: item.symbol, showsTitle: false, isOn: formatting.markIsOn(item.mark), isEnabled: hasText) { _ in
                    formatting.toggle(item.mark)
                }
            }),
            .docKeys("lists", DocFormatting.lists.map { item in
                FlooMenuTile(item.title, symbol: item.symbol, showsTitle: false, isOn: formatting.kindIsOn(item.kind), isEnabled: formatting.takes(.list)) { _ in
                    formatting.toggleList(item.kind)
                }
            }),
            .docKeys("indent", [
                FlooMenuTile(String(localized: "Outdent"), symbol: "decrease.indent", showsTitle: false, isOn: false, isEnabled: formatting.canIndent(-1), isMomentary: true) { _ in
                    formatting.indent(by: -1)
                },
                FlooMenuTile(String(localized: "Indent"), symbol: "increase.indent", showsTitle: false, isOn: false, isEnabled: formatting.canIndent(1), isMomentary: true) { _ in
                    formatting.indent(by: 1)
                },
            ]),
        ]
    }

    private func styleTile(_ style: (key: String, title: String, size: CGFloat, weight: Font.Weight, kind: BlockKind),
                           _ formatting: DocFormatting) -> FlooMenuTile {
        let weight: UIFont.Weight = style.weight == .bold ? .bold : style.weight == .semibold ? .semibold : .regular
        return FlooMenuTile(style.title, font: .systemFont(ofSize: style.size, weight: weight), isOn: formatting.kindIsOn(style.kind),
                            isEnabled: formatting.takes(.textStyle)) { _ in
            formatting.setTextStyle(style.kind)
        }
    }

    // MARK: Colours

    /// Craft's text colours: none, the palette, and any colour (the system's picker);
    /// the one the text has is ringed.
    static func textColors(_ title: String, _ formatting: DocFormatting, none: Color, isEnabled: Bool = true) -> FlooMenuItem {
        let current = formatting.editor.common(.color, over: formatting.markRanges)
        let picked: String? = if case .color(let token)? = current, token.hasPrefix("#") { token } else { nil }
        let swatch = { (token: String?, title: String) in
            DocSwatch(id: token ?? "none", title: title, color: token.map(DocColors.swatch) ?? none, isOn: current == token.map(Mark.color)) {
                formatting.setColor(token)
            }
        }
        return .docSwatches(title, [swatch(nil, String(localized: "Default"))] + DocColors.palette.map { swatch($0.token, $0.title) },
                            well: .init(title: String(localized: "Other Color"), selected: picked.map { UIColor(DocColors.swatch($0)) }) { formatting.pickColor(Color(uiColor: $0)) },
                            isEnabled: isEnabled)
    }

    /// Craft's fills: none, six hues by three strengths twice, any colour.
    /// `none`: what None sets (a stripe's is `TableStyle.noStripe`, a cell's nil).
    static func fills(_ title: String, current: String?, none: String? = nil, set: @escaping (String?) -> Void) -> FlooMenuItem {
        let custom: String? = if let current, current.hasPrefix("#") { current } else { nil }
        return .docSwatches(title, DocColors.fillGrid.enumerated().map { index, swatch in
            let token = swatch ?? none
            return DocSwatch(id: token ?? "none-\(index)", title: swatch.map(DocColors.fillTitle) ?? String(localized: "None"),
                             color: token.flatMap(DocColors.fill) ?? Tokens.ColorRole.Surface.canvas, isOn: current == token) { set(token) }
        }, well: .init(title: String(localized: "Other Color"), selected: custom.flatMap(DocColors.fill).map { UIColor($0) }) { set(DocColors.hex(Color(uiColor: $0))) })
    }

    // MARK: Cells

    /// The table's: its rows and columns, its header row and column.
    static func tableSections(_ cell: DocFormatCell, _ formatting: DocFormatting) -> [FlooMenuSection] {
        let size = cell.size
        let table = cell.table
        let takes = formatting.takes(.table)
        return [
            .init([
                .stepper(String(localized: "Rows"), symbol: "rectangle.split.1x2", value: size.rows, range: 1...999, isEnabled: takes) { cell.resize(rows: $0) },
                .stepper(String(localized: "Columns"), symbol: "rectangle.split.2x1", value: size.columns, range: 1...999, isEnabled: takes) { cell.resize(columns: $0) },
            ]),
            .init(String(localized: "Header"), [
                .toggle(String(localized: "Header Row"), symbol: "rectangle.topthird.inset.filled", isOn: table.hasHeaderRow, isEnabled: takes) { on in
                    cell.setTable { $0.headerRow = on }
                },
                .toggle(String(localized: "Header Column"), symbol: "rectangle.leftthird.inset.filled", isOn: table.hasHeaderColumn, isEnabled: takes) { on in
                    cell.setTable { $0.headerColumn = on }
                },
            ]),
        ]
    }

    /// The cells' own (Craft's Format in the cell menu): their text's marks, alignment and
    /// typeface; how a number in them reads; the rows' stripe, their fill, their text's colour.
    static func cellSections(_ cell: DocFormatCell, _ formatting: DocFormatting) -> [FlooMenuSection] {
        let style = cell.style
        let table = cell.table
        let hasText = formatting.takes(.marks) && !formatting.markRanges.isEmpty
        let textColor: Color? = if case .color(let token)? = formatting.color { DocColors.swatch(token) } else { nil }
        let fonts: [Typeface?] = [nil] + Typeface.allCases
        return [
            .init(String(localized: "Text Style"), [
                .docKeys("cell-marks", DocTextFormat.marks.map { item in
                    FlooMenuTile(item.title, symbol: item.symbol, showsTitle: false, isOn: formatting.markIsOn(item.mark), isEnabled: hasText) { _ in
                        formatting.toggle(item.mark)
                    }
                }),
                .docKeys("cell-alignment", CellAlignment.allCases.map { alignment in
                    FlooMenuTile(alignment.title, symbol: alignment.symbol, showsTitle: false, isOn: style.alignment == alignment, isEnabled: formatting.takes(.alignment)) { _ in
                        cell.toggle(alignment)
                    }
                }),
                .choice(String(localized: "Font"), options: fonts.map { $0?.title ?? String(localized: "Default Font") },
                        selected: fonts.firstIndex(of: style.font), isEnabled: formatting.takes(.typeface)) { cell.setFont(fonts[$0]) },
            ]),
            .init(String(localized: "Cell Format"), [
                .submenu(String(localized: "Cell Format"), subtitle: style.number?.title ?? String(localized: "Plain Text"),
                         isEnabled: formatting.takes(.numberFormat), numbers(style.number) { format in
                    cell.setStyle(.numberFormat) { $0.number = format }
                }),
            ]),
            .init(String(localized: "Cell Style"), [
                .docColor(String(localized: "Alternating Row Color"), picked: table.stripe.flatMap(DocColors.fill), isEnabled: formatting.takes(.table),
                          [.init([fills("stripes", current: table.stripe, none: TableStyle.noStripe) { token in cell.setTable { $0.stripe = token } }])]),
                .docColor(String(localized: "Cell Fill Color"), picked: style.fill.flatMap(DocColors.fill), isEnabled: formatting.takes(.fill),
                          [.init([fills("fills", current: style.fill) { token in cell.setStyle(.fill) { $0.fill = token } }])]),
                .docColor(String(localized: "Text Color"), picked: textColor, isEnabled: formatting.takes(.color) && !formatting.markRanges.isEmpty,
                          [.init([textColors("text-colors", formatting, none: Tokens.ColorRole.Content.primary)])]),
            ]),
        ]
    }

    /// Plain text, number and percent; a currency in a submenu (Craft's).
    private static func numbers(_ current: CellNumberFormat?, set: @escaping (CellNumberFormat?) -> Void) -> [FlooMenuSection] {
        let currencies = CellNumberFormat.currencies.map { code in
            FlooMenuItem.action(CellNumberFormat.currency(code: code).title, isOn: current == .currency(code: code), keepsOpen: true) {
                set(.currency(code: code))
            }
        }
        return [
            .init([
                .action(String(localized: "Plain Text"), isOn: current == nil, keepsOpen: true) { set(nil) },
                .action(CellNumberFormat.number.title, isOn: current == .number, keepsOpen: true) { set(.number) },
                .action(CellNumberFormat.percent.title, isOn: current == .percent, keepsOpen: true) { set(.percent) },
            ]),
            .init([.submenu(String(localized: "Currency"), [.init(currencies)])]),
        ]
    }
}
