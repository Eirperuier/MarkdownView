//
//  DocCellStylePanel.swift
//  DemoApp
//
//  The Mac's format panel with the cursor in a table's cell (Craft's Table Style): the
//  table's rows and columns, its header row and column; the cell's marks, alignment and
//  typeface; how a number in it reads; the rows' stripe, the cell's fill and its text's
//  colour, each picked from a palette under its swatch. What the cell doesn't take
//  (DocFormattable) is greyed in place.
//

import SwiftUI
import DocKit
import FlooDesign

private typealias Tokens = FlooDesignTokens
private typealias Metrics = FlooDesignTokens.Component.FormatPanel

struct DocCellStylePanel: View {
    let cell: DocFormatCell
    let formatting: DocFormatting
    let editor: DocEditor

    /// The menu or palette open under its control.
    @State private var open: Picker?

    private enum Picker { case font, number, stripe, fill, text }

    var body: some View {
        let style = cell.style
        let table = cell.table
        let size = cell.size
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: Tokens.Space.sm) {
                stepper(String(localized: "Rows"), symbol: "rectangle.split.1x2", value: size.rows, least: 1) { cell.resize(rows: $0) }
                stepper(String(localized: "Columns"), symbol: "rectangle.split.2x1", value: size.columns, least: 1) { cell.resize(columns: $0) }
            }
            .disabled(!formatting.takes(.table))
            .padding(.bottom, Metrics.sectionLead)
            section(String(localized: "Header")) {
                VStack(spacing: Tokens.Space.sm) {
                    toggle(String(localized: "Header Row"), symbol: "rectangle.topthird.inset.filled", isOn: table.hasHeaderRow) { on in
                        cell.setTable { $0.headerRow = on }
                    }
                    toggle(String(localized: "Header Column"), symbol: "rectangle.leftthird.inset.filled", isOn: table.hasHeaderColumn) { on in
                        cell.setTable { $0.headerColumn = on }
                    }
                }
                .disabled(!formatting.takes(.table))
            }
            section(String(localized: "Text Style")) {
                VStack(spacing: Metrics.segmentGap) {
                    FlooDesignSegments(items: DocFormatting.marks.map { item in
                        .init(id: item.id, symbol: item.symbol, title: item.title, isOn: formatting.markIsOn(item.mark),
                              isEnabled: formatting.takes(.marks) && !formatting.markRanges.isEmpty) {
                            formatting.toggle(item.mark)
                        }
                    })
                    FlooDesignSegments(items: CellAlignment.allCases.map { alignment in
                        .init(id: alignment.rawValue, symbol: alignment.symbol, title: alignment.title, isOn: style.alignment == alignment,
                              isEnabled: formatting.takes(.alignment)) {
                            cell.toggle(alignment)
                        }
                    })
                    menuTile(style.font?.sample ?? Typeface.system.sample, style.font?.title ?? String(localized: "Default Font"), picker: .font)
                        .disabled(!formatting.takes(.typeface))
                        .flooDesignActionMenu(isPresented: open == .font, configuration: .init(), onDismiss: { open = nil }) { _ in
                            [.init(.rows, [.action(String(localized: "Default Font"), isOn: style.font == nil, id: "default") { cell.setStyle { $0.font = nil } }]
                                + Typeface.allCases.map { font in
                                    .action(font.title, isOn: style.font == font, id: font.rawValue) { cell.setStyle { $0.font = font } }
                                })]
                        }
                }
            }
            section(String(localized: "Cell Format")) {
                menuTile(nil, style.number?.title ?? String(localized: "Plain Text"), picker: .number)
                    .disabled(!formatting.takes(.numberFormat))
                    .flooDesignActionMenu(isPresented: open == .number, configuration: .init(), onDismiss: { open = nil }) { _ in
                        numberMenu(style.number)
                    }
            }
            section(String(localized: "Cell Style")) {
                VStack(spacing: Tokens.Space.sm) {
                    colorRow(String(localized: "Alternating Row Color"), picked: table.stripe.flatMap(DocColors.fill), picker: .stripe) {
                        fills(current: table.stripe) { token in cell.setTable { $0.stripe = token } }
                    }
                    .disabled(!formatting.takes(.table))
                    colorRow(String(localized: "Cell Fill Color"), picked: style.fill.flatMap(DocColors.fill), picker: .fill) {
                        fills(current: style.fill) { token in cell.setStyle { $0.fill = token } }
                    }
                    .disabled(!formatting.takes(.fill))
                    colorRow(String(localized: "Text Color"), picked: textColor, picker: .text) {
                        DocCellTextColors(editor: editor, formatting: formatting)
                    }
                    .disabled(!formatting.takes(.color) || formatting.markRanges.isEmpty)
                }
            }
            .padding(.bottom, -Metrics.sectionGap)
        }
        .frame(width: Metrics.width)
    }

    private var textColor: Color? {
        if case .color(let token)? = formatting.color { return DocColors.swatch(token) }
        return nil
    }

    // MARK: Menus

    /// Plain text, number and percent; a currency in a submenu (Craft's).
    private func numberMenu(_ current: CellNumberFormat?) -> [FlooDesignActionMenuSection] {
        let set = { (format: CellNumberFormat?) in cell.setStyle { $0.number = format } }
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

    // MARK: Palettes

    /// Craft's fills: none, six hues by three strengths twice, any colour.
    private func fills(current: String?, set: @escaping (String?) -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
        let custom: String? = if let current, current.hasPrefix("#") { current } else { nil }
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(Metrics.swatch), spacing: Metrics.swatchSpacing), count: Metrics.swatchColumns),
                         spacing: Metrics.swatchSpacing) {
            ForEach(Array(DocColors.fillGrid.enumerated()), id: \.offset) { _, token in
                Button {
                    set(token)
                    open = nil
                } label: {
                    FlooDesignSwatch(shape, fill: token.flatMap(DocColors.fill) ?? Tokens.ColorRole.Surface.canvas, isOn: current == token)
                        .frame(width: Metrics.swatch, height: Metrics.swatch)
                }
                .buttonStyle(FlooDesignPlainButtonStyle(in: shape))
                .help(token.map(DocColors.fillTitle) ?? String(localized: "None"))
                .accessibilityLabel(token.map(DocColors.fillTitle) ?? String(localized: "None"))
                .accessibilityIdentifier("fill-\(token ?? "none")")
            }
            FlooDesignColorWell(shape, title: String(localized: "Other Color"), picked: custom.flatMap(DocColors.fill),
                                selection: Binding { custom.flatMap(DocColors.fill) ?? .primary } set: { set(DocColors.hex($0)) })
                .frame(width: Metrics.swatch, height: Metrics.swatch)
        }
        .padding(Tokens.Space.xs)
    }

    // MARK: Pieces

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Metrics.sectionLabelGap) {
            Text(title)
                .font(Metrics.sectionLabel)
                .foregroundStyle(Tokens.ColorRole.Content.secondary)
            content()
        }
        .padding(.bottom, Metrics.sectionGap)
    }

    /// A count with − and + (Craft's Rows and Columns).
    private func stepper(_ title: String, symbol: String, value: Int, least: Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: Tokens.Space.md) {
            Image(systemName: symbol)
                .font(Metrics.label)
                .foregroundStyle(Tokens.ColorRole.Content.secondary)
                .frame(width: Metrics.rowIcon)
            Text(title).font(Metrics.label)
            Spacer(minLength: Tokens.Space.xs)
            Text(value, format: .number)
                .font(Metrics.label.monospacedDigit())
                .frame(minWidth: Metrics.countWidth, minHeight: Tokens.Component.Segments.height)
                .background(Tokens.ColorRole.Surface.control, in: .rect(cornerRadius: Tokens.Component.Segments.cornerRadius, style: .continuous))
            FlooDesignSegments(items: [
                .init(id: "less", symbol: "minus", title: String(localized: "Remove \(title)"), isOn: false, isEnabled: value > least) { set(value - 1) },
                .init(id: "more", symbol: "plus", title: String(localized: "Add \(title)"), isOn: false) { set(value + 1) },
            ])
            .frame(width: Metrics.stepperWidth)
        }
    }

    private func toggle(_ title: String, symbol: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: Tokens.Space.md) {
            Image(systemName: symbol)
                .font(Metrics.label)
                .foregroundStyle(Tokens.ColorRole.Content.secondary)
                .frame(width: Metrics.rowIcon)
            Text(title).font(Metrics.label)
            Spacer(minLength: Tokens.Space.xs)
            Toggle(title, isOn: Binding { isOn } set: { set($0) })
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Tokens.ColorRole.Accent.primary)
        }
    }

    /// A choice shown as what it is now, ⌃⌄ at the end, opening its menu (Craft's Font and Cell Format).
    private func menuTile(_ sample: String?, _ title: String, picker: Picker) -> some View {
        Button {
            open = open == picker ? nil : picker
        } label: {
            HStack(spacing: Tokens.Space.md) {
                if let sample {
                    Text(sample).foregroundStyle(Tokens.ColorRole.Content.secondary)
                }
                Text(title)
                Spacer(minLength: Tokens.Space.xs)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: Tokens.Icon.inline, weight: .semibold))
                    .foregroundStyle(Tokens.ColorRole.Content.secondary)
            }
            .font(Metrics.label)
            .padding(.horizontal, Tokens.Space.md)
            .frame(maxWidth: .infinity, minHeight: Metrics.tallTile)
        }
        .buttonStyle(FlooDesignTileButtonStyle(isOn: open == picker))
    }

    /// A colour setting: its name, and the colour in a rainbow ring that opens its palette.
    private func colorRow(_ title: String, picked: Color?, picker: Picker, @ViewBuilder palette: @escaping () -> some View) -> some View {
        HStack {
            Text(title).font(Metrics.label)
            Spacer(minLength: Tokens.Space.xs)
            Button {
                open = open == picker ? nil : picker
            } label: {
                FlooDesignRainbowSwatch(Circle(), picked: picked)
                    .frame(width: Metrics.ring, height: Metrics.ring)
            }
            .buttonStyle(FlooDesignPlainButtonStyle(in: Circle()))
            .help(title)
            .accessibilityLabel(title)
            .flooDesignAnchoredPanel(isPresented: open == picker, configuration: .init(horizontalAlignment: .trailing), onDismiss: { open = nil }) {
                FlooDesignFloatingPanelSurface {
                    palette()
                }
            }
        }
        .frame(minHeight: Metrics.ring)
    }
}

