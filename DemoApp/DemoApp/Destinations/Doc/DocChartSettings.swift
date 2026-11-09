//
//  DocChartSettings.swift
//  DemoApp
//
//  A chart's settings, in its view's panel on every screen, each what it is on the left and its
//  control on the right: its kind and axes on the view's page, the rest in two pages a level in,
//  Data and Style. Each change one step, typing in a field one for the field.
//

import DocKit
import FlooUIKit
import UIKit

@MainActor
struct DocChartSettings {
    /// A reference line's first value: halfway across what the chart draws.
    static func middle(of snapshot: DocCollectionSnapshot, view: CollectionView) -> Double? {
        guard let data = view.chartData(of: view.records(of: snapshot.database), in: snapshot.database) else { return nil }
        let totals = data.groups.map(\.total)
        guard let low = totals.min(), let high = totals.max() else { return nil }
        return ((low + high) / 2).rounded()
    }

    static let formats: [(CollectionChartStyle.NumberFormat?, String)] = [
        (nil, String(localized: "As the Field")), (.compact, String(localized: "Compact (12.6K)")),
        (.cell(.number), String(localized: "Number")), (.cell(.percent), String(localized: "Percent")),
        (.cell(.currency(code: "USD")), "USD"), (.cell(.currency(code: "EUR")), "EUR"),
        (.cell(.currency(code: "CNY")), "CNY"), (.cell(.currency(code: "JPY")), "JPY"),
    ]

    let controller: DocCollectionController
    let block: DocBlockID
    let view: CollectionView
    let chart: CollectionChart
    let database: Database

    private var sizes: [(CollectionChartStyle.Height, String)] {
        [(.small, String(localized: "Small")), (.medium, String(localized: "Medium")), (.large, String(localized: "Large"))]
    }

    private var numbers: [Column] { database.columns.filter { $0.type == .number } }
    private var selects: [Column] { database.columns.filter(DocFieldText.hasOptions) }

    private func change(typing key: String? = nil, _ update: @escaping (inout CollectionChart) -> Void) {
        controller.changeChart(view.id, in: block, typing: key.map { [AnyHashable(view.id), "chart", $0] as [AnyHashable] }, update)
    }

    private func style(typing key: String? = nil, _ update: @escaping (inout CollectionChartStyle) -> Void) {
        change(typing: key) { update(&$0.style) }
    }

    /// Its kind on the view's page.
    var kinds: DocPanelRow {
        .tiles(CollectionChart.Kind.allCases.map { kind in
            DocKey(id: "chart-kind-\(kind)", title: DocCollectionNames.name(kind), look: .symbol(DocCollectionNames.symbol(kind)), isOn: chart.kind == kind,
                   action: .perform { [self] in change { $0.kind = kind } })
        }, isJoined: true)
    }

    /// The way to the rest, on the view's page.
    var opensPages: DocPanelRow {
        .tiles([
            DocKey(id: "chart-data", title: String(localized: "Data"), look: .symbol("number"), isMomentary: true, action: .open(.chartData)),
            DocKey(id: "chart-style", title: String(localized: "Style"), look: .symbol("paintbrush"), isMomentary: true, action: .open(.chartStyle)),
        ])
    }

    var pages: [DocPanelPage] {
        [DocPanelPage(.chartData, dataSections), DocPanelPage(.chartStyle, styleSections)]
    }

    private func toggle(_ title: String, isOn: Bool, set: @escaping @MainActor (Bool) -> Void) -> DocLine {
        DocLine(id: "toggle-\(title)", parts: [.label(id: "toggle-\(title)-label", title: title), .toggle(id: "toggle-\(title)-switch", title: title, isOn: isOn, set: set)])
    }

    private func choice<Value: Hashable>(_ title: String, _ choices: [(Value, String)], chosen: Value, pick: @escaping @MainActor (Value) -> Void) -> DocLine {
        DocLine(id: "choice-\(title)", parts: [
            .label(id: "choice-\(title)-label", title: title),
            .menu(id: "choice-\(title)-menu", title: choices.first { $0.0 == chosen }?.1 ?? "", name: title, sections: [
                .init(choices.map { value, name in .action(name, isOn: value == chosen) { pick(value) } }),
            ]),
        ])
    }

    // MARK: What it measures

    /// The value at `index` becomes `column`; none counts the records instead.
    private func set(_ index: Int, to column: ColumnID?) {
        change { chart in
            guard let column else {
                chart.values = []
                chart.calculation = .count
                return
            }
            if index < chart.values.count { chart.values[index] = column } else { chart.values.append(column) }
            if !CollectionChart.measures(chart.calculation) { chart.calculation = .sum }
        }
    }

