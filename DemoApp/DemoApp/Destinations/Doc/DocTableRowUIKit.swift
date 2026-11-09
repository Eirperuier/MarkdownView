//
//  DocTableRowUIKit.swift
//  DemoApp
//
//  A database block as a UIKit row: MarkdownUIKit's table, wide ones scrolling sideways.
//  Clicks on cells edit them; the edited cell shows its editor in the table's place for it
//  (its text, Craft's ring, its ⋮), and around it, on the table's edges, the bars that pick
//  its row or column and the dots that add one (DocTableEdgesView). While the Mac writes a
//  cell's formula in its panel, the table wears the columns' letters and the rows' numbers.
//

import DocKit
import FlooUIKit
import Markdown
import MarkdownCore
import MarkdownUIKit
import MessagingUI
import Observation
import UIKit

private typealias Handles = DocTokens.Component.TableHandles

/// A table row's content: the table, its markdown, and who edits it.
@MainActor
struct DocTableRowContent: TiledUIKitCellContent {
    /// Its row runs a reshape's animation and the rows round it move in its frames.
    var drivesRowMoves: Bool { true }

    let row: DocRow
    let table: DocTableSnapshot
    let source: String
    let controller: DocTableController

    static func makeRowView() -> DocTableRowView { DocTableRowView() }

    func configure(_ view: DocTableRowView, context: TiledUIKitCellContext) {
        view.show(row, table: table, source: source, controller: controller, context: context)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        DocTableRowView.height(of: row, table: table, source: source, controller: controller, width: width)
    }

    static func prepareForReuse(_ view: DocTableRowView) {
        view.reset()
    }
}

@MainActor
final class DocTableRowView: DocRowUIKitView {
    private let table = DocTableView()
    private var snapshot: DocTableSnapshot?
    private var source: String?
    private weak var controller: DocTableController?

    init() {
        super.init(content: table)
        table.onCellsMoved = { [weak self] in self?.cellsMoved() }
        table.onHeightChange = { [weak self] in self?.contentHeightChanged() }
    }

    func show(_ row: DocRow, table snapshot: DocTableSnapshot, source: String, controller: DocTableController, context: TiledUIKitCellContext) {
        if let old = self.snapshot?.block, old != snapshot.block { controller.placed(old, finder: nil) }
        self.snapshot = snapshot
        self.source = source
        self.controller = controller
        take(row, blocks: controller.editor.blocks, context: context)
        let block = snapshot.block
        controller.placed(block, finder: { [weak self] point in
            guard let self, self.snapshot?.block == block else { return nil }
            return self.table.position(at: self.convert(point, to: self.table))
        })
        follow()
        layOutShown()
    }

    /// The table as the controller has it: the edited cell's editor, the Mac's formula, the
    /// edges. Shown again as any of them changes.
    private func follow() {
        guard let snapshot, let source, let controller else { return }
        withObservationTracking {
            table.show(snapshot, source: source, controller: controller)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.snapshot?.block == snapshot.block else { return }
                self.follow()
            }
        }
        contentHeightChanged()
    }

    override func reset() {
        if let block = snapshot?.block { controller?.placed(block, finder: nil) }
        super.reset()
        snapshot = nil
        source = nil
        table.forget()
    }

    override func contentHeight(forWidth width: CGFloat) -> CGFloat {
        table.height(forWidth: width)
    }

    /// Where the cells are in the row (for a click the table doesn't take, and a selected
    /// table's highlight), and in the window (the formula's page flies from there).
    private func cellsMoved() {
        guard let block = snapshot?.block, let controller else { return }
        controller.placed(block, cells: table.cellsFrame.map { table.convert($0, to: self) })
        if window != nil { controller.tableFrames[block] = table.convert(table.tableBounds, to: nil) }
    }

    private static let sizing = DocTableView(measuresOnly: true)

    static func height(of row: DocRow, table: DocTableSnapshot, source: String, controller: DocTableController, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 1 }
        sizing.show(table, source: source, controller: controller)
        return frames(of: row, width: width, contentHeight: sizing.height(forWidth: contentWidth(of: row, width: width))).height
    }
}

