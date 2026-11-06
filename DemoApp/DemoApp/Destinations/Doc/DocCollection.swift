//
//  DocCollection.swift
//  DemoApp
//
//  A collection block, Craft's: its name, a tab for each view of its records (a table,
//  a kanban), and the view showing. The same records in every view, edited in any:
//  - the header: the name; a tab per view (click shows it; right-click for its panels,
//    rename, duplicate, delete); + adds a table (then names it) or a kanban (Create
//    Kanban: its name and the select it groups by). On the pointer over the block, the
//    toolbar: search, a new record, and the view's menu (Layout & Visibility, Filter,
//    Sort, Group, rename, duplicate, delete, Download as CSV);
//  - the table (DocCollectionTable): a field's header opens its menu, + adds a field;
//    the row number turns into a box to pick rows; the title's arrow opens the record;
//  - the kanban (DocCollectionKanban): a column per option of the grouping select;
//  - the chart (DocCollectionChart): a mark per group of the field it groups by.
//  Every change is DocKit steps (a database step for the records and fields, a setBlock
//  for the name and views), so undo, redo and sync treat it like the rest of the document.
//  What only this window shows (a search, the rows picked, an open panel) isn't.
//  Sizes are measured from Craft's (Mac, 2026-10-13 recordings).
//

import FlooUIKit
import SwiftUI
import DocKit
import FlooDesign
import MarkdownView

struct DocCollectionSnapshot: Equatable {
    let block: DocBlockID
    let collection: DocCollection
    let database: Database
}

/// The collection panel open, and the block it's for.
struct DocCollectionPanel: Hashable {
    enum Kind: Hashable {
        case layout, sort, filter, group
        /// A chart view's settings: what it measures, how it looks.
        case chart
        case createKanban
        case createChart
        /// A view just added, to name.
        case nameView(CollectionViewID)
        case addField
        case editField(ColumnID)
        /// A select or multi-select cell's options.
        case options(row: RowID, column: ColumnID)
        /// A new option of a select (a kanban's new column), or one to change.
        case addOption(ColumnID)
        case editOption(OptionID)
        /// A date cell's calendar.
        case date(row: RowID, column: ColumnID)
        /// A record's text, number or link typed in a field of its own (a kanban card's Edit
        /// Properties).
        case property(row: RowID, column: ColumnID)
        /// Add Field from a kanban card's Edit Properties.
        case cardField(RowID)
    }

    let block: DocBlockID
    let kind: Kind
}

// MARK: - Controller

@MainActor
@Observable
final class DocCollectionController {
    @ObservationIgnored private let demo: DocDemo
    @ObservationIgnored unowned let editor: DocEditor
    /// Typing in one field is one undo step until another is edited.
    @ObservationIgnored private var session: UInt64 = 0
    @ObservationIgnored private var typing: AnyHashable?
    /// The record whose title takes typing as it shows (one just added).
    var editingTitle: RowID?
    /// What each block's search looks for (not part of the document).
    var searches: [DocBlockID: String] = [:]
    /// The table rows picked in each block.
    var selectedRows: [DocBlockID: Set<RowID>] = [:]
    var panel: DocCollectionPanel?
    /// Opens a record as a page (the window's pages; DocRecordPage).
    @ObservationIgnored var openRecord: ((RowID, DocBlockID) -> Void)?
    /// Whether a record's page has something written in it (its title cell shows a page).
    @ObservationIgnored var hasPage: ((RowID) -> Bool)?
    /// A duplicated record's page made from the original's (the original's id, the copy's).
    @ObservationIgnored var copyPage: ((RowID, RowID) -> Void)?

    init(demo: DocDemo, editor: DocEditor) {
        self.demo = demo
        self.editor = editor
    }

    var isEditable: Bool { editor.isEditable }

    // MARK: Panels

    func isShowing(_ kind: DocCollectionPanel.Kind, in block: DocBlockID) -> Bool {
        panel == DocCollectionPanel(block: block, kind: kind)
    }

    func show(_ kind: DocCollectionPanel.Kind, in block: DocBlockID) {
        panel = DocCollectionPanel(block: block, kind: kind)
    }

    /// Closes the panel if it's still this one (another may have opened as it went).
    func close(_ kind: DocCollectionPanel.Kind, in block: DocBlockID) {
        if isShowing(kind, in: block) { panel = nil }
    }

    // MARK: Committing

    private func snapshot(_ block: DocBlockID) -> (collection: DocCollection, database: Database)? {
        guard case .collection(let collection)? = demo.doc.block(block)?.kind,
              let database = demo.doc.databases[collection.database] else { return nil }
        return (collection, database)
    }

    /// One undo step; or, with `typing`, one step for all the changes made under the same key
    /// in a row (each keystroke in one field).
    private func commit(_ block: DocBlockID, _ steps: [DocStep], typing key: AnyHashable? = nil) {
        guard !steps.isEmpty else { return }
        if key == nil || key != typing { session &+= 1 }
        typing = key
        _ = demo.edit(steps, before: nil, after: nil, merge: key == nil ? nil : .init(block: block, session: session))
    }

    private func records(_ block: DocBlockID, _ steps: [DatabaseStep], typing key: AnyHashable? = nil) {
        guard let (collection, _) = snapshot(block) else { return }
        commit(block, steps.map { .database(id: collection.database, step: $0) }, typing: key)
    }

    /// The block's name and views changed: one setBlock.
    private func change(_ block: DocBlockID, typing key: AnyHashable? = nil, _ update: (inout DocCollection) -> Void) {
        guard let step = setBlock(block, update) else { return }
        commit(block, [step], typing: key)
    }

    private func setBlock(_ block: DocBlockID, _ update: (inout DocCollection) -> Void) -> DocStep? {
        guard let existing = demo.doc.block(block), case .collection(var collection) = existing.kind else { return nil }
        update(&collection)
        let kind = BlockKind.collection(collection: collection)
        guard kind != existing.kind else { return nil }
        return .setBlock(block: block, kind: kind, indent: existing.indent, previousKind: existing.kind, previousIndent: existing.indent)
    }

    private func changeView(_ view: CollectionViewID, in block: DocBlockID, typing key: AnyHashable? = nil, _ update: (inout CollectionView) -> Void) {
        change(block, typing: key) { collection in
            guard let index = collection.views.firstIndex(where: { $0.id == view }) else { return }
            update(&collection.views[index])
        }
    }

    // MARK: Name and views

    func rename(_ block: DocBlockID, to name: String) { change(block, typing: [AnyHashable(block), "name"]) { $0.name = name } }

    func show(_ view: CollectionViewID, in block: DocBlockID) { change(block) { $0.current = view } }

    /// A new view after the others, showing.
    @discardableResult
    func addView(to block: DocBlockID, name: String, layout: DatabaseView) -> CollectionViewID {
        let view = CollectionView(name: name, layout: layout)
        change(block) { collection in
            collection.views.append(view)
            collection.current = view.id
        }
        return view.id
    }

