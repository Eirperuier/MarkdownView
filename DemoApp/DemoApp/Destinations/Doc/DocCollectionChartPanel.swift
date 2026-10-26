//
//  DocCollectionChartPanel.swift
//  DemoApp
//
//  A chart view's panel (from the view menu, Layout & Visibility, or a right-click on the
//  chart), in two pages:
//  - Data: its kind; what it measures and the calculation (more values side by side or
//    stacked, a running total); what colours it; only the groups that come to most; a
//    reference line at a value;
//  - Style: its colour, size and value axis; how its numbers read and their unit; values,
//    axis names, grid lines, legend; a line's curve and area.
//  Each change is one step; typing in a field is one for the field.
//

import SwiftUI
import DocKit
import FlooDesign

private typealias Metrics = DocCollectionMetrics
private typealias Tokens = FlooDesignTokens

struct DocChartPanel: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let controller: DocCollectionController
    // -docChartPage style: the panel opens at its Style page (screenshots).
    @State private var page = UserDefaults.standard.string(forKey: "docChartPage") == "style" ? Page.style : Page.data

    enum Page: Hashable { case data, style }

    private var block: DocBlockID { snapshot.block }

    var body: some View {
        DocPanelFrame(title: String(localized: "Chart"), close: { controller.close(.chart, in: block) }) {
            if let chart = view.layout.chart {
                Picker(String(localized: "Page"), selection: $page) {
                    Text(String(localized: "Data")).tag(Page.data)
                    Text(String(localized: "Style")).tag(Page.style)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch page {
                case .data: DocChartData(snapshot: snapshot, view: view, chart: chart, controller: controller)
                case .style: DocChartStyleSettings(snapshot: snapshot, view: view, chart: chart, controller: controller)
                }
            }
        }
    }
}

/// A switch on a line with its name.
private struct DocPanelSwitch: View {
    let title: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle(title, isOn: Binding { isOn } set: { set($0) })
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Tokens.ColorRole.Accent.primary)
        }
    }
}

/// A menu of named choices, the chosen one ticked.
private struct DocPanelChoice<Value: Hashable>: View {
    let choices: [(Value, String)]
    let chosen: Value
    var fills = false
    let pick: (Value) -> Void

