//
//  DocCollectionKanbanUIKit.swift
//  DemoApp
//
//  A collection's kanban view in UIKit (what DocCollectionKanban drew, Craft's): a column per
//  group of the field it's grouped by, an option's tinted with its colour, the records as cards
//  (the title, the view's other fields: words whole, the rest as chips).
//  - a column's head: its group and how many; on the pointer over it, … (an option's: edit or
//    delete it) and + (a new card at the top); its right-click menu adds a card, opens the
//    grouping, hides the group;
//  - a card drags to another column or place, a line where it will land; its title takes typing
//    on a click; on the pointer over it, an arrow opens the record; its right-click menu edits
//    its fields, duplicates or deletes it;
//  - + under a column adds a card at its end, + after the columns a new option (a column).
//

import DocKit
import FlooUIKit
import UIKit

private typealias Metrics = DocCollectionMetrics

@MainActor
final class DocCollectionKanbanView: UIScrollView {
    private var snapshot: DocCollectionSnapshot?
    private var view: CollectionView?
    private var group: ColumnID?
    private weak var controller: DocCollectionController?
    private var lanes: [String: DocKanbanLaneView] = [:]
    private var order: [String] = []
    private var addGroup: FlooContentButton?
    private var addSpot: FlooPanelAnchorView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        // Scrolls out to the page's edges, as a plain table does.
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var column: Column? { snapshot?.database.columns.first { $0.id == group } }

    static func height(_ snapshot: DocCollectionSnapshot, view: CollectionView, controller: DocCollectionController) -> CGFloat {
        guard let group = view.layout.groupBy, let column = snapshot.database.columns.first(where: { $0.id == group }) else { return 0 }
        let lanes = DocCollectionController.lanes(view, of: controller.rows(snapshot, view), in: snapshot.database)
        let heights = lanes.map { DocKanbanLaneView.height(of: $0, snapshot: snapshot, view: view, column: column, controller: controller) }
        return max(heights.max() ?? 0, controller.isEditable && DocFieldText.hasOptions(column) ? Metrics.columnHead : 0)
    }

    func show(_ snapshot: DocCollectionSnapshot, view: CollectionView, group: ColumnID, controller: DocCollectionController) {
        self.snapshot = snapshot
        self.view = view
        self.group = group
        self.controller = controller
        guard let column else { return }
        let groups = DocCollectionController.lanes(view, of: controller.rows(snapshot, view), in: snapshot.database)
        order = groups.map(\.key)
        var used: Set<String> = []
        for lane in groups {
            let laneView = lanes[lane.key] ?? {
                let new = DocKanbanLaneView()
                new.drop = { [weak self] drag, before in self?.drop(drag, into: lane.key, before: before) }
                addSubview(new)
                lanes[lane.key] = new
                return new
            }()
            laneView.drop = { [weak self] drag, before in self?.drop(drag, into: lane.key, before: before) }
            used.insert(lane.key)
            laneView.show(lane, snapshot: snapshot, view: view, column: column, controller: controller)
        }
        for (key, lane) in lanes where !used.contains(key) {
            lane.reset()
            lane.removeFromSuperview()
            lanes[key] = nil
        }
        let addsGroups = controller.isEditable && DocFieldText.hasOptions(column)
        if addsGroups, addGroup == nil {
            let button = docSymbolButton("plus", side: Metrics.columnHead, title: String(localized: "Add New Group")) { [weak self] in
                guard let self, let snapshot = self.snapshot, let group = self.group else { return }
                self.controller?.show(.addOption(group), in: snapshot.block)
            }
            addSubview(button)
            addGroup = button
        }
        addGroup?.isHidden = !addsGroups
        followPanels()
        setNeedsLayout()
    }