    func rename(_ view: CollectionViewID, in block: DocBlockID, to name: String) {
        guard !name.isEmpty else { return }
        changeView(view, in: block) { $0.name = name }
    }

    func duplicate(_ view: CollectionViewID, in block: DocBlockID) {
        change(block) { collection in
            guard let index = collection.views.firstIndex(where: { $0.id == view }) else { return }
            var copy = collection.views[index]
            copy.id = .generate()
            collection.views.insert(copy, at: index + 1)
            collection.current = copy.id
        }
    }

    func delete(_ view: CollectionViewID, in block: DocBlockID) {
        change(block) { collection in
            guard collection.views.count > 1, let index = collection.views.firstIndex(where: { $0.id == view }) else { return }
            collection.views.remove(at: index)
            if collection.current == view { collection.current = collection.views[max(0, index - 1)].id }
        }
    }

    func setCalculation(_ calculation: CollectionCalculation?, for column: ColumnID, in view: CollectionViewID, of block: DocBlockID) {
        changeView(view, in: block) { $0.calculations[column] = calculation }
    }

    func setShowsCalculations(_ shows: Bool, in view: CollectionViewID, of block: DocBlockID) {
        changeView(view, in: block) { $0.showsCalculations = shows }
    }

    /// A table becomes a kanban grouped by `group` (or what the table's grouped by, or the
    /// first select, or the first field after the title), a kanban an ungrouped table (a
    /// table groups only when asked to), a chart a table grouped by its axis; what's hidden
    /// and the sorting stay.
    func setLayout(kanban: Bool, groupedBy group: ColumnID? = nil, in view: CollectionViewID, of block: DocBlockID) {
        guard let (_, database) = snapshot(block) else { return }
        changeView(view, in: block) { view in
            let hidden = view.layout.hidden, sort = view.layout.sort
            if kanban {
                guard let group = group ?? view.layout.groupBy ?? Self.groupable(in: database).first?.id else { return }
                if group != view.layout.groupBy { view.grouping = CollectionGrouping() }
                view.layout = .kanban(groupBy: group, hidden: hidden, sort: sort)
            } else if view.layout.isKanban {
                view.layout = .table(hidden: hidden, sort: sort)
                view.grouping = CollectionGrouping()
            } else if let chart = view.layout.chart {
                view.layout = .table(hidden: hidden, sort: sort, groupBy: chart.groupBy)
            }
        }
    }

    /// A view becomes a chart of `kind` (a chart, one of that kind): along what it's grouped
    /// by, or the field its kind reads best along; its groups' order and what's hidden stay.
    func setChart(_ kind: CollectionChart.Kind = .bar, in view: CollectionViewID, of block: DocBlockID) {
        guard let (_, database) = snapshot(block) else { return }
        changeView(view, in: block) { view in
            if var chart = view.layout.chart {
                chart.kind = kind
                view.layout = .chart(chart: chart)
                return
            }
            guard var chart = Self.chart(kind, in: database, groupedBy: view.layout.groupBy) else { return }
            chart.hidden = view.layout.hidden
            chart.sort = view.layout.sort
            if chart.groupBy != view.layout.groupBy { view.grouping = CollectionGrouping() }
            view.layout = .chart(chart: chart)
        }
    }

    /// A new chart's fields: grouped by `group`, else the first select for a ring, the first
    /// date for bars up or a line, else the title; the first number summed (none: counted);
    /// bars along the titles ranked.
    static func chart(_ kind: CollectionChart.Kind, in database: Database, groupedBy group: ColumnID? = nil) -> CollectionChart? {
        let title = titleColumn(of: database)?.id
        let date = database.columns.first { $0.type == .date }?.id
        let preferred: ColumnID? = switch kind {
        case .donut: selects(in: database).first?.id
        case .column, .line: date
        case .bar: title
        }
        guard let axis = group ?? preferred ?? title ?? database.columns.first?.id else { return nil }
        let values = kind == .donut ? [] : database.columns.first { $0.type == .number }.map { [$0.id] } ?? []
        return CollectionChart(kind: kind, groupBy: axis, values: values, calculation: values.isEmpty ? .count : .sum,
                               order: kind == .bar && axis == title && !values.isEmpty ? .valueDescending : .groups)
    }

    /// A chart view's settings changed: one step (or one for all typed in one field).
    func changeChart(_ view: CollectionViewID, in block: DocBlockID, typing key: AnyHashable? = nil, _ update: @escaping (inout CollectionChart) -> Void) {
        changeView(view, in: block, typing: key) { view in
            guard var chart = view.layout.chart else { return }
            update(&chart)
            view.layout = .chart(chart: chart)
        }
    }

    /// The field the view's records are grouped by; nil ungroups a table (a kanban always
    /// groups). Another field starts its groups afresh: in their order, none left out.
    func setGroup(_ column: ColumnID?, in view: CollectionViewID, of block: DocBlockID) {
        changeView(view, in: block) { view in
            guard column != view.layout.groupBy else { return }
            switch view.layout {
            case .table(let hidden, let sort, _): view.layout = .table(hidden: hidden, sort: sort, groupBy: column)
            case .kanban(_, let hidden, let sort):
                guard let column else { return }
                view.layout = .kanban(groupBy: column, hidden: hidden, sort: sort)
            case .chart(var chart):
                guard let column else { return }
                chart.groupBy = column
                chart.highlight = []
                view.layout = .chart(chart: chart)
            }
            view.grouping = CollectionGrouping()
        }
    }

    /// The groups' order, or which are left out.
    func setGrouping(_ grouping: CollectionGrouping, in view: CollectionViewID, of block: DocBlockID) {
        changeView(view, in: block) { $0.grouping = grouping }
    }

    /// A group dragged before `before` (or to the end) among `keys`, the groups as they
    /// show: their order becomes manual.
    func moveGroup(_ key: String, before: String?, among keys: [String], in view: CollectionViewID, of block: DocBlockID) {
        guard key != before else { return }
        changeView(view, in: block) { view in
            var order = keys
            order.removeAll { $0 == key }
            order.insert(key, at: before.flatMap { order.firstIndex(of: $0) } ?? order.endIndex)
            view.grouping.order = .manual
            view.grouping.manual = order
        }
    }

    func setHidden(_ column: ColumnID, _ hidden: Bool, in view: CollectionViewID, of block: DocBlockID) {
        changeView(view, in: block) { view in
            view.layout.hidden.removeAll { $0 == column }
            if hidden { view.layout.hidden.append(column) }
        }
    }

    /// A field moved before `before` (or to the end) in the view's order.
    func moveField(_ column: ColumnID, before: ColumnID?, in view: CollectionViewID, of block: DocBlockID) {
        guard let (_, database) = snapshot(block), column != before else { return }
        changeView(view, in: block) { view in
            var order = view.ordered(database.columns).map(\.id)
            order.removeAll { $0 == column }
            order.insert(column, at: before.flatMap { order.firstIndex(of: $0) } ?? order.endIndex)
            view.order = order
        }
    }