    var body: some View {
        Menu {
            ForEach(choices, id: \.0) { value, name in
                Button {
                    pick(value)
                } label: {
                    if value == chosen { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            DocPanelMenuLabel(title: choices.first { $0.0 == chosen }?.1 ?? "", fills: fills)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fills, vertical: false)
    }
}

/// A short field that takes typing, each keystroke one step with the rest typed in it.
private struct DocPanelField: View {
    let placeholder: String
    let text: String
    var width: CGFloat?
    let set: (String) -> Void
    @State private var typed = ""

    var body: some View {
        TextField(placeholder, text: $typed)
            .textFieldStyle(FlooDesignTextFieldStyle())
            .frame(width: width)
            .onAppear { typed = text }
            .onChange(of: text) { _, new in if new != typed { typed = new } }
            .onChange(of: typed) { _, new in if new != text { set(new) } }
    }
}

// MARK: - Data

private struct DocChartData: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let chart: CollectionChart
    let controller: DocCollectionController

    private var block: DocBlockID { snapshot.block }
    private var database: Database { snapshot.database }
    private var numbers: [Column] { database.columns.filter { $0.type == .number } }
    private var selects: [Column] { database.columns.filter(DocFieldText.hasOptions) }

    private func change(typing key: String? = nil, _ update: @escaping (inout CollectionChart) -> Void) {
        controller.changeChart(view.id, in: block, typing: key.map { [AnyHashable(view.id), "chart", $0] as [AnyHashable] }, update)
    }

    var body: some View {
        DocChartKinds(kind: chart.kind) { kind in change { $0.kind = kind } }
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            DocPanelSection(title: String(localized: "Y Axis"))
            if chart.values.isEmpty {
                DocChartValueMenu(database: database, chosen: nil) { picked in set(0, to: picked) }
            }
            ForEach(Array(chart.values.enumerated()), id: \.offset) { index, value in
                HStack(spacing: Tokens.Space.sm) {
                    DocChartValueMenu(database: database, chosen: value, excluding: chart.values) { picked in set(index, to: picked) }
                    if index == 0 { calculations }
                    if chart.values.count > 1 {
                        DocTrashButton { change { $0.values.remove(at: index) } }
                    }
                }
            }
            // More values are side by side or stacked; a chart split by colour measures one.
            if !chart.values.isEmpty, chart.colorBy == nil {
                DocAddRuleMenu(title: String(localized: "Add Value"), columns: numbers.filter { !chart.values.contains($0.id) }) { column in
                    change { $0.values.append(column.id) }
                }
            }
            if chart.kind != .donut, chart.kind != .line, chart.values.count > 1 || chart.colorBy != nil {
                HStack {
                    Text(String(localized: "Several Values")).font(.system(size: 13))
                    Spacer()
                    DocPanelChoice(choices: [(false, String(localized: "Side by Side")), (true, String(localized: "Stacked"))],
                                   chosen: chart.isStacked) { stacks in change { $0.stacks = stacks } }
                }
            }
            if chart.kind != .donut {
                DocPanelSwitch(title: String(localized: "Running Total"), isOn: chart.cumulative) { on in change { $0.cumulative = on } }
            }
        }
        if chart.kind != .donut {
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                DocPanelSection(title: String(localized: "Color By"))
                Menu {
                    Button(String(localized: "None")) { change { $0.colorBy = nil } }
                    ForEach(selects, id: \.id) { column in
                        Button(column.name, systemImage: DocFieldText.symbol(column)) { change { $0.colorBy = column.id } }
                    }
                } label: {
                    let column = database.columns.first { $0.id == chart.colorBy }
                    DocPanelMenuLabel(symbol: column.map(DocFieldText.symbol), title: column?.name ?? String(localized: "None"), fills: true, quiet: column == nil)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .disabled(chart.values.count > 1 || selects.isEmpty)
            }
        }
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            DocPanelSection(title: String(localized: "Groups"))
            DocPanelSwitch(title: String(localized: "Only the Top Groups"), isOn: chart.limit != nil) { on in change { $0.limit = on ? 5 : nil } }
            if let limit = chart.limit {
                Stepper(value: Binding { limit } set: { new in change { $0.limit = max(1, new) } }, in: 1...50) {
                    Text(String(localized: "Top \(limit), the rest as Other")).font(.system(size: 13))
                }
            }
        }
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            DocPanelSection(title: String(localized: "Reference Line"))
            DocPanelSwitch(title: String(localized: "A Line at a Value"), isOn: chart.style.reference != nil) { on in
                change { $0.style.reference = on ? .init(value: Self.middle(of: snapshot, view: view) ?? 0, label: String(localized: "Goal")) : nil }
            }
            if let reference = chart.style.reference {
                HStack(spacing: Tokens.Space.sm) {
                    DocPanelField(placeholder: String(localized: "Value"), text: reference.value.formatted(.number.grouping(.never)), width: 90) { text in
                        guard let value = DocFieldText.number(text) else { return }
                        change(typing: "reference") { $0.style.reference?.value = value }
                    }
                    DocPanelField(placeholder: String(localized: "Label"), text: reference.label) { text in
                        change(typing: "referenceLabel") { $0.style.reference?.label = text }
                    }
                }
            }
        }
    }

    /// A reference line's first value: halfway across what the chart draws.
    static func middle(of snapshot: DocCollectionSnapshot, view: CollectionView) -> Double? {
        guard let data = view.chartData(of: view.records(of: snapshot.database), in: snapshot.database) else { return nil }
        let totals = data.groups.map(\.total)
        guard let low = totals.min(), let high = totals.max() else { return nil }
        return ((low + high) / 2).rounded()
    }

    /// What the first value comes to in each group: a number's calculations.
    private var calculations: some View {
        DocPanelChoice(choices: CollectionCalculation.allCases.filter(CollectionChart.measures).map { ($0, DocCollectionMath.title($0)) },
                       chosen: chart.calculation) { calculation in change { $0.calculation = calculation } }
    }

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
}

// MARK: - Style

