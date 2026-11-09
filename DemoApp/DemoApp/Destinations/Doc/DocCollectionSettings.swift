//
//  DocCollectionSettings.swift
//  DemoApp
//
//  A collection's view as something settings change (DocFormatTarget), for a phone's panel:
//  how it's laid out, then what it groups, sorts and filters by and which fields it shows,
//  each right there to read and change. Only what's more than a line is a level in: the order
//  of the fields, which groups show, a chart's settings, renaming and deleting the view.
//

import DocKit
import FlooUIKit
import UIKit

@MainActor
struct DocSelectedView: DocFormatTarget {
    let controller: DocCollectionController
    let block: DocBlockID
    let more: @MainActor () -> [FlooMenuSection]

    /// A colour of the document's, for what's on.
    static func tint(_ token: String) -> UIColor { UIColor(DocOptionColor.color(token)) }

    var pages: [DocPanelPage] {
        guard let (collection, database) = controller.snapshot(block), let view = collection.currentView else { return [] }
        let controller = controller
        let block = block
        let isChart = view.layout.chart != nil
        let layout = DocPanelRow.keys([
            DocKeyGroup(keys: [
                DocKey(id: "view-table", title: String(localized: "Table"), look: .symbol("tablecells"), isOn: !view.layout.isKanban && !isChart, tint: Self.tint("blue"),
                       action: .perform { controller.setLayout(kanban: false, in: view.id, of: block) }),
                DocKey(id: "view-kanban", title: String(localized: "Kanban"), look: .symbol("rectangle.split.3x1"), isOn: view.layout.isKanban,
                       isEnabled: !DocCollectionController.groupable(in: database).isEmpty, tint: Self.tint("orange"),
                       action: .perform { controller.setLayout(kanban: true, in: view.id, of: block) }),
                DocKey(id: "view-chart", title: String(localized: "Chart"), look: .symbol("chart.bar.xaxis"), isOn: isChart, tint: Self.tint("purple"),
                       action: .perform { if !isChart { controller.setChart(in: view.id, of: block) } }),
            ], isJoined: true),
            DocKeyGroup(keys: [
                DocKey(id: "view-more", title: String(localized: "More"), look: .symbol("ellipsis"), isMomentary: true, showsTitle: false, action: .open(.viewMore)),
            ], width: .fixed(DocPanelRhythm.iconKey)),
        ])
        var pages = [DocPanelPage(.viewMore, menu: more())]
        if let chart = view.layout.chart {
            let settings = DocChartSettings(controller: controller, block: block, view: view, chart: chart, database: database)
            pages.append(DocPanelPage(.view, closesOutside: true, [
                DocPageSection([layout, settings.kinds]),
                DocPageSection(lines: groupLines(view, database) + [settings.firstValue] + filterLines(view, database)),
                DocPageSection([settings.opensPages]),
            ]))
            pages += settings.pages
        } else {
            pages.append(DocPanelPage(.view, closesOutside: true, [
                DocPageSection([layout]),
                DocPageSection(lines: groupLines(view, database) + sortLines(view, database) + filterLines(view, database) + [fieldsLine(view, database)]),
            ]))
            pages.append(fields(view, database))
        }
        if let groups = groups(view, database) { pages.append(groups) }
        return pages
    }

    private func fieldMenu(_ columns: [Column], pick: @escaping @MainActor (Column) -> Void) -> [FlooMenuSection] {
        [.init(columns.map { column in .action(column.name, symbol: DocFieldText.symbol(column)) { pick(column) } })]
    }

    // MARK: Group

    private func groupLines(_ view: CollectionView, _ database: Database) -> [DocLine] {
        let controller = controller
        let block = block
        let isChart = view.layout.chart != nil
        let groupable = isChart ? database.columns : DocCollectionController.groupable(in: database)
        let name = isChart ? String(localized: "X Axis") : String(localized: "Group")
        let pick = fieldMenu(groupable) { controller.setGroup($0.id, in: view.id, of: block) }
        guard let column = database.columns.first(where: { $0.id == view.layout.groupBy }) else {
            return [DocLine(id: "group", parts: [
                .label(id: "group-label", title: name),
                .menu(id: "group-field", title: String(localized: "Add"), name: isChart ? String(localized: "Add X Axis") : String(localized: "Add Group"), sections: pick),
            ])]
        }
        // A chart's order and groups are its Data page's.
        if isChart {
            return [DocLine(id: "group", parts: [.label(id: "group-label", title: name), .menu(id: "group-field", title: column.name, name: "\(name) \(column.name)", sections: pick)])]
        }
        let orders: [FlooMenuItem] = DocCollectionNames.orders(manual: view.layout.isKanban).map { order in
            .action(DocCollectionNames.name(order, of: column), isOn: order == view.grouping.order) {
                controller.setGrouping(CollectionGrouping(order: order, hidden: view.grouping.hidden, manual: view.grouping.manual), in: view.id, of: block)
            }
        }
        return [DocLine(id: "group", parts: [
            .label(id: "group-label", title: name),
            .menu(id: "group-field", title: column.name, name: "\(name) \(column.name)", sections: pick),
            .menu(id: "group-order", title: DocCollectionNames.name(view.grouping.order, of: column), sections: [.init(orders)]),
            view.layout.isKanban
                ? .opens(id: "group-open", title: String(localized: "Show/Hide groups")) { controller.viewPanel?.openInner(.groups) }
                : .remove(id: "group-remove") { controller.setGroup(nil, in: view.id, of: block) },
        ])]
    }