    private func valueMenu(_ index: Int, chosen: ColumnID?, id: String) -> DocLine.Part {
        let offered = numbers.filter { $0.id == chosen || !chart.values.contains($0.id) }
        return .menu(id: id, title: database.columns.first { $0.id == chosen }?.name ?? String(localized: "Count"), sections: [
            .init([.action(String(localized: "Count"), isOn: chosen == nil) { [self] in set(index, to: nil) }] + offered.map { column in
                .action(column.name, symbol: DocFieldText.symbol(column), isOn: column.id == chosen) { [self] in set(index, to: column.id) }
            }),
        ])
    }

    private var calculation: DocLine.Part {
        let choices = CollectionCalculation.allCases.filter(CollectionChart.measures)
        return .menu(id: "chart-calculation", title: DocCollectionMath.title(chart.calculation), sections: [
            .init(choices.map { calculation in
                .action(DocCollectionMath.title(calculation), isOn: calculation == chart.calculation) { [self] in change { $0.calculation = calculation } }
            }),
        ])
    }

    /// The Y axis, on the view's page.
    var firstValue: DocLine {
        var parts: [DocLine.Part] = [.label(id: "chart-value-label", title: String(localized: "Y Axis")), valueMenu(0, chosen: chart.values.first, id: "chart-value-0")]
        if !chart.values.isEmpty { parts.append(calculation) }
        return DocLine(id: "chart-value", parts: parts)
    }

    /// A chart's order: by its groups, or by what they come to.
    private func orderLine(_ column: Column) -> DocLine {
        let controller = controller, block = block, view = view
        var orders: [FlooMenuItem] = DocCollectionNames.orders(manual: true).map { order in
            .action(DocCollectionNames.name(order, of: column), isOn: order == view.grouping.order && chart.order == .groups) { [self] in
                controller.setGrouping(CollectionGrouping(order: order, hidden: view.grouping.hidden, manual: view.grouping.manual), in: view.id, of: block)
                if chart.order != .groups { change { $0.order = .groups } }
            }
        }
        orders += [CollectionChart.Order.valueDescending, .valueAscending].map { order in
            .action(DocCollectionNames.name(order), isOn: order == chart.order) { [self] in change { $0.order = order } }
        }
        return DocLine(id: "data-order", parts: [
            .label(id: "data-order-label", title: String(localized: "Order")),
            .menu(id: "data-order-menu", title: chart.order != .groups ? DocCollectionNames.name(chart.order) : DocCollectionNames.name(view.grouping.order, of: column), name: String(localized: "Order"), sections: [.init(orders)]),
        ])
    }

    private var dataSections: [DocPageSection] {
        [DocPageSection(lines: valueLines), DocPageSection(lines: groupLines), DocPageSection(lines: referenceLines)]
    }

    /// What it measures.
    private var valueLines: [DocLine] {
        var lines: [DocLine] = []
        if chart.values.isEmpty {
            lines.append(DocLine(id: "data-value-none", parts: [.label(id: "data-value-none-label", title: String(localized: "Y Axis")), valueMenu(0, chosen: nil, id: "data-value-none-menu")]))
        }
        for (index, value) in chart.values.enumerated() {
            var parts: [DocLine.Part] = [
                .label(id: "data-value-\(index)-label", title: index == 0 ? String(localized: "Y Axis") : String(localized: "And")),
                valueMenu(index, chosen: value, id: "data-value-\(index)-menu"),
            ]
            if index == 0 { parts.append(calculation) }
            if chart.values.count > 1 {
                parts.append(.remove(id: "data-value-\(index)-remove") { [self] in change { $0.values.remove(at: index) } })
            }
            lines.append(DocLine(id: "data-value-\(index)", parts: parts))
        }
        // More values are side by side or stacked; a chart split by colour measures one.
        let more = numbers.filter { !chart.values.contains($0.id) }
        if !chart.values.isEmpty, chart.colorBy == nil, !more.isEmpty {
            lines.append(DocLine(id: "data-value-add", parts: [
                .label(id: "data-value-add-label", title: String(localized: "And")),
                .menu(id: "data-value-add-menu", title: String(localized: "Add"), name: String(localized: "Add Value"), sections: [
                    .init(more.map { column in
                        .action(column.name, symbol: DocFieldText.symbol(column)) { [self] in change { $0.values.append(column.id) } }
                    }),
                ]),
            ]))
        }
        if chart.kind != .donut, chart.kind != .line, chart.values.count > 1 || chart.colorBy != nil {
            lines.append(choice(String(localized: "Several Values"), [(false, String(localized: "Side by Side")), (true, String(localized: "Stacked"))], chosen: chart.isStacked) { [self] stacks in
                change { $0.stacks = stacks }
            })
        }
        if chart.kind != .donut {
            lines.append(toggle(String(localized: "Running Total"), isOn: chart.cumulative) { [self] on in change { $0.cumulative = on } })
            // What colours it: one value's, its options'.
            if chart.values.count <= 1, !selects.isEmpty {
                let column = database.columns.first { $0.id == chart.colorBy }
                lines.append(DocLine(id: "data-color-by", parts: [
                    .label(id: "data-color-by-label", title: String(localized: "Color By")),
                    .menu(id: "data-color-by-menu", title: column?.name ?? String(localized: "None"), name: String(localized: "Color By"), sections: [
                        .init([.action(String(localized: "None"), isOn: column == nil) { [self] in change { $0.colorBy = nil } }] + selects.map { option in
                            .action(option.name, symbol: DocFieldText.symbol(option), isOn: option.id == column?.id) { [self] in change { $0.colorBy = option.id } }
                        }),
                    ]),
                ]))
            }
        }
        return lines
    }

