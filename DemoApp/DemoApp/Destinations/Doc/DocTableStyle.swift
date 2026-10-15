//
//  DocTableStyle.swift
//  DemoApp
//
//  A table's look (Craft's Table Style): its size, whether its first row and column are
//  headers, its rows' stripe, and each cell's alignment, typeface, number format and
//  fill. DocKit keeps them (TableStyle, CellStyle); MarkdownView draws them
//  (MarkdownTableAppearance); the edited cell's editor reads the same.
//

import SwiftUI
import DocKit
import MarkdownView

extension DocTableController {
    // MARK: A cell's style

    func cellStyle(_ key: DocCellKey) -> CellStyle {
        database(key.block)?.database.cellStyle(row: key.row, column: key.column) ?? CellStyle()
    }

    /// One step; a style left with nothing set goes.
    func setCellStyle(_ key: DocCellKey, _ change: (inout CellStyle) -> Void) {
        var style = cellStyle(key)
        let previous = style
        change(&style)
        guard style != previous else { return }
        commit(key.block, [.setCellStyle(row: key.row, column: key.column, style: style, previous: previous)])
    }

    /// Whether the cell's column holds numbers a format can show: a number column's, or
    /// a text column's typed numbers.
    func holdsNumbers(_ key: DocCellKey) -> Bool {
        guard isEditable, key.row != nil, let (_, database) = database(key.block),
              let column = database.columns.first(where: { $0.id == key.column })
        else { return false }
        return column.type == .text || column.type == .number
    }

    // MARK: The table's

    func tableStyle(_ block: DocBlockID) -> DocKit.TableStyle {
        database(block)?.database.tableStyle ?? DocKit.TableStyle()
    }

    func setTableStyle(_ block: DocBlockID, _ change: (inout DocKit.TableStyle) -> Void) {
        var style = tableStyle(block)
        let previous = style
        change(&style)
        guard style != previous else { return }
        commit(block, [.setTableStyle(style: style, previous: database(block)?.database.style)])
    }

    /// Its rows (the header's among them) and columns.
    func size(of block: DocBlockID) -> (rows: Int, columns: Int) {
        guard let (_, database) = database(block) else { return (0, 0) }
        return (database.rows.count + 1, database.columns.count)
    }

    /// Rows or columns added at the end, or the last ones taken away (Craft's steppers);
    /// at least the header and one column stay. The edited cell, gone with them, moves
    /// to the last that's left.
    func resize(_ key: DocCellKey, rows: Int? = nil, columns: Int? = nil) {
        guard let (_, database) = database(key.block) else { return }
        var steps: [DatabaseStep] = []
        var rowList = database.rows
        var columnList = database.columns
        if let rows {
            let target = max(0, rows - 1)
            while rowList.count < target {
                let row = Row(id: demo.newID())
                steps.append(.insertRow(row: row, after: rowList.last?.id))
                rowList.append(row)
            }
            while rowList.count > target, let last = rowList.popLast() {
                steps.append(.deleteRow(row: last, after: rowList.last?.id))
            }
        }
        if let columns {
            let target = max(1, columns)
            while columnList.count < target {
                let column = Column(id: demo.newID(), name: "", type: .text)
                steps.append(.insertColumn(column: column, after: columnList.last?.id, cells: [:]))
                columnList.append(column)
            }
            while columnList.count > target, let last = columnList.popLast() {
                let values = database.rows.reduce(into: [RowID: CellValue]()) { $0[$1.id] = $1.cells[last.id] }
                steps.append(.deleteColumn(column: last, after: columnList.last?.id, cells: values))
            }
        }
        guard !steps.isEmpty else { return }
        commit(key.block, steps)
        let row = key.row.flatMap { row in rowList.contains { $0.id == row } ? row : rowList.last?.id }
        let column = columnList.contains { $0.id == key.column } ? key.column : columnList.last?.id ?? key.column
        let next = DocCellKey(block: key.block, row: row, column: column)
        if next != key { focusSoon(next, atEnd: true) }
    }

    // MARK: How it's drawn

    /// The table's look for MarkdownView, cells by where they are (row 0 the header's).
    func appearance(of table: DocTableSnapshot) -> MarkdownTableAppearance {
        let database = table.database
        let style = database.tableStyle
        var cells: [MarkdownTableCellPosition: MarkdownTableCellAppearance] = [:]
        for (c, column) in database.columns.enumerated() {
            if let header = column.headerStyle {
                cells[MarkdownTableCellPosition(row: 0, column: c)] = DocCellLook.appearance(header)
            }
            guard let styles = column.cellStyles else { continue }
            for (r, row) in database.rows.enumerated() {
                if let cell = styles[row.id] { cells[MarkdownTableCellPosition(row: r + 1, column: c)] = DocCellLook.appearance(cell) }
            }
        }
        // A document's table has no stripe until it's given one (Craft's).
        let stripe = style.stripe.flatMap(DocColors.fill).map(MarkdownTableAppearance.Stripe.color) ?? .none
        return MarkdownTableAppearance(headerRow: style.hasHeaderRow, headerColumn: style.hasHeaderColumn, stripe: stripe, cells: cells)
    }

