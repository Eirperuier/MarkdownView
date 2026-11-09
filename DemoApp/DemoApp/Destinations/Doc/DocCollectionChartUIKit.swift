//
//  DocCollectionChartUIKit.swift
//  DemoApp
//
//  A collection's chart view in UIKit, in the collection block as its table and kanban are
//  (what DocCollectionChart drew, from the same DocChartPlot):
//  - bars across: a group's name, its bars, its value, in rows of views;
//  - bars up and a line: floo's chart engine (EngineChart, its ChartUIView), its marks and
//    axes in its own layers;
//  - a ring by the engine, its groups listed beside it;
//  - its legend over it; a click on a group shows its values; its right-click menu opens its
//    record, highlights it, shows only it or hides it; elsewhere on the chart its settings.
//

import DocKit
import EngineChart
import FlooUIKit
import SwiftUI
import UIKit

private typealias Tokens = DocTokens

@MainActor
final class DocCollectionChartView: UIView {
    private var snapshot: DocCollectionSnapshot?
    private var view: CollectionView?
    private var chart: CollectionChart?
    private weak var controller: DocCollectionController?
    private var plot: DocChartPlot?

    private let note = UILabel()
    private let legend = UIView()
    private let bars = DocChartBarsView()
    private let picked = UILabel()
    private var engine: ChartUIView?
    private let ringList = DocChartRingList()

    /// The group whose values show, by block: kept while the row scrolls away.
    private(set) static var selections: [DocBlockID: String] = [:]
    /// Its height changed from within (a group picked shows its values over the chart).
    var heightChanged: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        note.font = .systemFont(ofSize: 13)
        note.textColor = UIColor(Tokens.ColorRole.Content.tertiary)
        note.textAlignment = .center
        note.numberOfLines = 0
        picked.font = .systemFont(ofSize: 12, weight: .semibold)
        picked.textColor = .floo(.label)
        [note, legend, bars, picked, ringList].forEach(addSubview)
        bars.pick = { [weak self] key in self?.pick(key) }
        bars.menu = { [weak self] group in self?.menu(group) ?? [] }
        ringList.pick = { [weak self] key in self?.pick(key) }
        ringList.menu = { [weak self] group in self?.menu(group) ?? [] }
        flooAddContextMenu { [weak self] in self?.settingsMenu() ?? [] }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var block: DocBlockID? { snapshot?.block }
    private var selected: String? { block.flatMap { Self.selections[$0] } }

    // MARK: Showing

    func show(_ snapshot: DocCollectionSnapshot, view: CollectionView, chart: CollectionChart, controller: DocCollectionController) {
        self.snapshot = snapshot
        self.view = view
        self.chart = chart
        self.controller = controller
        render()
    }

    private func render() {
        guard let snapshot, let view, let chart, let controller else { return }
        let plot = Self.plot(snapshot, view: view, chart: chart, controller: controller)
        self.plot = plot
        note.isHidden = plot != nil
        note.text = Self.noteText(snapshot, chart: chart)
        let kind = plot.map { _ in chart.kind }
        bars.isHidden = kind != .bar
        picked.isHidden = true
        ringList.isHidden = kind != .donut
        engine?.isHidden = kind != .column && kind != .line && kind != .donut
        showLegend(plot)
        guard let plot else { return setNeedsLayout() }
        switch chart.kind {
        case .bar:
            bars.show(plot, selected: selected)
        case .column, .line:
            if let key = selected, let group = plot.groups.first(where: { $0.key == key }) {
                picked.text = "\(plot.name(group)) · \(plot.label(group))"
                picked.isHidden = false
            }
            showEngine(DocChartAxesChart(plot: plot, selected: selected, pick: { [weak self] in self?.pick($0) },
                                         menu: { [weak self] in self?.menu($0) ?? [] }).chart)
        case .donut:
            showEngine(DocChartAxesChart.ring(plot, selected: selected))
            ringList.show(plot, selected: selected)
        }
        setNeedsLayout()
    }