/// The table and what's drawn round the edited cell: room on the right and below for the
/// dots on those edges, in the row (a touch out of it goes nowhere).
@MainActor
final class DocTableView: UIView {
    private let tableView = MarkdownUIKit.MarkdownTableView()
    private let edges = DocTableEdgesView()
    private let measuresOnly: Bool
    private var snapshot: DocTableSnapshot?
    private weak var controller: DocTableController?
    /// The editors in the table now, by cell.
    private var editors: [DocCellKey: DocTableCellEditorView] = [:]
    var onCellsMoved: (() -> Void)?
    var onHeightChange: (() -> Void)?
    private var shownHeight: CGFloat?

    init(measuresOnly: Bool = false) {
        self.measuresOnly = measuresOnly
        super.init(frame: .zero)
        addSubview(tableView)
        addSubview(edges)
        tableView.onCellsMoved = { [weak self] in
            guard let self else { return }
            self.placeEdges()
            self.onCellsMoved?()
            // An editor came or went, or its text changed size: the row is told.
            let height = self.tableView.height(forWidth: self.tableView.bounds.width)
            if let shown = self.shownHeight, abs(shown - height) > 0.5 { self.onHeightChange?() }
            self.shownHeight = height
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// How many times tables were shown (a test's count: a still table isn't shown again).
    static var shows = 0

    /// Reads the controller's state: called inside the row's observation.
    func show(_ snapshot: DocTableSnapshot, source: String, controller: DocTableController) {
        if !measuresOnly { Self.shows += 1 }
        // Another table: the last one's editors go with it.
        if let shown = self.snapshot?.block, shown != snapshot.block {
            for editor in editors.values { editor.dropped() }
            editors.removeAll()
            tableView.prepareForReuse()
        }
        self.snapshot = snapshot
        self.controller = controller
        let formula = controller.formulaPanel(in: snapshot.block)
        var style = MarkdownUIKit.MarkdownStyle()
        style.typography = DocUIKitType.body(design: nil)
        style.addsEdgeInsets = false
        // Wide tables scroll sideways instead of squeezing their columns; cells at the page's
        // body size (their editor's).
        style.table.scrollsSideways = true
        style.table.bodyFont = .init(.body)
        style.table.appearance = controller.uikitAppearance(of: snapshot)
        style.table.cellsSelectable = true
        if !measuresOnly {
            // The edited cell shows its editor; measured, it's as its text (the row tells the
            // list of the editor's own height once it's laid out).
            style.table.replacedCells = controller.replaced(in: snapshot)
            style.table.replacement = { [weak self] position in self?.editor(at: position) }
            style.table.onCellTap = { [controller] position in controller.clicked(snapshot, at: position) }
            if let formula {
                style.table.decoration = { frames in DocFormulaDecorationView(frames: frames, formula: formula, ringsCell: false) }
            }
        }
        // Editors of cells no longer edited go: the table drops their views.
        let replaced = style.table.replacedCells
        let kept = editors.filter { key, _ in controller.position(of: key, in: snapshot).map(replaced.contains) ?? false }
        for (key, editor) in editors where kept[key] == nil { editor.dropped() }
        editors = kept
        tableView.configure(source: source, style: style)
        for editor in editors.values { editor.refresh() }
        guard !measuresOnly else { return }
        // While a phone writes its formula it's on a page of its own (DocTableFormula): one
        // table on screen, the one flying there and back.
        tableView.alpha = !DocDevice.isMac && controller.formula?.key.block == snapshot.block ? 0 : 1
        edges.show(controller: controller, block: snapshot.block)
        setNeedsLayout()
        // An editor that came takes the focus now: it's at its cell before anything asks
        // where it is (a click's point, the caret's place to scroll to).
        if window != nil, bounds.width > 0 { layoutIfNeeded() }
    }

    func forget() {
        snapshot = nil
        for editor in editors.values { editor.dropped() }
        editors.removeAll()
        tableView.prepareForReuse()
        edges.hide()
    }

    /// The editor the table shows in an edited cell's place.
    private func editor(at position: MarkdownTableCellPosition) -> UIView? {
        guard let snapshot, let controller, let key = controller.key(in: snapshot, at: position), controller.isEditor(key) else { return nil }
        let editor = editors[key] ?? DocTableCellEditorView(key: key, controller: controller, measuresOnly: measuresOnly)
        editors[key] = editor
        return editor
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        tableView.height(forWidth: max(0, width - Handles.target / 2)) + Handles.target / 2
    }

    func position(at point: CGPoint) -> MarkdownTableCellPosition? {
        tableView.position(at: convert(point, to: tableView))
    }

    /// Where the cells are, in its own space.
    var cellsFrame: CGRect? { tableView.cellsFrame.map { tableView.convert($0, to: self) } }
    /// The table's own bounds.
    var tableBounds: CGRect { tableView.frame }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - Handles.target / 2), height: max(0, bounds.height - Handles.target / 2))
        if tableView.frame != frame { tableView.frame = frame }
        edges.frame = bounds
        placeEdges()
    }

    /// The edges by the edited cell, its ring where the table puts its editor.
    private func placeEdges() {
        guard let controller, let snapshot, let key = controller.editing, key.block == snapshot.block, controller.formula == nil,
              let editor = editors[key], editor.superview != nil, let cells = cellsFrame
        else { return edges.place(nil) }
        let ring = editor.convert(editor.bounds, to: self).insetBy(dx: -Handles.ringOutset.width, dy: -Handles.ringOutset.height)
        edges.place((key: key, table: cells, cell: ring))
    }

    /// The edges' bars and dots reach past the table, into the page's margin.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || edges.takes(convert(point, to: edges))
    }
}