    func setSort(_ sort: [DatabaseSort], in view: CollectionViewID, of block: DocBlockID) {
        changeView(view, in: block) { $0.layout.sort = sort }
    }

    /// The view's filters; a value typed in one is one undo step.
    func setFilters(_ filters: [CollectionFilter], typing key: AnyHashable? = nil, in view: CollectionViewID, of block: DocBlockID) {
        changeView(view, in: block, typing: key) { $0.filters = filters }
    }

    // MARK: Fields

    /// A new field after the others.
    @discardableResult
    func addField(_ name: String, type: ColumnType, to block: DocBlockID) -> ColumnID? {
        guard let (_, database) = snapshot(block) else { return nil }
        let column = Column(id: .generate(), name: name, type: type)
        records(block, [.insertColumn(column: column, after: database.columns.last?.id, cells: [:])])
        return column.id
    }

    /// A field renamed or of another type: each value turned into the new type as far as
    /// it goes (text into a number, names into options, …), in one undo step.
    func editField(_ column: ColumnID, name: String, type: ColumnType, in block: DocBlockID) {
        guard let (_, database) = snapshot(block), let old = database.columns.first(where: { $0.id == column }) else { return }
        var new = old
        new.name = name.isEmpty ? old.name : name
        var steps: [DatabaseStep] = []
        if !Self.sameKind(old.type, type) {
            var options = DocFieldText.options(old)
            var values: [RowID: CellValue?] = [:]
            for row in database.rows {
                let value = Self.converted(row.cells[column], from: old, to: type, options: &options)
                if value != row.cells[column] { values[row.id] = value }
            }
            new.type = switch type {
            case .select: .select(options: options)
            case .multiSelect: .multiSelect(options: options)
            default: type
            }
            steps.append(.updateColumn(column: new, previous: old))
            for row in database.rows {
                guard let value = values[row.id] else { continue }
                steps.append(.setCell(row: row.id, column: column, value: value, previous: row.cells[column]))
            }
        } else if new != old {
            steps.append(.updateColumn(column: new, previous: old))
        }
        records(block, steps)
    }

    /// A field gone from the records and from every view (a view grouped by it becomes an
    /// ungrouped table), in one undo step.
    func deleteField(_ column: ColumnID, in block: DocBlockID) {
        guard let (collection, database) = snapshot(block), database.columns.count > 1,
              let index = database.columns.firstIndex(where: { $0.id == column }) else { return }
        var cells: [RowID: CellValue] = [:]
        for row in database.rows { cells[row.id] = row.cells[column] }
        var steps: [DocStep] = [.database(id: collection.database, step: .deleteColumn(
            column: database.columns[index], after: index == 0 ? nil : database.columns[index - 1].id, cells: cells))]
        let views = setBlock(block) { collection in
            for index in collection.views.indices {
                var view = collection.views[index]
                view.layout.hidden.removeAll { $0 == column }
                view.layout.sort.removeAll { $0.column == column }
                if view.layout.groupBy == column {
                    view.layout = .table(hidden: view.layout.hidden, sort: view.layout.sort)
                    view.grouping = CollectionGrouping()
                }
                if var chart = view.layout.chart {
                    chart.values.removeAll { $0 == column }
                    if chart.values.isEmpty, CollectionChart.measures(chart.calculation) { chart.calculation = .count }
                    if chart.colorBy == column { chart.colorBy = nil }
                    view.layout = .chart(chart: chart)
                }
                view.filters.removeAll { $0.column == column }
                view.calculations[column] = nil
                view.order.removeAll { $0 == column }
                collection.views[index] = view
            }
        }
        if let views { steps.append(views) }
        commit(block, steps)
    }

    private static func sameKind(_ a: ColumnType, _ b: ColumnType) -> Bool {
        switch (a, b) {
        case (.select, .select), (.multiSelect, .multiSelect): true
        default: a == b
        }
    }

    /// A value as the new type holds it; names become options (added to `options`).
    private static func converted(_ value: CellValue?, from old: Column, to type: ColumnType, options: inout [SelectOption]) -> CellValue? {
        guard let value else { return nil }
        let parts: [String] = switch value {
        case .multiSelect: DocFieldText.text(value, in: old).components(separatedBy: ", ")
        case .checkbox(let on): on ? ["✓"] : []
        default: [DocFieldText.text(value, in: old)]
        }
        let names = parts.filter { !$0.isEmpty }
        func option(_ name: String) -> OptionID {
            if let found = options.first(where: { $0.name == name }) { return found.id }
            let added = SelectOption(id: .generate(), name: name, color: DocOptionColor.next(after: options))
            options.append(added)
            return added.id
        }
        let text = names.joined(separator: ", ")
        switch type {
        case .text: return text.isEmpty ? nil : .text(value: text)
        case .url: return CellFormat.link(text).map { .url(value: $0) }
        case .person: return text.isEmpty ? nil : .person(value: text)
        case .number:
            if case .checkbox(let on) = value { return .number(value: on ? 1 : 0) }
            return DocFieldText.number(text).map { .number(value: $0) }
        case .checkbox:
            if case .number(let number) = value { return number != 0 ? .checkbox(value: true) : nil }
            return ["✓", "true", "yes", "1", "x"].contains(text.lowercased()) ? .checkbox(value: true) : nil
        case .date:
            if case .date = value { return value }
            return DocFieldText.day(from: text).map { .date(value: .day($0)) }
        case .select: return names.first.map { .select(option: option($0)) }
        case .multiSelect: return names.isEmpty ? nil : .multiSelect(options: names.map(option))
        }
    }

    // MARK: Options

    /// A new option of a select or multi-select column.
    @discardableResult
    func addOption(_ name: String, color: String? = nil, to column: ColumnID, in block: DocBlockID) -> OptionID? {
        guard let (_, database) = snapshot(block), let field = database.columns.first(where: { $0.id == column }), !name.isEmpty else { return nil }
        var options = DocFieldText.options(field)
        let option = SelectOption(id: .generate(), name: name, color: color ?? DocOptionColor.next(after: options))
        options.append(option)
        var updated = field
        switch field.type {
        case .select: updated.type = .select(options: options)
        case .multiSelect: updated.type = .multiSelect(options: options)
        default: return nil
        }
        records(block, [.updateColumn(column: updated, previous: field)])
        return option.id
    }

    func updateOption(_ option: OptionID, name: String, color: String, in column: ColumnID, of block: DocBlockID) {
        guard let (_, database) = snapshot(block), let field = database.columns.first(where: { $0.id == column }), !name.isEmpty else { return }
        let options = DocFieldText.options(field).map { $0.id == option ? SelectOption(id: option, name: name, color: color) : $0 }
        var updated = field
        switch field.type {
        case .select: updated.type = .select(options: options)
        case .multiSelect: updated.type = .multiSelect(options: options)
        default: return
        }
        records(block, [.updateColumn(column: updated, previous: field)])
    }