    func followPanels() {
        lanes.values.forEach { $0.followPanels() }
        guard let addGroup, let snapshot, let group, let controller else { return }
        let spot = addSpot ?? {
            let spot = docPanelSpot(page: { [weak self] in
                guard let self, let snapshot = self.snapshot, let group = self.group, let controller = self.controller else { return UIViewController() }
                return DocOptionPage(snapshot: snapshot, column: group, option: nil, controller: controller).inNavigation()
            }, onDismiss: { [weak self] in
                guard let self, let snapshot = self.snapshot, let group = self.group else { return }
                self.controller?.close(.addOption(group), in: snapshot.block)
            })
            addSpot = spot
            return spot
        }()
        spot.show(!addGroup.isHidden && controller.isShowing(.addOption(group), in: snapshot.block), over: addGroup)
    }

    func reset() {
        lanes.values.forEach { $0.reset() }
        addSpot?.close()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        var height: CGFloat = 0
        for key in order {
            guard let lane = lanes[key] else { continue }
            let laneHeight = lane.height
            lane.frame = CGRect(x: x, y: 0, width: Metrics.columnWidth, height: laneHeight)
            height = max(height, laneHeight)
            x += Metrics.columnWidth + Metrics.columnGap
        }
        if let addGroup, !addGroup.isHidden {
            addGroup.frame = CGRect(x: x, y: 0, width: Metrics.columnHead, height: Metrics.columnHead)
            addSpot?.frame = addGroup.bounds
            x += Metrics.columnHead + Metrics.columnGap
        }
        contentSize = CGSize(width: max(0, x - Metrics.columnGap), height: height)
    }

    /// A card dropped in the lane `key`, before a card or at its end.
    private func drop(_ drag: DocKanbanDragItem, into key: String, before: RowID?) {
        guard let snapshot, let view, let group, let controller else { return }
        let groups = DocCollectionController.lanes(view, of: controller.rows(snapshot, view), in: snapshot.database)
        guard let lane = groups.first(where: { $0.key == key }) else { return }
        let source = groups.first { $0.key == drag.groupKey }?.value
        controller.move(drag.row, from: source, to: lane.value, groupedBy: group, before: before, in: snapshot.block)
    }
}

/// What a dragged card carries in this app.
struct DocKanbanDragItem {
    let row: RowID
    let groupKey: String
}

/// One column of a kanban: its group and how many, its cards, + for a new card.
@MainActor
private final class DocKanbanLaneView: UIView, UIDropInteractionDelegate {
    private let head = UIView()
    private var chip: FlooBadge?
    private let count = UILabel()
    private var more: FlooContentButton!
    private var addTop: FlooContentButton!
    private var addEnd: FlooContentButton!
    private var cards: [RowID: DocKanbanCardView] = [:]
    private var order: [RowID] = []
    private let line = UIView()
    private var optionSpot: FlooPanelAnchorView?
    private var hover: DocHover!
    private var shown: (group: CollectionGroup, snapshot: DocCollectionSnapshot, view: CollectionView, column: Column, controller: DocCollectionController)?
    var drop: ((DocKanbanDragItem, RowID?) -> Void)?
    /// Where a dragged card will land, while one is over the column.
    private var landing: Landing? { didSet { if landing != oldValue { showLanding() } } }

    private enum Landing: Equatable {
        case before(RowID)
        case end
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = Metrics.corner
        layer.cornerCurve = .continuous
        count.font = .systemFont(ofSize: 14)
        count.textColor = .floo(.secondaryLabel)
        addSubview(head)
        head.addSubview(count)
        more = docSymbolButton("ellipsis", side: 24, shape: .corner(DocTokens.Radius.xs), title: String(localized: "Group Options"))
        more.docMenu { [weak self] in self?.optionMenu() ?? [] }
        addTop = docSymbolButton("plus", side: 24, shape: .corner(DocTokens.Radius.xs), title: String(localized: "New Item")) { [weak self] in
            self?.addRecord(atTop: true)
        }
        head.addSubview(more)
        head.addSubview(addTop)
        addEnd = docSymbolButton("plus", side: Metrics.addHeight, shape: .corner(Metrics.cardCorner), title: String(localized: "New Item")) { [weak self] in
            self?.addRecord(atTop: false)
        }
        addEnd.layer.cornerRadius = Metrics.cardCorner
        addEnd.layer.cornerCurve = .continuous
        addEnd.layer.borderWidth = DocTokens.Border.standard
        addSubview(addEnd)
        line.isUserInteractionEnabled = false
        line.backgroundColor = .floo(.accent)
        line.layer.cornerRadius = DocTokens.Component.DropIndicator.thickness / 2
        line.isHidden = true
        addSubview(line)
        hover = DocHover(on: self) { [weak self] _ in self?.showActions() }
        flooAddContextMenu { [weak self] in self?.laneMenu() ?? [] }
        addInteraction(UIDropInteraction(delegate: self))
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.updateColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateColors() {
        addEnd.layer.borderColor = UIColor.floo(.label).withAlphaComponent(0.08).resolvedColor(with: traitCollection).cgColor
        showTint()
    }

