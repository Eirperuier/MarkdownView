/// A table's look as an agent reads and writes it: the table's `style` (its header row and
/// column, its rows' stripe); a column's own alignment, typeface, number format and fill
/// when all of its cells share it; a cell's own in `cells`, by its column's name and its
/// row's place in `rows` (or `"header": true`).
extension AgentBlocks {
    /// What a cell's style fields take.
    static let alignments = CellAlignment.allCases.map(\.rawValue)
    static let fonts = CellFont.allCases.map(\.rawValue)
    static let formats = ["number", "percent"]

    // MARK: Reading

    static func styles(_ database: Database, into object: inout [String: JSONValue]) {
        let table = database.tableStyle
        var style: [String: JSONValue] = [:]
        if !table.hasHeaderRow { style["header_row"] = false }
        if table.hasHeaderColumn { style["header_column"] = true }
        if let stripe = table.stripe { style["stripe"] = .string(stripe) }
        if !style.isEmpty { object["style"] = .object(style) }
        guard case .array(var columns)? = object["columns"] else { return }
        var cells: [JSONValue] = []
        for (index, column) in database.columns.enumerated() where index < columns.count {
            let all = [column.style(row: nil)] + database.rows.map { column.style(row: $0.id) }
            func shared<Value: Equatable>(_ value: (CellStyle) -> Value?) -> Value? {
                guard let first = all.first.flatMap(value), all.allSatisfy({ value($0) == first }) else { return nil }
                return first
            }
            let common = CellStyle(alignment: shared(\.alignment), font: shared(\.font), number: shared(\.number), fill: shared(\.fill))
            if !common.isPlain, case .object(var entry) = columns[index] {
                entry.merge(fields(common)) { $1 }
                columns[index] = .object(entry)
            }
            let places: [JSONValue?] = [nil] + database.rows.indices.map { .int(Int64($0)) }
            for (place, style) in zip(places, all) {
                var own = style
                if common.alignment != nil { own.alignment = nil }
                if common.font != nil { own.font = nil }
                if common.number != nil { own.number = nil }
                if common.fill != nil { own.fill = nil }
                guard !own.isPlain else { continue }
                var entry: [String: JSONValue] = ["column": .string(column.name)]
                if let place { entry["row"] = place } else { entry["header"] = true }
                entry.merge(fields(own)) { $1 }
                cells.append(.object(entry))
            }
        }
        object["columns"] = .array(columns)
        if !cells.isEmpty { object["cells"] = .array(cells) }
    }

