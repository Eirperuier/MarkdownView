//
//  DocFormatSheet.swift
//  DemoApp
//
//  The phone's format sheet, Craft's: a system sheet over the selected blocks, from the
//  selection bar's Style or the keyboard bar's Aa (which selects the caret's block).
//  Its pages:
//
//  - main: a few styles and More…; lists and indent; the quote and the box, the colour,
//    and … ; the cursor in a table's cell, the cell's (Craft's Table Style): its marks,
//    its alignment, its typeface and number format, its fill, its text's colour, and its
//    table's settings;
//  - a cell's typeface, number format and fill; its table's size, headers and stripe;
//  - styles: the six text styles (More…);
//  - colours: the text's own colour, the palette, and any colour (the system's picker);
//  - more (…): bold, italic, strikethrough, code; Copy Format and Paste Format.
//
//  Every page but the main one is a sheet of its own over it; a choice on it takes it
//  back to the main one. The sheets close with their own pull: no gestures
//  of ours over them. What the blocks take (DocFormattable) is enabled, the rest greyed in
//  place; in a table's cell, what a cell takes.
//
//  The colours over the keyboard bar's highlight key, Craft's: none, the text colours
//  and any; the highlights and any.
//

import SwiftUI
import UIKit
import DocKit
import FlooDesign

private typealias Tokens = FlooDesignTokens
private typealias Metrics = FlooDesignTokens.Component.FormatSheet

enum DocFormatSheetPage: Hashable, Identifiable {
    case main, styles, colors, more
    /// A cell's typeface, number format, fill; its table's settings and stripe.
    case cellFont, cellNumber, cellFill, table, stripe

    var id: Self { self }
}

struct DocFormatSheet: View {
    let editor: DocEditor

    private var formatting: DocFormatting { DocFormatting(editor: editor, caretTakesBlock: true) }
    private var page: DocFormatSheetPage { editor.panels.sheetPage ?? .main }

    var body: some View {
        sheet(.main)
            .sheet(item: Binding(get: { page == .main ? nil : page }, set: { if $0 == nil { go(.main) } })) { page in
                sheet(page).flooDesignSizedSheet(estimate: Metrics.estimate)
            }
    }

    private func sheet(_ shown: DocFormatSheetPage) -> some View {
        Group {
            switch shown {
            case .main where formatting.inCell: cell
            case .main: main
            case .styles: styles
            case .colors: colors
            case .more: more
            case .cellFont: cellFonts
            case .cellNumber: cellNumbers
            case .cellFill: fills(current: formatting.cell?.style.fill) { token in formatting.cell?.setStyle(.fill) { $0.fill = token } }
            case .stripe: fills(current: formatting.cell?.table.stripe) { token in formatting.cell?.setTable { $0.stripe = token } }
            case .table: table
            }
        }
        .frame(height: height(of: shown), alignment: .top)
        .padding(.horizontal, Metrics.inset)
        .padding(.bottom, Metrics.inset)
    }

    private func go(_ page: DocFormatSheetPage) {
        editor.panels.sheetPage = page
    }

    private func height(of page: DocFormatSheetPage) -> CGFloat {
        switch page {
        case .main where formatting.inCell: Metrics.cellPage
        case .cellFill, .stripe: Metrics.fillPage
        default: Metrics.page
        }
    }

    // MARK: Main