    private var option: SelectOption? {
        guard let shown else { return nil }
        return DocFieldText.options(shown.column).first { $0.id.description == shown.group.key }
    }

    private var tint: UIColor {
        guard let shown, let option else { return .floo(.secondaryLabel) }
        return DocChips.color(option, in: DocFieldText.options(shown.column))
    }

    private func showTint() {
        backgroundColor = tint.withAlphaComponent(landing != nil ? 0.2 : 0.1)
    }

    func show(_ group: CollectionGroup, snapshot: DocCollectionSnapshot, view: CollectionView, column: Column, controller: DocCollectionController) {
        shown = (group, snapshot, view, column, controller)
        chip?.removeFromSuperview()
        let chip = DocChips.group(group, of: column)
        chip.isUserInteractionEnabled = false
        head.addSubview(chip)
        self.chip = chip
        count.text = "\(group.rows.count)"
        more.isHidden = option == nil
        addEnd.isHidden = !controller.isEditable
        order = group.rows.map(\.id)
        var used: Set<RowID> = []
        for row in group.rows {
            let card = cards[row.id] ?? {
                let new = DocKanbanCardView()
                addSubview(new)
                cards[row.id] = new
                return new
            }()
            used.insert(row.id)
            card.show(row, groupKey: group.key, snapshot: snapshot, view: view, controller: controller)
        }
        for (id, card) in cards where !used.contains(id) {
            card.reset()
            card.removeFromSuperview()
            cards[id] = nil
        }
        showTint()
        showActions()
        followPanels()
        setNeedsLayout()
    }

    /// The head's buttons: over the column on a Mac, always on a phone.
    private func showActions() {
        let shows = (shown?.controller.isEditable ?? false) && (hover.isOver || !DocTokens.Platform.isPointer)
        for button in [more!, addTop!] {
            button.alpha = shows ? 1 : 0
            button.isUserInteractionEnabled = shows
        }
    }

    func followPanels() {
        cards.values.forEach { $0.followPanels() }
        guard let shown, let chip else { return }
        let showing = option.map { shown.controller.isShowing(.editOption($0.id), in: shown.snapshot.block) } ?? false
        let spot = optionSpot ?? {
            let spot = docPanelSpot(page: { [weak self] in
                guard let self, let shown = self.shown else { return UIViewController() }
                return DocOptionPage(snapshot: shown.snapshot, column: shown.column.id, option: self.option, controller: shown.controller).inNavigation()
            }, onDismiss: { [weak self] in
                guard let self, let shown = self.shown, let option = self.option else { return }
                shown.controller.close(.editOption(option.id), in: shown.snapshot.block)
            })
            optionSpot = spot
            return spot
        }()
        spot.show(showing, over: chip)
    }

    func reset() {
        optionSpot?.close()
        cards.values.forEach { $0.reset() }
    }

    private func addRecord(atTop: Bool) {
        guard let shown else { return }
        _ = shown.controller.addRecord(to: shown.snapshot.block, in: (shown.column.id, shown.group.value), atTop: atTop)
    }

    private func optionMenu() -> [FlooMenuSection] {
        guard let shown, let option else { return [] }
        return [.init([
            .action(String(localized: "Edit Group"), symbol: "pencil") { shown.controller.show(.editOption(option.id), in: shown.snapshot.block) },
            .action(String(localized: "Delete Group"), symbol: "trash", role: .destructive) {
                shown.controller.deleteOption(option.id, in: shown.column.id, of: shown.snapshot.block)
            },
        ])]
    }