    /// How the cell's editor sets its text: as the table draws the cell.
    func look(_ key: DocCellKey) -> DocCellLook {
        guard let (_, database) = database(key.block) else { return DocCellLook() }
        let table = database.tableStyle
        return DocCellLook(
            style: database.cellStyle(row: key.row, column: key.column),
            isHeader: key.row == nil && table.hasHeaderRow,
            isHeaderColumn: key.row != nil && table.hasHeaderColumn && database.columns.first?.id == key.column
        )
    }
}

/// A cell's look as its editor needs it.
struct DocCellLook: Equatable {
    var style = CellStyle()
    var isHeader = false
    var isHeaderColumn = false

    static func appearance(_ style: CellStyle) -> MarkdownTableCellAppearance {
        MarkdownTableCellAppearance(alignment: style.alignment.map(alignment), fontDesign: style.font.map(design),
                                    fill: style.fill.flatMap(DocColors.fill))
    }

    static func alignment(_ alignment: CellAlignment) -> MarkdownTableCellAppearance.Alignment {
        switch alignment {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        case .justify: .justified
        }
    }

    static func design(_ font: CellFont) -> Font.Design {
        switch font {
        case .system: .default
        case .serif: .serif
        case .mono: .monospaced
        case .rounded: .rounded
        }
    }

    var textAlignment: NSTextAlignment {
        switch style.alignment {
        case .left?: .left
        case .center?: .center
        case .right?: .right
        case .justify?: .justified
        case nil: .natural
        }
    }

    var frameAlignment: Alignment {
        switch style.alignment {
        case .center?: .top
        case .right?: .topTrailing
        default: .topLeading
        }
    }

    /// The header's font or the body's (DocTableCellField's), in the cell's typeface; a
    /// header column's in bold.
    var font: UIFont {
        var font = isHeader ? DocTableCellField.headerFont : DocTableCellField.bodyFont
        if let design = style.font.flatMap(Self.systemDesign), let descriptor = font.fontDescriptor.withDesign(design) {
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        }
        if isHeaderColumn, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) {
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        }
        return font
    }

    private static func systemDesign(_ font: CellFont) -> UIFontDescriptor.SystemDesign? {
        switch font {
        case .system: nil
        case .serif: .serif
        case .mono: .monospaced
        case .rounded: .rounded
        }
    }
}

extension DocColors {
    /// A cell's or a stripe's fill (CellStyle's tokens).
    static func fill(_ token: String) -> Color? {
        guard let fill = CellStyle.parseFill(token) else { return nil }
        return MarkdownColorToken.fill(fill.color, strength: fill.strength)
    }

    /// The fills to pick from, Craft's grid: six hues across, their three strengths down,
    /// the next six below; none in the first place, any colour in the last.
    static var fillGrid: [String?] {
        let hues = CellStyle.fillColors
        var grid: [String?] = []
        for half in [hues.prefix(6), hues.suffix(6)] {
            for strength in CellStyle.fillStrengths {
                grid += half.map { CellStyle.fill($0, strength: strength) }
            }
        }
        grid[0] = nil
        grid.removeLast()
        return grid
    }

    /// A fill's name: its hue's, and its strength.
    static func fillTitle(_ token: String) -> String {
        guard let fill = CellStyle.parseFill(token), let hue = (palette + texts + highlights).first(where: { $0.token == fill.color }) else {
            return String(localized: "Custom")
        }
        return fill.strength <= 1 ? hue.title : "\(hue.title) \(fill.strength)"
    }
}

extension CellNumberFormat {
    /// The currencies the menus offer.
    static let currencies = ["USD", "EUR", "GBP", "JPY", "CNY"]

    var title: String {
        switch self {
        case .number: String(localized: "Number")
        case .percent: String(localized: "Percent")
        case .currency(let code): Locale.current.localizedString(forCurrencyCode: code) ?? code
        }
    }
}

extension CellFont {
    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .serif: String(localized: "Serif")
        case .mono: String(localized: "Mono")
        case .rounded: String(localized: "Round")
        }
    }

    /// Craft's: the font's name in two letters of it.
    var sample: String {
        switch self {
        case .system: "Aa"
        case .serif: "Ss"
        case .mono: "00"
        case .rounded: "Rr"
        }
    }
}

extension CellAlignment {
    var symbol: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justify: "text.justify"
        }
    }

    var title: String {
        switch self {
        case .left: String(localized: "Align Left")
        case .center: String(localized: "Center")
        case .right: String(localized: "Align Right")
        case .justify: String(localized: "Justify")
        }
    }
}
