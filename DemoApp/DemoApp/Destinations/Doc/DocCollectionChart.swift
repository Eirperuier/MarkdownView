//
//  DocCollectionChart.swift
//  DemoApp
//
//  A collection's chart view: a mark for each group of the records the view shows by the
//  field it groups by (its axis, the Group panel's: the same groups, order and ones left
//  out as a kanban's columns), as long as its calculation makes the group's values
//  (DocKit's CollectionView.chartData), drawn as its style says (CollectionChartStyle).
//  - bars across, a group's name beside each, drawn here; bars up and a line in Swift
//    Charts; a ring with its groups listed beside it;
//  - several values side by side or stacked, or one split by a select's options in their
//    colours, with a legend; highlighted groups in colour, the rest quieter; the groups
//    past a limit as one, Other, in gray; a reference line at a value;
//  - a click on a group shows its values; its right-click menu opens its record (a group of
//    one), highlights it, shows only it or hides it; a right-click elsewhere on the chart
//    opens its settings (DocChartSettings).
//

import FlooUIKit
import SwiftUI
import Charts
import DocKit

private typealias Tokens = DocTokens

struct DocCollectionChart: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let chart: CollectionChart
    let controller: DocCollectionController
    @State private var selected: String?

    private var block: DocBlockID { snapshot.block }
    private var database: Database { snapshot.database }
    private var axis: Column? { database.columns.first { $0.id == chart.groupBy } }

    var body: some View {
        if let problem = chart.problem(in: database) {
            note(problem.prefix(1).uppercased() + problem.dropFirst() + ".")
        } else if let axis, let data = view.chartData(of: controller.rows(snapshot, view), in: database), !data.groups.isEmpty {
            let plot = DocChartPlot(data: data, chart: chart, axis: axis, database: database)
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                if chart.style.legend { legend(plot) }
                switch chart.kind {
                case .bar: DocChartBars(plot: plot, selected: $selected, menu: menu)
                case .column, .line: DocChartAxes(plot: plot, selected: $selected, menu: menu)
                case .donut: DocChartRing(plot: plot, selected: $selected, menu: menu)
                }
            }
            .padding(.vertical, Tokens.Space.xs)
            .contentShape(Rectangle())
            .flooContextMenu(isEnabled: controller.isEditable) {
                [.init([.action(String(localized: "Chart Settings…"), symbol: "slider.horizontal.3") { controller.show(.chart, in: block) }])]
            }
        } else {
            note(String(localized: "No records to chart."))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Tokens.ColorRole.Content.tertiary)
            .frame(maxWidth: .infinity, minHeight: 80)
    }

    /// The series' colours and names when there are several, and the reference line's.
    @ViewBuilder
    private func legend(_ plot: DocChartPlot) -> some View {
        let reference = chart.style.reference
        if plot.series.count > 1 || reference != nil && chart.kind == .bar {
            HStack(spacing: Tokens.Space.md) {
                if plot.series.count > 1 {
                    ForEach(plot.series.indices, id: \.self) { index in
                        HStack(spacing: Tokens.Space.xs) {
                            RoundedRectangle(cornerRadius: 3).fill(plot.color(series: index)).frame(width: 10, height: 10)
                            Text(plot.name(series: index)).font(.system(size: 12)).foregroundStyle(Tokens.ColorRole.Content.secondary)
                        }
                    }
                }
                if let reference, chart.kind == .bar {
                    HStack(spacing: Tokens.Space.xs) {
                        Rectangle().fill(DocChartPlot.referenceColor).frame(width: 2, height: 12)
                        Text(plot.referenceText(reference)).font(.system(size: 12)).foregroundStyle(DocChartPlot.referenceColor)
                    }
                }
            }
        }
    }

    /// A group's right-click menu.
    private func menu(_ group: CollectionChartData.Group) -> [FlooMenuSection] {
        let keys = (view.groups(of: database.rows, in: database, everyOption: true) ?? []).map(\.key)
        var record: [FlooMenuItem] = []
        if !group.isOther, group.group.rows.count == 1, let row = group.group.rows.first, let open = controller.openRecord {
            let title = DocCollectionController.titleColumn(of: database).map { DocFieldText.text(row.cells[$0.id], in: $0) } ?? ""
            record.append(.action(title.isEmpty ? String(localized: "Open Record") : String(localized: "Open “\(title)”"),
                                  symbol: "arrow.up.left.and.arrow.down.right") { open(row.id, block) })
        }
        var sections: [FlooMenuSection] = record.isEmpty ? [] : [.init(record)]
        guard controller.isEditable else { return sections }
        if !group.isOther {
            sections.append(.init([
                .action(String(localized: "Highlight"), symbol: "highlighter", isOn: group.highlighted) {
                    controller.changeChart(view.id, in: block) { chart in
                        if chart.highlight.contains(group.key) { chart.highlight.removeAll { $0 == group.key } } else { chart.highlight.append(group.key) }
                    }
                },
            ]))
            sections.append(.init([
                .action(String(localized: "Show Only This Group"), symbol: "eye") {
                    var grouping = view.grouping
                    grouping.hidden = keys.filter { $0 != group.key }
                    controller.setGrouping(grouping, in: view.id, of: block)
                },
                .action(String(localized: "Hide This Group"), symbol: "eye.slash") {
                    var grouping = view.grouping
                    grouping.hidden.append(group.key)
                    controller.setGrouping(grouping, in: view.id, of: block)
                },
            ]))
        }
        sections.append(.init([
            .action(String(localized: "Chart Settings…"), symbol: "slider.horizontal.3") { controller.show(.chart, in: block) },
        ]))
        return sections
    }
}