extension DocTableController {
    /// Whether the cell shows its editor: the edited one, and the one handing the focus over.
    func isEditor(_ key: DocCellKey) -> Bool {
        replacedKeys.contains(key)
    }
}

// MARK: - The edited cell

/// The edited cell: its text (a column's name in a text view of its own, a body cell's
/// text the editor's), Craft's ring around the cell, its ⋮. On the Mac, while its formula is
/// written, the panel under it.
@MainActor
final class DocTableCellEditorView: UIView {
    let key: DocCellKey
    private weak var controller: DocTableController?
    private let measuresOnly: Bool
    private let ring = UIView()
    private lazy var menuButton = DocTableMenuButton(target: DocTableMenuTarget(key: key))
    private var content: Content?

    private enum Content {
        case header(DocCellTextView)
        case placeholder(DocFormulaPlaceholderView)
        case result(UILabel)
        case text(MarkdownUIKit.MarkdownBlockView)

        var view: UIView {
            switch self {
            case .header(let view): view
            case .placeholder(let view): view
            case .result(let view): view
            case .text(let view): view
            }
        }
    }

    private lazy var formulaPanel: FlooPanelAnchorView = {
        let anchor = FlooPanelAnchorView { [weak self] _, _ in
            guard let controller = self?.controller, let formula = controller.formula else { return UIViewController() }
            return DocFormulaPage(formula: formula, done: { controller.finishFormula(writes: true) }, cancel: { controller.finishFormula(writes: false) })
        }
        anchor.update = { [weak self] page, _, _ in
            guard let formula = self?.controller?.formula else { return }
            (page as? DocFormulaPage)?.show(formula)
        }
        anchor.options.alignment = .center
        anchor.options.selfDrawn = true
        if let controller { anchor.options.keepsOpen = controller.formulaPanelKeepsOpen(key) }
        anchor.onDismiss = { [weak self] in self?.controller?.finishFormula(writes: true) }
        addSubview(anchor)
        formulaPanelMade = true
        return anchor
    }()
    private var formulaPanelMade = false