    /// A kanban's and a chart's groups, each shown or not, in an order dragged by hand.
    private func groups(_ view: CollectionView, _ database: Database) -> DocPanelPage? {
        guard view.layout.isKanban || view.layout.chart != nil, let snapshot = controller.collectionSnapshot(block),
              let column = database.columns.first(where: { $0.id == view.layout.groupBy }) else { return nil }
        let controller = controller
        let block = block
        let groups = view.groups(of: controller.rows(snapshot, view), in: database, everyOption: true) ?? []
        let keys = groups.map(\.key)
        let rows = groups.map { group in
            DocSettingRow(id: "group:\(group.key)", title: DocGroupLabel.title(group.value, in: column), canMove: true, isOn: !view.grouping.hidden.contains(group.key)) { shows in
                var grouping = view.grouping
                grouping.hidden.removeAll { $0 == group.key }
                if !shows { grouping.hidden.append(group.key) }
                controller.setGrouping(grouping, in: view.id, of: block)
            }
        }
        let list = DocSettingList(rows: rows) { moved, before in
            controller.moveGroup(String(moved.dropFirst(6)), before: before.map { String($0.dropFirst(6)) }, among: keys, in: view.id, of: block)
        }
        return DocPanelPage(.groups, [DocPageSection([.list(list)])])
    }

    // MARK: Sort

    private func sortLines(_ view: CollectionView, _ database: Database) -> [DocLine] {
        let controller = controller
        let block = block
        let columns = database.columns
        let sort = view.layout.sort
        let unused = columns.filter { column in !sort.contains { $0.column == column.id } }
        let set = { (sort: [DatabaseSort]) in controller.setSort(sort, in: view.id, of: block) }
        guard !sort.isEmpty else {
            return [DocLine(id: "sort-add", parts: [
                .label(id: "sort-add-label", title: String(localized: "Sort")),
                .menu(id: "sort-add-field", title: String(localized: "Add"), name: String(localized: "Add Sort"), sections: fieldMenu(columns) { set([DatabaseSort(column: $0.id)]) }),
            ])]
        }
        var lines = sort.enumerated().map { index, entry in
            let column = columns.first { $0.id == entry.column }
            let direction = { (ascending: Bool) in
                var sort = sort
                sort[index].ascending = ascending
                set(sort)
            }
            return DocLine(id: "sort-\(index)", parts: [
                .label(id: "sort-\(index)-label", title: index == 0 ? String(localized: "Sort") : String(localized: "Then")),
                .menu(id: "sort-\(index)-field", title: column?.name ?? "", sections: fieldMenu(unused + columns.filter { $0.id == entry.column }) { picked in
                    var sort = sort
                    sort[index].column = picked.id
                    set(sort)
                }),
                .menu(id: "sort-\(index)-direction", title: entry.ascending ? String(localized: "Ascending") : String(localized: "Descending"), sections: [.init([
                    .action(String(localized: "Ascending"), isOn: entry.ascending) { direction(true) },
                    .action(String(localized: "Descending"), isOn: !entry.ascending) { direction(false) },
                ])]),
                .remove(id: "sort-\(index)-remove") {
                    var sort = sort
                    sort.remove(at: index)
                    set(sort)
                },
            ])
        }
        if !unused.isEmpty {
            lines.append(DocLine(id: "sort-add", parts: [
                .label(id: "sort-add-label", title: String(localized: "Then")),
                .menu(id: "sort-add-field", title: String(localized: "Add"), name: String(localized: "Add Another Sort"), sections: fieldMenu(unused) { set(sort + [DatabaseSort(column: $0.id)]) }),
            ]))
        }
        return lines
    }

    // MARK: Filter

