//
//  DocCollectionTableUIKit.swift
//  DemoApp
//
//  A collection's table view in UIKit (what DocCollectionTable drew, Craft's): a row number,
//  the view's fields in its order with their type's symbol, their cells (DocCollectionCellView).
//  - a field's head opens its menu (edit it, sort, filter or group by it, hide or delete it);
//    + after the last adds a field;
//  - over a row (or with rows picked) its number is the box that picks it, and the title
//    shows the arrow that opens the record;
//  - a row's right-click menu opens it, adds a row above or below, clears the cell, copies
//    or deletes it;
//  - grouped, the records go under a head for each group, which folds them away;
//  - the calculation row computes a column; + adds a record.
//  Each column as wide as its widest cell or its head up to a cap past which its cells wrap,
//  stretched to fill the block when there's room; past it the table scrolls sideways out to
//  the page's edges.
//

import DocKit
import FlooUIKit
import UIKit

private typealias Metrics = DocCollectionMetrics

/// The table's parts down its length, and where each goes.
@MainActor
struct DocTablePlan {
    enum Part {
        case head
        case group(CollectionGroup, Column)
        case record(Row, number: Int)
        case foot
    }

    let columns: [Column]
    let widths: [CGFloat]
    let titleColumn: Column?
    let rows: [Row]
    /// Each part, its top and height; a line between each and the next.
    let parts: [(part: Part, y: CGFloat, height: CGFloat)]
    let width: CGFloat
    let height: CGFloat

    static var line: CGFloat { 1 / max(UITraitCollection.current.displayScale, 1) }

    init(snapshot: DocCollectionSnapshot, view: CollectionView, controller: DocCollectionController, width available: CGFloat) {
        let rows = controller.rows(snapshot, view)
        let columns = DocCollectionController.fields(view, of: snapshot.database)
        let titleColumn = DocCollectionController.titleColumn(of: snapshot.database)
        let trailing = controller.isEditable ? Metrics.addFieldWidth : 0
        // Each column as wide as its widest cell or its head on one line, up to the cap.
        let natural = columns.map { column in
            let isTitle = column.id == titleColumn?.id
            let widest = rows.map { DocCollectionWidths.cell($0.cells[column.id], in: column, isTitle: isTitle) }.max() ?? 0
            return min(max(widest, DocCollectionWidths.head(column), Metrics.minFieldWidth), Metrics.maxFieldWidth)
        }
        let fixed = Metrics.numberWidth + trailing
        let total = natural.reduce(0, +)
        let widths = available > total + fixed && total > 0 ? natural.map { $0 + (available - fixed - total) * $0 / total } : natural
        let line = Self.line

        var parts: [(Part, CGFloat, CGFloat)] = [(.head, 0, Metrics.headHeight)]
        var y = Metrics.headHeight
        func add(_ part: Part, _ height: CGFloat) {
            y += line
            parts.append((part, y, height))
            y += height
        }
        func recordHeight(_ row: Row) -> CGFloat {
            zip(columns, widths).map { column, width in
                DocCollectionCellView.height(of: row, column: column, isTitle: column.id == titleColumn?.id, compact: false,
                                             hasPage: controller.hasPage?(row.id) == true, width: width - 2 * Metrics.cellInset)
            }.max().map { max($0, Metrics.rowHeight) } ?? Metrics.rowHeight
        }
        let folded = DocTableFolds.folded[snapshot.block] ?? []
        if let groups = view.groups(of: rows, in: snapshot.database), let column = snapshot.database.columns.first(where: { $0.id == view.layout.groupBy }) {
            for group in groups {
                add(.group(group, column), Metrics.rowHeight)
                guard !folded.contains(group.key) else { continue }
                for (index, row) in group.rows.enumerated() { add(.record(row, number: index + 1), recordHeight(row)) }
            }
        } else {
            for (index, row) in rows.enumerated() { add(.record(row, number: index + 1), recordHeight(row)) }
        }
        add(.foot, Metrics.rowHeight)
        self.columns = columns
        self.widths = widths
        self.titleColumn = titleColumn
        self.rows = rows
        self.parts = parts
        width = fixed + widths.reduce(0, +) + CGFloat(columns.count + (controller.isEditable ? 1 : 0)) * line
        height = y
    }
}