/// What every chart draws from: the groups with their names, the series with their
/// colours, the numbers as they read, the span of its value axis.
struct DocChartPlot {
    let data: CollectionChartData
    let chart: CollectionChart
    let axis: Column
    let database: Database

    var series: [CollectionChartData.Series] { data.series }
    var groups: [CollectionChartData.Group] { data.groups }
    var style: CollectionChartStyle { chart.style }
    var stacks: Bool { chart.isStacked }
    var highlights: Bool { groups.contains(where: \.highlighted) }
    var domain: ClosedRange<Double> { chart.domain(of: data) }

    /// The value fields' colours when a series has none of its own.
    private static let palette = ["blue", "cyan", "purple", "orange", "green", "red", "yellow", "mint"]
    static let referenceColor = DocOptionColor.color("orange")

    func name(_ group: CollectionChartData.Group) -> String {
        if group.isOther { return String(localized: "Other (\(group.others))") }
        // A day along an axis: its month and day, the year only when the days span more than one.
        if case .date(let when)? = group.group.value {
            let date = DocFieldText.date(of: when)
            return years > 1 ? date.formatted(.dateTime.year().month(.abbreviated).day()) : date.formatted(.dateTime.month(.abbreviated).day())
        }
        return DocGroupLabel.title(group.group.value, in: axis)
    }

    private var years: Int {
        Set(groups.compactMap { group -> Int? in
            if case .date(let when)? = group.group.value { Calendar.current.component(.year, from: DocFieldText.date(of: when)) } else { nil }
        }).count
    }

    /// A series' name: a value field's, an option's, or Count.
    func name(series index: Int) -> String {
        series[index].key.isEmpty ? String(localized: "Count") : series[index].name
    }

    /// The value axis's name: its values', or Count.
    var valueName: String {
        series.count == 1 || chart.colorBy != nil ? (chart.values.isEmpty ? String(localized: "Count") : database.columns.first { $0.id == chart.values[0] }?.name ?? "")
            : series.indices.map(name(series:)).joined(separator: ", ")
    }

    /// The groups whose names the bottom axis writes: every one, or every few when there
    /// are too many to fit.
    var labelled: [String] {
        let step = max(1, Int((Double(groups.count) / 8).rounded(.up)))
        return groups.enumerated().filter { $0.offset % step == 0 }.map { name($0.element) }
    }

    /// Each group its own colour: a ring's, or a single value's when its colour is `multi`.
    private var eachGroupColored: Bool {
        chart.kind == .donut || series.count == 1 && style.color == CollectionChartStyle.multi
    }