    private func filterLines(_ view: CollectionView, _ database: Database) -> [DocLine] {
        let controller = controller
        let block = block
        let columns = database.columns
        let filters = view.filters
        let set = { (filters: [CollectionFilter], typing: AnyHashable?) in controller.setFilters(filters, typing: typing, in: view.id, of: block) }
        let added = { (column: Column) in
            CollectionFilter(column: column.id, condition: CollectionFilter.conditions(for: column.type)[0], value: column.type == .checkbox ? .checkbox(value: true) : nil)
        }
        guard !filters.isEmpty else {
            return [DocLine(id: "filter-add", parts: [
                .label(id: "filter-add-label", title: String(localized: "Filter")),
                .menu(id: "filter-add-field", title: String(localized: "Add"), name: String(localized: "Add Filter"), sections: fieldMenu(columns) { set([added($0)], nil) }),
            ])]
        }
        var lines: [DocLine] = []
        for (index, filter) in filters.enumerated() {
            guard let column = columns.first(where: { $0.id == filter.column }) else { continue }
            let change: @MainActor (CollectionFilter?, AnyHashable?) -> Void = { changed, typing in
                var filters = filters
                if let changed { filters[index] = changed } else { filters.remove(at: index) }
                set(filters, typing)
            }
            lines.append(DocLine(id: "filter-\(index)", parts: [
                .label(id: "filter-\(index)-label", title: index == 0 ? String(localized: "Filter") : String(localized: "And")),
                .menu(id: "filter-\(index)-field", title: column.name, sections: fieldMenu(columns) { picked in
                    if picked.id != column.id { change(added(picked), nil) }
                }),
                .menu(id: "filter-\(index)-condition", title: DocCollectionNames.name(filter.condition, for: column.type), sections: [
                    .init(CollectionFilter.conditions(for: column.type).map { condition in
                        .action(DocCollectionNames.name(condition, for: column.type), isOn: condition == filter.condition) {
                            var changed = filter
                            changed.condition = condition
                            change(changed, nil)
                        }
                    }),
                ]),
                .remove(id: "filter-\(index)-remove") { change(nil, nil) },
            ]))
            if filter.condition != .isEmpty, filter.condition != .isNotEmpty {
                lines.append(DocLine(id: "filter-\(index)-value", parts: [
                    .label(id: "filter-\(index)-value-label", title: String(localized: "Value")),
                    value(of: filter, column, id: "filter-\(index)-value-part", typing: [AnyHashable(view.id), AnyHashable(index)], change: change),
                ]))
            }
        }
        lines.append(DocLine(id: "filter-add", parts: [
            .label(id: "filter-add-label", title: String(localized: "And")),
            .menu(id: "filter-add-field", title: String(localized: "Add"), name: String(localized: "Add Filter"), sections: fieldMenu(columns) { set(filters + [added($0)], nil) }),
        ]))
        return lines
    }

    /// What a filter's compared with: as the field is.
    private func value(of filter: CollectionFilter, _ column: Column, id: String, typing: AnyHashable, change: @escaping @MainActor (CollectionFilter?, AnyHashable?) -> Void) -> DocLine.Part {
        let set = { (value: CellValue) in
            var changed = filter
            changed.value = value
            change(changed, nil)
        }
        switch column.type {
        case .select(let options), .multiSelect(let options):
            var chosen: SelectOption?
            if case .select(let selected)? = filter.value { chosen = options.first { $0.id == selected } }
            return .menu(id: id, title: chosen?.name ?? String(localized: "Select Option"), sections: [
                .init(options.map { option in .action(option.name, isOn: option.id == chosen?.id) { set(.select(option: option.id)) } }),
            ])
        case .checkbox:
            let on = filter.value != .checkbox(value: false)
            return .menu(id: id, title: on ? String(localized: "Checked") : String(localized: "Unchecked"), sections: [.init([
                .action(String(localized: "Checked"), isOn: on) { set(.checkbox(value: true)) },
                .action(String(localized: "Unchecked"), isOn: !on) { set(.checkbox(value: false)) },
            ])])
        case .date:
            var day: Date?
            if case .date(let value)? = filter.value { day = DocFieldText.date(of: value) }
            return .date(id: id, value: day) { set(.date(value: .day(DocFieldText.day(of: $0)))) }
        default:
            let shown: String = switch filter.value {
            case .text(let text)?, .url(let text)?, .person(let text)?: text
            case .number(let number)?: number.formatted()
            default: ""
            }
            return .text(id: id, placeholder: String(localized: "Value"), value: shown) { text in
                let value: CellValue? = switch column.type {
                case .number: DocFieldText.number(text).map { .number(value: $0) }
                case .url: .url(value: text)
                case .person: .person(value: text)
                default: .text(value: text)
                }
                var changed = filter
                changed.value = text.isEmpty ? nil : value
                change(changed, typing)
            }
        }
    }