/// The groups folded away in each block's table, by key (the table's, kept while it scrolls away).
@MainActor
enum DocTableFolds {
    static var folded: [DocBlockID: Set<String>] = [:]
}

@MainActor
final class DocCollectionTableView: UIScrollView {
    private let grid = UIView()
    private var snapshot: DocCollectionSnapshot?
    private var view: CollectionView?
    private weak var controller: DocCollectionController?
    private var plan: DocTablePlan?
    private var hover: DocHover!
    /// The pointer over a record, by id; over the calculation row.
    private var hoveredRow: RowID?
    private var overFoot = false

    // Parts kept by what they show.
    private let head = DocTableHeadView()
    private let foot = DocTableFootView()
    private var records: [RowID: DocTableRecordView] = [:]
    private var groupHeads: [String: DocTableGroupHeadView] = [:]
    private var lines: [UIView] = []

    /// Its height changed (a group folded): the block's row is told.
    var heightChanged: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = false
        // Scrolls out to the page's edges, as a plain table does.
        clipsToBounds = false
        grid.clipsToBounds = true
        grid.layer.cornerRadius = Metrics.corner
        grid.layer.cornerCurve = .continuous
        grid.layer.borderWidth = DocTokens.Border.hairline
        addSubview(grid)
        grid.addSubview(head)
        grid.addSubview(foot)
        hover = DocHover(on: grid) { [weak self] point in self?.hovered(point) }
        grid.flooAddContextMenu(at: { [weak self] point in self?.menu(at: point) ?? [] })
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.updateColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateColors() {
        grid.layer.borderColor = UIColor.floo(.separator).resolvedColor(with: traitCollection).cgColor
    }

    private var block: DocBlockID? { snapshot?.block }
    private var picked: Set<RowID> { block.flatMap { controller?.selectedRows[$0] } ?? [] }

    // MARK: Showing

    func show(_ snapshot: DocCollectionSnapshot, view: CollectionView, controller: DocCollectionController) {
        self.snapshot = snapshot
        self.view = view
        self.controller = controller
        render()
    }

    static func height(_ snapshot: DocCollectionSnapshot, view: CollectionView, controller: DocCollectionController, width: CGFloat) -> CGFloat {
        DocTablePlan(snapshot: snapshot, view: view, controller: controller, width: width).height
    }

    private func render() {
        guard let snapshot, let view, let controller else { return }
        let plan = DocTablePlan(snapshot: snapshot, view: view, controller: controller, width: bounds.width)
        self.plan = plan
        renderedWidth = bounds.width
        let picked = picked
        let line = DocTablePlan.line
        var usedRecords: Set<RowID> = [], usedGroups: Set<String> = []
        var lineIndex = 0
        func lineView(at y: CGFloat) {
            if lineIndex == lines.count {
                let divider = FlooDivider()
                grid.addSubview(divider)
                lines.append(divider)
            }
            lines[lineIndex].isHidden = false
            lines[lineIndex].frame = CGRect(x: 0, y: y, width: plan.width, height: line)
            lineIndex += 1
        }
        for (part, y, height) in plan.parts {
            if y > 0 { lineView(at: y - line) }
            let frame = CGRect(x: 0, y: y, width: plan.width, height: height)
            switch part {
            case .head:
                head.show(snapshot, view: view, columns: plan.columns, widths: plan.widths, controller: controller)
                head.frame = frame
            case .group(let group, let column):
                let groupHead = groupHeads[group.key] ?? {
                    let new = DocTableGroupHeadView()
                    new.toggle = { [weak self] key in self?.fold(key) }
                    grid.addSubview(new)
                    groupHeads[group.key] = new
                    return new
                }()
                usedGroups.insert(group.key)
                groupHead.show(group, column: column, isFolded: DocTableFolds.folded[snapshot.block]?.contains(group.key) == true)
                groupHead.frame = frame
            case .record(let row, let number):
                let record = records[row.id] ?? {
                    let new = DocTableRecordView()
                    grid.addSubview(new)
                    records[row.id] = new
                    return new
                }()
                usedRecords.insert(row.id)
                let isHovered = hoveredRow == row.id
                record.show(.init(snapshot: snapshot, row: row, number: number, columns: plan.columns, widths: plan.widths,
                                  titleColumn: plan.titleColumn, controller: controller, isHovered: isHovered, isPicked: picked.contains(row.id),
                                  anyPicked: !picked.isEmpty, menu: { [weak self] column in self?.menu(row, cell: column) ?? [] }))
                record.frame = frame
            case .foot:
                foot.show(snapshot, view: view, columns: plan.columns, widths: plan.widths, rows: plan.rows, controller: controller,
                          offers: overFoot || !DocTokens.Platform.isPointer)
                foot.frame = frame
            }
        }
        for index in lineIndex..<lines.count { lines[index].isHidden = true }
        for (id, record) in records where !usedRecords.contains(id) {
            record.reset()
            record.removeFromSuperview()
            records[id] = nil
        }
        for (key, groupHead) in groupHeads where !usedGroups.contains(key) {
            groupHead.removeFromSuperview()
            groupHeads[key] = nil
        }
        grid.frame = CGRect(x: 0, y: 0, width: plan.width, height: plan.height)
        contentSize = grid.frame.size
    }