    /// The column's right-click menu (Craft's): a new card at its end, the grouping's panel,
    /// leaving the group out.
    private func laneMenu() -> [FlooMenuSection] {
        guard let shown, shown.controller.isEditable else { return [] }
        return [
            .init([.action(String(localized: "Add Item"), symbol: "plus") { [weak self] in self?.addRecord(atTop: false) }]),
            .init([
                .action(String(localized: "Edit Grouping"), symbol: "rectangle.3.group") { shown.controller.show(.view, in: shown.snapshot.block) },
                .action(String(localized: "Hide Group"), symbol: "eye.slash") {
                    shown.controller.hide(group: shown.group.key, in: shown.view.id, of: shown.snapshot.block)
                },
            ]),
        ]
    }

    // MARK: Layout

    private static var headHeight: CGFloat { Metrics.columnHead - Metrics.columnInset }
    private static var cardWidth: CGFloat { Metrics.columnWidth - 2 * Metrics.columnInset }

    var height: CGFloat {
        guard let shown else { return 0 }
        return Self.height(of: shown.group, snapshot: shown.snapshot, view: shown.view, column: shown.column, controller: shown.controller)
    }

    static func height(of group: CollectionGroup, snapshot: DocCollectionSnapshot, view: CollectionView, column: Column, controller: DocCollectionController) -> CGFloat {
        var height = 2 * Metrics.columnInset + headHeight
        for row in group.rows {
            height += Metrics.cardGap + DocKanbanCardView.height(of: row, snapshot: snapshot, view: view, controller: controller, width: cardWidth)
        }
        if controller.isEditable { height += Metrics.cardGap + Metrics.addHeight }
        return height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let shown else { return }
        let inset = Metrics.columnInset
        head.frame = CGRect(x: inset, y: inset, width: Self.cardWidth, height: Self.headHeight)
        var x: CGFloat = 0
        if let chip {
            let size = chip.intrinsicContentSize
            chip.frame = CGRect(x: 0, y: ((Self.headHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
            x = size.width + DocTokens.Space.sm
        }
        count.frame = CGRect(x: x, y: 0, width: ceil(count.intrinsicContentSize.width), height: Self.headHeight)
        addTop.frame = CGRect(x: Self.cardWidth - 24, y: (Self.headHeight - 24) / 2, width: 24, height: 24)
        more.frame = addTop.frame.offsetBy(dx: -(24 + DocTokens.Space.sm), dy: 0)
        optionSpot?.frame = chip?.bounds ?? .zero
        var y = inset + Self.headHeight
        for id in order {
            guard let card = cards[id], let row = shown.group.rows.first(where: { $0.id == id }) else { continue }
            y += Metrics.cardGap
            let height = DocKanbanCardView.height(of: row, snapshot: shown.snapshot, view: shown.view, controller: shown.controller, width: Self.cardWidth)
            card.frame = CGRect(x: inset, y: y, width: Self.cardWidth, height: height)
            y += height
        }
        if !addEnd.isHidden {
            addEnd.frame = CGRect(x: inset, y: y + Metrics.cardGap, width: Self.cardWidth, height: Metrics.addHeight)
        }
        showLanding()
    }

    // MARK: Dropping

    /// Before the first card whose middle is below `y`, else at the end.
    private func landing(at y: CGFloat) -> Landing {
        order.first { (cards[$0]?.frame.midY ?? .infinity) > y }.map { .before($0) } ?? .end
    }

    /// Where a dragged card will land: a line in the accent between the cards.
    private func showLanding() {
        showTint()
        guard let landing else {
            line.isHidden = true
            return
        }
        let half = Metrics.cardGap / 2
        let headFoot = Metrics.columnInset + Self.headHeight
        let y: CGFloat = switch landing {
        case .before(let id): (cards[id]?.frame.minY ?? headFoot + Metrics.cardGap) - half
        case .end: order.last.flatMap { cards[$0]?.frame.maxY }.map { $0 + half } ?? headFoot + half
        }
        let indicator = DocTokens.Component.DropIndicator.self
        line.frame = CGRect(x: Metrics.columnInset - indicator.overhang, y: y - indicator.thickness / 2,
                            width: Self.cardWidth + 2 * indicator.overhang, height: indicator.thickness)
        line.isHidden = false
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.localDragSession?.items.first?.localObject is DocKanbanDragBox
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        landing = landing(at: session.location(in: self).y)
        return UIDropProposal(operation: .move)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) { landing = nil }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) { landing = nil }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        let at = landing(at: session.location(in: self).y)
        landing = nil
        guard let box = session.localDragSession?.items.first?.localObject as? DocKanbanDragBox else { return }
        let before: RowID? = if case .before(let id) = at { id } else { nil }
        drop?(box.item, before)
    }
}

/// A dragged card's item, as a drag session's local object.
final class DocKanbanDragBox: NSObject {
    let item: DocKanbanDragItem
    init(_ item: DocKanbanDragItem) { self.item = item }
}

/// A record as a card: its title (typed in place on a click), then the view's other fields.
@MainActor
private final class DocKanbanCardView: UIView, UITextViewDelegate, UIDragInteractionDelegate {
    private let title = UILabel()
    private let titleField = UITextView()
    private let pageMark = DocPageSheetView()
    private var reads: [UILabel] = []
    private let chips = UIView()
    private var openButton: FlooContentButton!
    private var hover: DocHover!
    private var spot: FlooPanelAnchorView?
    private var spotKind: DocCollectionPanel.Kind?
    private var shown: (row: Row, groupKey: String, snapshot: DocCollectionSnapshot, view: CollectionView, controller: DocCollectionController)?
    private var editing = false