    /// An option gone, and from every record that had it (a kanban's column of it with them).
    func deleteOption(_ option: OptionID, in column: ColumnID, of block: DocBlockID) {
        guard let (_, database) = snapshot(block), let field = database.columns.first(where: { $0.id == column }) else { return }
        var steps: [DatabaseStep] = []
        for row in database.rows {
            let value: CellValue?? = switch row.cells[column] {
            case .select(option)?: .some(nil)
            case .multiSelect(let ids)? where ids.contains(option):
                ids.count == 1 ? .some(nil) : .some(.multiSelect(options: ids.filter { $0 != option }))
            default: .none
            }
            if let value { steps.append(.setCell(row: row.id, column: column, value: value, previous: row.cells[column])) }
        }
        let options = DocFieldText.options(field).filter { $0.id != option }
        var updated = field
        switch field.type {
        case .select: updated.type = .select(options: options)
        case .multiSelect: updated.type = .multiSelect(options: options)
        default: return
        }
        steps.append(.updateColumn(column: updated, previous: field))
        records(block, steps)
    }

    /// A select set to the option (picked again, cleared); a multi-select with it added or taken out.
    func toggle(_ option: OptionID, row: RowID, column: ColumnID, in block: DocBlockID) {
        guard let (_, database) = snapshot(block), let record = database.rows.first(where: { $0.id == row }),
              let field = database.columns.first(where: { $0.id == column }) else { return }
        let value: CellValue?
        switch (field.type, record.cells[column]) {
        case (.select, .select(option)?): value = nil
        case (.select, _): value = .select(option: option)
        case (.multiSelect, .multiSelect(let ids)?):
            let toggled = ids.contains(option) ? ids.filter { $0 != option } : ids + [option]
            value = toggled.isEmpty ? nil : .multiSelect(options: toggled)
        case (.multiSelect, _): value = .multiSelect(options: [option])
        default: return
        }
        set(value, row: row, column: column, in: block)
    }

    // MARK: Records

    /// A new record: at the end, or in a group (its field set to the group's value) at the
    /// group's end or `atTop`; its title takes typing.
    @discardableResult
    func addRecord(to block: DocBlockID, in group: (column: ColumnID, value: CellValue?)? = nil, atTop: Bool = false) -> RowID? {
        guard let (_, database) = snapshot(block) else { return nil }
        var cells: [ColumnID: CellValue] = [:]
        if let group, let value = group.value { cells[group.column] = value }
        let row = Row(id: .generate(), cells: cells)
        var after = database.rows.last?.id
        if let group {
            let members = database.rows.indices.filter { Self.isIn(database.rows[$0], group.column, group.value) }
            if atTop, let first = members.first {
                after = first == 0 ? nil : database.rows[first - 1].id
            } else if let last = members.last {
                after = database.rows[last].id
            }
        }
        records(block, [.insertRow(row: row, after: after)])
        editingTitle = row.id
        return row.id
    }

    func setText(_ text: String, row: RowID, column: ColumnID, in block: DocBlockID) {
        guard let (_, database) = snapshot(block), let record = database.rows.first(where: { $0.id == row }),
              let field = database.columns.first(where: { $0.id == column }) else { return }
        let previous = record.cells[column]
        // Text the field doesn't take (a word in a number) isn't written; the cell shows
        // what it holds when the editing ends.
        guard DocFieldText.takes(text, in: field) else { return }
        let value = DocFieldText.value(typed: text, in: field)
        guard value != previous else { return }
        records(block, [.setCell(row: row, column: column, value: value, previous: previous)], typing: [AnyHashable(row), AnyHashable(column)])
    }

    func set(_ value: CellValue?, row: RowID, column: ColumnID, in block: DocBlockID) {
        guard let (_, database) = snapshot(block), let record = database.rows.first(where: { $0.id == row }) else { return }
        let previous = record.cells[column]
        guard value != previous else { return }
        records(block, [.setCell(row: row, column: column, value: value, previous: previous)])
    }

    /// A new record right above or below one (Craft's Insert Row Above/Below); in a view
    /// grouped by a field it takes the record's value of it, so it shows in the same group.
    /// Its title takes typing.
    @discardableResult
    func insertRecord(beside row: RowID, below: Bool, groupedBy column: ColumnID?, in block: DocBlockID) -> RowID? {
        guard let (_, database) = snapshot(block), let index = database.rows.firstIndex(where: { $0.id == row }) else { return nil }
        var cells: [ColumnID: CellValue] = [:]
        if let column, let value = database.rows[index].cells[column] { cells[column] = value }
        let new = Row(id: .generate(), cells: cells)
        records(block, [.insertRow(row: new, after: below ? row : index == 0 ? nil : database.rows[index - 1].id)])
        editingTitle = new.id
        return new.id
    }

    /// A copy of a record right after it, its page too (Craft's Duplicate Item).
    @discardableResult
    func duplicate(row: RowID, in block: DocBlockID) -> RowID? {
        duplicate(rows: [row], in: block).first
    }

    /// Copies of records, each right after its own, in one undo step.
    @discardableResult
    func duplicate(rows: Set<RowID>, in block: DocBlockID) -> [RowID] {
        guard let (_, database) = snapshot(block) else { return [] }
        let copies = database.rows.filter { rows.contains($0.id) }.map { ($0.id, Row(id: .generate(), cells: $0.cells)) }
        records(block, copies.map { .insertRow(row: $1, after: $0) })
        for (original, copy) in copies { copyPage?(original, copy.id) }
        return copies.map(\.1.id)
    }

    /// A group a kanban leaves out (Craft's Hide Group); the group panel shows it again.
    func hide(group key: String, in view: CollectionViewID, of block: DocBlockID) {
        changeView(view, in: block) { view in
            if !view.grouping.hidden.contains(key) { view.grouping.hidden.append(key) }
        }
    }

    func delete(_ row: RowID, in block: DocBlockID) { delete(rows: [row], in: block) }

    /// Records gone in one undo step (from the bottom up, so each one's place is still there).
    func delete(rows: Set<RowID>, in block: DocBlockID) {
        guard let (_, database) = snapshot(block) else { return }
        let steps: [DatabaseStep] = database.rows.indices.reversed().compactMap { index in
            guard rows.contains(database.rows[index].id) else { return nil }
            return .deleteRow(row: database.rows[index], after: index == 0 ? nil : database.rows[index - 1].id)
        }
        selectedRows[block]?.subtract(rows)
        records(block, steps)
    }

    func togglePicked(_ row: RowID, in block: DocBlockID) {
        var picked = selectedRows[block] ?? []
        if picked.remove(row) == nil { picked.insert(row) }
        selectedRows[block] = picked
    }