    func color(series index: Int) -> Color {
        if let own = series[index].color { return DocOptionColor.color(own) }
        if series.count == 1, let color = style.color, color != CollectionChartStyle.multi { return DocOptionColor.color(color) }
        return DocOptionColor.color(Self.palette[index % Self.palette.count])
    }

    /// A mark's colour: its series', or its group's own (an option's when the axis has
    /// them); gray for Other; quiet beside a highlight.
    func color(_ group: CollectionChartData.Group, series index: Int) -> Color {
        var color = color(series: index)
        if group.isOther {
            color = Tokens.ColorRole.Content.tertiary
        } else if eachGroupColored {
            let options = DocFieldText.options(axis)
            if let option = options.first(where: { $0.id.description == group.key }) {
                color = DocOptionColor.color(DocOptionColor.token(option, in: options))
            } else {
                color = DocOptionColor.color(Self.palette[(groups.firstIndex(of: group) ?? 0) % Self.palette.count])
            }
        }
        guard highlights, !group.highlighted else { return color }
        return series.count == 1 && !eachGroupColored ? Tokens.ColorRole.Content.tertiary.opacity(0.5) : color.opacity(0.45)
    }

    func text(_ value: Double?) -> String {
        guard let value else { return "–" }
        return style.text(value, field: data.format, locale: .current)
    }

    func referenceText(_ reference: CollectionChartStyle.Reference) -> String {
        reference.label.isEmpty ? text(reference.value) : "\(reference.label) \(text(reference.value))"
    }

    /// What a group comes to: its one value, or its parts' sum when stacked.
    func label(_ group: CollectionChartData.Group) -> String {
        if series.count == 1 || stacks { return text(series.count == 1 ? group.values[0] : group.total) }
        return group.values.map(text).joined(separator: " · ")
    }

    /// How tall a chart with axes is, a ring across, a bar.
    var plotHeight: CGFloat {
        switch style.height {
        case .small: 160
        case .medium: 220
        case .large: 320
        }
    }

    var ringSize: CGFloat {
        switch style.height {
        case .small: 140
        case .medium: 180
        case .large: 240
        }
    }

    var barThickness: CGFloat {
        switch style.height {
        case .small: 12
        case .medium: 16
        case .large: 22
        }
    }
}

/// Bars across: a group's name, its bar (its series side by side, or stacked), its value.
private struct DocChartBars: View {
    let plot: DocChartPlot
    @Binding var selected: String?
    let menu: (CollectionChartData.Group) -> [FlooMenuSection]