    init(key: DocCellKey, controller: DocTableController, measuresOnly: Bool) {
        self.key = key
        self.controller = controller
        self.measuresOnly = measuresOnly
        super.init(frame: .zero)
        clipsToBounds = false
        ring.isUserInteractionEnabled = false
        ring.layer.cornerRadius = Handles.ringRadius
        ring.layer.cornerCurve = .continuous
        ring.layer.borderWidth = DocTokens.Border.focus
        addSubview(ring)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.updateColors() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateColors() {
        ring.layer.borderColor = UIColor.floo(.label).resolvedColor(with: traitCollection).cgColor
    }

    /// Shows what the cell has now (read inside the row's observation).
    func refresh() {
        guard let controller else { return }
        let formula = controller.formulaPanel(in: key.block)
        if key.row == nil {
            let view: DocCellTextView
            if case .header(let shown) = content { view = shown } else { view = DocCellTextView.make(); replace(with: .header(view)) }
            if measuresOnly {
                view.font = controller.look(key).font
                view.text = controller.text(key)
            } else {
                view.show(key: key, text: controller.text(key), isHeader: true, controller: controller)
            }
        } else if let formula, formula.key == key {
            let view: DocFormulaPlaceholderView
            if case .placeholder(let shown) = content { view = shown } else { view = DocFormulaPlaceholderView(); replace(with: .placeholder(view)) }
            view.show(key: key, controller: controller, formula: formula)
        } else if controller.writesFormulaApart(key) {
            // What it computes; a click or tap writes the formula apart.
            let label: UILabel
            if case .result(let shown) = content { label = shown } else {
                label = UILabel()
                label.isUserInteractionEnabled = true
                label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(editFormula)))
                replace(with: .result(label))
            }
            let look = controller.look(key)
            label.text = controller.result(key) ?? ""
            label.font = look.font
            label.textColor = .floo(.label)
            label.textAlignment = look.textAlignment
        } else {
            let view: MarkdownUIKit.MarkdownBlockView
            if case .text(let shown) = content { view = shown } else { view = MarkdownUIKit.MarkdownBlockView(); replace(with: .text(view)) }
            let text = controller.docText(key)
            view.configure(document: text.lineTree, style: Self.textStyle(controller.look(key)))
            if !measuresOnly, let textView = view.textViews.first {
                let id = controller.textID(key)
                controller.editor.attachRowText(textView, to: id)
                controller.editor.rowTextChanged(textView, in: id)
            }
        }
        guard !measuresOnly else { return }
        // Where the table draws the cell's fill; while its row or column is picked, that one
        // is ringed instead (DocTableEdgesView).
        ring.isHidden = controller.line != nil
        // Not while its formula is written (Craft's).
        let showsMenu = formula?.key != key
        if showsMenu, menuButton.superview == nil { addSubview(menuButton) }
        menuButton.isHidden = !showsMenu
        menuButton.follow(controller)
        formulaPanel.setPresented(DocDevice.isMac && formula?.key == key && formula?.isShown == true)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func replace(with new: Content) {
        content?.view.removeFromSuperview()
        content = new
        insertSubview(new.view, at: 0)
    }

    @objc private func editFormula() {
        controller?.editFormula(key)
    }

    /// The table dropped it (its cell isn't edited now): what it opened goes with it, as a
    /// panel goes when what it stands by does.
    func dropped() {
        menuButton.close()
        if formulaPanelMade { formulaPanel.close() }
        if let controller, controller.menu == DocTableMenuTarget(key: key) { controller.closeMenu() }
    }

    /// The table cell's text as the table sets a body cell (MarkdownTableContent's look): its
    /// body type with no text style's leading, in the cell's typeface and alignment, a header
    /// column's in bold.
    private static func textStyle(_ look: DocCellLook) -> MarkdownUIKit.MarkdownStyle {
        var style = MarkdownUIKit.MarkdownStyle()
        var body = MarkdownUIKit.MarkdownTypography.Style(.body)
        body.keepsTextStyleLeading = false
        body.design = look.style.font.flatMap(DocCellLook.systemDesign)
        if look.isHeaderColumn { body.weight = .bold }
        style.typography = MarkdownUIKit.MarkdownTypography(body: body, headings: DocUIKitType.body(design: body.design).headings,
                                                            inlineCode: .init(.callout), strongWeight: .semibold)
        style.typography.paragraphAlignment = look.textAlignment
        // The system font at the body's size, as the table's cells (not the text style's, with its leading).
        var font = UIFont.systemFont(ofSize: look.font.pointSize, weight: body.weight)
        if let design = body.design, let descriptor = font.fontDescriptor.withDesign(design) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
        style.defaultFont = font
        style.textColor = .floo(.markdownTableText)
        style.lineSpacing = 0
        style.addsEdgeInsets = false
        style.drawsTextUntilTouched = false
        return style
    }

    /// Unconstrained: the text's own width (the table sizes its column from it, as from a
    /// drawn cell); given a width: that width, its text wrapped.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        guard let controller else { return .zero }
        let unlimited = size.width > 100_000
        let look = controller.look(key)
        let font = look.font
        let string: String = switch content {
        case .header: controller.text(key)
        case .placeholder, .result: controller.result(key) ?? controller.text(key)
        default: controller.docText(key).string
        }
        let natural = ceil((string as NSString).size(withAttributes: [.font: font]).width) + 2
        let width = unlimited ? natural : size.width
        let height: CGFloat = switch content {
        case .header(let view): view.fittingSize(width, text: string, font: font).height
        case .text(let view): view.height(forWidth: width)
        default: font.lineHeight
        }
        let scale = max(1, traitCollection.displayScale)
        return CGSize(width: width, height: max(height, (font.lineHeight * scale).rounded(.up) / scale))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let controller else { return }
        let look = controller.look(key)
        if let content {
            // Its room's top, by the cell's alignment: a header's text view fills it.
            let size = content.view.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
            switch content {
            case .text(let view):
                view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: view.height(forWidth: bounds.width))
            case .placeholder, .header:
                content.view.frame = bounds
            case .result:
                content.view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, size.height))
            }
        }
        _ = look
        ring.frame = bounds.insetBy(dx: -Handles.ringOutset.width, dy: -Handles.ringOutset.height)
        let button = Handles.menuButton
        menuButton.frame = CGRect(x: bounds.width - button.width + Handles.menuButtonOffset, y: (bounds.height - button.height) / 2,
                                  width: button.width, height: button.height)
        if formulaPanel.superview != nil { formulaPanel.frame = bounds }
    }

    /// Its ⋮ stands over the cell's padding, past its edge.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || (!menuButton.isHidden && menuButton.superview != nil && menuButton.frame.contains(point))
    }
}