    /// Which groups, in what order.
    private var groupLines: [DocLine] {
        var lines: [DocLine] = []
        if let column = database.columns.first(where: { $0.id == chart.groupBy }) {
            lines.append(orderLine(column))
            let controller = controller
            lines.append(DocLine(id: "data-groups", parts: [.row(id: "data-groups-row", title: String(localized: "Show/Hide groups")) { controller.viewPanel?.openInner(.groups) }]))
        }
        lines.append(toggle(String(localized: "Only the Top Groups"), isOn: chart.limit != nil) { [self] on in change { $0.limit = on ? 5 : nil } })
        if let limit = chart.limit {
            lines.append(DocLine(id: "data-limit", parts: [
                .label(id: "data-limit-label", title: String(localized: "Top \(limit), the rest as Other")),
                .stepper(id: "data-limit-stepper", title: String(localized: "Top Groups"), value: limit, range: 1...50) { [self] new in change { $0.limit = max(1, new) } },
            ]))
        }
        return lines
    }

    /// A line to read it against.
    private var referenceLines: [DocLine] {
        var lines = [toggle(String(localized: "A Line at a Value"), isOn: chart.style.reference != nil) { [self] on in
            let middle = controller.collectionSnapshot(block).flatMap { Self.middle(of: $0, view: view) } ?? 0
            style { $0.reference = on ? .init(value: middle, label: String(localized: "Goal")) : nil }
        }]
        if let reference = chart.style.reference {
            lines.append(DocLine(id: "data-reference-value", parts: [
                .label(id: "data-reference-value-label", title: String(localized: "Value")),
                .text(id: "data-reference-value-field", placeholder: String(localized: "Value"), value: reference.value.formatted(.number.grouping(.never))) { [self] text in
                    guard let value = DocFieldText.number(text) else { return }
                    style(typing: "reference") { $0.reference?.value = value }
                },
            ]))
            lines.append(DocLine(id: "data-reference-label", parts: [
                .label(id: "data-reference-label-label", title: String(localized: "Label")),
                .text(id: "data-reference-label-field", placeholder: String(localized: "Label"), value: reference.label) { [self] text in
                    style(typing: "referenceLabel") { $0.reference?.label = text }
                },
            ]))
        }
        return lines
    }

    // MARK: How it looks

    /// The colours offered: the document's, then one for each group.
    private static let colors = ["blue", "cyan", "green", "yellow", "orange", "red", "purple", "gray"]

    private var rangeChoice: Int {
        switch chart.style.range {
        case .zero: 0
        case .fit: 1
        case .custom: 2
        }
    }

    private var styleSections: [DocPageSection] {
        var sections = [DocPageSection(lines: colorLines + [sizeLine])]
        if chart.kind != .donut { sections.append(DocPageSection(lines: rangeLines)) }
        sections.append(DocPageSection(lines: numberLines))
        sections.append(DocPageSection(lines: frameLines))
        if chart.kind == .line {
            sections.append(DocPageSection(lines: [
                toggle(String(localized: "Smooth"), isOn: chart.style.smooth) { [self] on in style { $0.smooth = on } },
                toggle(String(localized: "Fill the Area"), isOn: chart.style.area) { [self] on in style { $0.area = on } },
            ]))
        }
        return sections
    }