    private var renderedWidth: CGFloat = -1

    override func layoutSubviews() {
        super.layoutSubviews()
        // The columns stretch with the block's width.
        if bounds.width != renderedWidth { render() }
    }

    /// Its panels follow the controller (the table's own, and each cell's).
    func followPanels() {
        head.followPanels()
        records.values.forEach { $0.followPanels() }
    }

    private func fold(_ key: String) {
        guard let block else { return }
        var folded = DocTableFolds.folded[block] ?? []
        if folded.contains(key) { folded.remove(key) } else { folded.insert(key) }
        DocTableFolds.folded[block] = folded
        render()
        heightChanged?()
    }

    // MARK: Pointer

    private func part(at point: CGPoint) -> DocTablePlan.Part? {
        plan?.parts.first { point.y >= $0.y && point.y < $0.y + $0.height }?.part
    }

    private func hovered(_ point: CGPoint?) {
        let part = point.flatMap(part(at:))
        var row: RowID?
        var foot = false
        switch part {
        case .record(let shown, _)?: row = shown.id
        case .foot?: foot = true
        default: break
        }
        guard row != hoveredRow || foot != overFoot else { return }
        hoveredRow = row
        overFoot = foot
        render()
    }

    /// The right-click menu of the record and cell at `point`.
    private func menu(at point: CGPoint) -> [FlooMenuSection] {
        guard let controller, controller.isEditable, let plan, case .record(let row, _)? = part(at: point) else { return [] }
        // The cell under it: the record's columns from the numbers' right.
        var x = Metrics.numberWidth
        var column: Column?
        for (shown, width) in zip(plan.columns, plan.widths) {
            if point.x >= x, point.x < x + width + DocTablePlan.line { column = shown }
            x += width + DocTablePlan.line
        }
        return menu(row, cell: column)
    }

    /// A record's right-click menu (Craft's): open it, a new row above or below, clear the
    /// cell clicked, copy or delete it. On a picked row: copy or delete the picked rows.
    private func menu(_ row: Row, cell column: Column?) -> [FlooMenuSection] {
        guard let controller, let block, let view else { return [] }
        let picked = picked
        let rows = picked.contains(row.id) ? picked : [row.id]
        let copyAndDelete = FlooMenuSection([
            .action(rows.count > 1 ? String(localized: "Duplicate \(rows.count) Rows") : String(localized: "Duplicate Row"),
                    symbol: "plus.square.on.square") { _ = controller.duplicate(rows: rows, in: block) },
            .action(rows.count > 1 ? String(localized: "Delete \(rows.count) Rows") : String(localized: "Delete Row"),
                    symbol: "trash", role: .destructive) { controller.delete(rows: rows, in: block) },
        ])
        guard !picked.contains(row.id) else { return [copyAndDelete] }
        var sections: [FlooMenuSection] = []
        if let open = controller.openRecord {
            sections.append(.init([.action(String(localized: "Open"), symbol: "arrow.right.circle") { open(row.id, block) }]))
        }
        sections.append(.init([
            .action(String(localized: "Insert Row Above"), symbol: "arrow.up.to.line") {
                _ = controller.insertRecord(beside: row.id, below: false, groupedBy: view.layout.groupBy, in: block)
            },
            .action(String(localized: "Insert Row Below"), symbol: "arrow.down.to.line") {
                _ = controller.insertRecord(beside: row.id, below: true, groupedBy: view.layout.groupBy, in: block)
            },
        ]))
        if let column {
            sections.append(.init([
                .action(String(localized: "Clear Cell Contents"), symbol: "eraser", isEnabled: row.cells[column.id] != nil) {
                    controller.set(nil, row: row.id, column: column.id, in: block)
                },
            ]))
        }
        sections.append(copyAndDelete)
        return sections
    }
}