    private static let titleFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
    private static let readFont = UIFont.systemFont(ofSize: 13)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = Metrics.cardCorner
        layer.cornerCurve = .continuous
        backgroundColor = .floo(.markdownPage)
        title.font = Self.titleFont
        title.numberOfLines = 0
        title.isUserInteractionEnabled = true
        title.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(titleTapped)))
        titleField.font = Self.titleFont
        titleField.backgroundColor = .clear
        titleField.isScrollEnabled = false
        titleField.textContainerInset = .zero
        titleField.textContainer.lineFragmentPadding = 0
        titleField.returnKeyType = .done
        titleField.delegate = self
        titleField.isHidden = true
        pageMark.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        chips.isUserInteractionEnabled = false
        openButton = docSymbolButton("arrow.right.circle", size: DocTokens.Icon.standard, weight: .regular, side: Metrics.openButton,
                                     shape: .capsule, title: String(localized: "Open")) { [weak self] in
            guard let self, let shown = self.shown else { return }
            shown.controller.openRecord?(shown.row.id, shown.snapshot.block)
        }
        [title, titleField, pageMark, chips, openButton].forEach(addSubview)
        hover = DocHover(on: self) { [weak self] _ in self?.showOpen() }
        flooAddContextMenu { [weak self] in self?.place?.menu?.rows?() ?? [] }
        addInteraction(UIDragInteraction(delegate: self))
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.updateColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Outlined in the accent while its title has the caret, else a quiet edge.
    private func updateColors() {
        layer.borderColor = (titleField.isFirstResponder ? UIColor.floo(.accent) : UIColor.floo(.label).withAlphaComponent(0.08))
            .resolvedColor(with: traitCollection).cgColor
        layer.borderWidth = titleField.isFirstResponder ? Metrics.focusWidth : DocTokens.Border.standard
    }

    private var block: DocBlockID? { shown?.snapshot.block }

    private static func titleColumn(_ snapshot: DocCollectionSnapshot) -> Column? { DocCollectionController.titleColumn(of: snapshot.database) }

    private static func titleText(_ row: Row, _ snapshot: DocCollectionSnapshot) -> String {
        titleColumn(snapshot).map { DocFieldText.text(row.cells[$0.id], in: $0) } ?? ""
    }

    /// Text that reads as words (a note, a link, a person) goes under the title whole; the
    /// short values (options, numbers, dates, a box) are chips.
    private static func reads(_ column: Column) -> Bool {
        switch column.type {
        case .text, .url, .person: true
        default: false
        }
    }