    var body: some View {
        // The names as wide as the widest, up to a point past which they wrap.
        let names = min(plot.groups.map { DocCollectionWidths.width(plot.name($0), size: 13, weight: .semibold) }.max() ?? 0, 220) + 2
        Grid(alignment: .leading, horizontalSpacing: Tokens.Space.md, verticalSpacing: Tokens.Space.xs) {
            if plot.style.axisNames {
                GridRow {
                    Text(plot.axis.name).frame(width: names, alignment: .leading)
                    Text(plot.valueName)
                    Color.clear.frame(width: 0, height: 0)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tokens.ColorRole.Content.tertiary)
            }
            ForEach(plot.groups, id: \.key) { group in
                GridRow {
                    Text(plot.name(group))
                        .font(.system(size: 13, weight: group.highlighted ? .semibold : .regular))
                        .foregroundStyle(group.isOther ? Tokens.ColorRole.Content.secondary : Tokens.ColorRole.Content.primary)
                        .lineLimit(2)
                        .frame(width: names, alignment: .leading)
                    bars(group)
                        .frame(maxWidth: .infinity)
                    if plot.chart.showsValues || selected == group.key {
                        Text(plot.label(group))
                            .font(.system(size: 12, weight: group.highlighted ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(group.highlighted ? Tokens.ColorRole.Content.primary : Tokens.ColorRole.Content.secondary)
                    } else {
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .background(selected == group.key ? Tokens.ColorRole.Surface.selected : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.xs))
                .onTapGesture { selected = selected == group.key ? nil : group.key }
                .flooContextMenu { menu(group) }
            }
        }
    }

    @ViewBuilder
    private func bars(_ group: CollectionChartData.Group) -> some View {
        let single = plot.stacks || plot.series.count == 1
        GeometryReader { proxy in
            let domain = plot.domain
            let span = domain.upperBound - domain.lowerBound
            // From the axis's start to a value; stacked parts from where the last ended.
            let x = { (value: Double) -> CGFloat in CGFloat((min(max(value, domain.lowerBound), domain.upperBound) - domain.lowerBound) / span) * proxy.size.width }
            ZStack(alignment: .leading) {
                if single {
                    let ends = plot.series.indices.reduce(into: [Double]()) { ends, index in
                        ends.append((ends.last ?? 0) + (group.values[index] ?? 0))
                    }
                    ForEach(plot.series.indices.reversed(), id: \.self) { index in
                        Rectangle()
                            .fill(plot.color(group, series: index))
                            .frame(width: max(x(plot.series.count == 1 ? group.values[index] ?? 0 : ends[index]), 0))
                    }
                    .frame(height: plot.barThickness)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(plot.series.indices, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(plot.color(group, series: index))
                                .frame(width: x(group.values[index] ?? 0), height: plot.barThickness * 0.65)
                        }
                    }
                }
                if let reference = plot.style.reference {
                    Rectangle()
                        .fill(DocChartPlot.referenceColor)
                        .frame(width: 2)
                        .offset(x: x(reference.value) - 1)
                }
            }
            .frame(maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: single ? plot.barThickness + 4 : CGFloat(plot.series.count) * (plot.barThickness * 0.65 + 2))
    }
}

/// Bars up or a line, in Swift Charts: the groups along the bottom in their order.
private struct DocChartAxes: View {
    let plot: DocChartPlot
    @Binding var selected: String?
    let menu: (CollectionChartData.Group) -> [FlooMenuSection]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            if let key = selected, let group = plot.groups.first(where: { $0.key == key }) {
                Text("\(plot.name(group)) · \(plot.label(group))")
                    .font(.system(size: 12, weight: .semibold))
            }
            chart
                .frame(height: plot.plotHeight)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(plot.groups, id: \.key) { group in
                ForEach(plot.series.indices, id: \.self) { index in
                    if let value = group.values[index] {
                        mark(group, index, value)
                    }
                }
            }
            if let reference = plot.style.reference {
                RuleMark(y: .value("Reference", reference.value))
                    .foregroundStyle(DocChartPlot.referenceColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text(plot.referenceText(reference)).font(.system(size: 11, weight: .medium)).foregroundStyle(DocChartPlot.referenceColor)
                    }
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: plot.domain)
        .chartXAxis {
            AxisMarks(values: plot.labelled) { _ in
                if plot.style.grid { AxisGridLine() }
                AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks { value in
                if plot.style.grid { AxisGridLine() }
                AxisValueLabel { if let number = value.as(Double.self) { Text(plot.text(number)) } }
            }
        }
        .chartXAxisLabel(plot.style.axisNames ? plot.axis.name : "")
        .chartYAxisLabel(plot.style.axisNames ? plot.valueName : "")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let frame = proxy.plotFrame.map({ geometry[$0] }) {
                    let band = frame.width / CGFloat(max(plot.groups.count, 1))
                    ForEach(plot.groups, id: \.key) { group in
                        if let x = proxy.position(forX: plot.name(group)) {
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: band, height: frame.height)
                                .position(x: frame.minX + x, y: frame.midY)
                                .onTapGesture { selected = selected == group.key ? nil : group.key }
                                .flooContextMenu { menu(group) }
                        }
                    }
                }
            }
        }
    }