// MARK: - The head

/// The fields' heads under the number's symbol, + after them.
@MainActor
private final class DocTableHeadView: UIView {
    private let number = UIImageView(image: UIImage(systemName: "number", withConfiguration: UIImage.SymbolConfiguration(pointSize: DocTokens.Icon.compact)))
    private var heads: [ColumnID: DocFieldHeadView] = [:]
    private var separators: [UIView] = []
    private var addField: FlooContentButton?
    private var addSpot: FlooPanelAnchorView?
    private var shown: (snapshot: DocCollectionSnapshot, columns: [Column], widths: [CGFloat], controller: DocCollectionController)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .floo(.markdownBlockDecoration)
        number.tintColor = .floo(.disabledLabel)
        number.contentMode = .center
        addSubview(number)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ snapshot: DocCollectionSnapshot, view: CollectionView, columns: [Column], widths: [CGFloat], controller: DocCollectionController) {
        shown = (snapshot, columns, widths, controller)
        var used: Set<ColumnID> = []
        for column in columns {
            let head = heads[column.id] ?? {
                let new = DocFieldHeadView()
                addSubview(new)
                heads[column.id] = new
                return new
            }()
            used.insert(column.id)
            head.show(snapshot, view: view, column: column, controller: controller)
        }
        for (id, head) in heads where !used.contains(id) {
            head.removeFromSuperview()
            heads[id] = nil
        }
        let needed = columns.count + (controller.isEditable ? 1 : 0)
        while separators.count < needed {
            let line = UIView()
            line.backgroundColor = .floo(.separator)
            addSubview(line)
            separators.append(line)
        }
        if controller.isEditable, addField == nil {
            let button = docSymbolButton("plus", side: Metrics.addFieldWidth, shape: .corner(0), title: String(localized: "Add Field")) { [weak self] in
                guard let self, let shown = self.shown else { return }
                shown.controller.show(.addField, in: shown.snapshot.block)
            }
            addSubview(button)
            addField = button
        }
        addField?.isHidden = !controller.isEditable
        followPanels()
        setNeedsLayout()
    }

    func followPanels() {
        heads.values.forEach { $0.followPanel() }
        guard let shown, let addField else { return }
        let spot = addSpot ?? {
            let spot = docPanelSpot(alignment: .trailing, page: { [weak self] in
                guard let self, let shown = self.shown else { return UIViewController() }
                return DocFieldPage(column: nil, block: shown.snapshot.block, controller: shown.controller).inNavigation()
            }, onDismiss: { [weak self] in
                guard let self, let shown = self.shown else { return }
                shown.controller.close(.addField, in: shown.snapshot.block)
            })
            addSpot = spot
            return spot
        }()
        spot.show(shown.controller.isShowing(.addField, in: shown.snapshot.block), over: addField)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let shown else { return }
        let line = DocTablePlan.line
        number.frame = CGRect(x: 0, y: 0, width: Metrics.numberWidth, height: bounds.height)
        var x = Metrics.numberWidth
        var index = 0
        for (column, width) in zip(shown.columns, shown.widths) {
            separators[index].frame = CGRect(x: x, y: 0, width: line, height: bounds.height)
            separators[index].isHidden = false
            index += 1
            x += line
            heads[column.id]?.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
        if let addField, !addField.isHidden {
            separators[index].frame = CGRect(x: x, y: 0, width: line, height: bounds.height)
            separators[index].isHidden = false
            index += 1
            x += line
            addField.frame = CGRect(x: x, y: 0, width: Metrics.addFieldWidth - line, height: bounds.height)
            addSpot?.frame = addField.bounds
        }
        for rest in index..<separators.count { separators[rest].isHidden = true }
    }
}

