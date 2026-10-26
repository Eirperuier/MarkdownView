//
//  DocCollectionChart.swift
//  DemoApp
//
//  A collection's chart view: a mark for each group of the records the view shows by the
//  field it groups by (its axis, the Group panel's: the same groups, order and ones left
//  out as a kanban's columns), as long as its calculation makes the group's values
//  (DocKit's CollectionView.chartData).
//  - bars across, a group's name beside each, drawn here; bars up and a line in Swift
//    Charts; a ring with its groups listed beside it;
//  - several values side by side, or one split by a select's options stacked in their
//    colours, with a legend; highlighted groups in colour, the rest quieter;
//  - a click on a group shows its values; its right-click menu opens its record (a group of
//    one), highlights it, shows only it or hides it.
//

import SwiftUI
import Charts
import DocKit
import FlooDesign

private typealias Tokens = FlooDesignTokens

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
            let plot = DocChartPlot(data: data, chart: chart, axis: axis)
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                if plot.series.count > 1 { legend(plot) }
                switch chart.kind {
                case .bar: DocChartBars(plot: plot, selected: $selected, menu: menu)
                case .column, .line: DocChartAxes(plot: plot, selected: $selected, menu: menu)
                case .donut: DocChartRing(plot: plot, selected: $selected, menu: menu)
                }
            }
            .padding(.vertical, Tokens.Space.xs)
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

    private func legend(_ plot: DocChartPlot) -> some View {
        HStack(spacing: Tokens.Space.md) {
            ForEach(plot.series.indices, id: \.self) { index in
                HStack(spacing: Tokens.Space.xs) {
                    RoundedRectangle(cornerRadius: 3).fill(plot.color(series: index)).frame(width: 10, height: 10)
                    Text(plot.name(series: index)).font(.system(size: 12)).foregroundStyle(Tokens.ColorRole.Content.secondary)
                }
            }
        }
    }

    /// A group's right-click menu.
    private func menu(_ group: CollectionChartData.Group) -> [FlooDesignActionMenuSection] {
        let keys = (view.groups(of: database.rows, in: database, everyOption: true) ?? []).map(\.key)
        var record: [FlooDesignActionMenuItem] = []
        if group.group.rows.count == 1, let row = group.group.rows.first, let open = controller.openRecord {
            let title = DocCollectionController.titleColumn(of: database).map { DocFieldText.text(row.cells[$0.id], in: $0) } ?? ""
            record.append(.action(title.isEmpty ? String(localized: "Open Record") : String(localized: "Open “\(title)”"),
                                  symbol: "arrow.up.left.and.arrow.down.right") { open(row.id, block) })
        }
        var sections: [FlooDesignActionMenuSection] = record.isEmpty ? [] : [.init(.rows, record)]
        guard controller.isEditable else { return sections }
        sections.append(.init(.rows, [
            .action(String(localized: "Highlight"), symbol: "highlighter", isOn: group.highlighted) {
                controller.changeChart(view.id, in: block) { chart in
                    if chart.highlight.contains(group.key) { chart.highlight.removeAll { $0 == group.key } } else { chart.highlight.append(group.key) }
                }
            },
        ]))
        sections.append(.init(.rows, [
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
        return sections
    }
}

/// What every chart draws from: the groups with their names, the series with their
/// colours, the numbers as they read.
struct DocChartPlot {
    let data: CollectionChartData
    let chart: CollectionChart
    let axis: Column

    var series: [CollectionChartData.Series] { data.series }
    var groups: [CollectionChartData.Group] { data.groups }
    /// Split by a select's options: one bar, its parts stacked; else side by side.
    var stacks: Bool { chart.colorBy != nil }
    var highlights: Bool { groups.contains(where: \.highlighted) }

    /// The value fields' colours when a series has none of its own.
    private static let palette = ["blue", "cyan", "purple", "orange", "green", "red"]

    func name(_ group: CollectionChartData.Group) -> String {
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

    /// The groups whose names the bottom axis writes: every one, or every few when there
    /// are too many to fit.
    var labelled: [String] {
        let step = max(1, Int((Double(groups.count) / 8).rounded(.up)))
        return groups.enumerated().filter { $0.offset % step == 0 }.map { name($0.element) }
    }

    func color(series index: Int) -> Color {
        DocOptionColor.color(series[index].color ?? Self.palette[index % Self.palette.count])
    }

    /// A mark's colour: its series', a group's option's in a ring; quiet beside a highlight.
    func color(_ group: CollectionChartData.Group, series index: Int) -> Color {
        var color = color(series: index)
        if chart.kind == .donut, let option = DocFieldText.options(axis).first(where: { $0.id.description == group.key }) {
            color = DocOptionColor.color(DocOptionColor.token(option, in: DocFieldText.options(axis)))
        } else if chart.kind == .donut {
            color = DocOptionColor.color(Self.palette[(groups.firstIndex(of: group) ?? 0) % Self.palette.count])
        }
        guard highlights, !group.highlighted else { return color }
        return series.count == 1 && chart.kind != .donut ? Tokens.ColorRole.Content.tertiary.opacity(0.5) : color.opacity(0.45)
    }

    func text(_ value: Double?) -> String {
        guard let value else { return "–" }
        return data.format?.text(value, locale: .current) ?? value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// What a group comes to: its one value, or its parts' sum when stacked.
    func label(_ group: CollectionChartData.Group) -> String {
        if series.count == 1 || stacks { return text(series.count == 1 ? group.values[0] : group.total) }
        return group.values.map(text).joined(separator: " · ")
    }

    var largest: Double {
        let values = stacks ? groups.map(\.total) : groups.flatMap { $0.values.compactMap { $0 } }
        return max(values.max() ?? 0, 0)
    }
}

/// Bars across: a group's name, its bar (its series side by side, or stacked), its value.
private struct DocChartBars: View {
    let plot: DocChartPlot
    @Binding var selected: String?
    let menu: (CollectionChartData.Group) -> [FlooDesignActionMenuSection]

    var body: some View {
        // The names as wide as the widest, up to a point past which they wrap.
        let names = min(plot.groups.map { DocCollectionWidths.width(plot.name($0), size: 13, weight: .semibold) }.max() ?? 0, 220) + 2
        Grid(alignment: .leading, horizontalSpacing: Tokens.Space.md, verticalSpacing: Tokens.Space.xs) {
            ForEach(plot.groups, id: \.key) { group in
                GridRow {
                    Text(plot.name(group))
                        .font(.system(size: 13, weight: group.highlighted ? .semibold : .regular))
                        .foregroundStyle(Tokens.ColorRole.Content.primary)
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
                .flooDesignContextMenu { _ in menu(group) }
            }
        }
    }

    @ViewBuilder
    private func bars(_ group: CollectionChartData.Group) -> some View {
        GeometryReader { proxy in
            let length = { (value: Double?) -> CGFloat in
                plot.largest > 0 ? CGFloat(max(value ?? 0, 0) / plot.largest) * proxy.size.width : 0
            }
            if plot.stacks || plot.series.count == 1 {
                HStack(spacing: 0) {
                    ForEach(plot.series.indices, id: \.self) { index in
                        Rectangle().fill(plot.color(group, series: index)).frame(width: length(group.values[index]))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .frame(height: 16)
                .frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(plot.series.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(plot.color(group, series: index))
                            .frame(width: length(group.values[index]), height: 10)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(height: plot.stacks || plot.series.count == 1 ? 20 : CGFloat(plot.series.count) * 12)
    }
}

/// Bars up or a line, in Swift Charts: the groups along the bottom in their order.
private struct DocChartAxes: View {
    let plot: DocChartPlot
    @Binding var selected: String?
    let menu: (CollectionChartData.Group) -> [FlooDesignActionMenuSection]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            if let key = selected, let group = plot.groups.first(where: { $0.key == key }) {
                Text("\(plot.name(group)) · \(plot.label(group))")
                    .font(.system(size: 12, weight: .semibold))
            }
            Chart {
                ForEach(plot.groups, id: \.key) { group in
                    ForEach(plot.series.indices, id: \.self) { index in
                        if let value = group.values[index] {
                            mark(group, index, value)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartXAxis { AxisMarks(values: plot.labelled) }
            .chartYAxis { AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let number = value.as(Double.self) { Text(plot.text(number)) } }
            } }
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
                                    .flooDesignContextMenu { _ in menu(group) }
                            }
                        }
                    }
                }
            }
            .frame(height: 220)
        }
    }

    @ChartContentBuilder
    private func mark(_ group: CollectionChartData.Group, _ index: Int, _ value: Double) -> some ChartContent {
        let x = PlottableValue.value("Group", plot.name(group))
        let y = PlottableValue.value("Value", value)
        let series = PlottableValue.value("Series", plot.series[index].name)
        let last = group.key == plot.groups.last?.key
        if plot.chart.kind == .line {
            LineMark(x: x, y: y, series: series)
                .foregroundStyle(plot.color(series: index))
                .interpolationMethod(.monotone)
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
                    if (plot.chart.showsValues || selected == group.key) && index == plot.series.count - 1 {
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
    let menu: (CollectionChartData.Group) -> [FlooDesignActionMenuSection]

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
            .frame(width: 180, height: 180)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(plot.groups, id: \.key) { group in
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
                    .flooDesignContextMenu { _ in menu(group) }
                }
            }
            .frame(maxWidth: 260)
        }
    }
}
