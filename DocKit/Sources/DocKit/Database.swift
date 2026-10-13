/// A document database: the thing behind a table or kanban block. Lives in
/// `Doc.databases`; a block only references it by id, so several view blocks
/// can share one database.
public struct Database: Hashable, Sendable, Codable {
    public var id: DatabaseID
    public var columns: [Column]
    public var rows: [Row]

    public init(id: DatabaseID, columns: [Column] = [], rows: [Row] = []) {
        self.id = id
        self.columns = columns
        self.rows = rows
    }
}

public struct Column: Hashable, Sendable, Codable {
    public var id: ColumnID
    public var name: String
    public var type: ColumnType

    public init(id: ColumnID, name: String, type: ColumnType) {
        self.id = id
        self.name = name
        self.type = type
    }
}

public enum ColumnType: Hashable, Sendable, Codable {
    case text
    case number
    case select(options: [SelectOption])
    case multiSelect(options: [SelectOption])
    case date
    case checkbox
    case url
    case person
}

public struct SelectOption: Hashable, Sendable, Codable {
    public var id: OptionID
    public var name: String
    /// One of the document's colours (gray, purple, blue, …); nil takes one by its place.
    public var color: String?

    public init(id: OptionID, name: String, color: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
    }
}

public struct Row: Hashable, Sendable, Codable {
    public var id: RowID
    /// Only columns present in `Database.columns` carry values.
    public var cells: [ColumnID: CellValue]

    public init(id: RowID, cells: [ColumnID: CellValue] = [:]) {
        self.id = id
        self.cells = cells
    }
}

public enum CellValue: Hashable, Sendable, Codable {
    case text(value: String)
    case number(value: Double)
    case select(option: OptionID)
    case multiSelect(options: [OptionID])
    case date(value: Timestamp)
    case checkbox(value: Bool)
    case url(value: String)
    case person(value: String)
}

/// How a database block presents its database. Two blocks on the same
/// database can use different views.
public enum DatabaseView: Hashable, Sendable, Codable {
    case table(hidden: [ColumnID], sort: [DatabaseSort])
    case kanban(groupBy: ColumnID, hidden: [ColumnID], sort: [DatabaseSort])
}

public struct DatabaseSort: Hashable, Sendable, Codable {
    public var column: ColumnID
    public var ascending: Bool

    public init(column: ColumnID, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}
