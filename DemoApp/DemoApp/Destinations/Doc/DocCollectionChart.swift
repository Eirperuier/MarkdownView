//
//  DocCollectionChart.swift
//  DemoApp
//
//  A collection's chart view: a mark for each group of the records the view shows by the
//  field it groups by (its axis, the Group panel's: the same groups, order and ones left
//  out as a kanban's columns), as long as its calculation makes the group's values
//  (DocKit's CollectionView.chartData), drawn as its style says (CollectionChartStyle).
//  - bars across, a group's name beside each; bars up and a line by floo's chart engine; a
//    ring with its groups listed beside it (DocCollectionChartView draws them);
//  - several values side by side or stacked, or one split by a select's options in their
//    colours, with a legend; highlighted groups in colour, the rest quieter; the groups
//    past a limit as one, Other, in gray; a reference line at a value;
//  - a click on a group shows its values; its right-click menu opens its record (a group of
//    one), highlights it, shows only it or hides it; a right-click elsewhere on the chart
//    opens its settings (DocChartSettings).
//

import FlooUIKit
import SwiftUI
import DocKit

private typealias Tokens = DocTokens

/// The chart where a collection is SwiftUI's (DocCollectionView): the UIKit one, the same.
struct DocCollectionChart: UIViewRepresentable {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let chart: CollectionChart
    let controller: DocCollectionController

    func makeUIView(context: Context) -> DocCollectionChartView { DocCollectionChartView() }

    func updateUIView(_ uiView: DocCollectionChartView, context: Context) {
        uiView.show(snapshot, view: view, chart: chart, controller: controller)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DocCollectionChartView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: DocCollectionChartView.height(snapshot, view: view, chart: chart, controller: controller, width: width))
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