/// A field's head: its symbol and name, a sort's arrow, on the pointer over it a chevron; it
/// opens the field's menu.
@MainActor
private final class DocFieldHeadView: UIView {
    private let symbol = UIImageView()
    private let name = UILabel()
    private let arrow = UIImageView()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down",
                                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: DocTokens.Icon.inline, weight: .semibold)))
    private let button = FlooContentButton(content: UIView(), shape: .corner(0))
    private var spot: FlooPanelAnchorView?
    private var hover: DocHover!
    private var shown: (snapshot: DocCollectionSnapshot, view: CollectionView, column: Column, controller: DocCollectionController)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        symbol.tintColor = .floo(.disabledLabel)
        symbol.contentMode = .center
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = .floo(.secondaryLabel)
        arrow.tintColor = .floo(.disabledLabel)
        arrow.contentMode = .center
        chevron.tintColor = .floo(.disabledLabel)
        chevron.contentMode = .center
        chevron.alpha = 0
        [symbol, name, arrow, chevron].forEach { $0.isUserInteractionEnabled = false }
        addSubview(button)
        [symbol, name, arrow, chevron].forEach(addSubview)
        button.docMenu { [weak self] in self?.sections ?? [] }
        hover = DocHover(on: self) { [weak self] point in self?.chevron.alpha = point == nil ? 0 : 1 }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ snapshot: DocCollectionSnapshot, view: CollectionView, column: Column, controller: DocCollectionController) {
        shown = (snapshot, view, column, controller)
        symbol.image = UIImage(systemName: DocFieldText.symbol(column), withConfiguration: UIImage.SymbolConfiguration(pointSize: DocTokens.Icon.compact))
        name.text = column.name
        if let sort = view.layout.sort.first(where: { $0.column == column.id }) {
            arrow.image = UIImage(systemName: sort.ascending ? "arrow.up" : "arrow.down",
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: DocTokens.Icon.inline, weight: .semibold))
            arrow.isHidden = false
        } else {
            arrow.isHidden = true
        }
        chevron.isHidden = !DocTokens.Platform.isPointer
        button.accessibilityLabel = column.name
        followPanel()
        setNeedsLayout()
    }

    func followPanel() {
        guard let shown else { return }
        let kind = DocCollectionPanel.Kind.editField(shown.column.id)
        let spot = spot ?? {
            let spot = docPanelSpot(page: { [weak self] in
                guard let self, let shown = self.shown else { return UIViewController() }
                return DocFieldPage(column: shown.column, block: shown.snapshot.block, controller: shown.controller).inNavigation()
            }, onDismiss: { [weak self] in
                guard let self, let shown = self.shown else { return }
                shown.controller.close(.editField(shown.column.id), in: shown.snapshot.block)
            })
            self.spot = spot
            return spot
        }()
        spot.show(shown.controller.isShowing(kind, in: shown.snapshot.block), over: self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = bounds
        spot?.frame = bounds
        let gap = DocTokens.Space.xs + 2
        let symbolWidth = DocTokens.Icon.compact + 6
        var x = Metrics.cellInset
        symbol.frame = CGRect(x: x, y: 0, width: symbolWidth, height: bounds.height)
        x += symbolWidth + gap
        let chevronWidth = chevron.isHidden ? 0 : DocTokens.Icon.inline + 4
        let arrowWidth = arrow.isHidden ? 0 : DocTokens.Icon.inline + 4 + gap
        let room = max(0, bounds.width - x - Metrics.cellInset - arrowWidth - (chevronWidth > 0 ? chevronWidth + gap : 0))
        let nameWidth = min(ceil(name.intrinsicContentSize.width), room)
        name.frame = CGRect(x: x, y: 0, width: nameWidth, height: bounds.height)
        x += nameWidth + gap
        arrow.frame = CGRect(x: x, y: 0, width: DocTokens.Icon.inline + 4, height: bounds.height)
        chevron.frame = CGRect(x: bounds.width - Metrics.cellInset - chevronWidth, y: 0, width: chevronWidth, height: bounds.height)
    }

    private var sections: [FlooMenuSection] {
        guard let (snapshot, view, column, controller) = shown else { return [] }
        let block = snapshot.block
        let isTitle = column.id == DocCollectionController.titleColumn(of: snapshot.database)?.id
        var sections: [FlooMenuSection] = []
        if controller.isEditable {
            sections.append(.init([.action(String(localized: "Edit Field"), symbol: "pencil") { controller.show(.editField(column.id), in: block) }]))
        }
        var viewItems: [FlooMenuItem] = [
            .action(String(localized: "Sort Ascending"), symbol: "arrow.up") {
                controller.setSort([DatabaseSort(column: column.id, ascending: true)], in: view.id, of: block)
            },
            .action(String(localized: "Sort Descending"), symbol: "arrow.down") {
                controller.setSort([DatabaseSort(column: column.id, ascending: false)], in: view.id, of: block)
            },
            .action(String(localized: "Filter"), symbol: "line.3.horizontal.decrease") {
                let condition = CollectionFilter.conditions(for: column.type)[0]
                controller.setFilters(view.filters + [CollectionFilter(column: column.id, condition: condition)], in: view.id, of: block)
                controller.show(.view, in: block)
            },
        ]
        if !isTitle {
            viewItems.append(.submenu(String(localized: "Group by this Field"), symbol: "rectangle.3.group", [.init(DocCollectionNames.orders(manual: false).map { order in
                .action(DocCollectionNames.name(order, of: column)) {
                    controller.setGroup(column.id, in: view.id, of: block)
                    controller.setGrouping(CollectionGrouping(order: order), in: view.id, of: block)
                }
            })]))
        }
        sections.append(.init(viewItems))
        if controller.isEditable {
            sections.append(.init([
                .action(String(localized: "Hide Field"), symbol: "eye.slash", isEnabled: !isTitle) { controller.setHidden(column.id, true, in: view.id, of: block) },
                .action(String(localized: "Delete Field"), symbol: "trash", role: .destructive, isEnabled: snapshot.database.columns.count > 1) {
                    controller.deleteField(column.id, in: block)
                },
            ]))
        }
        return sections
    }
}

