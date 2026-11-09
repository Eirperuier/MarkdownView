//
//  DocCollectionBlockUIKit.swift
//  DemoApp
//
//  A collection as a UIKit row, wider than the page's text (Craft's): its name, its toolbar
//  (search, a new item, the view's settings: over the block on a Mac, always on a phone), a
//  tab for each view, then the view: a table, a kanban or a chart (DocCollectionChartView,
//  its marks drawn by floo's chart engine). And a record's fields on its page. What
//  DocCollectionView, its header and DocRecordFields drew, in frames.
//

import DocKit
import FlooUIKit
import MessagingUI
import Observation
import UIKit

private typealias Metrics = DocCollectionMetrics

// MARK: - The row

/// A collection row's content: what it shows and who changes it.
@MainActor
struct DocCollectionRowContent: TiledUIKitCellContent {
    var drivesRowMoves: Bool { true }

    let row: DocRow
    let snapshot: DocCollectionSnapshot
    let controller: DocCollectionController

    /// The views it draws: a table, a kanban, a chart: all of them.
    static func draws(_ snapshot: DocCollectionSnapshot) -> Bool { true }

    static func makeRowView() -> DocCollectionRowView { DocCollectionRowView() }

    func configure(_ view: DocCollectionRowView, context: TiledUIKitCellContext) {
        view.show(row, snapshot: snapshot, controller: controller, context: context)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let contentWidth = DocRowUIKitView.contentWidth(of: row, width: width, maxWidth: DocCollectionRowView.pageMaxWidth)
        return DocRowUIKitView.frames(of: row, width: width, contentHeight: DocCollectionBlockView.height(snapshot, controller: controller, width: contentWidth),
                                      maxWidth: DocCollectionRowView.pageMaxWidth).height
    }

    static func prepareForReuse(_ view: DocCollectionRowView) {
        view.reset()
    }

    /// Its block view made ahead, shown in the stage at its width (AheadWork).
    func prepareAhead(forWidth width: CGFloat, traits: UITraitCollection) {
        let contentWidth = DocRowUIKitView.contentWidth(of: row, width: width, maxWidth: DocCollectionRowView.pageMaxWidth)
        DocCollectionRowView.prepare(snapshot, controller: controller, width: contentWidth)
    }
}

@MainActor
final class DocCollectionRowView: DocRowUIKitView {
    /// The row's content, holding the block view it shows: the one kept for its block (made
    /// ahead, or shown before and put away) when there is one.
    private let holder = UIView()
    private var collection: DocCollectionBlockView?
    private var shownBlock: DocBlockID?

    override class var pageMaxWidth: CGFloat { DocCollectionLayout.maxWidth }

    init() {
        super.init(content: holder)
    }

    func show(_ row: DocRow, snapshot: DocCollectionSnapshot, controller: DocCollectionController, context: TiledUIKitCellContext) {
        if shownBlock != snapshot.block { putAway() }
        let view = collection ?? Self.kept.removeValue(forKey: snapshot.block) ?? DocCollectionBlockView()
        if view !== collection {
            view.frame = holder.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            holder.addSubview(view)
            view.heightChanged = { [weak self] in self?.contentHeightChanged() }
            collection = view
        }
        shownBlock = snapshot.block
        Self.showing.insert(snapshot.block)
        take(row, blocks: controller.editor.blocks, context: context)
        view.show(snapshot, controller: controller)
        layOutShown()
    }

    override func reset() {
        super.reset()
        collection?.reset()
        putAway()
    }

    /// The block view it showed kept for its block, in the stage (in the window, as it was
    /// drawn), for the row that shows it next.
    private func putAway() {
        guard let collection else { return }
        self.collection = nil
        collection.heightChanged = nil
        if let shownBlock, let stage = AheadWork.stage {
            Self.showing.remove(shownBlock)
            stage.addSubview(collection)
            Self.keep(collection, for: shownBlock)
        } else {
            collection.removeFromSuperview()
        }
        shownBlock = nil
    }

    override func contentHeight(forWidth width: CGFloat) -> CGFloat {
        collection?.height(forWidth: width) ?? 0
    }

    // MARK: Made ahead

    /// Block views made ahead or put away, by block, in the stage.
    private static var kept: [DocBlockID: DocCollectionBlockView] = [:]
    /// The blocks rows show now.
    private static var showing: Set<DocBlockID> = []

    private static func keep(_ view: DocCollectionBlockView, for block: DocBlockID) {
        kept[block]?.removeFromSuperview()
        kept[block] = view
        // A few: a page has a collection or two.
        if kept.count > 4, let other = kept.keys.first(where: { $0 != block }) { kept.removeValue(forKey: other)?.removeFromSuperview() }
    }