    // MARK: Fields

    /// Each field to show or not, right there; their order a level in.
    private func fieldsLine(_ view: CollectionView, _ database: Database) -> DocLine {
        let controller = controller
        let block = block
        let title = DocCollectionController.titleColumn(of: database)?.id
        return DocLine(id: "fields", parts: [
            .label(id: "fields-label", title: String(localized: "Fields")),
            .chips(id: "fields-chips", keys: view.ordered(database.columns).map { column in
                let shows = !view.layout.hidden.contains(column.id)
                return DocKey(id: "field-\(column.id.description)", title: column.name, look: .value, isOn: shows,
                              isEnabled: column.id != title && !(view.layout.isKanban && column.id == view.layout.groupBy),
                              action: .perform { controller.setHidden(column.id, shows, in: view.id, of: block) })
            }),
            .opens(id: "fields-open", title: String(localized: "Fields")) { controller.viewPanel?.openInner(.fields) },
        ])
    }

    /// The calculation row (a table's), then every field, its handle and whether it shows.
    private func fields(_ view: CollectionView, _ database: Database) -> DocPanelPage {
        let controller = controller
        let block = block
        let title = DocCollectionController.titleColumn(of: database)?.id
        var rows: [DocSettingRow] = []
        if !view.layout.isKanban {
            rows.append(DocSettingRow(id: "calculations", title: String(localized: "Show Calculation Row"), isOn: view.showsCalculations) {
                controller.setShowsCalculations($0, in: view.id, of: block)
            })
        }
        let columns = view.ordered(database.columns)
        rows += columns.map { column in
            DocSettingRow(id: column.id.description, title: column.name, canMove: true, isOn: !view.layout.hidden.contains(column.id),
                          // The title always shows, as a record's name.
                          isEnabled: column.id != title && !(view.layout.isKanban && column.id == view.layout.groupBy)) { shows in
                controller.setHidden(column.id, !shows, in: view.id, of: block)
            }
        }
        let list = DocSettingList(rows: rows) { moved, before in
            guard let moved = columns.first(where: { $0.id.description == moved }) else { return }
            controller.moveField(moved.id, before: before.flatMap { id in columns.first { $0.id.description == id }?.id }, in: view.id, of: block)
        }
        return DocPanelPage(.fields, [DocPageSection([.list(list)])])
    }
}

/// What a collection's settings call things.
enum DocCollectionNames {
    /// The orders a field's groups can take: by its options or values either way, a
    /// kanban's also as they're put.
    static func orders(manual: Bool) -> [CollectionGrouping.Order] {
        manual ? [.ascending, .descending, .manual] : [.ascending, .descending]
    }

    static func name(_ order: CollectionChart.Order) -> String {
        order == .valueAscending ? String(localized: "Value: Low → High") : String(localized: "Value: High → Low")
    }

    static func name(_ order: CollectionGrouping.Order, of column: Column) -> String {
        let up = order == .ascending
        switch (order, column.type) {
        case (.manual, _): return String(localized: "Manual")
        case (_, .date): return up ? String(localized: "Earliest → Latest") : String(localized: "Latest → Earliest")
        case (_, .number): return up ? String(localized: "Lowest → Highest") : String(localized: "Highest → Lowest")
        case (_, .text), (_, .url), (_, .person): return up ? String(localized: "A → Z") : String(localized: "Z → A")
        default: return up ? String(localized: "First → Last") : String(localized: "Last → First")
        }
    }

    static func name(_ condition: CollectionFilter.Condition, for type: ColumnType) -> String {
        let dated = type == .date
        return switch condition {
        case .contains: String(localized: "Contains")
        case .doesNotContain: String(localized: "Does Not Contain")
        case .is: String(localized: "Is")
        case .isNot: String(localized: "Is Not")
        case .greaterThan: dated ? String(localized: "Is After") : String(localized: "Greater Than")
        case .lessThan: dated ? String(localized: "Is Before") : String(localized: "Less Than")
        case .isEmpty: String(localized: "Is Empty")
        case .isNotEmpty: String(localized: "Is Not Empty")
        }
    }

    static func name(_ kind: CollectionChart.Kind) -> String {
        switch kind {
        case .bar: String(localized: "Bars")
        case .column: String(localized: "Columns")
        case .line: String(localized: "Line")
        case .donut: String(localized: "Donut")
        }
    }

    static func symbol(_ kind: CollectionChart.Kind) -> String {
        switch kind {
        case .bar: "chart.bar.doc.horizontal"
        case .column: "chart.bar.xaxis"
        case .line: "chart.xyaxis.line"
        case .donut: "chart.pie"
        }
    }
}