// MARK: - Groups

/// A group's head (Craft's): a chevron under the row numbers that folds it, its name and how many.
@MainActor
private final class DocTableGroupHeadView: UIView {
    private let button = FlooContentButton(content: UIView(), shape: .corner(0))
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down",
                                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: DocTokens.Icon.inline, weight: .semibold)))
    private var chip: FlooBadge?
    private let count = UILabel()
    private var key: String?
    var toggle: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        chevron.tintColor = .floo(.disabledLabel)
        chevron.contentMode = .center
        count.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        count.textColor = .floo(.secondaryLabel)
        [chevron, count].forEach { $0.isUserInteractionEnabled = false }
        addSubview(button)
        addSubview(chevron)
        addSubview(count)
        button.addAction(UIAction { [weak self] _ in
            guard let self, let key = self.key else { return }
            self.toggle?(key)
        }, for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ group: CollectionGroup, column: Column, isFolded: Bool) {
        key = group.key
        chip?.removeFromSuperview()
        let chip = DocChips.group(group, of: column)
        chip.isUserInteractionEnabled = false
        addSubview(chip)
        self.chip = chip
        count.text = "\(group.rows.count)"
        chevron.transform = isFolded ? CGAffineTransform(rotationAngle: -.pi / 2) : .identity
        button.accessibilityLabel = DocGroupLabel.title(group.value, in: column)
        button.accessibilityValue = isFolded ? String(localized: "Collapsed") : String(localized: "Expanded")
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = bounds
        chevron.bounds = CGRect(x: 0, y: 0, width: Metrics.numberWidth, height: bounds.height)
        chevron.center = CGPoint(x: Metrics.numberWidth / 2, y: bounds.midY)
        var x = Metrics.numberWidth + Metrics.cellInset
        if let chip {
            let size = chip.intrinsicContentSize
            chip.frame = CGRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + DocTokens.Space.sm
        }
        count.frame = CGRect(x: x, y: 0, width: ceil(count.intrinsicContentSize.width), height: bounds.height)
    }
}

// MARK: - Records

/// A record's row: its number (or the box that picks it), its cells, the lines between.
@MainActor
private final class DocTableRecordView: UIView {
    struct Shown {
        let snapshot: DocCollectionSnapshot
        let row: Row
        let number: Int
        let columns: [Column]
        let widths: [CGFloat]
        let titleColumn: Column?
        let controller: DocCollectionController
        let isHovered: Bool
        let isPicked: Bool
        let anyPicked: Bool
        let menu: (Column?) -> [FlooMenuSection]
    }