    private static func fields(_ style: CellStyle) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        if let alignment = style.alignment { fields["align"] = .string(alignment.rawValue) }
        if let font = style.font { fields["font"] = .string(font.rawValue) }
        if let number = style.number { fields["format"] = .string(formatName(number)) }
        if let fill = style.fill { fields["fill"] = .string(fill) }
        return fields
    }

    private static func formatName(_ format: CellNumberFormat) -> String {
        switch format {
        case .number: "number"
        case .percent: "percent"
        case .currency(let code): code
        }
    }

    // MARK: Writing

    /// The table's style, its columns' and its cells' (the cells' over their columns').
    static func applyStyles(_ object: [String: JSONValue], to database: inout Database) throws(AgentFormatError) {
        if let value = object["style"], value != .null {
            guard case .object(let fields) = value else {
                throw AgentFormatError("a table's style is {\"header_row\", \"header_column\", \"stripe\"}")
            }
            var style = TableStyle()
            func flag(_ key: String) throws(AgentFormatError) -> Bool? {
                guard let value = fields[key], value != .null else { return nil }
                guard let on = value.boolValue else { throw AgentFormatError("a table's \(key) is true or false") }
                return on
            }
            style.headerRow = try flag("header_row")
            style.headerColumn = try flag("header_column")
            style.stripe = try fields["stripe"]?.stringValue.map { (token) throws(AgentFormatError) in try fill(token) }
            database.style = style.isPlain ? nil : style
        }
        if case .array(let columns)? = object["columns"] {
            for (index, entry) in columns.enumerated() where index < database.columns.count {
                guard case .object(let fields) = entry else { continue }
                let style = try cellStyle(fields)
                guard !style.isPlain else { continue }
                let rows = [nil] + database.rows.map(\.id)
                for row in rows { database.columns[index].setStyle(style, row: row) }
            }
        }
        guard case .array(let cells)? = object["cells"] else { return }
        for entry in cells {
            guard case .object(let fields) = entry, let name = fields["column"]?.stringValue,
                  let index = database.columns.firstIndex(where: { $0.name == name })
            else {
                throw AgentFormatError("a cell is {\"column\", \"row\" or \"header\": true, …} on one of the columns: \(database.columns.map(\.name).joined(separator: ", "))")
            }
            let row: RowID?
            if fields["header"]?.boolValue == true {
                row = nil
            } else {
                guard let place = fields["row"]?.intValue.map(Int.init), database.rows.indices.contains(place) else {
                    throw AgentFormatError("a cell's row is its place in rows, 0 to \(database.rows.count - 1), or \"header\": true")
                }
                row = database.rows[place].id
            }
            let given = try cellStyle(fields)
            var style = database.columns[index].style(row: row)
            style.alignment = given.alignment ?? style.alignment
            style.font = given.font ?? style.font
            style.number = given.number ?? style.number
            style.fill = given.fill ?? style.fill
            database.columns[index].setStyle(style, row: row)
        }
    }

    private static func cellStyle(_ fields: [String: JSONValue]) throws(AgentFormatError) -> CellStyle {
        var style = CellStyle()
        if let name = fields["align"]?.stringValue {
            guard let alignment = CellAlignment(rawValue: name.lowercased()) else {
                throw AgentFormatError("align is \(alignments.joined(separator: ", ")), not \(name)")
            }
            style.alignment = alignment
        }
        if let name = fields["font"]?.stringValue {
            guard let font = CellFont(rawValue: name.lowercased()) else {
                throw AgentFormatError("a font is \(fonts.joined(separator: ", ")), not \(name)")
            }
            style.font = font
        }
        if let name = fields["format"]?.stringValue {
            switch name.lowercased() {
            case "number": style.number = .number
            case "percent": style.number = .percent
            default:
                guard CellNumberFormat.isCurrencyCode(name.uppercased()) else {
                    throw AgentFormatError("a format is number, percent or a currency's code (USD, EUR, CNY, …), not \(name)")
                }
                style.number = .currency(code: name.uppercased())
            }
        }
        if let token = fields["fill"]?.stringValue { style.fill = try fill(token) }
        return style
    }

    private static func fill(_ token: String) throws(AgentFormatError) -> String {
        let token = token.lowercased()
        guard CellStyle.parseFill(token) != nil else {
            throw AgentFormatError("a fill is \(fillDescription), not \(token)")
        }
        return token
    }

    /// What a fill takes, in words: the colours named (an error's), or not (the guide's,
    /// which names them for text).
    static var fillDescription: String { fill(colors: "a color (\(CellStyle.fillColors.joined(separator: ", ")))") }
    static var fillGuide: String { fill(colors: "a color") }

    private static func fill(colors: String) -> String {
        let strengths = CellStyle.fillStrengths.dropFirst().map { "-\($0)" }.joined(separator: " or ")
        return "\(colors), stronger with \(strengths) after it, or #RRGGBB"
    }

    // MARK: A set

    /// The style changes that make `current` look as `rebuilt` (a table read, changed and
    /// written back): its own, and each cell's, matched by its column's name and its row's place.
    static func styleSteps(from rebuilt: Database, to current: Database) -> [DatabaseStep] {
        var steps: [DatabaseStep] = []
        if rebuilt.style != current.style { steps.append(.setTableStyle(style: rebuilt.style, previous: current.style)) }
        for column in current.columns {
            guard let from = rebuilt.columns.first(where: { $0.name == column.name }) else { continue }
            let rows: [(RowID?, RowID?)] = [(nil, nil)] + zip(current.rows, rebuilt.rows).map { ($0.id, $1.id) }
            for (row, other) in rows {
                let wanted = from.style(row: other)
                let had = column.style(row: row)
                if wanted != had { steps.append(.setCellStyle(row: row, column: column.id, style: wanted, previous: had)) }
            }
        }
        return steps
    }
}