/// The formula's cell while the Mac writes it: Craft's "Edit Formula", in the room of what
/// the cell shows, so its column stays as wide; what the cell shows comes back as the panel closes.
@MainActor
final class DocFormulaPlaceholderView: UIView {
    private let value = UILabel()
    private let prompt = UILabel()
    private var shown: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        prompt.text = String(localized: "Edit Formula")
        prompt.textColor = .floo(.disabledLabel)
        prompt.adjustsFontSizeToFitWidth = true
        prompt.minimumScaleFactor = 0.7
        value.textColor = .floo(.label)
        addSubview(value)
        addSubview(prompt)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(key: DocCellKey, controller: DocTableController, formula: DocFormulaEditing) {
        let look = controller.look(key)
        value.text = controller.result(key) ?? controller.text(key)
        value.font = look.font
        value.textAlignment = look.textAlignment
        prompt.font = look.font
        prompt.textAlignment = look.textAlignment
        let isShown = formula.isShown
        guard isShown != shown else { return }
        let first = shown == nil
        shown = isShown
        let change = {
            self.value.alpha = isShown ? 0 : 1
            self.prompt.alpha = isShown ? 1 : 0
        }
        if first { change() } else { (isShown ? FlooMotion.appear : FlooMotion.disappear).animate(change) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        value.frame = CGRect(x: 0, y: 0, width: bounds.width, height: value.font.lineHeight.rounded(.up))
        prompt.frame = bounds
    }
}

// MARK: - The table's edges

/// On the table's edges, by the edited cell (Craft's): bars on the top and left over its
/// column and row, which pick them; dots on the right and bottom, which add a column or a
/// row; the picked row or column ringed.
@MainActor
final class DocTableEdgesView: UIView {
    private let lineRing = UIView()
    private let columnGrip = DocTableGripButton(line: .column)
    private let rowGrip = DocTableGripButton(line: .row)
    private let columnDot = DocTableEdgeDot(label: String(localized: "Add Column"))
    private let rowDot = DocTableEdgeDot(label: String(localized: "Add Row"))
    private weak var controller: DocTableController?
    private var placed: (key: DocCellKey, table: CGRect, cell: CGRect)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        lineRing.isUserInteractionEnabled = false
        lineRing.layer.cornerRadius = Handles.ringRadius
        lineRing.layer.cornerCurve = .continuous
        lineRing.layer.borderWidth = DocTokens.Border.focus
        for view in [lineRing, columnGrip, rowGrip, columnDot, rowDot] {
            view.isHidden = true
            addSubview(view)
        }
        columnDot.action = { [weak self] in
            guard let self, let key = self.placed?.key else { return }
            self.controller?.appendColumn(beside: key)
        }
        rowDot.action = { [weak self] in
            guard let self, let key = self.placed?.key else { return }
            self.controller?.appendRow(below: key)
        }
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.updateColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateColors() {
        lineRing.layer.borderColor = UIColor.floo(.label).resolvedColor(with: traitCollection).cgColor
    }

    /// Follows the controller's picked line and menus (read inside the row's observation).
    func show(controller: DocTableController, block: DocBlockID) {
        self.controller = controller
        columnGrip.controller = controller
        rowGrip.controller = controller
        if let key = controller.editing, key.block == block {
            columnGrip.follow(controller, key: key)
            rowGrip.follow(controller, key: key)
        }
        _ = controller.line
        _ = controller.isEditable
        layoutEdges()
    }

    func hide() {
        place(nil)
    }