    static func prepare(_ snapshot: DocCollectionSnapshot, controller: DocCollectionController, width: CGFloat) {
        let block = snapshot.block
        guard width > 0, AheadWork.stage != nil, !showing.contains(block), kept[block] == nil else { return }
        AheadWork.add("collection|\(block)") { [weak controller] in
            guard let controller, let stage = AheadWork.stage, !showing.contains(block), kept[block] == nil else { return }
            let view = DocCollectionBlockView()
            stage.addSubview(view)
            view.show(snapshot, controller: controller)
            view.frame = CGRect(x: 0, y: 0, width: width, height: view.height(forWidth: width))
            view.layoutIfNeeded()
            keep(view, for: block)
        }
    }
}

// MARK: - The block

@MainActor
final class DocCollectionBlockView: UIView, UITextFieldDelegate {
    private let name = UITextField()
    private let toolbar = UIView()
    private var searchButton: FlooButton!
    private let searchField = FlooTextField(placeholder: String(localized: "Search"), size: .small)
    private var closeSearch: FlooButton!
    private var newItem: FlooButton!
    private var viewOptions: FlooButton!
    private var viewSpot: FlooPanelAnchorView?
    private let tabs = UIView()
    private var tabButtons: [CollectionViewID: DocCollectionTabView] = [:]
    private var addView: FlooContentButton!
    private var kanbanSpot: FlooPanelAnchorView?
    private var chartSpot: FlooPanelAnchorView?
    private let table = DocCollectionTableView()
    private let kanban = DocCollectionKanbanView()
    private let chartView = DocCollectionChartView()
    private var hover: DocHover!

    private var snapshot: DocCollectionSnapshot?
    private weak var controller: DocCollectionController?
    private var searching = false
    private var renaming: CollectionViewID?
    /// The tab its view's settings opened from; none, the toolbar's button.
    private var viewPanelTab: CollectionViewID?
    private var showedViewPanel = false
    private var shownHeight: CGFloat?
    /// Its height changed from within (a group folded, records filtered): the row is told.
    var heightChanged: (() -> Void)?

    private static let nameFont = UIFont.systemFont(ofSize: Metrics.titleSize, weight: .bold)