    private let number = UILabel()
    private let pick = FlooContentButton(content: UIView(), shape: .corner(0))
    private let pickBox = UIImageView()
    private var cells: [ColumnID: DocCollectionCellView] = [:]
    private var separators: [UIView] = []
    private var shown: Shown?

    override init(frame: CGRect) {
        super.init(frame: frame)
        number.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        number.textColor = .floo(.disabledLabel)
        number.textAlignment = .center
        number.isUserInteractionEnabled = false
        pickBox.contentMode = .center
        pickBox.isUserInteractionEnabled = false
        pick.accessibilityLabel = String(localized: "Select Row")
        pick.addAction(UIAction { [weak self] _ in
            guard let self, let shown = self.shown, shown.controller.isEditable else { return }
            shown.controller.togglePicked(shown.row.id, in: shown.snapshot.block)
        }, for: .primaryActionTriggered)
        addSubview(pick)
        addSubview(number)
        addSubview(pickBox)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ new: Shown) {
        shown = new
        backgroundColor = new.isPicked ? .floo(.markdownBlockSelected) : nil
        // Over the row, with rows picked, or (by touch) picked: the box that picks it.
        let picking = new.controller.isEditable && (new.isHovered || new.anyPicked || !DocTokens.Platform.isPointer && new.isPicked)
        number.isHidden = picking
        pickBox.isHidden = !picking
        number.text = "\(new.number)"
        pickBox.image = UIImage(systemName: new.isPicked ? "checkmark.square.fill" : "square",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: DocTokens.Icon.standard))
        pickBox.tintColor = new.isPicked ? .floo(.label) : .floo(.disabledLabel)
        var used: Set<ColumnID> = []
        for column in new.columns {
            let cell = cells[column.id] ?? {
                let new = DocCollectionCellView(compact: false)
                addSubview(new)
                cells[column.id] = new
                return new
            }()
            used.insert(column.id)
            let place = DocCollectionCell.place(row: new.row, column: column, in: new.snapshot.block) { new.menu(column) }
            cell.show(.init(snapshot: new.snapshot, row: new.row, column: column, controller: new.controller,
                            isTitle: column.id == new.titleColumn?.id, rowHovered: new.isHovered, place: place))
        }
        for (id, cell) in cells where !used.contains(id) {
            cell.reset()
            cell.removeFromSuperview()
            cells[id] = nil
        }
        let needed = new.columns.count + (new.controller.isEditable ? 1 : 0)
        while separators.count < needed {
            let line = UIView()
            line.backgroundColor = .floo(.separator)
            addSubview(line)
            separators.append(line)
        }
        setNeedsLayout()
    }

    func followPanels() {
        cells.values.forEach { $0.followPanel() }
    }

    func reset() {
        cells.values.forEach { $0.reset() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let shown else { return }
        let line = DocTablePlan.line
        number.frame = CGRect(x: 0, y: 0, width: Metrics.numberWidth, height: Metrics.rowHeight)
        pickBox.frame = number.frame
        pick.frame = number.frame
        var x = Metrics.numberWidth
        var index = 0
        for (column, width) in zip(shown.columns, shown.widths) {
            separators[index].frame = CGRect(x: x, y: 0, width: line, height: bounds.height)
            separators[index].isHidden = false
            index += 1
            x += line
            cells[column.id]?.frame = CGRect(x: x + Metrics.cellInset, y: 0, width: max(0, width - 2 * Metrics.cellInset), height: bounds.height)
            x += width
        }
        if shown.controller.isEditable {
            separators[index].frame = CGRect(x: x, y: 0, width: line, height: bounds.height)
            separators[index].isHidden = false
            index += 1
        }
        for rest in index..<separators.count { separators[rest].isHidden = true }
    }
}

// MARK: - The foot

