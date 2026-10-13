/// A collection view's filter: a column, how its value is tested, and what against.
/// A view shows the records every one of its filters lets through.
public struct CollectionFilter: Hashable, Sendable, Codable {
    public enum Condition: String, Hashable, Sendable, Codable, CaseIterable {
        /// Text holds the value's text; a multi-select has the option.
        case contains, doesNotContain
        /// The same value (a day for a date, the option for a select).
        case `is`, isNot
        /// A number above or below; a date after or before.
        case greaterThan, lessThan
        case isEmpty, isNotEmpty
    }

    public var column: ColumnID
    public var condition: Condition
    /// What the condition tests against; none for isEmpty and isNotEmpty.
    public var value: CellValue?

    public init(column: ColumnID, condition: Condition, value: CellValue? = nil) {
        self.column = column
        self.condition = condition
        self.value = value
    }

    /// The conditions a column of this type takes, the first its default.
    public static func conditions(for type: ColumnType) -> [Condition] {
        switch type {
        case .text, .url, .person: [.contains, .doesNotContain, .is, .isNot, .isEmpty, .isNotEmpty]
        case .number, .date: [.is, .isNot, .greaterThan, .lessThan, .isEmpty, .isNotEmpty]
        case .select: [.is, .isNot, .isEmpty, .isNotEmpty]
        case .multiSelect: [.contains, .doesNotContain, .isEmpty, .isNotEmpty]
        case .checkbox: [.is]
        }
    }

    /// Whether the record passes. A filter without a value yet (one being set up), or on a
    /// column that's gone, lets everything through.
    public func matches(_ row: Row, in database: Database) -> Bool {
        guard let column = database.columns.first(where: { $0.id == self.column }) else { return true }
        let cell = row.cells[column.id]
        switch condition {
        case .isEmpty: return Self.isEmpty(cell)
        case .isNotEmpty: return !Self.isEmpty(cell)
        default: break
        }
        if case .checkbox = column.type {
            let wanted = if case .checkbox(let on)? = value { on } else { true }
            return (cell == .checkbox(value: true)) == wanted
        }
        guard let value else { return true }
        switch condition {
        case .contains, .doesNotContain:
            let holds: Bool
            if case .multiSelect = column.type {
                let options = cell.map(Self.options) ?? []
                holds = Self.options(value).allSatisfy(options.contains)
            } else {
                let wanted = Self.text(value).lowercased()
                holds = wanted.isEmpty || (cell.map(Self.text)?.lowercased().contains(wanted) ?? false)
            }
            return holds == (condition == .contains)
        case .is, .isNot:
            let same: Bool = switch (cell, value) {
            case (.number(let a)?, .number(let b)): a == b
            case (.date(let a)?, .date(let b)): Self.day(a) == Self.day(b)
            case (.select(let a)?, .select(let b)): a == b
            case (nil, _): false
            default: cell.map(Self.text)?.lowercased() == Self.text(value).lowercased()
            }
            return same == (condition == .is)
        case .greaterThan, .lessThan:
            let order: (Double, Double)? = switch (cell, value) {
            case (.number(let a)?, .number(let b)): (a, b)
            case (.date(let a)?, .date(let b)): (Double(Self.day(a)), Double(Self.day(b)))
            default: nil
            }
            guard let (a, b) = order else { return false }
            return condition == .greaterThan ? a > b : a < b
        case .isEmpty, .isNotEmpty:
            return true
        }
    }

    private static func isEmpty(_ cell: CellValue?) -> Bool {
        switch cell {
        case nil: true
        case .text(let text)?, .url(let text)?, .person(let text)?: text.isEmpty
        case .multiSelect(let options)?: options.isEmpty
        case .checkbox(let on)?: !on
        default: false
        }
    }

    private static func text(_ value: CellValue) -> String {
        switch value {
        case .text(let text), .url(let text), .person(let text): text
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        default: ""
        }
    }

    private static func options(_ value: CellValue) -> [OptionID] {
        switch value {
        case .select(let option): [option]
        case .multiSelect(let options): options
        default: []
        }
    }

    /// The day a date is on (dates are days at midnight UTC).
    private static func day(_ timestamp: Timestamp) -> Int64 {
        let ms = timestamp.millisecondsSince1970
        return ms >= 0 ? ms / 86_400_000 : -((-ms + 86_399_999) / 86_400_000)
    }
}

extension CollectionView {
    /// The records it shows, in its order: those its filters let through, sorted.
    public func records(of database: Database) -> [Row] {
        let kept = database.rows.filter { row in filters.allSatisfy { $0.matches(row, in: database) } }
        return DatabaseSorting.sorted(kept, by: layout.sort, in: database)
    }
}

/// A view's sorting: by each sort column in turn, empties last; ties keep the records' order.
public enum DatabaseSorting {
    public static func sorted(_ rows: [Row], by sort: [DatabaseSort], in database: Database) -> [Row] {
        guard !sort.isEmpty else { return rows }
        let columns = Dictionary(database.columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.enumerated().sorted { a, b in
            for entry in sort {
                guard let column = columns[entry.column] else { continue }
                let x = key(a.element.cells[entry.column], column), y = key(b.element.cells[entry.column], column)
                if x == y { continue }
                guard let x else { return false }
                guard let y else { return true }
                return entry.ascending ? x < y : x > y
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    private enum Key: Comparable {
        case number(Double)
        case text(String)
    }

    private static func key(_ value: CellValue?, _ column: Column) -> Key? {
        switch value {
        case nil: return nil
        case .number(let number)?: return .number(number)
        case .date(let date)?: return .number(Double(date.millisecondsSince1970))
        case .checkbox(let on)?: return .number(on ? 1 : 0)
        case .select(let option)?:
            guard case .select(let options) = column.type, let index = options.firstIndex(where: { $0.id == option }) else { return nil }
            return .number(Double(index))
        case .multiSelect(let ids)?:
            guard case .multiSelect(let options) = column.type else { return nil }
            return .text(options.filter { ids.contains($0.id) }.map(\.name).joined(separator: ", ").lowercased())
        case .text(let text)?, .url(let text)?, .person(let text)?:
            return text.isEmpty ? nil : .text(text.lowercased())
        }
    }
}
