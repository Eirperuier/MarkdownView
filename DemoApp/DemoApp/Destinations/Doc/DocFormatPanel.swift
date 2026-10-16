//
//  DocFormatPanel.swift
//  DemoApp
//
//  The Mac's format panel: Craft's sections (the text styles as tiles, marks, lists
//  and indent as segments, the quote and the box as decorations, the colours, the
//  typefaces), FlooDesign's menu of controls opened from the bar's Aa. It acts on the
//  selected blocks, or the block the cursor is in; marks on the selected text, or on the
//  selected blocks' text, and so does the colour. What the blocks take (DocFormattable)
//  decides: the shared sections stay, greyed where none of them takes one, and a kind's
//  own come after (a link's layout, an image's size and fit). In a table, the panel is
//  the cells' (Craft's Table Style): the table's size and headers, then the sections the
//  cell menu's Format shows (its text, its number format, its colours), whose choices
//  and palettes open as the menu's next level.
//

import SwiftUI
import DocKit
import FlooDesign

private typealias Tokens = FlooDesignTokens
private typealias Metrics = FlooDesignTokens.Component.FormatPanel
private typealias Controls = FlooDesignTokens.Component.ActionMenu.Controls

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

    var sections: [FlooDesignActionMenuSection] {
        let formatting = formatting
        if let cell = formatting.cell { return Self.tableSections(cell, formatting) + Self.cellSections(cell, formatting) }
        return blockSections(formatting)
    }

    // MARK: Blocks

    private func blockSections(_ formatting: DocFormatting) -> [FlooDesignActionMenuSection] {
        let decorated = formatting.decorated
        var sections: [FlooDesignActionMenuSection] = []
        // Text first offers its kinds; a link, file or image its layout, after the
        // segments (as Craft orders them).
        // Text styles: how big a block's text is (Craft's six, ⌃1–⌃6).
        if !decorated.isEmpty {
            sections.append(.init(String(localized: "Titles"), controls: [.tiles("titles", DocFormatting.styles.prefix(3).map { styleTile($0, formatting) })]))
            sections.append(.init(String(localized: "Content"), controls: [.tiles("content", DocFormatting.styles.suffix(3).map { styleTile($0, formatting) })]))
        }
        sections.append(.init(controls: segments(formatting)))
        if formatting.takes(.layout) {
            sections.append(.init(String(localized: "Layout"), controls: [.tiles("layout", DocLayout.allCases.map { layout in
                FlooDesignMenuTile(id: "layout-\(layout)", help: layout.title, isOn: editor.blocks.selectedLayouts == [layout]) {
                    editor.blocks.setLayout(layout)
                } label: {
                    FlooDesignMediaStyleGlyph(layout.style)
                        .frame(maxWidth: .infinity, minHeight: Controls.tallTile)
                }
            })]))
        }
        if formatting.takes(.image) {
            let sizes = editor.blocks.selectedImageSizes
            let fits = editor.blocks.selectedImageFits
            sections.append(.init(String(localized: "Image Size"), controls: [.tiles("image-size", [
                imageTile(String(localized: "Auto"), symbol: "rectangle.center.inset.filled", isOn: sizes == [.auto]) { editor.blocks.setImage(size: .auto) },
                imageTile(String(localized: "Large"), symbol: "rectangle", isOn: sizes == [.large]) { editor.blocks.setImage(size: .large) },
            ])]))
            sections.append(.init(String(localized: "Image Display"), controls: [.tiles("image-fit", [
                imageTile(String(localized: "Fill"), symbol: "square.arrowtriangle.4.outward", isOn: fits == [.fill]) { editor.blocks.setImage(fit: .fill) },
                imageTile(String(localized: "Fit"), symbol: "arrow.down.and.line.horizontal.and.arrow.up", isOn: fits == [.fit]) { editor.blocks.setImage(fit: .fit) },
            ])]))
        }
        // Decorations (Craft's): the quote, its bar at the left (Craft's Focus; a kind
        // of text block here), and the grey box any blocks can sit in.
        if !decorated.isEmpty {
            sections.append(.init(String(localized: "Decorations"), controls: [.tiles("decorations", [
                FlooDesignMenuTile(id: "quote", help: String(localized: "Quote"), isOn: formatting.kindIsOn(.quote), isEnabled: formatting.takes(.quote),
                                   identifier: "format-quote") {
                    formatting.toggleQuote()
                } label: {
                    HStack(spacing: Tokens.Space.md) {
                        Capsule().frame(width: Metrics.quoteBar.width, height: Metrics.quoteBar.height)
                        Text("Quote").font(Controls.label)
                    }
                    .frame(maxWidth: .infinity, minHeight: Controls.tallTile)
                },
                FlooDesignMenuTile(id: "block", help: String(localized: "Block"), isOn: formatting.isBoxed, isEnabled: formatting.takes(.box),
                                   identifier: "format-block") {
                    formatting.toggleBox()
                } label: {
                    Text("Block")
                        .font(Controls.label)
                        .frame(maxWidth: .infinity, minHeight: Controls.tallTile - 12)
                        .background(Tokens.ColorRole.Surface.pressed, in: .rect(cornerRadius: Tokens.Radius.sm, style: .continuous))
                        .padding(Tokens.Space.sm - 2)
                },
            ])]))
        }
        if !decorated.isEmpty || formatting.takes(.color) {
            sections.append(.init(String(localized: "Color"), controls: [
                .swatches("color", isEnabled: !formatting.markRanges.isEmpty, Self.textColors(formatting, none: Tokens.ColorRole.Surface.canvas, identifier: "color")),
            ]))
        }
        // The blocks' typeface (Craft's Font): pressed again, the document's.
        if !decorated.isEmpty {
            sections.append(.init(String(localized: "Font"), controls: [.tiles("font", isEnabled: formatting.takes(.typeface), Typeface.blockOrder.map { font in
                FlooDesignMenuTile(id: "font-\(font.rawValue)", help: font.title, isOn: formatting.font == font, identifier: "format-font-\(font.rawValue)") {
                    formatting.setFont(font)
                } label: {
                    VStack(spacing: Tokens.Space.xs) {
                        Text(font.sample)
                            .font(.system(size: Metrics.fontSample, design: DocCellLook.design(font)))
                        Text(font.title)
                            .font(Metrics.fontName)
                            .foregroundStyle(Tokens.ColorRole.Content.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: Metrics.fontTile)
                }
            })]))
        }
        return sections
    }

    private func segments(_ formatting: DocFormatting) -> [FlooDesignMenuControl] {
        let hasText = !formatting.markRanges.isEmpty
        return [
            .segments("marks", DocTextFormat.marks.map { item in
                .init(id: item.id, symbol: item.symbol, title: item.title, isOn: formatting.markIsOn(item.mark), isEnabled: hasText) {
                    formatting.toggle(item.mark)
                }
            }),
            .segments("lists", DocFormatting.lists.map { item in
                .init(id: item.id, symbol: item.symbol, title: item.title, isOn: formatting.kindIsOn(item.kind), isEnabled: formatting.takes(.list)) {
                    formatting.toggleList(item.kind)
                }
            }),
            .segments("indent", [
                .init(id: "outdent", symbol: "decrease.indent", title: String(localized: "Outdent"), isOn: false, isEnabled: formatting.canIndent(-1)) {
                    formatting.indent(by: -1)
                },
                .init(id: "indent", symbol: "increase.indent", title: String(localized: "Indent"), isOn: false, isEnabled: formatting.canIndent(1)) {
                    formatting.indent(by: 1)
                },
            ]),
        ]
    }

    private func styleTile(_ style: (key: String, title: String, size: CGFloat, weight: Font.Weight, kind: BlockKind),
                           _ formatting: DocFormatting) -> FlooDesignMenuTile {
        FlooDesignMenuTile(id: "style-\(style.key)", help: "⌃\(style.key)", isOn: formatting.kindIsOn(style.kind),
                           isEnabled: formatting.takes(.textStyle), identifier: "format-style-\(style.key)") {
            formatting.setTextStyle(style.kind)
        } label: {
            Text(style.title)
                .font(.system(size: style.size, weight: style.weight))
                .frame(maxWidth: .infinity, minHeight: Tokens.Component.Tile.minHeight)
        }
    }

    /// An image's size or fit: its name, and its symbol at the right (Craft's).
    private func imageTile(_ title: String, symbol: String, isOn: Bool, perform: @escaping () -> Void) -> FlooDesignMenuTile {
        FlooDesignMenuTile(id: title, help: title, isOn: isOn, perform: perform) {
            HStack {
                Text(title).font(Controls.label)
                Spacer(minLength: Tokens.Space.xs)
                Image(systemName: symbol).font(Controls.label)
            }
            .padding(.horizontal, Tokens.Space.md)
            .frame(maxWidth: .infinity, minHeight: Controls.tallTile)
        }
    }

    // MARK: Colours

    /// Craft's text colours: none, the palette, and any colour (the system's picker);
    /// the one the text has is ringed.
    static func textColors(_ formatting: DocFormatting, none: Color, identifier: String) -> FlooDesignMenuSwatches {
        let current = formatting.editor.common(.color, over: formatting.markRanges)
        let picked: String? = if case .color(let token)? = current, token.hasPrefix("#") { token } else { nil }
        let swatch = { (token: String?, title: String) in
            FlooDesignMenuSwatches.Swatch(id: token ?? "none", title: title, fill: token.map(DocColors.swatch) ?? none,
                                          isOn: current == token.map(Mark.color), identifier: "\(identifier)-\(token ?? "none")") {
                formatting.setColor(token)
            }
        }
        return FlooDesignMenuSwatches(chosen: .ring(Tokens.ColorRole.Content.primary),
                                      [swatch(nil, String(localized: "Default"))] + DocColors.palette.map { swatch($0.token, $0.title) },
                                      well: .init(title: String(localized: "Other Color"), picked: picked.map(DocColors.swatch) ?? none,
                                                  selection: Binding { picked.map(DocColors.swatch) ?? .primary } set: { formatting.pickColor($0) },
                                                  identifier: "\(identifier)-custom"))
    }

    /// Craft's fills: none, six hues by three strengths twice, any colour.
    /// `none`: what None sets (a stripe's is `TableStyle.noStripe`, a cell's nil).
    static func fills(current: String?, none: String? = nil, set: @escaping (String?) -> Void) -> FlooDesignMenuSwatches {
        let custom: String? = if let current, current.hasPrefix("#") { current } else { nil }
        return FlooDesignMenuSwatches(shape: .rounded, DocColors.fillGrid.enumerated().map { index, swatch in
            let token = swatch ?? none
            let title = swatch.map(DocColors.fillTitle) ?? String(localized: "None")
            return .init(id: token ?? "none-\(index)", title: title, fill: token.flatMap(DocColors.fill) ?? Tokens.ColorRole.Surface.canvas,
                         isOn: current == token, identifier: "fill-\(token ?? "none")") { set(token) }
        }, well: .init(title: String(localized: "Other Color"), picked: custom.flatMap(DocColors.fill),
                       selection: Binding { custom.flatMap(DocColors.fill) ?? .primary } set: { set(DocColors.hex($0)) }))
    }

    // MARK: Cells

    /// The table's: its rows and columns, its header row and column.
    static func tableSections(_ cell: DocFormatCell, _ formatting: DocFormatting) -> [FlooDesignActionMenuSection] {
        let size = cell.size
        let table = cell.table
        let takes = formatting.takes(.table)
        let keys = { (title: String) in (fewer: String(localized: "Remove \(title)"), more: String(localized: "Add \(title)")) }
        return [
            .init(controls: [
                .stepper(String(localized: "Rows"), symbol: "rectangle.split.1x2", value: size.rows, least: 1, keys: keys(String(localized: "Rows")),
                         isEnabled: takes) { cell.resize(rows: $0) },
                .stepper(String(localized: "Columns"), symbol: "rectangle.split.2x1", value: size.columns, least: 1, keys: keys(String(localized: "Columns")),
                         isEnabled: takes) { cell.resize(columns: $0) },
            ]),
            .init(String(localized: "Header"), controls: [
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
    static func cellSections(_ cell: DocFormatCell, _ formatting: DocFormatting) -> [FlooDesignActionMenuSection] {
        let style = cell.style
        let table = cell.table
        let hasText = formatting.takes(.marks) && !formatting.markRanges.isEmpty
        let textColor: Color? = if case .color(let token)? = formatting.color { DocColors.swatch(token) } else { nil }
        return [
            .init(String(localized: "Text Style"), controls: [
                .segments("cell-marks", DocTextFormat.marks.map { item in
                    .init(id: item.id, symbol: item.symbol, title: item.title, isOn: formatting.markIsOn(item.mark), isEnabled: hasText) {
                        formatting.toggle(item.mark)
                    }
                }),
                .segments("cell-alignment", CellAlignment.allCases.map { alignment in
                    .init(id: alignment.rawValue, symbol: alignment.symbol, title: alignment.title, isOn: style.alignment == alignment,
                          isEnabled: formatting.takes(.alignment)) {
                        cell.toggle(alignment)
                    }
                }),
                .picker(String(localized: "Font"), value: style.font?.title ?? String(localized: "Default Font"), sample: (style.font ?? .system).sample,
                        isEnabled: formatting.takes(.typeface), id: "cell-font", sections: [
                    .init(.rows, [.action(String(localized: "Default Font"), isOn: style.font == nil, id: "font-default") { cell.setFont(nil) }]
                        + Typeface.allCases.map { font in
                            .action(font.title, isOn: style.font == font, id: "font-\(font.rawValue)") { cell.setFont(font) }
                        }),
                ]),
            ]),
            .init(String(localized: "Cell Format"), controls: [
                .picker(String(localized: "Cell Format"), value: style.number?.title ?? String(localized: "Plain Text"),
                        isEnabled: formatting.takes(.numberFormat), id: "cell-number", sections: numbers(style.number) { format in
                    cell.setStyle(.numberFormat) { $0.number = format }
                }),
            ]),
            .init(String(localized: "Cell Style"), controls: [
                .color(String(localized: "Alternating Row Color"), picked: table.stripe.flatMap(DocColors.fill), isEnabled: formatting.takes(.table),
                       id: "cell-stripe", sections: [.init(controls: [.swatches("stripes", fills(current: table.stripe, none: TableStyle.noStripe) { token in cell.setTable { $0.stripe = token } })])]),
                .color(String(localized: "Cell Fill Color"), picked: style.fill.flatMap(DocColors.fill), isEnabled: formatting.takes(.fill),
                       id: "cell-fill", sections: [.init(controls: [.swatches("fills", fills(current: style.fill) { token in cell.setStyle(.fill) { $0.fill = token } })])]),
                .color(String(localized: "Text Color"), picked: textColor, isEnabled: formatting.takes(.color) && !formatting.markRanges.isEmpty,
                       id: "cell-text-color", sections: [.init(controls: [
                           .swatches("text-colors", textColors(formatting, none: Tokens.ColorRole.Content.primary, identifier: "cell-color")),
                       ])]),
            ]),
        ]
    }

    /// Plain text, number and percent; a currency in a submenu (Craft's).
    private static func numbers(_ current: CellNumberFormat?, set: @escaping (CellNumberFormat?) -> Void) -> [FlooDesignActionMenuSection] {
        let currencies = CellNumberFormat.currencies.map { code in
            FlooDesignActionMenuItem.action(CellNumberFormat.currency(code: code).title, isOn: current == .currency(code: code), id: code) {
                set(.currency(code: code))
            }
        }
        return [
            .init(.rows, [
                .action(String(localized: "Plain Text"), isOn: current == nil, id: "plain") { set(nil) },
                .action(CellNumberFormat.number.title, isOn: current == .number, id: "number") { set(.number) },
                .action(CellNumberFormat.percent.title, isOn: current == .percent, id: "percent") { set(.percent) },
            ]),
            .init(.rows, [.submenu(String(localized: "Currency"), id: "currency", sections: [.init(.rows, currencies)])]),
        ]
    }
}
