//
//  CollectionGroups.swift
//  DocKit
//
//  A collection view's records in groups by a field's values (Craft's Group By): a kanban's
//  columns, a grouped table's sections. A group is named by a key, the same for the same
//  value: an option's id, a day, a number, the words of a text; "" for records with none.
//  A record with several options of a multiple select is in each of their groups.
//

import Foundation

/// How a view's groups are ordered, and which a kanban leaves out; the field they're of
/// is the view's layout's `groupBy`.
public struct CollectionGrouping: Hashable, Sendable, Codable {
    public enum Order: String, Hashable, Sendable, Codable {
        /// An option field's in its options' order, others' by value.
        case ascending, descending
        /// In `manual`'s order.
        case manual
    }

    public var order: Order
    /// The keys of the groups a kanban leaves out.
    public var hidden: [String]
    /// The keys in the order the groups were put in; groups it doesn't name follow.
    public var manual: [String]

    public init(order: Order = .ascending, hidden: [String] = [], manual: [String] = []) {
        self.order = order
        self.hidden = hidden
        self.manual = manual
    }
}

/// One group of a view's records.
public struct CollectionGroup: Hashable, Sendable {
    /// "" for the records with no value.
    public var key: String
    /// The value a record takes to join it; nil for the group of none.
    public var value: CellValue?
    public var rows: [Row]

    public init(key: String, value: CellValue?, rows: [Row]) {
        self.key = key
        self.value = value
        self.rows = rows
    }
}

extension CollectionView {
    /// `rows` (the view's, in its order) in groups by its layout's column, in its grouping's
    /// order, the group of none first; nil when it doesn't group. A group with no records
    /// is there only for an option, when `everyOption`.
    public func groups(of rows: [Row], in database: Database, everyOption: Bool = false) -> [CollectionGroup]? {
        guard let id = layout.groupBy, let column = database.columns.first(where: { $0.id == id }) else { return nil }
        let options: [SelectOption]? = switch column.type {
        case .select(let options), .multiSelect(let options): options
        default: nil
        }
        var groups: [String: CollectionGroup] = [:]
        var none: [Row] = []
        for row in rows {
            let members = Self.members(row.cells[id], options: options)
            if members.isEmpty { none.append(row) }
            for (key, value) in members {
                groups[key, default: CollectionGroup(key: key, value: value, rows: [])].rows.append(row)
            }
        }
        var ordered: [CollectionGroup]
        if let options {
            ordered = options.compactMap { option in
                groups[option.id.description] ?? (everyOption ? CollectionGroup(key: option.id.description, value: Self.value(option.id, in: column), rows: []) : nil)
            }
        } else {
            ordered = groups.values.sorted { a, b in
                switch (DatabaseSorting.key(a.value, column), DatabaseSorting.key(b.value, column)) {
                case let (x?, y?) where x != y: x < y
                default: a.key < b.key
                }
            }
        }
        switch grouping.order {
        case .ascending: break
        case .descending: ordered.reverse()
        case .manual:
            let place = Dictionary(grouping.manual.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            ordered = ordered.enumerated().sorted { a, b in
                (place[a.element.key] ?? Int.max, a.offset) < (place[b.element.key] ?? Int.max, b.offset)
            }.map(\.element)
        }
        if !none.isEmpty || everyOption && options != nil {
            let empty = CollectionGroup(key: "", value: nil, rows: none)
            if grouping.order == .manual, let index = grouping.manual.firstIndex(of: "") {
                // Before the first group named after it.
                let after = Set(grouping.manual[(index + 1)...])
                ordered.insert(empty, at: ordered.firstIndex { after.contains($0.key) } ?? ordered.endIndex)
            } else {
                ordered.insert(empty, at: 0)
            }
        }
        return ordered
    }

    /// The groups a value puts a record in: their keys, and the value each stands for.
    private static func members(_ value: CellValue?, options: [SelectOption]?) -> [(String, CellValue)] {
        switch value {
        case nil: []
        case .select(let option)?:
            options?.contains(where: { $0.id == option }) == true ? [(option.description, .select(option: option))] : []
        case .multiSelect(let ids)?:
            (options ?? []).filter { ids.contains($0.id) }.map { ($0.id.description, .multiSelect(options: [$0.id])) }
        case .checkbox(let on)?: on ? [("true", .checkbox(value: true))] : []
        case .number(let number)?: [(String(number), .number(value: number))]
        case .date(let day)?: [(String(day.millisecondsSince1970), .date(value: day))]
        case .text(let text)?: text.isEmpty ? [] : [(text, .text(value: text))]
        case .url(let text)?: text.isEmpty ? [] : [(text, .url(value: text))]
        case .person(let text)?: text.isEmpty ? [] : [(text, .person(value: text))]
        case .richText(let text)?: text.string.isEmpty ? [] : [(text.string, .text(value: text.string))]
        }
    }

    private static func value(_ option: OptionID, in column: Column) -> CellValue {
        if case .multiSelect = column.type { .multiSelect(options: [option]) } else { .select(option: option) }
    }
}