    private func showEngine(_ chart: some View) {
        if let engine {
            engine.update(chart)
        } else {
            let engine = ChartUIView(chart)
            engine.backgroundColor = .clear
            addSubview(engine)
            self.engine = engine
        }
    }

    private func pick(_ key: String) {
        guard let block else { return }
        Self.selections[block] = Self.selections[block] == key ? nil : key
        let before = bounds.height
        render()
        if let snapshot, let view, let chart, let controller,
           Self.height(snapshot, view: view, chart: chart, controller: controller, width: bounds.width) != before {
            heightChanged?()
        }
    }

    func reset() {
        engine?.removeFromSuperview()
        engine = nil
    }

    // MARK: Legend

    private func showLegend(_ plot: DocChartPlot?) {
        legend.subviews.forEach { $0.removeFromSuperview() }
        guard let plot else { return }
        for item in Self.legendItems(plot) {
            let swatch = UIView()
            swatch.backgroundColor = item.color
            swatch.layer.cornerRadius = item.isLine ? 0 : 3
            let label = UILabel()
            label.font = .systemFont(ofSize: 12)
            label.textColor = item.isLine ? item.color : UIColor(Tokens.ColorRole.Content.secondary)
            label.text = item.text
            legend.addSubview(swatch)
            legend.addSubview(label)
        }
    }

    /// The series' colours and names when there are several, and the reference line's.
    private static func legendItems(_ plot: DocChartPlot) -> [(color: UIColor, text: String, isLine: Bool)] {
        guard plot.style.legend else { return [] }
        var items: [(UIColor, String, Bool)] = []
        if plot.series.count > 1 {
            items += plot.series.indices.map { (UIColor(plot.color(series: $0)), plot.name(series: $0), false) }
        }
        if let reference = plot.style.reference, plot.chart.kind == .bar {
            items.append((UIColor(DocChartPlot.referenceColor), plot.referenceText(reference), true))
        }
        return items
    }

    private static let legendHeight: CGFloat = 16

    // MARK: Menus

    private func settingsMenu() -> [FlooMenuSection] {
        guard let controller, controller.isEditable, let block else { return [] }
        return [.init([.action(String(localized: "Chart Settings…"), symbol: "slider.horizontal.3") { controller.show(.chart, in: block) }])]
    }