    /// A card dropped in a kanban's column, before `before` (or at the column's end): it
    /// takes the column's value (of a multiple select, the column's option for the one it
    /// came from; none, no options), and moves to its place among the records.
    func move(_ row: RowID, from source: CellValue?, to value: CellValue?, groupedBy column: ColumnID, before: RowID?, in block: DocBlockID) {
        guard let (_, database) = snapshot(block), let record = database.rows.first(where: { $0.id == row }), row != before else { return }
        var steps: [DatabaseStep] = []
        var new = value
        if case .multiSelect(let ids)? = record.cells[column], case .multiSelect(let to)? = value {
            let from: [OptionID] = if case .multiSelect(let options)? = source { options } else { [] }
            let kept = ids.filter { !from.contains($0) && !to.contains($0) }
            new = .multiSelect(options: kept + to)
        }
        if record.cells[column] != new {
            steps.append(.setCell(row: row, column: column, value: new, previous: record.cells[column]))
        }
        let others = database.rows.filter { $0.id != row }
        let from = database.rows.firstIndex { $0.id == row }.flatMap { $0 == 0 ? nil : database.rows[$0 - 1].id }
        let after: RowID?
        if let before, let index = others.firstIndex(where: { $0.id == before }) {
            after = index == 0 ? nil : others[index - 1].id
        } else {
            after = others.last { Self.isIn($0, column, value) }?.id ?? others.last?.id
        }
        if after != from { steps.append(.moveRow(row: row, after: after, from: from)) }
        records(block, steps)
    }

    // MARK: What a view shows