/// The cell's text colour: none, the palette, any (the panel's Color section's).
private struct DocCellTextColors: View {
    let editor: DocEditor
    let formatting: DocFormatting

    var body: some View {
        let ranges = formatting.markRanges
        let current = editor.common(.color, over: ranges)
        let picked: String? = if case .color(let token)? = current, token.hasPrefix("#") { token } else { nil }
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Metrics.swatch), spacing: Metrics.swatchSpacing), count: Metrics.swatchColumns),
                  spacing: Metrics.swatchSpacing) {
            swatch(nil, title: String(localized: "Default"), isOn: current == nil)
            ForEach(DocColors.palette, id: \.token) { item in
                swatch(item.token, title: item.title, isOn: current == .color(item.token))
            }
            FlooDesignColorWell(Circle(), title: String(localized: "Other Color"), picked: picked.map(DocColors.swatch),
                                selection: Binding { picked.map(DocColors.swatch) ?? .primary } set: { formatting.pickColor($0) })
                .frame(width: Metrics.swatch, height: Metrics.swatch)
        }
        .padding(Tokens.Space.xs)
    }

    private func swatch(_ token: String?, title: String, isOn: Bool) -> some View {
        Button {
            formatting.setColor(token)
        } label: {
            FlooDesignSwatch(Circle(), fill: token.map(DocColors.swatch) ?? Tokens.ColorRole.Content.primary, isOn: isOn,
                             chosen: .ring(Tokens.ColorRole.Content.primary))
                .frame(width: Metrics.swatch, height: Metrics.swatch)
        }
        .buttonStyle(FlooDesignPlainButtonStyle(in: Circle()))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("cell-color-\(token ?? "none")")
    }
}