    private var colorLines: [DocLine] {
        let current = chart.style
        // One value's colour; a ring and a chart coloured by a field take their options'.
        guard chart.kind != .donut, chart.colorBy == nil, chart.values.count <= 1 else { return [] }
        return [DocLine(id: "style-color", parts: [
            .label(id: "style-color-label", title: String(localized: "Color")),
            .swatches(id: "style-swatches-row", swatches: Self.colors.map { token in
                DocLineSwatch(id: "style-color-\(token)", title: token, color: UIColor(DocOptionColor.color(token)), isOn: (current.color ?? "blue") == token) { [self] in
                    style { $0.color = token == "blue" ? nil : token }
                }
            } + [
                DocLineSwatch(id: "style-color-multi", title: String(localized: "A Color for Each Group"), isOn: current.color == CollectionChartStyle.multi) { [self] in
                    style { $0.color = CollectionChartStyle.multi }
                },
            ]),
        ])]
    }

    private var sizeLine: DocLine {
        choice(String(localized: "Size"), sizes, chosen: chart.style.height) { [self] height in style { $0.height = height } }
    }

    private var rangeLines: [DocLine] {
        let current = chart.style
        var lines: [DocLine] = []
        // Its numbers' range; nothing else on a ring.
        if chart.kind != .donut {
            lines.append(choice(String(localized: "Range"), [(0, String(localized: "From Zero")), (1, String(localized: "Close to the Values")), (2, String(localized: "Custom"))], chosen: rangeChoice) { [self] choice in
                style { style in
                    switch choice {
                    case 0: style.range = .zero
                    case 1: style.range = .fit
                    default:
                        if case .custom = style.range { return }
                        style.range = .custom(min: nil, max: nil)
                    }
                }
            })
            if case .custom(let low, let high) = current.range {
                lines.append(DocLine(id: "style-range-min", parts: [
                    .label(id: "style-range-min-label", title: String(localized: "Min")),
                    .text(id: "style-range-min-field", placeholder: String(localized: "Min"), value: low.map { $0.formatted(.number.grouping(.never)) } ?? "") { [self] text in
                        style(typing: "min") { style in
                            if case .custom(_, let high) = style.range { style.range = .custom(min: DocFieldText.number(text), max: high) }
                        }
                    },
                ]))
                lines.append(DocLine(id: "style-range-max", parts: [
                    .label(id: "style-range-max-label", title: String(localized: "Max")),
                    .text(id: "style-range-max-field", placeholder: String(localized: "Max"), value: high.map { $0.formatted(.number.grouping(.never)) } ?? "") { [self] text in
                        style(typing: "max") { style in
                            if case .custom(let low, _) = style.range { style.range = .custom(min: low, max: DocFieldText.number(text)) }
                        }
                    },
                ]))
            }
        }
        return lines
    }

    /// How its numbers read.
    private var numberLines: [DocLine] {
        let current = chart.style
        var lines: [DocLine] = []
        lines.append(choice(String(localized: "Format"), Self.formats.map { (FormatChoice($0.0), $0.1) }, chosen: FormatChoice(current.format)) { [self] format in
            style { $0.format = format.format }
        })
        lines.append(DocLine(id: "style-unit", parts: [
            .label(id: "style-unit-label", title: String(localized: "Unit")),
            .text(id: "style-unit-field", placeholder: String(localized: "None"), value: current.unit ?? "") { [self] text in
                style(typing: "unit") { $0.unit = text.isEmpty ? nil : text }
            },
        ]))
        lines.append(toggle(String(localized: "Show Values"), isOn: chart.showsValues) { [self] on in change { $0.showsValues = on } })
        return lines
    }

    /// What's around it.
    private var frameLines: [DocLine] {
        let current = chart.style
        var lines: [DocLine] = []
        if chart.kind != .donut {
            lines.append(toggle(String(localized: "Axis Names"), isOn: current.axisNames) { [self] on in style { $0.axisNames = on } })
            lines.append(toggle(String(localized: "Grid Lines"), isOn: current.grid) { [self] on in style { $0.grid = on } })
        }
        lines.append(toggle(String(localized: "Legend"), isOn: current.legend) { [self] on in style { $0.legend = on } })
        return lines
    }

    /// A number format as a choice.
    private struct FormatChoice: Hashable {
        let format: CollectionChartStyle.NumberFormat?
        init(_ format: CollectionChartStyle.NumberFormat?) { self.format = format }
    }
}