    private static func fields(_ row: Row, _ snapshot: DocCollectionSnapshot, _ view: CollectionView) -> [Column] {
        let title = titleColumn(snapshot)
        return DocCollectionController.fields(view, of: snapshot.database).filter { $0.id != title?.id && row.cells[$0.id] != nil }
    }

    func show(_ row: Row, groupKey: String, snapshot: DocCollectionSnapshot, view: CollectionView, controller: DocCollectionController) {
        shown = (row, groupKey, snapshot, view, controller)
        let text = Self.titleText(row, snapshot)
        title.text = text.isEmpty ? String(localized: "Title") : text
        title.textColor = text.isEmpty ? .floo(.disabledLabel) : .floo(.label)
        if !editing, titleField.text != text { titleField.text = text }
        pageMark.isHidden = controller.hasPage?(row.id) != true
        let fields = Self.fields(row, snapshot, view)
        let words = fields.filter(Self.reads)
        while reads.count < words.count {
            let label = UILabel()
            label.font = Self.readFont
            label.textColor = .floo(.secondaryLabel)
            label.numberOfLines = 0
            label.isUserInteractionEnabled = false
            addSubview(label)
            reads.append(label)
        }
        for (index, label) in reads.enumerated() {
            label.isHidden = index >= words.count
            if index < words.count { label.text = DocFieldText.text(row.cells[words[index].id], in: words[index]) }
        }
        chips.subviews.forEach { $0.removeFromSuperview() }
        for chip in Self.chipViews(row, fields.filter { !Self.reads($0) }) { chips.addSubview(chip) }
        if controller.editingTitle == row.id { startEditing() }
        showOpen()
        followPanels()
        setNeedsLayout()
    }

    private static func chipViews(_ row: Row, _ columns: [Column]) -> [FlooBadge] {
        columns.flatMap { column -> [FlooBadge] in
            let value = row.cells[column.id]
            switch (column.type, value) {
            case (.select(let options), .select(let id)?):
                return options.first { $0.id == id }.map { [DocChips.chip($0, in: options)] } ?? []
            case (.multiSelect(let options), .multiSelect(let ids)?):
                return options.filter { ids.contains($0.id) }.map { DocChips.chip($0, in: options) }
            case (.checkbox, .checkbox(let on)?):
                return [DocChips.chip(column.name, symbol: on ? "checkmark.square.fill" : "square")]
            default:
                return [DocChips.chip(DocFieldText.text(value, in: column))]
            }
        }
    }

    /// The arrow over the card's corner: on the pointer over it, always by touch; not while typing.
    private func showOpen() {
        openButton.isHidden = titleField.isFirstResponder || !(hover.isOver || !DocTokens.Platform.isPointer)
    }

    func reset() {
        spot?.close()
        if titleField.isFirstResponder { titleField.resignFirstResponder() }
    }

    // MARK: The title

    /// The card's title as a place: its menu the card's right-click rows.
    private var place: DocFieldPlace? {
        guard let shown else { return nil }
        let block = shown.snapshot.block
        return DocFieldPlace(field: [block, shown.row.id, "card"] as [AnyHashable], block: block,
                             menu: DocPlaceMenu(title: String(localized: "Card Actions"), symbol: "ellipsis.circle", opens: .rows { [weak self] in self?.menu() ?? [] }))
    }

    @objc private func titleTapped() {
        guard let shown, shown.controller.isEditable, Self.titleColumn(shown.snapshot) != nil else { return }
        startEditing()
    }

    private func startEditing() {
        guard let shown else { return }
        editing = true
        if shown.controller.editingTitle == shown.row.id { shown.controller.editingTitle = nil }
        titleField.text = Self.titleText(shown.row, shown.snapshot)
        titleField.isHidden = false
        title.isHidden = true
        DispatchQueue.main.async { [weak self] in self?.titleField.becomeFirstResponder() }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        updateColors()
        showOpen()
        if let shown, let place { shown.controller.editor.field(place, isFocused: true) }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        editing = false
        titleField.isHidden = true
        title.isHidden = false
        updateColors()
        showOpen()
        if let shown, let place { shown.controller.editor.field(place, isFocused: false) }
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let shown, let column = Self.titleColumn(shown.snapshot) else { return }
        if titleField.text.contains("\n") {
            titleField.text = titleField.text.replacingOccurrences(of: "\n", with: "")
            titleField.resignFirstResponder()
            return
        }
        shown.controller.setText(titleField.text, row: shown.row.id, column: column.id, in: shown.snapshot.block)
    }