    /// A group's right-click menu.
    private func menu(_ group: CollectionChartData.Group) -> [FlooMenuSection] {
        guard let snapshot, let view, let controller else { return [] }
        let block = snapshot.block
        let database = snapshot.database
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

    // MARK: Measuring

    private static func plot(_ snapshot: DocCollectionSnapshot, view: CollectionView, chart: CollectionChart, controller: DocCollectionController) -> DocChartPlot? {
        let database = snapshot.database
        guard chart.problem(in: database) == nil, let axis = database.columns.first(where: { $0.id == chart.groupBy }),
              let data = view.chartData(of: controller.rows(snapshot, view), in: database), !data.groups.isEmpty else { return nil }
        return DocChartPlot(data: data, chart: chart, axis: axis, database: database)
    }

    private static func noteText(_ snapshot: DocCollectionSnapshot, chart: CollectionChart) -> String {
        if let problem = chart.problem(in: snapshot.database) { return problem.prefix(1).uppercased() + problem.dropFirst() + "." }
        return String(localized: "No records to chart.")
    }

    private static let noteHeight: CGFloat = 80
    private static let pickedHeight: CGFloat = ceil(UIFont.systemFont(ofSize: 12, weight: .semibold).lineHeight)

    /// Its height at a width: its padding, its legend, what its kind draws.
    static func height(_ snapshot: DocCollectionSnapshot, view: CollectionView, chart: CollectionChart,
                       controller: DocCollectionController, width: CGFloat) -> CGFloat {
        guard let plot = plot(snapshot, view: view, chart: chart, controller: controller) else { return noteHeight }
        var height = Tokens.Space.xs * 2
        if !legendItems(plot).isEmpty { height += legendHeight + Tokens.Space.sm }
        switch chart.kind {
        case .bar:
            height += DocChartBarsView.height(plot, selected: selections[snapshot.block], width: width)
        case .column, .line:
            let selected = selections[snapshot.block]
            if let selected, plot.groups.contains(where: { $0.key == selected }) { height += pickedHeight + Tokens.Space.xs }
            height += plot.plotHeight
        case .donut:
            height += max(plot.ringSize, DocChartRingList.height(plot))
        }
        return height
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let plot, let chart else {
            note.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.noteHeight)
            return
        }
        var y = Tokens.Space.xs
        let items = Self.legendItems(plot)
        if !items.isEmpty {
            legend.frame = CGRect(x: 0, y: y, width: bounds.width, height: Self.legendHeight)
            var x: CGFloat = 0
            let views = legend.subviews
            for (index, item) in items.enumerated() {
                let swatch = views[index * 2], label = views[index * 2 + 1] as! UILabel
                swatch.frame = item.isLine ? CGRect(x: x, y: 2, width: 2, height: 12) : CGRect(x: x, y: 3, width: 10, height: 10)
                x = swatch.frame.maxX + Tokens.Space.xs
                let width = ceil(label.intrinsicContentSize.width)
                label.frame = CGRect(x: x, y: 0, width: width, height: Self.legendHeight)
                x += width + Tokens.Space.md
            }
            y += Self.legendHeight + Tokens.Space.sm
        }
        legend.isHidden = items.isEmpty
        switch chart.kind {
        case .bar:
            bars.frame = CGRect(x: 0, y: y, width: bounds.width, height: DocChartBarsView.height(plot, selected: selected, width: bounds.width))
        case .column, .line:
            if !picked.isHidden {
                picked.frame = CGRect(x: 0, y: y, width: bounds.width, height: Self.pickedHeight)
                y += Self.pickedHeight + Tokens.Space.xs
            }
            engine?.frame = CGRect(x: 0, y: y, width: bounds.width, height: plot.plotHeight)
        case .donut:
            let listHeight = DocChartRingList.height(plot)
            let rowHeight = max(plot.ringSize, listHeight)
            let listWidth = plot.style.legend ? min(260, max(0, bounds.width - plot.ringSize - Tokens.Space.xl)) : 0
            engine?.frame = CGRect(x: 0, y: y + (rowHeight - plot.ringSize) / 2, width: plot.ringSize, height: plot.ringSize)
            ringList.isHidden = !plot.style.legend
            ringList.frame = CGRect(x: plot.ringSize + Tokens.Space.xl, y: y + (rowHeight - listHeight) / 2, width: listWidth, height: listHeight)
        }
    }
}

// MARK: - Bars up, a line, a ring: the engine's

/// The chart the engine draws for bars up or a line: the groups along the bottom in their
/// order, the value up the side; a click on a group's band picks it, its menu is its own.
@MainActor
private struct DocChartAxesChart {
    let plot: DocChartPlot
    let selected: String?
    let pick: (String) -> Void
    let menu: (CollectionChartData.Group) -> [FlooMenuSection]