    private var main: some View {
        let formatting = formatting
        return VStack(spacing: Metrics.rowSpacing) {
            HStack(spacing: Tokens.Component.Tile.spacing) {
                ForEach(shortStyles, id: \.key) { style in
                    chip(isOn: formatting.kindIsOn(style.kind), identifier: "sheet-style-\(style.key)") {
                        formatting.setTextStyle(style.kind)
                    } label: {
                        styleLabel(style)
                    }
                }
                FlooDesignDivider(.vertical, length: Metrics.row - Tokens.Space.xl)
                Button { go(.styles) } label: {
                    Text("More…")
                        .font(Metrics.label)
                        .foregroundStyle(Tokens.ColorRole.Content.secondary)
                        .frame(maxWidth: .infinity, minHeight: Metrics.row)
                }
                .buttonStyle(FlooDesignPlainButtonStyle())
                .accessibilityIdentifier("sheet-more-styles")
            }
            .disabled(!formatting.takes(.textStyle))
            HStack(spacing: Tokens.Component.Tile.spacing) {
                ForEach(DocFormatting.lists, id: \.id) { item in
                    tile(isOn: formatting.kindIsOn(item.kind), identifier: "sheet-\(item.id)") {
                        formatting.toggleList(item.kind)
                    } label: {
                        Image(systemName: item.symbol).font(.system(size: Tokens.Icon.toolbar))
                    }
                    .disabled(!formatting.takes(.list))
                    .accessibilityLabel(item.title)
                }
                Spacer().frame(width: Metrics.groupGap - Tokens.Component.Tile.spacing * 2)
                tile(isOn: false, identifier: "sheet-outdent") { formatting.indent(by: -1) } label: {
                    Image(systemName: "decrease.indent").font(.system(size: Tokens.Icon.toolbar))
                }
                .disabled(!formatting.canIndent(-1))
                .accessibilityLabel(Text("Outdent"))
                tile(isOn: false, identifier: "sheet-indent") { formatting.indent(by: 1) } label: {
                    Image(systemName: "increase.indent").font(.system(size: Tokens.Icon.toolbar))
                }
                .disabled(!formatting.canIndent(1))
                .accessibilityLabel(Text("Indent"))
            }
            HStack(spacing: Tokens.Component.Tile.spacing) {
                tile(isOn: formatting.kindIsOn(.quote), identifier: "sheet-quote") { formatting.toggleQuote() } label: {
                    HStack(spacing: Tokens.Space.md) {
                        Capsule().frame(width: Metrics.quoteBar.width, height: Metrics.quoteBar.height)
                        Text("Quote").font(Metrics.label)
                    }
                }
                .disabled(!formatting.takes(.quote))
                .frame(maxWidth: .infinity)
                tile(isOn: formatting.isBoxed, identifier: "sheet-block") { formatting.toggleBox() } label: {
                    Text("Block")
                        .font(Metrics.label)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Tokens.ColorRole.Surface.pressed, in: .rect(cornerRadius: Tokens.Radius.sm, style: .continuous))
                        .padding(Tokens.Space.sm - 2)
                }
                .disabled(!formatting.takes(.box))
                .frame(maxWidth: .infinity)
                Button { go(.colors) } label: {
                    FlooDesignRainbowSwatch(Circle(),
                                            picked: formatting.color.flatMap(Self.token).map(DocColors.swatch) ?? Tokens.ColorRole.Content.primary)
                        .frame(width: Metrics.colorRing, height: Metrics.colorRing)
                        .frame(width: Metrics.row + Tokens.Space.md, height: Metrics.row)
                }
                .buttonStyle(FlooDesignPlainButtonStyle())
                .disabled(formatting.markRanges.isEmpty)
                .accessibilityLabel(Text("Text Color"))
                .accessibilityIdentifier("sheet-colors")
                tile(isOn: false, identifier: "sheet-more") { go(.more) } label: {
                    Image(systemName: "ellipsis").font(.system(size: Tokens.Icon.toolbar, weight: .semibold))
                }
                .frame(width: Metrics.row + Tokens.Space.sm)
                .accessibilityLabel(Text("More"))
            }
        }
    }

    /// The main page's styles: the two most used, and the one the blocks have if it's
    /// another (Craft's).
    private var shortStyles: [(key: String, title: String, size: CGFloat, weight: Font.Weight, kind: BlockKind)] {
        let styles = DocFormatting.styles
        let common = styles.filter { $0.kind == .heading(level: 3) || $0.kind == .paragraph }
        guard let current = styles.first(where: { formatting.kindIsOn($0.kind) }), !common.contains(where: { $0.key == current.key }) else { return common }
        return [current] + common
    }

    // MARK: Styles

    private var styles: some View {
        let formatting = formatting
        let rows = [Array(DocFormatting.styles.prefix(3)), Array(DocFormatting.styles.suffix(3))]
        return VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 { FlooDesignDivider() }
                HStack(spacing: Tokens.Component.Tile.spacing) {
                    ForEach(rows[index], id: \.key) { style in
                        chip(isOn: formatting.kindIsOn(style.kind), identifier: "sheet-style-\(style.key)") {
                            formatting.setTextStyle(style.kind)
                            go(.main)
                        } label: {
                            styleLabel(style, large: true)
                        }
                    }
                }
                .frame(height: (Metrics.page - Tokens.Border.hairline) / 2)
            }
        }
        .disabled(!formatting.takes(.textStyle))
    }

    /// A style's name in its own type (Craft's: titles bigger and bolder, the caption smaller and quieter).
    private func styleLabel(_ style: (key: String, title: String, size: CGFloat, weight: Font.Weight, kind: BlockKind), large: Bool = false) -> some View {
        let size: CGFloat = switch style.kind {
        case .heading(level: 1): large ? Metrics.titleLabelLarge : Metrics.styleLabel
        case .heading(level: 2): large ? Metrics.headingLabelLarge : Metrics.styleLabel
        case .caption: Metrics.captionLabel
        default: Metrics.styleLabel
        }
        return Text(style.title)
            .font(.system(size: size, weight: style.weight))
            .foregroundStyle(style.kind == .caption ? Tokens.ColorRole.Content.secondary : Tokens.ColorRole.Content.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    // MARK: Colours

    private var colors: some View {
        let formatting = formatting
        let current = formatting.color
        let picked: String? = if case .color(let token)? = current, token.hasPrefix("#") { token } else { nil }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.swatchSpacing), count: Metrics.swatchColumns),
                         spacing: Metrics.swatchSpacing) {
            swatch(fill: Tokens.ColorRole.Content.primary, title: String(localized: "Default"), isOn: current == nil, identifier: "sheet-color-none") {
                formatting.setColor(nil)
                go(.main)
            }
            ForEach(DocColors.palette, id: \.token) { item in
                swatch(fill: DocColors.swatch(item.token), title: item.title, isOn: current == .color(item.token), identifier: "sheet-color-\(item.token)") {
                    formatting.setColor(item.token)
                    go(.main)
                }
            }
            Button {
                DocColorPicking.present(from: editor, initial: picked.map(DocColors.swatch) ?? .primary) { color in
                    formatting.pickColor(color)
                }
            } label: {
                FlooDesignRainbowSwatch(RoundedRectangle(cornerRadius: Metrics.swatchRadius, style: .continuous),
                                        picked: picked.map(DocColors.swatch) ?? Tokens.ColorRole.Content.primary)
                    .frame(height: Metrics.swatchHeight)
            }
            .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: Metrics.swatchRadius, style: .continuous)))
            .accessibilityLabel(Text("Other Color"))
            .accessibilityIdentifier("sheet-color-custom")
        }
        .disabled(formatting.markRanges.isEmpty)
    }

    private func swatch(fill: Color, title: String, isOn: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.swatchRadius, style: .continuous)
        return Button(action: action) {
            FlooDesignSwatch(shape, fill: fill, isOn: isOn, chosen: .ring(fill))
                .frame(height: Metrics.swatchHeight)
        }
        .buttonStyle(FlooDesignPlainButtonStyle(in: shape))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    // MARK: A cell's

    /// The cursor in a table's cell (Craft's Table Style): its marks, its alignment, its
    /// typeface and number format, its fill and its text's colour, its table's settings.
    @ViewBuilder
    private var cell: some View {
        let formatting = formatting
        if let cell = formatting.cell {
            let style = cell.style
            VStack(spacing: Metrics.rowSpacing) {
                marks(formatting)
                HStack(spacing: Tokens.Component.Tile.spacing) {
                    ForEach(CellAlignment.allCases, id: \.self) { alignment in
                        chip(isOn: style.alignment == alignment, identifier: "sheet-align-\(alignment.rawValue)") {
                            cell.toggle(alignment)
                        } label: {
                            Image(systemName: alignment.symbol).font(.system(size: Tokens.Icon.toolbar, weight: .medium))
                        }
                        .accessibilityLabel(alignment.title)
                    }
                }
                .disabled(!formatting.takes(.alignment))
                HStack(spacing: Tokens.Component.Tile.spacing) {
                    tile(isOn: style.font != nil, identifier: "sheet-cell-font") { go(.cellFont) } label: {
                        Text(style.font?.title ?? String(localized: "Default Font")).font(Metrics.label)
                    }
                    .disabled(!formatting.takes(.typeface))
                    tile(isOn: style.number != nil, identifier: "sheet-cell-number") { go(.cellNumber) } label: {
                        Text(style.number?.title ?? String(localized: "Plain Text")).font(Metrics.label).lineLimit(1)
                    }
                    .disabled(!formatting.takes(.numberFormat))
                }
                HStack(spacing: Tokens.Component.Tile.spacing) {
                    tile(isOn: style.fill != nil, identifier: "sheet-cell-fill") { go(.cellFill) } label: {
                        HStack(spacing: Tokens.Space.md) {
                            FlooDesignRainbowSwatch(Circle(), picked: style.fill.flatMap(DocColors.fill))
                                .frame(width: Tokens.Icon.toolbar, height: Tokens.Icon.toolbar)
                            Text("Fill").font(Metrics.label)
                        }
                    }
                    .disabled(!formatting.takes(.fill))
                    tile(isOn: formatting.color != nil, identifier: "sheet-cell-colors") { go(.colors) } label: {
                        HStack(spacing: Tokens.Space.md) {
                            FlooDesignRainbowSwatch(Circle(),
                                                    picked: formatting.color.flatMap(Self.token).map(DocColors.swatch) ?? Tokens.ColorRole.Content.primary)
                                .frame(width: Tokens.Icon.toolbar, height: Tokens.Icon.toolbar)
                            Text("Text").font(Metrics.label)
                        }
                    }
                    .disabled(!formatting.takes(.color) || formatting.markRanges.isEmpty)
                    tile(isOn: false, identifier: "sheet-table") { go(.table) } label: {
                        Label("Table", systemImage: "tablecells").font(Metrics.label)
                    }
                    .disabled(!formatting.takes(.table))
                }
            }
        }
    }

    /// The default typeface and Craft's four, each in its own.
    private var cellFonts: some View {
        let cell = formatting.cell
        let current = cell?.style.font
        let choices: [Typeface?] = [nil] + Typeface.allCases
        return VStack(spacing: Metrics.rowSpacing) {
            ForEach([Array(choices.prefix(3)), Array(choices.suffix(2))], id: \.self) { row in
                HStack(spacing: Tokens.Component.Tile.spacing) {
                    ForEach(row, id: \.self) { font in
                        chip(isOn: current == font, identifier: "sheet-font-\(font?.rawValue ?? "default")") {
                            cell?.setFont(font)
                            go(.main)
                        } label: {
                            Text(font?.title ?? String(localized: "Default"))
                                .font(.system(size: Metrics.styleLabel, design: font.map(DocCellLook.design) ?? .default))
                        }
                    }
                }
            }
        }
    }

    /// Plain text, number, percent; a currency.
    private var cellNumbers: some View {
        let cell = formatting.cell
        let current = cell?.style.number
        let set = { (format: CellNumberFormat?) in
            cell?.setStyle(.numberFormat) { $0.number = format }
            go(.main)
        }
        return VStack(spacing: Metrics.rowSpacing) {
            HStack(spacing: Tokens.Component.Tile.spacing) {
                chip(isOn: current == nil, identifier: "sheet-number-plain") { set(nil) } label: {
                    Text("Plain Text").font(Metrics.label)
                }
                chip(isOn: current == .number, identifier: "sheet-number-number") { set(.number) } label: {
                    Text(CellNumberFormat.number.title).font(Metrics.label)
                }
                chip(isOn: current == .percent, identifier: "sheet-number-percent") { set(.percent) } label: {
                    Text(CellNumberFormat.percent.title).font(Metrics.label)
                }
            }
            HStack(spacing: Tokens.Component.Tile.spacing) {
                ForEach(CellNumberFormat.currencies, id: \.self) { code in
                    chip(isOn: current == .currency(code: code), identifier: "sheet-number-\(code)") { set(.currency(code: code)) } label: {
                        Text(code).font(Metrics.label)
                    }
                    .accessibilityLabel(CellNumberFormat.currency(code: code).title)
                }
            }
        }
    }

    /// Craft's fills: none, six hues by three strengths twice, any colour.
    private func fills(current: String?, set: @escaping (String?) -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.fillRadius, style: .continuous)
        let custom: String? = if let current, current.hasPrefix("#") { current } else { nil }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.swatchSpacing), count: Metrics.swatchColumns),
                         spacing: Metrics.fillSpacing) {
            ForEach(Array(DocColors.fillGrid.enumerated()), id: \.offset) { _, token in
                Button {
                    set(token)
                    go(.main)
                } label: {
                    FlooDesignSwatch(shape, fill: token.flatMap(DocColors.fill) ?? Tokens.ColorRole.Surface.canvas, isOn: current == token)
                        .frame(height: Metrics.fillHeight)
                }
                .buttonStyle(FlooDesignPlainButtonStyle(in: shape))
                .accessibilityLabel(token.map(DocColors.fillTitle) ?? String(localized: "None"))
                .accessibilityIdentifier("sheet-fill-\(token ?? "none")")
            }
            Button {
                DocColorPicking.present(from: editor, initial: custom.flatMap(DocColors.fill) ?? .primary) { color in
                    set(DocColors.hex(color))
                }
            } label: {
                FlooDesignRainbowSwatch(shape, picked: custom.flatMap(DocColors.fill))
                    .frame(height: Metrics.fillHeight)
            }
            .buttonStyle(FlooDesignPlainButtonStyle(in: shape))
            .accessibilityLabel(Text("Other Color"))
            .accessibilityIdentifier("sheet-fill-custom")
        }
    }

    /// The table's: its rows and columns, its header row and column, its rows' stripe.
    @ViewBuilder
    private var table: some View {
        if let cell = formatting.cell {
            let size = cell.size
            let style = cell.table
            VStack(spacing: Metrics.rowSpacing) {
                HStack(spacing: Tokens.Component.Tile.spacing) {
                    stepper(String(localized: "Rows"), value: size.rows) { cell.resize(rows: $0) }
                    stepper(String(localized: "Columns"), value: size.columns) { cell.resize(columns: $0) }
                }
                HStack(spacing: Tokens.Component.Tile.spacing) {
                    tile(isOn: style.hasHeaderRow, identifier: "sheet-header-row") { cell.setTable { $0.headerRow = !style.hasHeaderRow } } label: {
                        Label("Header Row", systemImage: "rectangle.topthird.inset.filled").font(Metrics.label)
                    }
                    tile(isOn: style.hasHeaderColumn, identifier: "sheet-header-column") { cell.setTable { $0.headerColumn = !style.hasHeaderColumn } } label: {
                        Label("Header Column", systemImage: "rectangle.leftthird.inset.filled").font(Metrics.label)
                    }
                }
                tile(isOn: style.stripe != nil, identifier: "sheet-stripe") { go(.stripe) } label: {
                    HStack(spacing: Tokens.Space.md) {
                        FlooDesignRainbowSwatch(Circle(), picked: style.stripe.flatMap(DocColors.fill))
                            .frame(width: Tokens.Icon.toolbar, height: Tokens.Icon.toolbar)
                        Text("Alternating Row Color").font(Metrics.label)
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    /// A count between − and +; at least one.
    private func stepper(_ title: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            Button { set(value - 1) } label: {
                Image(systemName: "minus").frame(width: Metrics.row, height: Metrics.row)
            }
            .disabled(value <= 1)
            .accessibilityLabel(Text("Remove \(title)"))
            VStack(spacing: 0) {
                Text(value, format: .number).font(Metrics.label.monospacedDigit())
                Text(title).font(.caption).foregroundStyle(Tokens.ColorRole.Content.secondary)
            }
            .frame(maxWidth: .infinity)
            Button { set(value + 1) } label: {
                Image(systemName: "plus").frame(width: Metrics.row, height: Metrics.row)
            }
            .accessibilityLabel(Text("Add \(title)"))
        }
        .buttonStyle(FlooDesignPlainButtonStyle())
        .frame(maxWidth: .infinity, minHeight: Metrics.row, maxHeight: Metrics.row)
        .background(Tokens.ColorRole.Surface.control, in: .rect(cornerRadius: Tokens.Component.Tile.cornerRadius, style: .continuous))
    }

    // MARK: More

    private var more: some View {
        let formatting = formatting
        let copied = editor.panels.copiedFormat
        return VStack(spacing: Metrics.rowSpacing) {
            marks(formatting)
            HStack(spacing: Tokens.Component.Tile.spacing) {
                tile(isOn: false, identifier: "sheet-copy-format") {
                    editor.panels.copiedFormat = formatting.format
                } label: {
                    Label("Copy Format", systemImage: "doc.on.clipboard").font(Metrics.label)
                }
                .disabled(formatting.decorated.isEmpty)
                tile(isOn: false, identifier: "sheet-paste-format") {
                    if let copied { formatting.paste(copied) }
                } label: {
                    Label("Paste Format", systemImage: "doc.on.clipboard.fill").font(Metrics.label)
                }
                .disabled(copied == nil || formatting.decorated.isEmpty)
            }
            // The blocks' typeface, each in its own (Craft's Font); pressed again, the document's.
            HStack(spacing: Tokens.Component.Tile.spacing) {
                ForEach(Typeface.blockOrder, id: \.self) { font in
                    chip(isOn: formatting.font == font, identifier: "sheet-block-font-\(font.rawValue)") {
                        formatting.setFont(font)
                    } label: {
                        Text(font.title).font(.system(size: Metrics.styleLabel, design: DocCellLook.design(font)))
                    }
                }
            }
            .disabled(!formatting.takes(.typeface))
        }
    }

    // MARK: Pieces

    /// Bold, italic, strikethrough, code.
    private func marks(_ formatting: DocFormatting) -> some View {
        HStack(spacing: Tokens.Component.Tile.spacing) {
            ForEach(DocFormatting.marks, id: \.id) { item in
                chip(isOn: formatting.markIsOn(item.mark), identifier: "sheet-\(item.id)") {
                    formatting.toggle(item.mark)
                } label: {
                    Image(systemName: item.symbol).font(.system(size: Tokens.Icon.toolbar, weight: .medium))
                }
                .accessibilityLabel(item.title)
            }
        }
        .disabled(!formatting.takes(.marks) || formatting.markRanges.isEmpty)
    }

    /// A choice standing free (a style, a mark): outlined in the tint when it's on.
    private func chip(isOn: Bool, identifier: String, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label().frame(maxWidth: .infinity, minHeight: Metrics.row)
        }
        .buttonStyle(FlooDesignTileButtonStyle(isOn: isOn, surface: .chip))
        .accessibilityIdentifier(identifier)
    }

    /// A choice on a soft tile: tinted and outlined when it's on.
    private func tile(isOn: Bool, identifier: String, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label().frame(maxWidth: .infinity, minHeight: Metrics.row, maxHeight: Metrics.row)
        }
        .buttonStyle(FlooDesignTileButtonStyle(isOn: isOn))
        .accessibilityIdentifier(identifier)
    }

    private static func token(_ mark: Mark) -> String? {
        if case .color(let token) = mark { token } else { nil }
    }
}

/// The colours over the keyboard bar's highlight key: none (both off), the text
/// colours and any; the highlights and any. A choice applies and closes it.
struct DocColorsPopover: View {
    private typealias Popover = FlooDesignTokens.Component.ColorsPopover

    let editor: DocEditor
    let block: DocBlockID
    let range: Range<Int>
    let onClose: () -> Void

    private var ranges: [(block: DocBlockID, range: Range<Int>)] { [(block, range)] }

    var body: some View {
        let color = editor.common(.color, over: ranges)
        let highlight = editor.common(.highlight, over: ranges)
        VStack(spacing: Popover.spacing) {
            HStack(spacing: Popover.spacing) {
                Button {
                    editor.clearColors(over: ranges)
                    onClose()
                } label: {
                    FlooDesignNoColorSwatch()
                        .frame(width: Popover.swatch, height: Popover.swatch)
                }
                .buttonStyle(FlooDesignPlainButtonStyle(in: Circle()))
                .accessibilityLabel(Text("No Color"))
                .accessibilityIdentifier("popover-none")
                ForEach(DocColors.texts, id: \.token) { item in
                    let isOn = color == .color(item.token)
                    swatch(Circle(), fill: DocColors.swatch(item.token), title: item.title, isOn: isOn, identifier: "popover-color-\(item.token)") {
                        editor.endColorChanges()
                        editor.set(.color, to: isOn ? nil : .color(item.token), over: ranges)
                        onClose()
                    }
                }
                custom(Circle(), title: String(localized: "Other Text Color"), identifier: "popover-color-custom") { picked in
                    editor.set(.color, to: .color(DocColors.hex(picked)), over: ranges, merge: editor.colorMergeKey(over: ranges))
                }
            }
            FlooDesignDivider().padding(.horizontal, Tokens.Space.xs)
            HStack(spacing: Popover.spacing) {
                ForEach(DocColors.highlights, id: \.token) { item in
                    let isOn = highlight == .highlight(color: item.token)
                    swatch(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous), fill: DocColors.highlightSwatch(item.token),
                           title: item.title, isOn: isOn, identifier: "popover-highlight-\(item.token)") {
                        editor.endColorChanges()
                        editor.set(.highlight, to: isOn ? nil : .highlight(color: item.token), over: ranges)
                        onClose()
                    }
                }
                custom(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous), title: String(localized: "Other Highlight Color"),
                       identifier: "popover-highlight-custom") { picked in
                    editor.set(.highlight, to: .highlight(color: DocColors.hex(picked)), over: ranges, merge: editor.colorMergeKey(over: ranges))
                }
            }
        }
        .padding(Popover.inset)
        .flooDesignGlass(.regular, in: RoundedRectangle(cornerRadius: Popover.cornerRadius, style: .continuous))
    }

    private func swatch(_ shape: some InsettableShape, fill: Color, title: String, isOn: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FlooDesignSwatch(shape, fill: fill, isOn: isOn)
                .frame(width: Popover.swatch, height: Popover.swatch)
        }
        .buttonStyle(FlooDesignPlainButtonStyle(in: shape))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    /// Any colour: a rainbow edge round a ▾; the system's picker.
    private func custom(_ shape: some InsettableShape, title: String, identifier: String, picked: @escaping (Color) -> Void) -> some View {
        Button {
            onClose()
            DocColorPicking.present(from: editor, initial: .primary, picked: picked)
        } label: {
            FlooDesignRainbowSwatch(shape, picked: nil)
                .frame(width: Popover.swatch, height: Popover.swatch)
        }
        .buttonStyle(FlooDesignPlainButtonStyle(in: shape))
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

/// The system's colour picker, as a sheet, reporting each colour as it's chosen; a
/// run of them is one undo step (the caller's merge key), ended when it closes.
@MainActor
final class DocColorPicking: NSObject, UIColorPickerViewControllerDelegate {
    private static var current: DocColorPicking?
    private let editor: DocEditor
    private let picked: (Color) -> Void

    private init(editor: DocEditor, picked: @escaping (Color) -> Void) {
        self.editor = editor
        self.picked = picked
    }

    static func present(from editor: DocEditor, initial: Color, picked: @escaping (Color) -> Void) {
        guard let presenter = editor.presentingController() else { return }
        let picking = DocColorPicking(editor: editor, picked: picked)
        let controller = UIColorPickerViewController()
        controller.selectedColor = UIColor(initial)
        controller.supportsAlpha = false
        controller.delegate = picking
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        current = picking
        editor.endColorChanges()
        presenter.present(controller, animated: true)
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        picked(Color(uiColor: color))
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        editor.endColorChanges()
        Self.current = nil
    }
}