    /// The records a view shows: its filters', in its order, then those the search finds.
    func rows(_ snapshot: DocCollectionSnapshot, _ view: CollectionView) -> [Row] {
        let rows = view.records(of: snapshot.database)
        let search = (searches[snapshot.block] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard !search.isEmpty else { return rows }
        return rows.filter { row in
            snapshot.database.columns.contains { DocFieldText.text(row.cells[$0.id], in: $0).lowercased().contains(search) }
        }
    }

    /// The fields a view shows, in its order.
    static func fields(_ view: CollectionView, of database: Database) -> [Column] {
        view.ordered(database.columns).filter { !view.layout.hidden.contains($0.id) }
    }

    /// The field records are titled by: the first text one.
    static func titleColumn(of database: Database) -> Column? {
        database.columns.first { $0.type == .text }
    }

    static func selects(in database: Database) -> [Column] {
        database.columns.filter { if case .select = $0.type { true } else { false } }
    }

    /// The fields a view can group by (Craft's): all but the title, the selects first.
    static func groupable(in database: Database) -> [Column] {
        let title = titleColumn(of: database)?.id
        let fields = database.columns.filter { $0.id != title }
        return selects(in: database) + fields.filter { if case .select = $0.type { false } else { true } }
    }

    nonisolated static func option(of row: Row, in column: ColumnID) -> OptionID? {
        if case .select(let option)? = row.cells[column] { option } else { nil }
    }

    /// A kanban's columns: its groups, every option's, but those it leaves out, and none's
    /// only when there are records with none.
    nonisolated static func lanes(_ view: CollectionView, of rows: [Row], in database: Database) -> [CollectionGroup] {
        (view.groups(of: rows, in: database, everyOption: true) ?? [])
            .filter { !view.grouping.hidden.contains($0.key) && !($0.key.isEmpty && $0.rows.isEmpty) }
    }

    /// Whether a record is in the group of `value` (nil: the group of none).
    nonisolated static func isIn(_ row: Row, _ column: ColumnID, _ value: CellValue?) -> Bool {
        switch (row.cells[column], value) {
        case (.multiSelect(let ids)?, .multiSelect(let group)?): group.allSatisfy(ids.contains)
        case (.multiSelect(let ids)?, nil): ids.isEmpty
        case (.checkbox(false)?, nil): true
        case (.text("")?, nil), (.url("")?, nil), (.person("")?, nil): true
        case (let cell, let value): cell == value
        }
    }

    /// The view as CSV: its fields and the records it shows.
    func csv(_ snapshot: DocCollectionSnapshot, _ view: CollectionView) -> String {
        let fields = Self.fields(view, of: snapshot.database)
        func quoted(_ text: String) -> String {
            text.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        let lines = [fields.map { quoted($0.name) }] + rows(snapshot, view).map { row in
            fields.map { quoted(DocFieldText.text(row.cells[$0.id], in: $0)) }
        }
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - Looks

enum DocCollectionLayout {
    /// How wide a collection grows: past the page's text (720), as Craft's does.
    static let maxWidth: CGFloat = 1040
}

/// The collection's measurements (Craft's, on a Mac).
enum DocCollectionMetrics {
    static let titleSize: CGFloat = 22
    static let tabSize: CGFloat = 14
    static let tabHeight: CGFloat = 26
    static let headerGap = DocTokens.Space.sm
    static let corner = DocTokens.Radius.sm
    static let toolbarHeight: CGFloat = 28
    static let toolbarButton: CGFloat = 30
    static let searchWidth: CGFloat = 180
    // Table
    static let rowHeight: CGFloat = 36
    static let headHeight: CGFloat = 32
    static let numberWidth: CGFloat = 46
    static let fieldWidth: CGFloat = 140
    /// A table column's width as its cells read: no narrower, and no wider before they wrap.
    static let minFieldWidth: CGFloat = 72
    static let maxFieldWidth: CGFloat = 300
    /// Above and below a cell's lines, so a wrapped one keeps the row's spacing.
    static let cellLinePadding: CGFloat = 8
    static let addFieldWidth: CGFloat = 36
    static let cellInset = DocTokens.Space.sm
    static let focusWidth: CGFloat = 2
    // Kanban
    static let columnWidth: CGFloat = 268
    static let columnGap: CGFloat = 13
    static let columnInset = DocTokens.Space.sm
    static let columnHead: CGFloat = 40
    static let cardGap: CGFloat = 10
    static let cardInset = DocTokens.Space.md
    static let cardCorner: CGFloat = 8
    /// The arrow that opens a record (a card's, a title cell's).
    static let openButton: CGFloat = 24
    static let chipHeight: CGFloat = 21
    static let addHeight: CGFloat = 32
    // Panels
    static let panelWidth: CGFloat = 290
    static let wideFieldsPanel: CGFloat = 340
    static let fieldHeight: CGFloat = 30
    static let swatch: CGFloat = 26
}

private typealias Metrics = DocCollectionMetrics

/// An option's colour: its own, or one by its place among the column's options.
enum DocOptionColor {
    static let order = ["purple", "cyan", "yellow", "blue", "green", "red", "orange", "mint", "brown", "slate", "lemon", "gray"]
    /// The colours a new option is offered, Craft's row of them.
    static let offered = ["red", "orange", "yellow", "green", "cyan", "blue", "purple", "gray"]

    static func token(_ option: SelectOption, in options: [SelectOption]) -> String {
        option.color ?? order[(options.firstIndex(of: option) ?? 0) % order.count]
    }

    static func color(_ token: String) -> Color { MarkdownColorToken.text(token) ?? .secondary }

    /// A new option's colour: the first in the order the column doesn't use yet.
    static func next(after options: [SelectOption]) -> String {
        let used = Set(options.map { token($0, in: options) })
        return order.first { !used.contains($0) } ?? order[options.count % order.count]
    }
}

/// A field's value as a chip: a select's option in its colour, softened toward the text's
/// on a faint wash of it (no outline); the rest quiet.
struct DocChip: View {
    let text: String
    var color: Color?
    var systemImage: String?

    var body: some View {
        HStack(spacing: DocTokens.Space.xs) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: DocTokens.Icon.inline, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(color.map { $0.mix(with: DocTokens.ColorRole.Content.primary, by: 0.2) }
                         ?? DocTokens.ColorRole.Content.secondary)
        .padding(.horizontal, 7)
        .frame(height: Metrics.chipHeight)
        .background(color.map { $0.opacity(DocTokens.State.selectedOpacity) } ?? DocTokens.ColorRole.Surface.control,
                    in: RoundedRectangle(cornerRadius: DocTokens.Radius.xs + 1, style: .continuous))
    }

    /// An option's chip, in its colour.
    init(_ option: SelectOption, in options: [SelectOption]) {
        self.init(text: option.name, color: DocOptionColor.color(DocOptionColor.token(option, in: options)))
    }

    init(text: String, color: Color? = nil, systemImage: String? = nil) {
        self.text = text
        self.color = color
        self.systemImage = systemImage
    }
}

/// Chips laid out in lines, as many as fit on each.
/// A group's name: an option's chip, the value's words, None for records with none.
struct DocGroupLabel: View {
    let column: Column
    let group: CollectionGroup

    var body: some View {
        let options = DocFieldText.options(column)
        if let option = options.first(where: { $0.id.description == group.key }) {
            DocChip(option, in: options)
        } else {
            DocChip(text: Self.title(group.value, in: column))
        }
    }

    static func title(_ value: CellValue?, in column: Column) -> String {
        switch value {
        case nil: column.type == .checkbox ? String(localized: "Unchecked") : String(localized: "None")
        case .checkbox?: String(localized: "Checked")
        case let value?: DocFieldText.text(value, in: column)
        }
    }
}

struct DocFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: subviews.isEmpty ? 0 : y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// What a value reads as, a field type's name and symbol.
enum DocFieldText {
    static func text(_ value: CellValue?, in column: Column) -> String {
        switch value {
        case .text(let value)?, .url(let value)?, .person(let value)?: value
        case .richText(let text)?: text.string
        case .number(let value)?: value.formatted()
        case .date(let value)?: shown(value)
        case .select(let option)?: options(column).first { $0.id == option }?.name ?? ""
        case .multiSelect(let ids)?: options(column).filter { ids.contains($0.id) }.map(\.name).joined(separator: ", ")
        case .checkbox(let on)?: on ? "✓" : ""
        case nil: ""
        }
    }

    /// Typed text as the column holds it (`CellFormat`, `Column.holds`): nil when it's empty
    /// or isn't one of its values (`takes`). A select's names are its panel's to pick.
    static func value(typed text: String, in column: Column) -> CellValue? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return switch column.type {
        case .text: .text(value: text)
        case .person: .person(value: text)
        case .number: number(text).map { .number(value: $0) }
        case .url: CellFormat.link(text).map { .url(value: $0) }
        case .date: day(from: text).map { .date(value: .day($0)) }
        case .checkbox: ["✓", "true", "yes", "1", "x"].contains(text.lowercased()) ? .checkbox(value: true) : nil
        case .select, .multiSelect: nil
        }
    }

    /// Whether the column takes the typed text: nothing (no value), or one of its values.
    static func takes(_ text: String, in column: Column) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value(typed: text, in: column) != nil
    }

    /// A number as this person writes one ("1,234.5" here, "1.234,5" in Germany), as it shows.
    static func number(_ text: String) -> Double? {
        CellFormat.number(text, grouping: Locale.current.groupingSeparator ?? "", decimal: Locale.current.decimalSeparator ?? ".")
    }

    /// A day as Craft shows it ("Oct 15 2026").
    private static let day = Date.FormatStyle.dateTime.month(.abbreviated).day().year()

    /// A date cell as it shows (floo docs/time.md §8): a day as that day wherever it's read, a
    /// moment with its time by this device's clock.
    static func shown(_ value: When) -> String {
        switch value {
        case .day(let day): date(of: .day(day)).formatted(Self.day)
        case .moment(let moment): moment.at.date.formatted(Self.day.hour().minute())
        }
    }

    /// A day read from text (as shown, or yyyy-MM-dd).
    static func day(from text: String) -> Day? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let day = Day(trimmed) { return day }
        // The shown form's reading is lenient ("2026-13-40" is a day in 2208): a day counts
        // when it shows as what was typed, spaces and commas aside.
        func letters(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        guard let shown = try? Date(trimmed, strategy: day.parseStrategy), letters(shown.formatted(day)) == letters(trimmed) else { return nil }
        return day(of: shown)
    }

    /// The day a date picker picked, on this device's calendar.
    static func day(of date: Date) -> Day {
        // time: shown on this device, by its calendar
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return Day(LocalDate(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1))
    }

    /// A date cell's value to show in a date picker: a day at its start on this device's
    /// calendar, a moment as it is.
    static func date(of value: When) -> Date {
        switch value {
        case .day(let day):
            // time: shown on this device, by its calendar
            Calendar.current.date(from: DateComponents(year: day.year ?? 2000, month: day.month, day: day.day)) ?? .distantPast
        case .moment(let moment): moment.at.date
        }
    }

    static func hasOptions(_ column: Column) -> Bool {
        switch column.type {
        case .select, .multiSelect: true
        default: false
        }
    }

    static func options(_ column: Column) -> [SelectOption] {
        switch column.type {
        case .select(let options), .multiSelect(let options): options
        default: []
        }
    }

    /// The column's type as Craft shows it in the header.
    static func symbol(_ type: ColumnType) -> String {
        switch type {
        case .text: "textformat"
        case .number: "number"
        case .select: "list.bullet.indent"
        case .multiSelect: "checklist"
        case .date: "calendar"
        case .checkbox: "checkmark.square"
        case .url: "link"
        case .person: "person"
        }
    }

    static func symbol(_ column: Column) -> String { symbol(column.type) }

    /// The types a field can be, in Craft's order.
    static let types: [ColumnType] = [.text, .number, .checkbox, .date, .url, .person, .select(options: []), .multiSelect(options: [])]

    static func name(_ type: ColumnType) -> String {
        switch type {
        case .text: String(localized: "Text")
        case .number: String(localized: "Number")
        case .checkbox: String(localized: "Checkbox")
        case .date: String(localized: "Date")
        case .url: String(localized: "URL")
        case .person: String(localized: "Person")
        case .select: String(localized: "Single Select")
        case .multiSelect: String(localized: "Multiple Select")
        }
    }
}

// MARK: - The block

struct DocCollectionView: View {
    let snapshot: DocCollectionSnapshot
    let controller: DocCollectionController
    @State private var hovering = false

    private var collection: DocCollection { snapshot.collection }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.headerGap) {
            DocCollectionHeader(snapshot: snapshot, controller: controller, hovering: hovering)
            if let view = collection.currentView {
                switch view.layout {
                case .table:
                    DocCollectionTable(snapshot: snapshot, view: view, controller: controller)
                case .kanban(let group, _, _):
                    DocCollectionKanban(snapshot: snapshot, view: view, group: group, controller: controller)
                case .chart(let chart):
                    DocCollectionChart(snapshot: snapshot, view: view, chart: chart, controller: controller)
                }
            }
        }
        .padding(.vertical, DocTokens.Space.sm)
        .onHover { hovering = $0 }
    }
}