    func place(_ placed: (key: DocCellKey, table: CGRect, cell: CGRect)?) {
        self.placed = placed
        layoutEdges()
    }

    private func layoutEdges() {
        guard let placed, let controller else {
            for view in [lineRing, columnGrip, rowGrip, columnDot, rowDot] { view.isHidden = true }
            return
        }
        let (table, cell) = (placed.table, placed.cell)
        if let line = controller.line {
            lineRing.isHidden = false
            lineRing.frame = line == .column
                ? CGRect(x: cell.minX, y: table.minY, width: cell.width, height: table.height)
                // Out past the table's edges as far as its rows' stripes.
                : CGRect(x: table.minX - Handles.rowOutset.leading, y: cell.minY,
                         width: table.width + Handles.rowOutset.leading + Handles.rowOutset.trailing, height: cell.height)
        } else {
            lineRing.isHidden = true
        }
        columnGrip.isHidden = false
        columnGrip.center(at: CGPoint(x: cell.midX, y: table.minY))
        rowGrip.isHidden = false
        rowGrip.center(at: CGPoint(x: table.minX - Handles.rowOutset.leading, y: cell.midY))
        let editable = controller.isEditable
        columnDot.isHidden = !editable
        rowDot.isHidden = !editable
        columnDot.center(at: CGPoint(x: table.maxX, y: cell.midY))
        rowDot.center(at: CGPoint(x: cell.midX, y: table.maxY))
    }

    /// Whether a touch at `point` is one of its controls'.
    func takes(_ point: CGPoint) -> Bool {
        [columnGrip, rowGrip, columnDot, rowDot].contains { !$0.isHidden && $0.frame.contains(point) }
    }

    /// Only its controls take touches.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// What opens the table's menu pages (DocTableMenu) by a control while it's `target`'s:
/// beside it, or at the window's foot on a small screen (the controller's).
@MainActor
final class DocTableMenuAnchor {
    private(set) var target: DocTableMenuTarget
    weak var controller: DocTableController?
    let anchor: FlooPanelAnchorView

    init(target: DocTableMenuTarget, in view: UIView) {
        self.target = target
        anchor = FlooPanelAnchorView { _, _ in UIViewController() }
        anchor.options.isModal = true
        anchor.options.selfDrawn = true
        anchor.make = { [weak self] _, _ in self?.controller?.besideMenuPages() ?? UIViewController() }
        anchor.onDismiss = { [weak self] in
            guard let self, let controller = self.controller, controller.menu == self.target else { return }
            controller.closeMenu()
        }
        view.addSubview(anchor)
    }

    /// Open while the controller's menu is this one's.
    func follow(_ controller: DocTableController, target: DocTableMenuTarget? = nil) {
        self.controller = controller
        if let target { self.target = target }
        anchor.setPresented(controller.menu == self.target && controller.menuPanel == nil)
    }
}

/// The edited cell's ⋮: it opens the cell's menu, and closes it.
@MainActor
final class DocTableMenuButton: FlooContentButton {
    private var menuAnchor: DocTableMenuAnchor?
    private let target: DocTableMenuTarget
    private weak var controller: DocTableController?

