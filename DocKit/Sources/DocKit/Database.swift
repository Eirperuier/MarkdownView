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
    /// Text with marks (bold, a link, a mention…); text without marks is `.text`.
    case richText(text: DocText)
}

extension CellValue {
    /// A text cell: `.text` when it carries no marks, else `.richText`.
    public static func text(_ text: DocText) -> CellValue {
        text.marks.isEmpty ? .text(value: text.string) : .richText(text: text)
    }

    /// The text of a text cell, marks and all; nil for other kinds.
    public var docText: DocText? {
        switch self {
        case .text(let value): DocText(string: value)
        case .richText(let text): text
        default: nil
        }
    }
}

/// How a database block presents its database. Two blocks on the same
/// database can use different views.
public enum DatabaseView: Hashable, Sendable, Codable {
    case table(hidden: [ColumnID], sort: [DatabaseSort])
    case kanban(groupBy: ColumnID, hidden: [ColumnID], sort: [DatabaseSort])
}

extension DatabaseView {
    /// The columns it leaves out.
    public var hidden: [ColumnID] {
        get {
            switch self {
            case .table(let hidden, _), .kanban(_, let hidden, _): hidden
            }
        }
        set {
            switch self {
            case .table(_, let sort): self = .table(hidden: newValue, sort: sort)
            case .kanban(let group, _, let sort): self = .kanban(groupBy: group, hidden: newValue, sort: sort)
            }
        }
    }

    /// How its records are ordered, by each column in turn.
    public var sort: [DatabaseSort] {
        get {
            switch self {
            case .table(_, let sort), .kanban(_, _, let sort): sort
            }
        }
        set {
            switch self {
            case .table(let hidden, _): self = .table(hidden: hidden, sort: newValue)
            case .kanban(let group, let hidden, _): self = .kanban(groupBy: group, hidden: hidden, sort: newValue)
            }
        }
    }

    /// The select column a kanban groups by; nil for a table.
    public var groupBy: ColumnID? {
        if case .kanban(let group, _, _) = self { group } else { nil }
    }
}

public struct DatabaseSort: Hashable, Sendable, Codable {
    public var column: ColumnID
    public var ascending: Bool

    public init(column: ColumnID, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}