/// The name, the toolbar, and a tab for each view.
private struct DocCollectionHeader: View {
    let snapshot: DocCollectionSnapshot
    let controller: DocCollectionController
    let hovering: Bool
    @State private var name = ""
    @State private var renaming: CollectionViewID?
    @State private var viewName = ""
    @State private var searching = false
    @State private var showsViewMenu = false
    @FocusState private var searchFocused: Bool
    @FocusState private var nameFocused: Bool
    @FocusState private var viewNameFocused: Bool

    private var block: DocBlockID { snapshot.block }
    private var collection: DocCollection { snapshot.collection }
    private var current: CollectionView? { collection.currentView }

    var body: some View {
        VStack(alignment: .leading, spacing: DocTokens.Space.sm) {
            HStack(alignment: .center) {
                TextField(String(localized: "Untitled Collection"), text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: Metrics.titleSize, weight: .bold))
                    .disabled(!controller.isEditable)
                    .focused($nameFocused)
                    .onChange(of: name) { _, name in if name != collection.name { controller.rename(block, to: name) } }
                    .docEditingPlace(DocFieldPlace(field: [block, "name"] as [AnyHashable], block: block), isFocused: nameFocused,
                                     editor: controller.editor)
                Spacer(minLength: DocTokens.Space.md)
                toolbar
            }
            tabs
        }
        .onAppear { name = collection.name }
        .onChange(of: collection.name) { _, new in if new != name { name = new } }
    }

    // MARK: Toolbar

    /// Over the block (or with a panel or a search open) on a Mac; always on a phone.
    private var showsToolbar: Bool {
        !DocTokens.Platform.isPointer || hovering || searching || controller.panel?.block == block
    }

    private var toolbar: some View {
        HStack(spacing: DocTokens.Space.sm) {
            search
            HStack(spacing: 0) {
                if controller.isEditable {
                    toolbarButton("plus.circle.fill", String(localized: "New Item")) {
                        let row = controller.addRecord(to: block, in: kanbanGroup)
                        // A chart doesn't show a record with nothing in it: it opens to be filled in.
                        if current?.layout.chart != nil, let row { controller.openRecord?(row, block) }
                    }
                }
                viewMenu
            }
            .padding(.horizontal, DocTokens.Space.xxs)
            .background(toolbarBox)
        }
        .opacity(showsToolbar ? 1 : 0)
        .allowsHitTesting(showsToolbar)
        // The view's panels open under the toolbar, at its right.
        .docPanel(isPresented: toolbarPanel != nil, alignment: .trailing,
                                 onDismiss: { if let toolbarPanel { controller.close(toolbarPanel, in: block) } }) {
            if let current {
                switch toolbarPanel {
                case .layout?: DocLayoutPanel(snapshot: snapshot, view: current, controller: controller)
                case .sort?: DocSortPanel(snapshot: snapshot, view: current, controller: controller)
                case .filter?: DocFilterPanel(snapshot: snapshot, view: current, controller: controller)
                case .group?: DocGroupPanel(snapshot: snapshot, view: current, controller: controller)
                case .chart?: DocChartPanel(snapshot: snapshot, view: current, controller: controller)
                default: EmptyView()
                }
            }
        }
    }

    private var toolbarPanel: DocCollectionPanel.Kind? {
        guard let panel = controller.panel, panel.block == block else { return nil }
        switch panel.kind {
        case .layout, .sort, .filter, .group, .chart: return panel.kind
        default: return nil
        }
    }

    private var toolbarBox: some View {
        RoundedRectangle(cornerRadius: DocTokens.Radius.md, style: .continuous)
            .strokeBorder(DocTokens.Border.subtle, lineWidth: DocTokens.Border.standard)
    }

    private func toolbarButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: DocTokens.Icon.standard))
                .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                .frame(width: Metrics.toolbarButton, height: Metrics.toolbarHeight)
        }
        .buttonStyle(.flooContent(in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)))
        .help(title)
        .accessibilityLabel(title)
    }

    /// The magnifier, or the search field it opens (Escape or ✕ closes it and shows all again).
    @ViewBuilder
    private var search: some View {
        if searching {
            HStack(spacing: DocTokens.Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DocTokens.Icon.compact))
                    .foregroundStyle(DocTokens.ColorRole.Content.tertiary)
                TextField(String(localized: "Search"), text: Binding {
                    controller.searches[block] ?? ""
                } set: {
                    controller.searches[block] = $0
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .docEditingPlace(DocFieldPlace(field: [block, "search"] as [AnyHashable], block: block), isFocused: searchFocused,
                                 editor: controller.editor)
                .onKeyPress(.escape) {
                    endSearch()
                    return .handled
                }
                Button(action: endSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DocTokens.Icon.compact))
                        .foregroundStyle(DocTokens.ColorRole.Content.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Close Search"))
            }
            .padding(.horizontal, DocTokens.Space.sm)
            .frame(width: Metrics.searchWidth, height: Metrics.toolbarHeight)
            .background(toolbarBox)
        } else {
            toolbarButton("magnifyingglass", String(localized: "Search")) {
                searching = true
                Task { @MainActor in searchFocused = true }
            }
            .padding(.horizontal, DocTokens.Space.xxs)
            .background(toolbarBox)
        }
    }

    private func endSearch() {
        controller.searches[block] = nil
        searching = false
    }

    private var viewMenu: some View {
        Button {
            showsViewMenu.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: DocTokens.Icon.standard))
                .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                .frame(width: Metrics.toolbarButton, height: Metrics.toolbarHeight)
        }
        .buttonStyle(.flooContent(in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)))
        .help(String(localized: "View Options"))
        .accessibilityLabel(String(localized: "View Options"))
        .flooDesignActionMenu(isPresented: showsViewMenu, configuration: .init(horizontalAlignment: .trailing),
                              onDismiss: { showsViewMenu = false }) { _ in
            current.map { viewSections($0, full: true) } ?? []
        }
    }

    /// A view's menu: its panels, then renaming, copying and deleting it; the toolbar's
    /// also downloads it.
    private func viewSections(_ view: CollectionView, full: Bool) -> [FlooDesignActionMenuSection] {
        // Ticked when the view groups (Craft's).
        // A chart's groups are its axis; its order is theirs, so it has no sorting.
        let isChart = view.layout.chart != nil
        let panels: [FlooDesignActionMenuItem] = [
            .action(String(localized: "Filter"), symbol: "line.3.horizontal.decrease") { open(.filter, for: view) },
        ] + (isChart ? [] : [
            .action(String(localized: "Sort"), symbol: "arrow.up.arrow.down") { open(.sort, for: view) },
        ]) + [
            isChart
                ? .action(String(localized: "X Axis"), symbol: "chart.bar.xaxis") { open(.group, for: view) }
                : .action(String(localized: "Group"), symbol: "rectangle.3.group", isOn: view.layout.groupBy != nil) { open(.group, for: view) },
        ]
        var sections: [FlooDesignActionMenuSection] = [
            .init(.rows, [.action(String(localized: "Layout & Visibility"), symbol: "tablecells") { open(.layout, for: view) }]
                  + (isChart ? [.action(String(localized: "Chart"), symbol: "slider.horizontal.3") { open(.chart, for: view) }] : [])),
            .init(.rows, panels),
        ]
        if controller.isEditable {
            sections.append(.init(.rows, [
                .action(String(localized: "Rename View"), symbol: "character.cursor.ibeam") {
                    viewName = view.name
                    renaming = view.id
                },
                .action(String(localized: "Duplicate View"), symbol: "plus.square.on.square") { controller.duplicate(view.id, in: block) },
                .action(String(localized: "Delete View"), symbol: "trash", role: .destructive, isEnabled: collection.views.count > 1) {
                    controller.delete(view.id, in: block)
                },
            ]))
        }
        if full {
            sections.append(.init(.rows, [
                .action(String(localized: "Download as CSV"), symbol: "arrow.down.circle") {
                    DocCSVExport.save(controller.csv(snapshot, view), named: collection.name.isEmpty ? String(localized: "Collection") : collection.name)
                },
            ]))
        }
        return sections
    }

    /// A view's panel, the view showing first.
    private func open(_ kind: DocCollectionPanel.Kind, for view: CollectionView) {
        if view.id != current?.id { controller.show(view.id, in: block) }
        controller.show(kind, in: block)
    }

    /// A new card from the toolbar goes to the first column of a kanban.
    private var kanbanGroup: (column: ColumnID, value: CellValue?)? {
        guard let current, current.layout.isKanban, let group = current.layout.groupBy else { return nil }
        let first = DocCollectionController.lanes(current, of: controller.rows(snapshot, current), in: snapshot.database).first
        return (group, first?.value)
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: DocTokens.Space.xxs) {
            ForEach(collection.views) { view in
                tab(view)
            }
            if controller.isEditable {
                addView
            }
        }
        // A tab's words line up with the name; its fill reaches out past them (Craft's).
        .padding(.leading, -DocTokens.Space.sm)
    }

    private var addView: some View {
        Menu {
            Button(String(localized: "Add Table View"), systemImage: "tablecells") {
                let view = controller.addView(to: block, name: String(localized: "New Table"), layout: .table(hidden: [], sort: []))
                controller.show(.nameView(view), in: block)
            }
            Button(String(localized: "Add Kanban View"), systemImage: "rectangle.split.3x1") {
                controller.show(.createKanban, in: block)
            }
            .disabled(DocCollectionController.groupable(in: snapshot.database).isEmpty)
            Button(String(localized: "Add Chart View"), systemImage: "chart.bar.xaxis") {
                controller.show(.createChart, in: block)
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: DocTokens.Icon.compact, weight: .semibold))
                .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                .frame(width: Metrics.tabHeight, height: Metrics.tabHeight)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.flooContent(in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)))
        .accessibilityLabel(String(localized: "Add View"))
        .docPanel(isPresented: controller.isShowing(.createKanban, in: block) || controller.isShowing(.createChart, in: block),
                                 onDismiss: {
                                     controller.close(.createKanban, in: block)
                                     controller.close(.createChart, in: block)
                                 }) {
            if controller.isShowing(.createChart, in: block) {
                DocCreateChartPanel(snapshot: snapshot, controller: controller)
            } else {
                DocCreateKanbanPanel(snapshot: snapshot, controller: controller)
            }
        }
    }

    @ViewBuilder
    private func tab(_ view: CollectionView) -> some View {
        let isCurrent = view.id == current?.id
        if renaming == view.id {
            TextField("", text: $viewName)
                .textFieldStyle(.plain)
                .font(.system(size: Metrics.tabSize, weight: .medium))
                .fixedSize()
                .padding(.horizontal, DocTokens.Space.sm)
                .frame(height: Metrics.tabHeight)
                .background(DocTokens.ColorRole.Surface.selected, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
                .focused($viewNameFocused)
                // The view's name: its menu is its tab's right-click rows.
                .docEditingPlace(DocFieldPlace(field: [block, view.id] as [AnyHashable], block: block,
                                               menu: DocPlaceMenu(title: String(localized: "View Actions"), symbol: "ellipsis.circle",
                                                                  opens: .rows { viewSections(view, full: false) })),
                                 isFocused: viewNameFocused, editor: controller.editor)
                .onSubmit {
                    controller.rename(view.id, in: block, to: viewName)
                    renaming = nil
                }
                .onKeyPress(.escape) {
                    renaming = nil
                    return .handled
                }
        } else {
            Button {
                controller.show(view.id, in: block)
            } label: {
                Text(view.name)
                    .font(.system(size: Metrics.tabSize, weight: .medium))
                    .foregroundStyle(isCurrent ? DocTokens.ColorRole.Content.primary : DocTokens.ColorRole.Content.secondary)
                    .padding(.horizontal, DocTokens.Space.sm)
                    .frame(height: Metrics.tabHeight)
                    .background(isCurrent ? DocTokens.ColorRole.Surface.selected : .clear,
                                in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            }
            .buttonStyle(.flooContent(in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)))
            .flooDesignContextMenu { _ in viewSections(view, full: false) }
            .docPanel(isPresented: controller.isShowing(.nameView(view.id), in: block),
                                     onDismiss: { controller.close(.nameView(view.id), in: block) }) {
                DocNameViewPanel(block: block, view: view, controller: controller)
            }
        }
    }
}

/// A view's records saved as a CSV file: the system's export (a save panel on a Mac, the
/// files picker on a phone), presented by the window's topmost controller. A file exporter
/// on the block's view has none: the block is in a cell of the page's list.
enum DocCSVExport {
    static func save(_ text: String, named name: String) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
            .appendingPathExtension("csv")
        guard (try? Data(text.utf8).write(to: file, options: .atomic)) != nil,
              let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(UIDocumentPickerViewController(forExporting: [file], asCopy: true), animated: true)
    }
}