    // MARK: Menu and panels

    /// Craft's card menu: a field to edit (or a new one), a copy, gone.
    private func menu() -> [FlooMenuSection] {
        guard let shown else { return [] }
        let block = shown.snapshot.block, row = shown.row, controller = shown.controller
        let title = Self.titleColumn(shown.snapshot)
        let others = shown.snapshot.database.columns.filter { $0.id != title?.id }
        let properties = FlooMenuItem.submenu(String(localized: "Edit Properties"), symbol: "slider.horizontal.3", [
            .init(others.map { column in
                .action(column.name, symbol: DocFieldText.symbol(column.type)) { [weak self] in self?.edit(column) }
            }),
            .init([.action(String(localized: "Add Field"), symbol: "plus") { controller.show(.cardField(row.id), in: block) }]),
        ])
        return [
            .init([properties]),
            .init([
                .action(String(localized: "Duplicate Item"), symbol: "plus.square.on.square") { _ = controller.duplicate(row: row.id, in: block) },
                .action(String(localized: "Delete Item"), symbol: "trash", role: .destructive) { controller.delete(row.id, in: block) },
            ]),
        ]
    }

    /// A field from the menu: its options, its calendar, a field to type in; a box turns over.
    private func edit(_ column: Column) {
        guard let shown else { return }
        let block = shown.snapshot.block, row = shown.row
        switch column.type {
        case .select, .multiSelect: shown.controller.show(.options(row: row.id, column: column.id), in: block)
        case .date: shown.controller.show(.date(row: row.id, column: column.id), in: block)
        case .checkbox:
            let on = row.cells[column.id] == .checkbox(value: true)
            shown.controller.set(on ? nil : .checkbox(value: true), row: row.id, column: column.id, in: block)
        default: shown.controller.show(.property(row: row.id, column: column.id), in: block)
        }
    }

    /// The panel the card's menu opened, if one is showing.
    private var fieldPanel: DocCollectionPanel.Kind? {
        guard let shown, let panel = shown.controller.panel, panel.block == shown.snapshot.block else { return nil }
        let id = shown.row.id
        switch panel.kind {
        case .options(id, _), .date(id, _), .property(id, _), .cardField(id): return panel.kind
        default: return nil
        }
    }

    func followPanels() {
        let kind = fieldPanel
        if kind != spotKind {
            spot?.close()
            spot?.removeFromSuperview()
            spot = nil
            spotKind = kind
            if let kind {
                spot = docPanelSpot(page: { [weak self] in self?.page(for: kind) ?? UIViewController() }, follow: { [weak self] page in
                    guard let self, let shown = self.shown, let options = page as? DocOptionsPage, case .options(_, let id) = kind,
                          let column = shown.snapshot.database.columns.first(where: { $0.id == id }) else { return }
                    options.update(row: shown.row, column: column)
                }, onDismiss: { [weak self] in
                    guard let self, let shown = self.shown else { return }
                    shown.controller.close(kind, in: shown.snapshot.block)
                })
            }
        }
        spot?.show(kind != nil, over: self)
    }

    private func page(for kind: DocCollectionPanel.Kind) -> UIViewController {
        guard let shown else { return UIViewController() }
        let block = shown.snapshot.block, row = shown.row, controller = shown.controller
        let field = { (id: ColumnID) in shown.snapshot.database.columns.first { $0.id == id } }
        switch kind {
        case .options(_, let id):
            if let column = field(id) { return DocOptionsPage(row: row, column: column, block: block, controller: controller) }
        case .date(_, let id):
            if let column = field(id) { return DocDatePage(row: row, column: column, block: block, controller: controller) }
        case .property(_, let id):
            if let column = field(id) { return DocPropertyPage(row: row, column: column, block: block, controller: controller) }
        case .cardField:
            return DocFieldPage(column: nil, block: block, controller: controller, panel: .cardField(row.id)).inNavigation()
        default:
            break
        }
        return UIViewController()
    }