    var chart: some View {
        let plot = plot
        let step = max(1, Int((Double(plot.groups.count) / 8).rounded(.up)))
        return Chart {
            for group in plot.groups {
                for index in plot.series.indices {
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
        .chartYScale(domain: plot.domain)
        .chartXAxis {
            AxisMarks { value in
                if plot.style.grid { AxisGridLine() }
                if value.index % step == 0 { AxisValueLabel() }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                if plot.style.grid { AxisGridLine() }
                AxisValueLabel(value.as(Double.self).map(plot.text))
            }
        }
        .chartXAxisLabel(plot.style.axisNames ? plot.axis.name : "")
        .chartYAxisLabel(plot.style.axisNames ? plot.valueName : "")
        .chartOverlay { proxy in
            let frame = proxy.plotFrame
            let band = frame.width / CGFloat(max(plot.groups.count, 1))
            ZStack(alignment: .topLeading) {
                ForEach(Array(plot.groups.enumerated()), id: \.element.key) { index, group in
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: band, height: frame.height)
                        .position(x: frame.minX + band * (CGFloat(index) + 0.5), y: frame.midY)
                        .onTapGesture { pick(group.key) }
                        .flooContextMenu { menu(group) }
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
        let shows = selected == group.key
        if plot.chart.kind == .line {
            if plot.style.area {
                AreaMark(x: x, y: y, series: series, stacking: .unstacked)
                    .foregroundStyle(.linearGradient(colors: [plot.color(series: index).opacity(0.35), plot.color(series: index).opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(plot.style.smooth ? .monotone : .linear)
            }
            LineMark(x: x, y: y, series: series)
                .foregroundStyle(plot.color(series: index))
                .interpolationMethod(plot.style.smooth ? .monotone : .linear)
            PointMark(x: x, y: y)
                .foregroundStyle(plot.color(group, series: index))
                .symbolSize(group.highlighted || shows ? 70 : 30)
                .annotation(position: .top, spacing: 4) {
                    if plot.chart.showsValues && (last || group.highlighted) || shows {
                        Text(plot.text(value)).font(.system(size: 11, weight: .semibold))
                    }
                }
        } else if plot.stacks || plot.series.count == 1 {
            BarMark(x: x, y: y, width: .ratio(0.6))
                .foregroundStyle(plot.color(group, series: index))
                .cornerRadius(3)
                .annotation(position: .top, spacing: 3) {
                    // The total over the top part the group has.
                    if (plot.chart.showsValues || shows) && index == group.values.lastIndex(where: { ($0 ?? 0) != 0 }) {
                        Text(plot.label(group)).font(.system(size: 11)).foregroundStyle(Tokens.ColorRole.Content.secondary)
                    }
                }
        } else {
            BarMark(x: x, y: y, width: .ratio(0.8))
                .foregroundStyle(plot.color(group, series: index))
                .position(by: series)
                .cornerRadius(3)
                .annotation(position: .top, spacing: 3) {
                    if plot.chart.showsValues || shows {
                        Text(plot.text(value)).font(.system(size: 10)).foregroundStyle(Tokens.ColorRole.Content.secondary)
                    }
                }
        }
    }

    /// A ring: each group's share of the whole, the whole (or the group picked) in its middle.
    static func ring(_ plot: DocChartPlot, selected: String?) -> some View {
        let total = plot.groups.reduce(0) { $0 + max($1.total, 0) }
        let group = selected.flatMap { key in plot.groups.first { $0.key == key } }
        return Chart(plot.groups, id: \.key) { group in
            SectorMark(angle: .value("Value", max(group.total, 0)), innerRadius: .ratio(0.62), angularInset: 1.5)
                .foregroundStyle(plot.color(group, series: 0))
                .cornerRadius(3)
        }
        .chartBackground { (_: EngineChart.ChartProxy) in
            VStack(spacing: 0) {
                Text(plot.text(group?.total ?? total)).font(.system(size: 22, weight: .bold).monospacedDigit())
                Text(group.map(plot.name) ?? (plot.series.isEmpty ? "" : plot.name(series: 0)))
                    .font(.system(size: 11)).foregroundStyle(Tokens.ColorRole.Content.secondary).lineLimit(1)
            }
            .padding(.horizontal, 30)
        }
    }
}

// MARK: - Bars across

/// Bars across: a group's name, its bar (its series side by side, or stacked), its value; a
/// click on a row picks it.
@MainActor
private final class DocChartBarsView: UIView {
    var pick: ((String) -> Void)?
    var menu: ((CollectionChartData.Group) -> [FlooMenuSection])?
    private var plot: DocChartPlot?
    private var selected: String?
    private var rows: [Row] = []
    private let headName = UILabel()
    private let headValue = UILabel()

    private static let nameFont = UIFont.systemFont(ofSize: 13)
    private static let strongNameFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
    private static let valueFont = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let strongValueFont = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static let headFont = UIFont.systemFont(ofSize: 11, weight: .medium)
    private static let rowPadding: CGFloat = 3

    /// A group's row: its name, its bars, its value, its fill while picked.
    private final class Row: UIView {
        let name = UILabel()
        let value = UILabel()
        let track = UIView()
        var parts: [UIView] = []
        let reference = UIView()
        var key = ""

        override init(frame: CGRect) {
            super.init(frame: frame)
            name.numberOfLines = 2
            layer.cornerRadius = Tokens.Radius.xs
            layer.cornerCurve = .continuous
            track.clipsToBounds = true
            reference.backgroundColor = UIColor(DocChartPlot.referenceColor)
            [name, track, value].forEach(addSubview)
            track.addSubview(reference)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for head in [headName, headValue] {
            head.font = Self.headFont
            head.textColor = UIColor(Tokens.ColorRole.Content.tertiary)
            addSubview(head)
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        flooAddContextMenu(at: { [weak self] point in
            guard let self, let row = self.row(at: point), let group = self.plot?.groups.first(where: { $0.key == row.key }) else { return [] }
            return self.menu?(group) ?? []
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func row(at point: CGPoint) -> Row? { rows.first { $0.frame.contains(point) } }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard let row = row(at: tap.location(in: self)) else { return }
        pick?(row.key)
    }

    func show(_ plot: DocChartPlot, selected: String?) {
        self.plot = plot
        self.selected = selected
        headName.isHidden = !plot.style.axisNames
        headValue.isHidden = !plot.style.axisNames
        headName.text = plot.axis.name
        headValue.text = plot.valueName
        while rows.count < plot.groups.count {
            let row = Row()
            addSubview(row)
            rows.append(row)
        }
        while rows.count > plot.groups.count { rows.removeLast().removeFromSuperview() }
        let single = plot.stacks || plot.series.count == 1
        for (row, group) in zip(rows, plot.groups) {
            row.key = group.key
            row.name.text = plot.name(group)
            row.name.font = group.highlighted ? Self.strongNameFont : Self.nameFont
            row.name.textColor = group.isOther ? UIColor(Tokens.ColorRole.Content.secondary) : UIColor(Tokens.ColorRole.Content.primary)
            row.value.text = Self.showsValue(plot, group, selected: selected) ? plot.label(group) : nil
            row.value.font = group.highlighted ? Self.strongValueFont : Self.valueFont
            row.value.textColor = group.highlighted ? UIColor(Tokens.ColorRole.Content.primary) : UIColor(Tokens.ColorRole.Content.secondary)
            row.backgroundColor = selected == group.key ? UIColor(Tokens.ColorRole.Surface.selected) : nil
            while row.parts.count < plot.series.count {
                let part = UIView()
                part.layer.cornerCurve = .continuous
                row.track.insertSubview(part, belowSubview: row.reference)
                row.parts.append(part)
            }
            while row.parts.count > plot.series.count { row.parts.removeLast().removeFromSuperview() }
            for (index, part) in row.parts.enumerated() {
                part.backgroundColor = UIColor(plot.color(group, series: index))
                part.layer.cornerRadius = single ? 0 : 3
            }
            row.track.layer.cornerRadius = single ? 4 : 0
            row.track.layer.cornerCurve = .continuous
            row.reference.isHidden = plot.style.reference == nil
        }
        setNeedsLayout()
    }

    private static func showsValue(_ plot: DocChartPlot, _ group: CollectionChartData.Group, selected: String?) -> Bool {
        plot.chart.showsValues || selected == group.key
    }

    /// The names as wide as the widest, up to a point past which they wrap.
    private static func namesWidth(_ plot: DocChartPlot) -> CGFloat {
        min(plot.groups.map { DocCollectionWidths.width(plot.name($0), size: 13, weight: .semibold) }.max() ?? 0, 220) + 2
    }

    private static func valuesWidth(_ plot: DocChartPlot, selected: String?) -> CGFloat {
        plot.groups.filter { showsValue(plot, $0, selected: selected) }.map { group in
            ceil((plot.label(group) as NSString).size(withAttributes: [.font: group.highlighted ? strongValueFont : valueFont]).width)
        }.max() ?? 0
    }

    private static func barsHeight(_ plot: DocChartPlot) -> CGFloat {
        plot.stacks || plot.series.count == 1 ? plot.barThickness + 4 : CGFloat(plot.series.count) * (plot.barThickness * 0.65 + 2)
    }

    private static func rowHeight(_ plot: DocChartPlot, _ group: CollectionChartData.Group, names: CGFloat) -> CGFloat {
        let font = group.highlighted ? strongNameFont : nameFont
        let text = (plot.name(group) as NSString).boundingRect(with: CGSize(width: names, height: .greatestFiniteMagnitude),
                                                               options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
        let name = min(ceil(text.height), ceil(font.lineHeight * 2))
        return max(name, barsHeight(plot)) + rowPadding * 2
    }

    private static var headHeight: CGFloat { ceil(headFont.lineHeight) }

    static func height(_ plot: DocChartPlot, selected: String?, width: CGFloat) -> CGFloat {
        let names = namesWidth(plot)
        let rows = plot.groups.map { rowHeight(plot, $0, names: names) }
        var height = rows.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * Tokens.Space.xs
        if plot.style.axisNames { height += headHeight + Tokens.Space.xs }
        return height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let plot else { return }
        let names = Self.namesWidth(plot)
        let values = Self.valuesWidth(plot, selected: selected)
        let spacing = Tokens.Space.md
        let barsX = names + spacing
        let barsWidth = max(0, bounds.width - barsX - spacing - values)
        var y: CGFloat = 0
        if plot.style.axisNames {
            headName.frame = CGRect(x: 0, y: 0, width: names, height: Self.headHeight)
            headValue.frame = CGRect(x: barsX, y: 0, width: barsWidth, height: Self.headHeight)
            y += Self.headHeight + Tokens.Space.xs
        }
        let domain = plot.domain
        let span = max(domain.upperBound - domain.lowerBound, .leastNonzeroMagnitude)
        // From the axis's start to a value.
        let x = { (value: Double) -> CGFloat in CGFloat((min(max(value, domain.lowerBound), domain.upperBound) - domain.lowerBound) / span) * barsWidth }
        let single = plot.stacks || plot.series.count == 1
        let barsHeight = Self.barsHeight(plot)
        for (row, group) in zip(rows, plot.groups) {
            let height = Self.rowHeight(plot, group, names: names)
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            row.name.frame = CGRect(x: 0, y: 0, width: names, height: height)
            row.value.frame = CGRect(x: bounds.width - values, y: 0, width: values, height: height)
            if single {
                let thickness = plot.barThickness
                row.track.frame = CGRect(x: barsX, y: (height - thickness) / 2, width: barsWidth, height: thickness)
                // Stacked parts end where the parts before them end, drawn from the last back.
                var end = 0.0
                for (index, part) in row.parts.enumerated() {
                    end += group.values[index] ?? 0
                    let width = max(x(plot.series.count == 1 ? group.values[index] ?? 0 : end), 0)
                    part.frame = CGRect(x: 0, y: 0, width: width, height: thickness)
                    row.track.sendSubviewToBack(part)
                }
            } else {
                let thickness = plot.barThickness * 0.65
                row.track.frame = CGRect(x: barsX, y: (height - barsHeight) / 2, width: barsWidth, height: barsHeight)
                for (index, part) in row.parts.enumerated() {
                    part.frame = CGRect(x: 0, y: CGFloat(index) * (thickness + 2), width: x(group.values[index] ?? 0), height: thickness)
                }
            }
            if let reference = plot.style.reference {
                row.reference.frame = CGRect(x: x(reference.value) - 1, y: 0, width: 2, height: row.track.bounds.height)
            }
            y += height + Tokens.Space.xs
        }
    }
}

// MARK: - A ring's groups

/// The groups beside a ring: each one's colour, name, value and share; a click picks it.
@MainActor
private final class DocChartRingList: UIView {
    var pick: ((String) -> Void)?
    var menu: ((CollectionChartData.Group) -> [FlooMenuSection])?
    private var plot: DocChartPlot?
    private var rows: [Row] = []

    private static let rowHeight: CGFloat = ceil(UIFont.systemFont(ofSize: 13).lineHeight) + 8
    private static let rowSpacing: CGFloat = 2

    private final class Row: UIView {
        let swatch = UIView()
        let name = UILabel()
        let value = UILabel()
        let share = UILabel()
        var key = ""

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.cornerRadius = Tokens.Radius.xs
            layer.cornerCurve = .continuous
            swatch.layer.cornerRadius = 3
            value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            share.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            share.textColor = UIColor(Tokens.ColorRole.Content.secondary)
            share.textAlignment = .right
            value.textAlignment = .right
            [swatch, name, value, share].forEach(addSubview)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let inset = Tokens.Space.xs
            swatch.frame = CGRect(x: inset, y: (bounds.height - 12) / 2, width: 12, height: 12)
            let shareWidth = max(36, ceil(share.intrinsicContentSize.width))
            share.frame = CGRect(x: bounds.width - inset - shareWidth, y: 0, width: shareWidth, height: bounds.height)
            let valueWidth = value.text == nil ? 0 : ceil(value.intrinsicContentSize.width)
            value.frame = CGRect(x: share.frame.minX - Tokens.Space.sm - valueWidth, y: 0, width: valueWidth, height: bounds.height)
            let nameX = swatch.frame.maxX + Tokens.Space.sm
            name.frame = CGRect(x: nameX, y: 0, width: max(0, value.frame.minX - Tokens.Space.md - nameX), height: bounds.height)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        flooAddContextMenu(at: { [weak self] point in
            guard let self, let row = self.rows.first(where: { $0.frame.contains(point) }),
                  let group = self.plot?.groups.first(where: { $0.key == row.key }) else { return [] }
            return self.menu?(group) ?? []
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        guard let row = rows.first(where: { $0.frame.contains(point) }) else { return }
        pick?(row.key)
    }

    func show(_ plot: DocChartPlot, selected: String?) {
        self.plot = plot
        while rows.count < plot.groups.count {
            let row = Row()
            addSubview(row)
            rows.append(row)
        }
        while rows.count > plot.groups.count { rows.removeLast().removeFromSuperview() }
        let total = plot.groups.reduce(0) { $0 + max($1.total, 0) }
        for (row, group) in zip(rows, plot.groups) {
            row.key = group.key
            row.swatch.backgroundColor = UIColor(plot.color(group, series: 0))
            row.name.text = plot.name(group)
            row.name.font = .systemFont(ofSize: 13, weight: group.highlighted ? .semibold : .regular)
            row.value.text = plot.chart.showsValues ? plot.text(group.total) : nil
            row.share.text = total > 0 ? (max(group.total, 0) / total).formatted(.percent.precision(.fractionLength(0))) : "–"
            row.backgroundColor = selected == group.key ? UIColor(Tokens.ColorRole.Surface.selected) : nil
            row.setNeedsLayout()
        }
        setNeedsLayout()
    }

    static func height(_ plot: DocChartPlot) -> CGFloat {
        guard plot.style.legend else { return 0 }
        let count = CGFloat(plot.groups.count)
        return count * rowHeight + max(0, count - 1) * rowSpacing
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(index) * (Self.rowHeight + Self.rowSpacing), width: bounds.width, height: Self.rowHeight)
        }
    }
}