/// The calculation row, with + for a new record under the row numbers.
@MainActor
private final class DocTableFootView: UIView {
    private var add: FlooContentButton!
    private var calculations: [ColumnID: DocCalculationCellView] = [:]
    private var shown: (snapshot: DocCollectionSnapshot, columns: [Column], widths: [CGFloat], showsCalculations: Bool)?
    private weak var controller: DocCollectionController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        add = docSymbolButton("plus", side: Metrics.numberWidth, shape: .corner(0), title: String(localized: "Add Row")) { [weak self] in
            guard let self, let controller = self.controller, let shown = self.shown else { return }
            _ = controller.addRecord(to: shown.snapshot.block)
        }
        addSubview(add)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ snapshot: DocCollectionSnapshot, view: CollectionView, columns: [Column], widths: [CGFloat], rows: [Row],
              controller: DocCollectionController, offers: Bool) {
        self.controller = controller
        shown = (snapshot, columns, widths, view.showsCalculations)
        add.isEnabled = controller.isEditable
        var used: Set<ColumnID> = []
        if view.showsCalculations {
            for column in columns {
                let cell = calculations[column.id] ?? {
                    let new = DocCalculationCellView()
                    addSubview(new)
                    calculations[column.id] = new
                    return new
                }()
                used.insert(column.id)
                cell.show(snapshot, view: view, column: column, rows: rows, controller: controller, offers: offers)
            }
        }
        for (id, cell) in calculations where !used.contains(id) {
            cell.removeFromSuperview()
            calculations[id] = nil
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        add.frame = CGRect(x: 0, y: 0, width: Metrics.numberWidth, height: bounds.height)
        guard let shown else { return }
        let line = DocTablePlan.line
        var x = Metrics.numberWidth
        for (column, width) in zip(shown.columns, shown.widths) {
            x += line
            calculations[column.id]?.frame = CGRect(x: x + Metrics.cellInset, y: 0, width: max(0, width - 2 * Metrics.cellInset), height: bounds.height)
            x += width
        }
    }
}

/// A column's cell in the calculation row: Calculate, or what it computes over the rows shown.
@MainActor
private final class DocCalculationCellView: UIView {
    private let button = FlooContentButton(content: UIView(), shape: .corner(0))
    private let label = UILabel()
    private let value = UILabel()
    private var shown: (snapshot: DocCollectionSnapshot, view: CollectionView, column: Column, controller: DocCollectionController)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .right
        value.textAlignment = .right
        value.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        value.textColor = .floo(.secondaryLabel)
        [label, value].forEach { $0.isUserInteractionEnabled = false }
        addSubview(button)
        addSubview(label)
        addSubview(value)
        button.docMenu { [weak self] in self?.sections ?? [] }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ snapshot: DocCollectionSnapshot, view: CollectionView, column: Column, rows: [Row], controller: DocCollectionController, offers: Bool) {
        shown = (snapshot, view, column, controller)
        button.isEnabled = controller.isEditable
        if let calculation = view.calculations[column.id] {
            label.text = DocCollectionMath.label(calculation)
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .floo(.disabledLabel)
            label.alpha = 1
            value.text = DocCollectionMath.value(calculation, of: column, in: rows)
            value.isHidden = false
        } else {
            label.text = String(localized: "Calculate")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .floo(.disabledLabel)
            label.alpha = controller.isEditable && offers ? 1 : 0
            value.isHidden = true
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = bounds
        let valueWidth = value.isHidden ? 0 : ceil(value.intrinsicContentSize.width)
        value.frame = CGRect(x: bounds.width - valueWidth, y: 0, width: valueWidth, height: bounds.height)
        let labelWidth = ceil(label.intrinsicContentSize.width)
        label.frame = CGRect(x: value.frame.minX - (valueWidth > 0 ? DocTokens.Space.xs : 0) - labelWidth, y: 0, width: labelWidth, height: bounds.height)
    }

    private var sections: [FlooMenuSection] {
        guard let (snapshot, view, column, controller) = shown else { return [] }
        let current = view.calculations[column.id]
        var sections = [FlooMenuSection(DocCollectionMath.available(for: column).map { calculation in
            .action(DocCollectionMath.title(calculation), isOn: calculation == current) {
                controller.setCalculation(calculation, for: column.id, in: view.id, of: snapshot.block)
            }
        })]
        if current != nil {
            sections.append(.init([.action(String(localized: "None")) { controller.setCalculation(nil, for: column.id, in: view.id, of: snapshot.block) }]))
        }
        return sections
    }
}