private struct DocChartStyleSettings: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let chart: CollectionChart
    let controller: DocCollectionController

    private var block: DocBlockID { snapshot.block }
    private var style: CollectionChartStyle { chart.style }

    private func change(typing key: String? = nil, _ update: @escaping (inout CollectionChartStyle) -> Void) {
        controller.changeChart(view.id, in: block, typing: key.map { [AnyHashable(view.id), "chart", $0] as [AnyHashable] }) { update(&$0.style) }
    }

    /// The colours offered: the document's, then one for each group.
    private static let colors = ["blue", "cyan", "green", "yellow", "orange", "red", "purple", "gray"]

    var body: some View {
        // One value's colour; a ring and a chart coloured by a field take their options'.
        if chart.kind != .donut, chart.colorBy == nil, chart.values.count <= 1 {
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                DocPanelSection(title: String(localized: "Color"))
                HStack(spacing: Tokens.Space.xxs) {
                    ForEach(Self.colors, id: \.self) { token in
                        swatch(DocOptionColor.color(token), isOn: (style.color ?? "blue") == token) { change { $0.color = token == "blue" ? nil : token } }
                    }
                    swatch(nil, isOn: style.color == CollectionChartStyle.multi) { change { $0.color = CollectionChartStyle.multi } }
                }
            }
        }
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            DocPanelSection(title: String(localized: "Size"))
            Picker(String(localized: "Size"), selection: Binding { style.height } set: { height in change { $0.height = height } }) {
                Text(String(localized: "Small")).tag(CollectionChartStyle.Height.small)
                Text(String(localized: "Medium")).tag(CollectionChartStyle.Height.medium)
                Text(String(localized: "Large")).tag(CollectionChartStyle.Height.large)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        if chart.kind != .donut {
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                DocPanelSection(title: String(localized: "Value Axis"))
                HStack {
                    Text(String(localized: "Range")).font(.system(size: 13))
                    Spacer()
                    DocPanelChoice(choices: [(0, String(localized: "From Zero")), (1, String(localized: "Close to the Values")), (2, String(localized: "Custom"))],
                                   chosen: rangeChoice) { choice in
                        change { style in
                            switch choice {
                            case 0: style.range = .zero
                            case 1: style.range = .fit
                            default:
                                if case .custom = style.range { return }
                                style.range = .custom(min: nil, max: nil)
                            }
                        }
                    }
                }
                if case .custom(let min, let max) = style.range {
                    HStack(spacing: Tokens.Space.sm) {
                        DocPanelField(placeholder: String(localized: "Min"), text: min.map { $0.formatted(.number.grouping(.never)) } ?? "") { text in
                            change(typing: "min") { style in
                                if case .custom(_, let max) = style.range { style.range = .custom(min: DocFieldText.number(text), max: max) }
                            }
                        }
                        Text("–").foregroundStyle(Tokens.ColorRole.Content.secondary)
                        DocPanelField(placeholder: String(localized: "Max"), text: max.map { $0.formatted(.number.grouping(.never)) } ?? "") { text in
                            change(typing: "max") { style in
                                if case .custom(let min, _) = style.range { style.range = .custom(min: min, max: DocFieldText.number(text)) }
                            }
                        }
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            DocPanelSection(title: String(localized: "Numbers"))
            HStack {
                Text(String(localized: "Format")).font(.system(size: 13))
                Spacer()
                DocPanelChoice(choices: Self.formats, chosen: style.format) { format in change { $0.format = format } }
            }
            HStack {
                Text(String(localized: "Unit")).font(.system(size: 13))
                Spacer()
                DocPanelField(placeholder: String(localized: "None"), text: style.unit ?? "", width: 90) { text in
                    change(typing: "unit") { $0.unit = text.isEmpty ? nil : text }
                }
            }
            DocPanelSwitch(title: String(localized: "Show Values"), isOn: chart.showsValues) { on in
                controller.changeChart(view.id, in: block) { $0.showsValues = on }
            }
        }
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            DocPanelSection(title: String(localized: "Show"))
            if chart.kind != .donut {
                DocPanelSwitch(title: String(localized: "Axis Names"), isOn: style.axisNames) { on in change { $0.axisNames = on } }
                DocPanelSwitch(title: String(localized: "Grid Lines"), isOn: style.grid) { on in change { $0.grid = on } }
            }
            DocPanelSwitch(title: String(localized: "Legend"), isOn: style.legend) { on in change { $0.legend = on } }
        }
        if chart.kind == .line {
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                DocPanelSection(title: String(localized: "Line"))
                DocPanelSwitch(title: String(localized: "Smooth"), isOn: style.smooth) { on in change { $0.smooth = on } }
                DocPanelSwitch(title: String(localized: "Fill the Area"), isOn: style.area) { on in change { $0.area = on } }
            }
        }
    }

    private var rangeChoice: Int {
        switch style.range {
        case .zero: 0
        case .fit: 1
        case .custom: 2
        }
    }

    static let formats: [(CollectionChartStyle.NumberFormat?, String)] = [
        (nil, String(localized: "As the Field")), (.compact, String(localized: "Compact (12.6K)")),
        (.cell(.number), String(localized: "Number")), (.cell(.percent), String(localized: "Percent")),
        (.cell(.currency(code: "USD")), "USD"), (.cell(.currency(code: "EUR")), "EUR"),
        (.cell(.currency(code: "CNY")), "CNY"), (.cell(.currency(code: "JPY")), "JPY"),
    ]

    /// A colour to pick, ringed when it's the one; none, a colour for each group.
    private func swatch(_ color: Color?, isOn: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            Circle()
                .fill(color.map { AnyShapeStyle($0) }
                      ?? AnyShapeStyle(AngularGradient(colors: Self.colors.prefix(7).map(DocOptionColor.color), center: .center)))
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(Circle().strokeBorder(isOn ? Tokens.ColorRole.Content.primary : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color == nil ? String(localized: "A Color for Each Group") : String(localized: "Color"))
    }
}