    init(target: DocTableMenuTarget) {
        self.target = target
        super.init(content: DocTableMenuGlyph(), shape: .corner(DocTokens.Radius.sm), accessibilityLabel: "Table Actions")
        addAction(UIAction { [weak self] _ in
            guard let self, let controller = self.controller else { return }
            controller.menu == self.target ? controller.closeMenu() : controller.showMenu(self.target.key)
        }, for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Its cell's editor went: its menu goes.
    func close() {
        menuAnchor?.anchor.close()
    }

    func follow(_ controller: DocTableController) {
        self.controller = controller
        let anchor = menuAnchor ?? DocTableMenuAnchor(target: target, in: self)
        menuAnchor = anchor
        anchor.follow(controller)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        menuAnchor?.anchor.frame = bounds
    }
}

/// The ⋮ in the cell's menu button: secondary, as the button's content tint would make it
/// the label's (the button tints its content view, this holds the symbol in its own).
@MainActor
private final class DocTableMenuGlyph: UIView {
    private let image = UIImageView(image: UIImage(systemName: "ellipsis",
                                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: DocTokens.Icon.compact, weight: .semibold)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.transform = CGAffineTransform(rotationAngle: .pi / 2)
        image.contentMode = .center
        image.tintColor = .floo(.secondaryLabel)
        addSubview(image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        let size = image.intrinsicContentSize
        return CGSize(width: size.height, height: size.width)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Turned a quarter: its bounds are the box's the other way round.
        image.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
        image.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

/// A bar on the table's top edge over the edited cell's column, or on its left edge by its
/// row: a click picks the column or row and opens the menu for it.
@MainActor
final class DocTableGripButton: UIControl {
    let line: DocTableLine
    weak var controller: DocTableController?
    private var key: DocCellKey?
    private let bar = UIView()
    private var menuAnchor: DocTableMenuAnchor?

    init(line: DocTableLine) {
        self.line = line
        super.init(frame: .zero)
        bar.isUserInteractionEnabled = false
        bar.backgroundColor = UIColor { UIColor.floo(.label).resolvedColor(with: $0).withAlphaComponent(Handles.gripOpacity) }
        addSubview(bar)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = line == .column ? String(localized: "Select Column") : String(localized: "Select Row")
        addAction(UIAction { [weak self] _ in
            guard let self, let key = self.key else { return }
            self.controller?.pick(self.line, of: key)
        }, for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var size: CGSize { line == .column ? Handles.columnGrip : Handles.rowGrip }

    func follow(_ controller: DocTableController, key: DocCellKey) {
        self.controller = controller
        self.key = key
        let target = DocTableMenuTarget(key: key, line: line)
        let anchor = menuAnchor ?? DocTableMenuAnchor(target: target, in: self)
        menuAnchor = anchor
        anchor.follow(controller, target: target)
    }

    func center(at point: CGPoint) {
        let target = CGSize(width: max(size.width, Handles.target), height: max(size.height, Handles.target))
        frame = CGRect(x: point.x - target.width / 2, y: point.y - target.height / 2, width: target.width, height: target.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bar.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        bar.layer.cornerRadius = min(size.width, size.height) / 2
        menuAnchor?.anchor.frame = bounds
    }
}

/// A dot on the table's edge that adds a row or a column (Craft's); it swells under the pointer.
@MainActor
final class DocTableEdgeDot: UIControl {
    var action: (() -> Void)?
    private let dot = UIView()

    init(label: String) {
        super.init(frame: .zero)
        dot.isUserInteractionEnabled = false
        dot.backgroundColor = .floo(.label)
        addSubview(dot)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = label
        toolTip = label
        addAction(UIAction { [weak self] _ in self?.action?() }, for: .primaryActionTriggered)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func center(at point: CGPoint) {
        frame = CGRect(x: point.x - Handles.target / 2, y: point.y - Handles.target / 2, width: Handles.target, height: Handles.target)
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        let scale: CGFloat = recognizer.state == .began || recognizer.state == .changed ? Handles.dotHoverScale : 1
        guard dot.transform.a != scale else { return }
        FlooMotion.press.animate { self.dot.transform = CGAffineTransform(scaleX: scale, y: scale) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dot.bounds = CGRect(x: 0, y: 0, width: Handles.dot, height: Handles.dot)
        dot.center = CGPoint(x: bounds.midX, y: bounds.midY)
        dot.layer.cornerRadius = Handles.dot / 2
    }
}

// MARK: - The Mac's formula on the table

/// Over the table while the Mac writes a cell's formula: the columns' letters and the rows'
/// numbers, each reference's cells in its colour (the cell's editor rings the formula's cell).
@MainActor
final class DocFormulaDecorationView: UIView {
    private let frames: [MarkdownTableCellPosition: CGRect]
    private let formula: DocFormulaEditing
    private let ringsCell: Bool

    private typealias Decoration = DocFormulaDecoration
    private typealias Tokens = DocTokens

    init(frames: [MarkdownTableCellPosition: CGRect], formula: DocFormulaEditing, ringsCell: Bool) {
        self.frames = frames
        self.formula = formula
        self.ringsCell = ringsCell
        super.init(frame: .zero)
        isOpaque = false
        contentMode = .redraw
        clipsToBounds = false
        alpha = formula.isShown ? 1 : 0
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Fades with the formula's panel.
    private func follow() {
        withObservationTracking {
            let shown = formula.isShown
            if (alpha == 1) != shown {
                (shown ? FlooMotion.appear : FlooMotion.disappear).animate { self.alpha = shown ? 1 : 0 }
            }
            _ = formula.text
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.build()
                self.follow()
            }
        }
    }

    private func line(_ position: (Int) -> MarkdownTableCellPosition) -> [CGRect] {
        var line: [CGRect] = []
        while let frame = frames[position(line.count)] { line.append(frame) }
        return line
    }

    private func build() {
        subviews.forEach { $0.removeFromSuperview() }
        let columns = line { MarkdownTableCellPosition(row: 0, column: $0) }
        let rows = line { MarkdownTableCellPosition(row: $0, column: 0) }
        if let first = columns.first, let last = columns.last {
            let strip = CGRect(x: first.minX, y: first.minY - Decoration.gap - Decoration.gutterHeight, width: last.maxX - first.minX, height: Decoration.gutterHeight)
            addSubview(GutterView(frame: strip, cuts: columns.dropFirst().map { $0.minX - strip.minX }, vertical: true))
            for (index, frame) in columns.enumerated() {
                addSubview(label(DatabaseFormula.columnName(index), in: CGRect(x: frame.minX, y: strip.minY, width: frame.width, height: strip.height)))
            }
        }
        if let first = rows.first, let last = rows.last {
            let strip = CGRect(x: first.minX - Decoration.gap - Decoration.gutterWidth, y: first.minY, width: Decoration.gutterWidth, height: last.maxY - first.minY)
            addSubview(GutterView(frame: strip, cuts: rows.dropFirst().map { $0.minY - strip.minY }, vertical: false))
            for (index, frame) in rows.enumerated() {
                addSubview(label(String(index + 1), in: CGRect(x: strip.minX, y: frame.minY, width: strip.width, height: frame.height)))
            }
        }
        for (index, reference) in formula.references.enumerated() {
            guard let frame = frame(of: reference) else { continue }
            let color = DocFormulaEditing.uiColor(index)
            let box = UIView(frame: frame)
            box.backgroundColor = color.withAlphaComponent(Tokens.Opacity.faint)
            box.layer.borderColor = color.withAlphaComponent(Tokens.Opacity.strong).cgColor
            box.layer.borderWidth = Tokens.Border.focus
            box.layer.cornerRadius = DocTokens.Component.TableHandles.ringRadius
            box.layer.cornerCurve = .continuous
            addSubview(box)
        }
        if ringsCell, let frame = frames[formula.cell] {
            let ring = UIView(frame: frame)
            ring.layer.borderColor = UIColor.floo(.label).resolvedColor(with: traitCollection).cgColor
            ring.layer.borderWidth = Tokens.Border.focus
            ring.layer.cornerRadius = DocTokens.Component.TableHandles.ringRadius
            ring.layer.cornerCurve = .continuous
            addSubview(ring)
        }
    }

    /// The cells a reference names, together (those there are).
    private func frame(of reference: DatabaseFormula.Reference) -> CGRect? {
        var union: CGRect?
        for row in reference.rows {
            for column in reference.columns {
                guard let frame = frames[MarkdownTableCellPosition(row: row, column: column)] else { continue }
                union = union?.union(frame) ?? frame
            }
        }
        return union
    }

    private func label(_ text: String, in frame: CGRect) -> UILabel {
        let label = UILabel(frame: frame)
        label.text = text
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .floo(.secondaryLabel)
        label.textAlignment = .center
        return label
    }

    /// A strip of letters or numbers: a rounded frame, lines between its parts.
    private final class GutterView: UIView {
        private let cuts: [CGFloat]
        private let vertical: Bool

        init(frame: CGRect, cuts: [CGFloat], vertical: Bool) {
            self.cuts = cuts
            self.vertical = vertical
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = .floo(.markdownPage)
            layer.cornerRadius = DocTokens.Radius.xs
            layer.cornerCurve = .continuous
            layer.borderWidth = DocTokens.Border.standard
            updateColors()
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: GutterView, _) in
                view.updateColors()
                view.setNeedsDisplay()
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private var line: UIColor { UIColor.floo(.label).resolvedColor(with: traitCollection).withAlphaComponent(0.08) }

        private func updateColors() {
            layer.borderColor = line.cgColor
        }

        override func draw(_ rect: CGRect) {
            line.setStroke()
            let path = UIBezierPath()
            path.lineWidth = DocTokens.Border.standard
            for cut in cuts {
                path.move(to: vertical ? CGPoint(x: cut, y: 0) : CGPoint(x: 0, y: cut))
                path.addLine(to: vertical ? CGPoint(x: cut, y: bounds.height) : CGPoint(x: bounds.width, y: cut))
            }
            path.stroke()
        }
    }
}