    @ChartContentBuilder
    private func mark(_ group: CollectionChartData.Group, _ index: Int, _ value: Double) -> some ChartContent {
        let x = PlottableValue.value("Group", plot.name(group))
        let y = PlottableValue.value("Value", value)
        let series = PlottableValue.value("Series", plot.series[index].name)
        let last = group.key == plot.groups.last?.key
        if plot.chart.kind == .line {
            if plot.style.area {
                AreaMark(x: x, y: y, series: series, stacking: .unstacked)
                    .foregroundStyle(LinearGradient(colors: [plot.color(series: index).opacity(0.35), plot.color(series: index).opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(plot.style.smooth ? .monotone : .linear)
            }
            LineMark(x: x, y: y, series: series)
                .foregroundStyle(plot.color(series: index))
                .interpolationMethod(plot.style.smooth ? .monotone : .linear)
            PointMark(x: x, y: y)
                .foregroundStyle(plot.color(group, series: index))
                .symbolSize(group.highlighted || selected == group.key ? 70 : 30)
                .annotation(position: .top, spacing: 4) {
                    if plot.chart.showsValues && (last || group.highlighted) || selected == group.key {
                        Text(plot.text(value)).font(.system(size: 11, weight: .semibold))
                    }
                }
        } else if plot.stacks || plot.series.count == 1 {
            BarMark(x: x, y: y, width: .ratio(0.6))
                .foregroundStyle(plot.color(group, series: index))
                .cornerRadius(3)
                .annotation(position: .top, spacing: 3) {
                    // The total over the top part the group has.
                    if (plot.chart.showsValues || selected == group.key) && index == group.values.lastIndex(where: { ($0 ?? 0) != 0 }) {
                        Text(plot.label(group)).font(.system(size: 11)).foregroundStyle(Tokens.ColorRole.Content.secondary)
                    }
                }
        } else {
            BarMark(x: x, y: y, width: .ratio(0.8))
                .foregroundStyle(plot.color(group, series: index))
                .position(by: series)
                .cornerRadius(3)
                .annotation(position: .top, spacing: 3) {
                    if plot.chart.showsValues || selected == group.key {
                        Text(plot.text(value)).font(.system(size: 10)).foregroundStyle(Tokens.ColorRole.Content.secondary)
                    }
                }
        }
    }
}

/// A ring, each group's share of the whole, and the groups listed beside it.
private struct DocChartRing: View {
    let plot: DocChartPlot
    @Binding var selected: String?
    let menu: (CollectionChartData.Group) -> [FlooMenuSection]

    private var total: Double { plot.groups.reduce(0) { $0 + max($1.total, 0) } }

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Space.xl) {
            Chart(plot.groups, id: \.key) { group in
                SectorMark(angle: .value("Value", max(group.total, 0)), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .foregroundStyle(plot.color(group, series: 0))
                    .cornerRadius(3)
            }
            .chartLegend(.hidden)
            .chartBackground { _ in
                VStack(spacing: 0) {
                    let group = selected.flatMap { key in plot.groups.first { $0.key == key } }
                    Text(plot.text(group?.total ?? total)).font(.system(size: 22, weight: .bold).monospacedDigit())
                    Text(group.map(plot.name) ?? (plot.series.isEmpty ? "" : plot.name(series: 0)))
                        .font(.system(size: 11)).foregroundStyle(Tokens.ColorRole.Content.secondary).lineLimit(1)
                }
                .padding(.horizontal, 30)
            }
            .frame(width: plot.ringSize, height: plot.ringSize)
            if plot.style.legend {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(plot.groups, id: \.key) { group in
                        row(group)
                    }
                }
                .frame(maxWidth: 260)
            }
        }
    }

    private func row(_ group: CollectionChartData.Group) -> some View {
        HStack(spacing: Tokens.Space.sm) {
            RoundedRectangle(cornerRadius: 3).fill(plot.color(group, series: 0)).frame(width: 12, height: 12)
            Text(plot.name(group)).font(.system(size: 13, weight: group.highlighted ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: Tokens.Space.md)
            if plot.chart.showsValues {
                Text(plot.text(group.total)).font(.system(size: 13).monospacedDigit())
            }
            Text(total > 0 ? (max(group.total, 0) / total).formatted(.percent.precision(.fractionLength(0))) : "–")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Tokens.ColorRole.Content.secondary)
                .frame(minWidth: 36, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, Tokens.Space.xs)
        .contentShape(Rectangle())
        .background(selected == group.key ? Tokens.ColorRole.Surface.selected : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.xs))
        .onTapGesture { selected = selected == group.key ? nil : group.key }
        .flooContextMenu { menu(group) }
    }
}