    // MARK: Dragging

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard let shown, shown.controller.isEditable, !titleField.isFirstResponder else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: Self.titleText(shown.row, shown.snapshot) as NSString))
        item.localObject = DocKanbanDragBox(DocKanbanDragItem(row: shown.row.id, groupKey: shown.groupKey))
        return [item]
    }

    // MARK: Layout

    /// Its parts at a width: the title (room at its end for the arrow, a page's mark before
    /// it), the fields that read as words, the chips in lines.
    private static func plan(_ row: Row, snapshot: DocCollectionSnapshot, view: CollectionView, hasPage: Bool, width: CGFloat)
        -> (title: CGRect, mark: CGRect?, reads: [CGRect], chips: CGRect, chipFrames: [CGRect], height: CGFloat) {
        let inset = Metrics.cardInset
        let inner = width - 2 * inset
        let mark: CGRect? = hasPage ? CGRect(x: inset, y: inset + 1, width: DocPageMetrics.sheet.width / 2, height: DocPageMetrics.sheet.height / 2) : nil
        let titleX = inset + (hasPage ? DocPageMetrics.sheet.width / 2 + DocTokens.Space.sm : 0)
        let titleWidth = max(0, width - inset - titleX - Metrics.openButton - DocTokens.Space.xs)
        let text = titleText(row, snapshot)
        let titleHeight = DocTextMeasure.height(text.isEmpty ? String(localized: "Title") : text, font: titleFont, width: titleWidth)
        var y = inset
        let title = CGRect(x: titleX, y: y, width: titleWidth, height: titleHeight)
        y += titleHeight
        let fields = fields(row, snapshot, view)
        var reads: [CGRect] = []
        for column in fields.filter(Self.reads) {
            let height = DocTextMeasure.height(DocFieldText.text(row.cells[column.id], in: column), font: readFont, width: inner)
            y += DocTokens.Space.sm
            reads.append(CGRect(x: inset, y: y, width: inner, height: height))
            y += height
        }
        let chipColumns = fields.filter { !Self.reads($0) }
        var chips = CGRect.zero
        var chipFrames: [CGRect] = []
        if !chipColumns.isEmpty {
            let sizes = chipViews(row, chipColumns).map(\.intrinsicContentSize)
            let flow = DocChips.flow(sizes, width: inner)
            y += DocTokens.Space.sm
            chips = CGRect(x: inset, y: y, width: inner, height: flow.height)
            chipFrames = flow.frames
            y += flow.height
        }
        return (title, mark, reads, chips, chipFrames, y + inset)
    }

    static func height(of row: Row, snapshot: DocCollectionSnapshot, view: CollectionView, controller: DocCollectionController, width: CGFloat) -> CGFloat {
        plan(row, snapshot: snapshot, view: view, hasPage: controller.hasPage?(row.id) == true, width: width).height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let shown else { return }
        let plan = Self.plan(shown.row, snapshot: shown.snapshot, view: shown.view, hasPage: !pageMark.isHidden, width: bounds.width)
        title.frame = plan.title
        titleField.frame = CGRect(x: plan.title.minX, y: plan.title.minY, width: plan.title.width, height: max(plan.title.height, Self.titleFont.lineHeight))
        if let mark = plan.mark { pageMark.frame = mark }
        for (label, frame) in zip(reads, plan.reads) { label.frame = frame }
        chips.frame = plan.chips
        for (chip, frame) in zip(chips.subviews, plan.chipFrames) { chip.frame = frame }
        openButton.frame = CGRect(x: bounds.width - Metrics.cardInset + DocTokens.Space.xs - Metrics.openButton, y: Metrics.cardInset - 2,
                                  width: Metrics.openButton, height: Metrics.openButton)
        spot?.frame = bounds
    }
}