    override init(frame: CGRect) {
        super.init(frame: frame)
        name.font = Self.nameFont
        name.textColor = .floo(.label)
        name.placeholder = String(localized: "Untitled Collection")
        name.delegate = self
        name.addAction(UIAction { [weak self] _ in self?.nameChanged() }, for: .editingChanged)
        addSubview(name)
        addSubview(toolbar)
        searchButton = docToolbarButton("magnifyingglass", String(localized: "Search")) { [weak self] in self?.startSearch() }
        closeSearch = docToolbarButton("xmark", String(localized: "Close Search")) { [weak self] in self?.endSearch() }
        newItem = docToolbarButton("plus", String(localized: "New Item")) { [weak self] in self?.addItem() }
        viewOptions = docToolbarButton("slider.horizontal.3", String(localized: "View Options")) { [weak self] in self?.toggleViewOptions() }
        searchField.delegate = self
        searchField.addAction(UIAction { [weak self] _ in
            guard let self, let snapshot = self.snapshot else { return }
            self.controller?.searches[snapshot.block] = self.searchField.text ?? ""
        }, for: .editingChanged)
        [searchButton, searchField, closeSearch, newItem, viewOptions].forEach(toolbar.addSubview)
        addSubview(tabs)
        addView = docSymbolButton("plus", weight: .semibold, side: Metrics.tabHeight, title: String(localized: "Add View"))
        addView.docMenu { [weak self] in self?.addViewMenu() ?? [] }
        tabs.addSubview(addView)
        addSubview(table)
        addSubview(kanban)
        addSubview(chartView)
        chartView.heightChanged = { [weak self] in self?.heightChanged?() }
        table.heightChanged = { [weak self] in self?.heightChanged?() }
        hover = DocHover(on: self) { [weak self] _ in self?.showToolbar() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var block: DocBlockID? { snapshot?.block }
    private var collection: DocCollection? { snapshot?.collection }
    private var current: CollectionView? { collection?.currentView }

    // MARK: Showing

    func show(_ snapshot: DocCollectionSnapshot, controller: DocCollectionController) {
        if self.snapshot?.block != snapshot.block {
            searching = false
            renaming = nil
            viewPanelTab = nil
            showedViewPanel = false
        }
        self.snapshot = snapshot
        self.controller = controller
        refresh()
    }

    /// Everything as the controller has it now, again when what it read changes.
    private func refresh() {
        guard let snapshot, let controller else { return }
        withObservationTracking {
            render(snapshot, controller: controller)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.snapshot?.block == snapshot.block else { return }
                self.refresh()
                // Records filtered, a picked row, a cell typed in: its height again.
                let height = self.height(forWidth: self.bounds.width)
                if height != self.shownHeight { self.heightChanged?() }
            }
        }
    }

    private func render(_ snapshot: DocCollectionSnapshot, controller: DocCollectionController) {
        let editable = controller.isEditable
        if !name.isFirstResponder, name.text != snapshot.collection.name { name.text = snapshot.collection.name }
        name.isEnabled = editable
        newItem.isHidden = !editable
        addView.isHidden = !editable
        searchButton.isHidden = searching
        searchField.isHidden = !searching
        closeSearch.isHidden = !searching
        showTabs(snapshot, controller: controller)
        let view = snapshot.collection.currentView
        table.isHidden = true
        kanban.isHidden = true
        chartView.isHidden = true
        switch view?.layout {
        case .table?:
            table.isHidden = false
            table.show(snapshot, view: view!, controller: controller)
        case .kanban(let group, _, _)?:
            kanban.isHidden = false
            kanban.show(snapshot, view: view!, group: group, controller: controller)
        case .chart(let chart)?:
            chartView.isHidden = false
            chartView.show(snapshot, view: view!, chart: chart, controller: controller)
        default:
            break
        }
        followPanels(snapshot, controller: controller)
        showToolbar()
        shownHeight = height(forWidth: bounds.width)
        setNeedsLayout()
    }

    func reset() {
        for spot in [viewSpot, kanbanSpot, chartSpot] { spot?.close() }
        tabButtons.values.forEach { $0.reset() }
        kanban.reset()
        if name.isFirstResponder || searchField.isFirstResponder { endEditing(true) }
    }

    // MARK: Toolbar

    /// Over the block (or with a panel or a search open) on a Mac; always on a phone.
    private func showToolbar() {
        guard let block, let controller else { return }
        let shows = !DocTokens.Platform.isPointer || hover.isOver || searching || controller.panel?.block == block
        toolbar.alpha = shows ? 1 : 0
        toolbar.isUserInteractionEnabled = shows
    }

    private func startSearch() {
        searching = true
        refresh()
        setNeedsLayout()
        layoutIfNeeded()
        searchField.becomeFirstResponder()
    }

    private func endSearch() {
        guard let block else { return }
        controller?.searches[block] = nil
        searchField.text = nil
        searching = false
        searchField.resignFirstResponder()
        refresh()
    }

    private func addItem() {
        guard let block, let controller else { return }
        let row = controller.addRecord(to: block, in: kanbanGroup)
        // A chart doesn't show a record with nothing in it: it opens to be filled in.
        if current?.layout.chart != nil, let row { controller.openRecord?(row, block) }
    }

    /// A new card from the toolbar goes to the first column of a kanban.
    private var kanbanGroup: (column: ColumnID, value: CellValue?)? {
        guard let snapshot, let controller, let current, current.layout.isKanban, let group = current.layout.groupBy else { return nil }
        let first = DocCollectionController.lanes(current, of: controller.rows(snapshot, current), in: snapshot.database).first
        return (group, first?.value)
    }

    /// A small screen's at the window's foot, the text left in view; else beside the button.
    private var viewPanelIsBeside: Bool { DocDevice.isMac || traitCollection.horizontalSizeClass != .compact }

    private func toggleViewOptions() {
        guard let block, let controller else { return }
        if controller.isShowing(.view, in: block) {
            controller.close(.view, in: block)
        } else {
            viewPanelTab = nil
            controller.show(.view, in: block)
        }
    }

    /// The view panel's More.
    private func viewPageMore() -> [FlooMenuSection] {
        current.map { manageSections($0, full: true) } ?? []
    }

    /// Renaming, copying and deleting a view; the panel's also downloads it.
    private func manageSections(_ view: CollectionView, full: Bool) -> [FlooMenuSection] {
        guard let snapshot, let controller else { return [] }
        let block = snapshot.block
        var sections: [FlooMenuSection] = []
        if controller.isEditable {
            sections.append(.init([
                .action(String(localized: "Rename View"), symbol: "character.cursor.ibeam") { [weak self] in
                    self?.renaming = view.id
                    controller.close(.view, in: block)
                    self?.refresh()
                },
                .action(String(localized: "Duplicate View"), symbol: "plus.square.on.square") { controller.duplicate(view.id, in: block) },
                .action(String(localized: "Delete View"), symbol: "trash", role: .destructive, isEnabled: snapshot.collection.views.count > 1) {
                    controller.delete(view.id, in: block)
                },
            ]))
        }
        if full {
            sections.append(.init([
                .action(String(localized: "Download as CSV"), symbol: "arrow.down.circle") {
                    DocCSVExport.save(controller.csv(snapshot, view), named: snapshot.collection.name.isEmpty ? String(localized: "Collection") : snapshot.collection.name)
                },
            ]))
        }
        return sections
    }

    // MARK: Tabs

    private func showTabs(_ snapshot: DocCollectionSnapshot, controller: DocCollectionController) {
        var used: Set<CollectionViewID> = []
        for view in snapshot.collection.views {
            let tab = tabButtons[view.id] ?? {
                let new = DocCollectionTabView()
                tabs.addSubview(new)
                tabButtons[view.id] = new
                return new
            }()
            used.insert(view.id)
            tab.show(view, isCurrent: view.id == snapshot.collection.currentView?.id, isRenaming: renaming == view.id, actions: .init(
                select: { controller.show(view.id, in: snapshot.block) },
                settings: { [weak self] in self?.openSettings(of: view) },
                rename: { [weak self] name in
                    if let name { controller.rename(view.id, in: snapshot.block, to: name) }
                    self?.renaming = nil
                    self?.refresh()
                },
                place: DocFieldPlace(field: [snapshot.block, view.id] as [AnyHashable], block: snapshot.block,
                                     menu: DocPlaceMenu(title: String(localized: "View Actions"), symbol: "ellipsis.circle",
                                                        opens: .rows { [weak self] in self?.manageSections(view, full: false) ?? [] })),
                editor: controller.editor
            ))
        }
        for (id, tab) in tabButtons where !used.contains(id) {
            tab.reset()
            tab.removeFromSuperview()
            tabButtons[id] = nil
        }
    }

    /// A tab's right-click or long press: its view showing, its settings beside the tab.
    private func openSettings(of view: CollectionView) {
        guard let block, let controller else { return }
        if view.id != current?.id { controller.show(view.id, in: block) }
        viewPanelTab = view.id
        controller.show(.view, in: block)
    }

    private func addViewMenu() -> [FlooMenuSection] {
        guard let snapshot, let controller else { return [] }
        let block = snapshot.block
        return [.init([
            .action(String(localized: "Add Table View"), symbol: "tablecells") {
                let view = controller.addView(to: block, name: String(localized: "New Table"), layout: .table(hidden: [], sort: []))
                controller.show(.nameView(view), in: block)
            },
            .action(String(localized: "Add Kanban View"), symbol: "rectangle.split.3x1", isEnabled: !DocCollectionController.groupable(in: snapshot.database).isEmpty) {
                controller.show(.createKanban, in: block)
            },
            .action(String(localized: "Add Chart View"), symbol: "chart.bar.xaxis") {
                controller.show(.createChart, in: block)
            },
        ])]
    }

    // MARK: Panels

    private func followPanels(_ snapshot: DocCollectionSnapshot, controller: DocCollectionController) {
        let block = snapshot.block
        let showsView = controller.isShowing(.view, in: block)
        if viewPanelIsBeside {
            let spot = viewSpot ?? {
                let spot = docPanelSpot(alignment: .trailing, page: { [weak self] in
                    guard let self, let controller = self.controller, let block = self.block else { return UIViewController() }
                    return controller.viewPanelPages(block, more: { [weak self] in self?.viewPageMore() ?? [] })
                }, onDismiss: { [weak self] in
                    guard let self, let block = self.block else { return }
                    self.controller?.close(.view, in: block)
                })
                viewSpot = spot
                return spot
            }()
            spot.show(showsView && viewPanelTab == nil, over: viewOptions)
            if !showsView, showedViewPanel {
                controller.viewPanelClosed()
                viewPanelTab = nil
            }
        } else if showsView != showedViewPanel {
            if showsView {
                controller.openViewPanel(block, more: { [weak self] in self?.viewPageMore() ?? [] })
            } else {
                controller.closeViewPanel()
            }
        }
        showedViewPanel = showsView
        for (id, tab) in tabButtons {
            tab.followPanels(settings: viewPanelIsBeside && showsView && viewPanelTab == id,
                             naming: controller.isShowing(.nameView(id), in: block),
                             settingsPage: { [weak self] in
                                 guard let self, let controller = self.controller, let block = self.block else { return UIViewController() }
                                 return controller.viewPanelPages(block, more: { [weak self] in self?.viewPageMore() ?? [] })
                             },
                             namePage: { [weak self] in
                                 guard let self, let snapshot = self.snapshot, let controller = self.controller,
                                       let view = snapshot.collection.views.first(where: { $0.id == id }) else { return UIViewController() }
                                 return DocNameViewPage(block: snapshot.block, view: view, controller: controller).inNavigation()
                             },
                             close: { [weak controller] kind in controller?.close(kind, in: block) })
        }
        let kanbanPanel = kanbanSpot ?? {
            let spot = docPanelSpot(page: { [weak self] in
                guard let self, let snapshot = self.snapshot, let controller = self.controller else { return UIViewController() }
                return DocCreateKanbanPage(snapshot: snapshot, controller: controller).inNavigation()
            }, onDismiss: { [weak self] in
                guard let self, let block = self.block else { return }
                self.controller?.close(.createKanban, in: block)
            })
            kanbanSpot = spot
            return spot
        }()
        kanbanPanel.show(controller.isShowing(.createKanban, in: block), over: addView)
        let chartPanel = chartSpot ?? {
            let spot = docPanelSpot(page: { [weak self] in
                guard let self, let snapshot = self.snapshot, let controller = self.controller else { return UIViewController() }
                return DocCreateChartPage(snapshot: snapshot, controller: controller).inNavigation()
            }, onDismiss: { [weak self] in
                guard let self, let block = self.block else { return }
                self.controller?.close(.createChart, in: block)
            })
            chartSpot = spot
            return spot
        }()
        chartPanel.show(controller.isShowing(.createChart, in: block), over: addView)
        table.followPanels()
        kanban.followPanels()
    }

    // MARK: Fields

    private var namePlace: DocFieldPlace? {
        block.map { DocFieldPlace(field: [$0, "name"] as [AnyHashable], block: $0) }
    }

    private var searchPlace: DocFieldPlace? {
        block.map { DocFieldPlace(field: [$0, "search"] as [AnyHashable], block: $0) }
    }

    private func nameChanged() {
        guard let block, let controller, let text = name.text, text != collection?.name else { return }
        controller.rename(block, to: text)
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        guard let controller, let place = textField === name ? namePlace : searchPlace else { return }
        controller.editor.field(place, isFocused: true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        guard let controller, let place = textField === name ? namePlace : searchPlace else { return }
        controller.editor.field(place, isFocused: false)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    /// Escape closes the search.
    override var keyCommands: [UIKeyCommand]? {
        guard searchField.isFirstResponder else { return nil }
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    @objc private func escape() { endSearch() }

    // MARK: Layout

    private static var buttonHeight: CGFloat { FlooButtonMetrics.of(.small).height }
    private static var nameRow: CGFloat { max(ceil(nameFont.lineHeight), buttonHeight) }
    private static var headerHeight: CGFloat { nameRow + DocTokens.Space.sm + Metrics.tabHeight }

    /// Its height at a width: its padding, the header, the view's.
    static func height(_ snapshot: DocCollectionSnapshot, controller: DocCollectionController, width: CGFloat) -> CGFloat {
        var body: CGFloat = 0
        if let view = snapshot.collection.currentView {
            switch view.layout {
            case .table: body = DocCollectionTableView.height(snapshot, view: view, controller: controller, width: width)
            case .kanban: body = DocCollectionKanbanView.height(snapshot, view: view, controller: controller)
            case .chart(let chart): body = DocCollectionChartView.height(snapshot, view: view, chart: chart, controller: controller, width: width)
            }
        }
        return DocTokens.Space.sm + headerHeight + Metrics.headerGap + body + DocTokens.Space.sm
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let snapshot, let controller else { return 0 }
        return Self.height(snapshot, controller: controller, width: width)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        var y = DocTokens.Space.sm
        let row = Self.nameRow
        // The toolbar at the name's right.
        let height = Self.buttonHeight
        var x = width
        var toolbarItems: [UIView] = [viewOptions]
        if !newItem.isHidden { toolbarItems.append(newItem) }
        var placed: [(UIView, CGFloat)] = []
        for item in toolbarItems {
            let size = item.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: height))
            x -= max(size.width, height)
            placed.append((item, x))
            x -= DocTokens.Space.xs
        }
        x += DocTokens.Space.xs - DocTokens.Space.sm
        if searching {
            let close = max(closeSearch.sizeThatFits(.zero).width, height)
            x -= close
            placed.append((closeSearch, x))
            x -= DocTokens.Space.xs + Metrics.searchWidth
            placed.append((searchField, x))
        } else {
            let size = max(searchButton.sizeThatFits(.zero).width, height)
            x -= size
            placed.append((searchButton, x))
        }
        let toolbarLeft = x
        toolbar.frame = CGRect(x: toolbarLeft, y: y + (row - height) / 2, width: width - toolbarLeft, height: height)
        for (item, itemX) in placed {
            let itemWidth = item === searchField ? Metrics.searchWidth : max(item.sizeThatFits(.zero).width, height)
            item.frame = CGRect(x: itemX - toolbarLeft, y: 0, width: itemWidth, height: height)
        }
        viewSpot?.frame = viewOptions.bounds
        name.frame = CGRect(x: 0, y: y, width: max(0, toolbarLeft - DocTokens.Space.md), height: row)
        y += row + DocTokens.Space.sm
        // A tab's words line up with the name; its fill reaches out past them (Craft's).
        tabs.frame = CGRect(x: -DocTokens.Space.sm, y: y, width: width + DocTokens.Space.sm, height: Metrics.tabHeight)
        var tabX: CGFloat = 0
        for view in collection?.views ?? [] {
            guard let tab = tabButtons[view.id] else { continue }
            let tabWidth = tab.width
            tab.frame = CGRect(x: tabX, y: 0, width: tabWidth, height: Metrics.tabHeight)
            tabX += tabWidth + DocTokens.Space.xxs
        }
        addView.frame = CGRect(x: tabX, y: 0, width: Metrics.tabHeight, height: Metrics.tabHeight)
        kanbanSpot?.frame = addView.bounds
        chartSpot?.frame = addView.bounds
        y += Metrics.tabHeight + Metrics.headerGap
        let bodyHeight = max(0, bounds.height - y - DocTokens.Space.sm)
        table.frame = CGRect(x: 0, y: y, width: width, height: bodyHeight)
        kanban.frame = CGRect(x: 0, y: y, width: width, height: bodyHeight)
        chartView.frame = CGRect(x: 0, y: y, width: width, height: bodyHeight)
    }
}

// MARK: - A view's tab

/// A view's tab: its name (the current one on the selected fill), or the field renaming it;
/// a right-click or a long press opens its settings beside it.
@MainActor
private final class DocCollectionTabView: UIView, UITextFieldDelegate {
    struct Actions {
        let select: () -> Void
        let settings: () -> Void
        /// The new name, or nil: renaming ended.
        let rename: (String?) -> Void
        let place: DocFieldPlace
        let editor: DocEditor
    }

    private let title = UILabel()
    private var button: FlooContentButton!
    private let field = UITextField()
    private var actions: Actions?
    private var settingsSpot: FlooPanelAnchorView?
    private var nameSpot: FlooPanelAnchorView?

    private static let font = UIFont.systemFont(ofSize: Metrics.tabSize, weight: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = Self.font
        title.isUserInteractionEnabled = false
        let content = UIView()
        content.addSubview(title)
        button = FlooContentButton(content: content, shape: .corner(Metrics.corner)) { [weak self] in self?.actions?.select() }
        button.layer.cornerRadius = Metrics.corner
        button.layer.cornerCurve = .continuous
        addSubview(button)
        field.font = Self.font
        field.delegate = self
        field.layer.cornerRadius = Metrics.corner
        field.layer.cornerCurve = .continuous
        field.backgroundColor = .floo(.markdownBlockSelected)
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: DocTokens.Space.sm, height: 1))
        field.leftViewMode = .always
        field.isHidden = true
        addSubview(field)
        // What opens the view's settings: a right-click on the Mac, a long press by touch.
        if DocDevice.isMac {
            let press = UITapGestureRecognizer(target: self, action: #selector(pressed(_:)))
            press.buttonMaskRequired = .secondary
            addGestureRecognizer(press)
        } else {
            addGestureRecognizer(DocOwnPress(target: self, action: #selector(pressed(_:))))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func pressed(_ recognizer: UIGestureRecognizer) {
        let fires = recognizer is UILongPressGestureRecognizer ? recognizer.state == .began : recognizer.state == .ended
        if fires { actions?.settings() }
    }

    func show(_ view: CollectionView, isCurrent: Bool, isRenaming: Bool, actions: Actions) {
        self.actions = actions
        title.text = view.name
        title.textColor = isCurrent ? .floo(.label) : .floo(.secondaryLabel)
        button.backgroundColor = isCurrent ? .floo(.markdownBlockSelected) : nil
        button.accessibilityLabel = view.name
        let wasRenaming = !field.isHidden
        field.isHidden = !isRenaming
        button.isHidden = isRenaming
        if isRenaming, !wasRenaming {
            field.text = view.name
            DispatchQueue.main.async { [weak self] in self?.field.becomeFirstResponder() }
        }
        setNeedsLayout()
    }

    var width: CGFloat {
        let text = field.isHidden ? (title.text ?? "") : (field.text ?? "")
        return ceil((text as NSString).size(withAttributes: [.font: Self.font]).width) + 2 * DocTokens.Space.sm + (field.isHidden ? 0 : 2)
    }

    func followPanels(settings: Bool, naming: Bool, settingsPage: @escaping @MainActor () -> UIViewController,
                      namePage: @escaping @MainActor () -> UIViewController, close: @escaping @MainActor (DocCollectionPanel.Kind) -> Void) {
        let settingsSpot = settingsSpot ?? {
            let spot = docPanelSpot(page: settingsPage, onDismiss: { close(.view) })
            self.settingsSpot = spot
            return spot
        }()
        settingsSpot.show(settings, over: button)
        guard let id = viewID else { return }
        let nameSpot = nameSpot ?? {
            let spot = docPanelSpot(page: namePage, onDismiss: { close(.nameView(id)) })
            self.nameSpot = spot
            return spot
        }()
        nameSpot.show(naming, over: button)
    }

    private var viewID: CollectionViewID? {
        (actions?.place.field as? [AnyHashable])?.last?.base as? CollectionViewID
    }

    func reset() {
        settingsSpot?.close()
        nameSpot?.close()
        if field.isFirstResponder { field.resignFirstResponder() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = bounds
        title.frame = CGRect(x: DocTokens.Space.sm, y: 0, width: max(0, bounds.width - 2 * DocTokens.Space.sm), height: bounds.height)
        field.frame = bounds
        settingsSpot?.frame = button.bounds
        nameSpot?.frame = button.bounds
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        guard let actions else { return }
        actions.editor.field(actions.place, isFocused: true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        guard let actions else { return }
        actions.editor.field(actions.place, isFocused: false)
        if !field.isHidden { actions.rename(nil) }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let name = field.text ?? ""
        field.isHidden = true
        actions?.rename(name)
        field.resignFirstResponder()
        return true
    }

    /// Escape leaves the name as it was.
    override var keyCommands: [UIKeyCommand]? {
        guard field.isFirstResponder else { return nil }
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    @objc private func escape() {
        field.isHidden = true
        field.resignFirstResponder()
        actions?.rename(nil)
    }
}

// MARK: - A record's fields

/// A record's fields row: on the record's page, under its title.
@MainActor
struct DocRecordFieldsRowContent: TiledUIKitCellContent {
    var drivesRowMoves: Bool { true }

    let row: DocRow
    let link: DocRecordLink
    let page: DocDemo

    static func makeRowView() -> DocRecordFieldsRowView { DocRecordFieldsRowView() }

    func configure(_ view: DocRecordFieldsRowView, context: TiledUIKitCellContext) {
        view.show(row, link: link, page: page, context: context)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        DocRowUIKitView.frames(of: row, width: width, contentHeight: DocRecordFieldsView.height(link, width: DocRowUIKitView.contentWidth(of: row, width: width))).height
    }

    static func prepareForReuse(_ view: DocRecordFieldsRowView) {
        view.reset()
    }
}

@MainActor
final class DocRecordFieldsRowView: DocRowUIKitView {
    private let fields = DocRecordFieldsView()

    init() {
        super.init(content: fields)
        fields.heightChanged = { [weak self] in self?.contentHeightChanged() }
    }

    func show(_ row: DocRow, link: DocRecordLink, page: DocDemo, context: TiledUIKitCellContext) {
        take(row, blocks: link.controller.editor.blocks, context: context)
        fields.show(link, page: page)
        layOutShown()
    }

    override func reset() {
        super.reset()
        fields.reset()
    }

    override func contentHeight(forWidth width: CGFloat) -> CGFloat {
        fields.height(forWidth: width)
    }
}

/// Each field a row of its name and its value (a compact cell), Add Field, a line.
@MainActor
final class DocRecordFieldsView: UIView {
    private var rows: [ColumnID: (label: UILabel, cell: DocCollectionCellView)] = [:]
    private var order: [ColumnID] = []
    private var addField: FlooContentButton!
    private var addSpot: FlooPanelAnchorView?
    private let line = FlooDivider()
    private var link: DocRecordLink?
    private weak var page: DocDemo?
    private var fieldCount: Int?
    var heightChanged: (() -> Void)?

    private static let labelFont = UIFont.systemFont(ofSize: 15)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let label = UILabel()
        label.attributedText = Self.labelText(String(localized: "Add Field"), symbol: "plus")
        label.isUserInteractionEnabled = false
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let content = UIView()
        content.addSubview(label)
        addField = FlooContentButton(content: content, shape: .corner(0), accessibilityLabel: String(localized: "Add Field")) { [weak self] in
            guard let self, let link = self.link else { return }
            link.controller.show(.addField, in: link.block)
        }
        addSubview(addField)
        addSubview(line)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A field's name after its type's symbol, as Label draws it.
    private static func labelText(_ name: String, symbol: String) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: labelFont))?.withTintColor(.floo(.secondaryLabel), renderingMode: .alwaysOriginal) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            text.append(NSAttributedString(string: "  "))
        }
        text.append(NSAttributedString(string: name, attributes: [.font: labelFont, .foregroundColor: UIColor.floo(.secondaryLabel)]))
        return text
    }

    func show(_ link: DocRecordLink, page: DocDemo) {
        self.link = link
        self.page = page
        refresh()
    }

    private func refresh() {
        guard let link else { return }
        withObservationTracking {
            render(link)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.link === link else { return }
                self.refresh()
                self.heightChanged?()
            }
        }
    }

    private func render(_ link: DocRecordLink) {
        // The page's rows again when fields come or go.
        let count = link.fieldCount
        if let shown = fieldCount, shown != count { DispatchQueue.main.async { [weak page] in page?.republish() } }
        fieldCount = count
        guard let snapshot = link.snapshot, let record = link.record else {
            order = []
            rows.values.forEach { $0.label.removeFromSuperview(); $0.cell.removeFromSuperview() }
            rows = [:]
            return
        }
        let fields = link.fields
        order = fields.map(\.id)
        var used: Set<ColumnID> = []
        for column in fields {
            let row = rows[column.id] ?? {
                let label = UILabel()
                label.lineBreakMode = .byTruncatingTail
                let cell = DocCollectionCellView(compact: true)
                addSubview(label)
                addSubview(cell)
                rows[column.id] = (label, cell)
                return (label, cell)
            }()
            used.insert(column.id)
            row.label.attributedText = Self.labelText(column.name, symbol: DocFieldText.symbol(column))
            row.cell.show(.init(snapshot: snapshot, row: record, column: column, controller: link.controller))
        }
        for (id, row) in rows where !used.contains(id) {
            row.cell.reset()
            row.label.removeFromSuperview()
            row.cell.removeFromSuperview()
            rows[id] = nil
        }
        addField.isHidden = !link.controller.isEditable
        let spot = addSpot ?? {
            let spot = docPanelSpot(page: { [weak self] in
                guard let link = self?.link else { return UIViewController() }
                return DocFieldPage(column: nil, block: link.block, controller: link.controller).inNavigation()
            }, onDismiss: { [weak self] in
                guard let link = self?.link else { return }
                link.controller.close(.addField, in: link.block)
            })
            addSpot = spot
            return spot
        }()
        spot.show(link.controller.isShowing(.addField, in: link.block), over: addField)
        setNeedsLayout()
    }

    func reset() {
        addSpot?.close()
        rows.values.forEach { $0.cell.reset() }
    }

    /// Each half of the row, the gap between.
    private static func half(_ width: CGFloat) -> CGFloat { max(0, (width - DocTokens.Space.md) / 2) }

    static func height(_ link: DocRecordLink, width: CGFloat) -> CGFloat {
        guard let record = link.record else { return DocTablePlan.line }
        let fields = link.fields.map { column in
            max(Metrics.rowHeight, DocCollectionCellView.height(of: record, column: column, isTitle: false, compact: true, hasPage: false, width: half(width)))
        }.reduce(0, +)
        return fields + (link.controller.isEditable ? Metrics.rowHeight : 0) + DocTablePlan.line
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        link.map { Self.height($0, width: width) } ?? 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let link, let record = link.record else { return }
        let half = Self.half(bounds.width)
        var y: CGFloat = 0
        for column in link.fields {
            guard let row = rows[column.id] else { continue }
            let height = max(Metrics.rowHeight, DocCollectionCellView.height(of: record, column: column, isTitle: false, compact: true, hasPage: false, width: half))
            row.label.frame = CGRect(x: 0, y: y, width: half, height: Metrics.rowHeight)
            row.cell.frame = CGRect(x: half + DocTokens.Space.md, y: y, width: half, height: height)
            y += height
        }
        if !addField.isHidden {
            addField.frame = CGRect(x: 0, y: y, width: bounds.width, height: Metrics.rowHeight)
            addSpot?.frame = addField.bounds
            y += Metrics.rowHeight
        }
        line.frame = CGRect(x: 0, y: y, width: bounds.width, height: DocTablePlan.line)
    }
}
