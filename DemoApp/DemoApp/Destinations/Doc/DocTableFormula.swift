//
//  DocTableFormula.swift
//  DemoApp
//
//  A cell's formula written apart from its cell, Craft's way: Insert Formula (the cell's
//  f(x) key on the keyboard bar, its menu's), or a click or tap on what a formula's cell
//  computes.
//
//  On a phone it takes the table off the page onto one of its own: it flies from its place to the top, the columns'
//  letters over it and the rows' numbers beside it (what a reference names), the cell
//  ringed and reading "Edit Formula". Above the keyboard, the formula in a field after
//  its "=" and a row of keys: the usual functions while it's empty (the rest in the
//  system's menu), the operators once it isn't. A tap on a cell puts its reference at
//  the caret, or in place of the reference just before the caret (a tap on another cell
//  moves it there); each reference has a colour, the text's and its cells' ring. Done
//  writes the formula into the cell, one undo step, and the table flies back; the cell,
//  still ringed, shows what it computes.
//
//  On the Mac the table stays where it is, the letters, numbers and rings drawn on it,
//  and the field and keys are in a panel under the cell: the same anchored panel as the
//  table's menus (Craft's are one kind too, its formula picker a draggable panel as its
//  context menus are). A click on a cell of the table puts its reference in; Return or a
//  click anywhere else writes the formula, Esc leaves the cell as it was. The keys are
//  laid out in a grid, the functions under their full names.
//
//  Both: right after a "(" the keys are the directions (ABOVE, BELOW, LEFT, RIGHT), which
//  are references too, coloured and ringed as the cells they name.
//

import FlooUIKit
import SwiftUI
import UIKit
import DocKit
import MarkdownUIKit
import MarkdownView

/// A formula being written: its cell, its text (without its "=") and the caret.
@MainActor
@Observable
final class DocFormulaEditing: Identifiable {
    let key: DocCellKey
    /// The cell in its table (row 0 the header): where it's ringed, and what a reference to
    /// it would be (none: it can't name itself).
    let cell: MarkdownTableCellPosition
    /// Where it is in its table: the cells its directions name.
    let place: DatabaseFormula.Place
    private(set) var text: String
    /// In UTF-16 units, as the field counts.
    @ObservationIgnored private(set) var selection: NSRange {
        didSet { caretMoved() }
    }
    @ObservationIgnored weak var field: DocFormulaTextField?
    /// What's the formula's page's own is in: its keys, the letters and numbers, the
    /// rings. They come once the table has landed, and go as it flies back.
    var isShown = false

    init(key: DocCellKey, cell: MarkdownTableCellPosition, place: DatabaseFormula.Place, text: String) {
        self.key = key
        self.cell = cell
        self.place = place
        self.text = text
        selection = NSRange(location: text.utf16.count, length: 0)
    }

    var references: [DatabaseFormula.Reference] { DatabaseFormula.references(in: text, at: place) }

    /// The functions on the keys (Craft's: on the Mac by their full names), and those in
    /// the menu after them.
    static let functions = DocDevice.isMac ? ["SUM", "MIN", "MAX", "AVERAGE", "COUNT"] : ["SUM", "MIN", "MAX", "AVG", "CNT"]
    static let moreFunctions = ["COUNTA", "MEDIAN", "MODE", "PRODUCT", "ROUND", "ABS", "INT", "SIGN"]
    static let operators = ["+", "-", "*", "/", "(", ")", ":"]
    static let directions = ["ABOVE", "BELOW", "LEFT", "RIGHT"]

    /// The caret is right after a "(": the keys are what a function takes.
    private(set) var opensArguments = false

    private func caretMoved() {
        let opens = selection.length == 0 && selection.location > 0 && selection.location <= text.utf16.count
            && ["(", "（"].contains((text as NSString).substring(with: NSRange(location: selection.location - 1, length: 1)))
        if opens != opensArguments { opensArguments = opens }
    }

    /// A reference's colour, by its place among them.
    static func uiColor(_ index: Int) -> UIColor {
        let tokens = ["purple", "green", "blue", "orange", "red", "cyan", "brown"]
        return DocColors.ink(tokens[index % tokens.count]) ?? .floo(.secondaryLabel)
    }

    /// The field's typing.
    func typed(_ text: String, selection: NSRange) {
        if self.text != text { self.text = text }
        self.selection = selection
    }

    /// A function's key: its name and parentheses, the caret between them.
    func insert(function name: String) {
        replace(selection, with: name + "()", caret: name.utf16.count + 1)
    }

    /// An operator's key.
    func insert(_ string: String) {
        replace(selection, with: string)
    }

    /// A tap on a cell: its reference at the caret, or in place of the reference that ends
    /// there.
    func point(at position: MarkdownTableCellPosition) {
        guard position != cell else { return }
        var range = selection
        if range.length == 0, let last = references.last(where: { $0.range.upperBound == range.location }) {
            range = NSRange(location: last.range.lowerBound, length: last.range.count)
        }
        replace(range, with: DatabaseFormula.reference(row: position.row, column: position.column))
    }

    private func replace(_ range: NSRange, with string: String, caret: Int? = nil) {
        let length = text.utf16.count
        let location = min(range.location, length)
        let range = NSRange(location: location, length: min(range.length, length - location))
        text = (text as NSString).replacingCharacters(in: range, with: string)
        selection = NSRange(location: range.location + (caret ?? string.utf16.count), length: 0)
        field?.show(text, selection: selection)
    }
}

private typealias Tokens = DocTokens

extension DocTableController {
    /// Insert Formula: the cell's formula written on the table's own page (a phone), or in
    /// a panel under the cell (the Mac).
    func editFormula(_ key: DocCellKey) {
        guard let row = key.row, let (_, database) = database(key.block),
              let r = database.rows.firstIndex(where: { $0.id == row }), let c = database.columns.firstIndex(where: { $0.id == key.column })
        else { return }
        let current = text(key)
        let editing = DocFormulaEditing(key: key, cell: MarkdownTableCellPosition(row: r + 1, column: c),
                                        place: DatabaseFormula.Place(row: r + 1, column: c, rows: database.rows.count, columns: database.columns.count),
                                        text: DatabaseFormula.isFormula(current) ? String(current.dropFirst()) : "")
        willEdit(key)
        // The keyboard goes down while the table flies, and comes back for the formula
        // once it's landed (Craft's): changing it mid-flight would hold the flight up.
        view(for: key)?.resignFirstResponder()
        editor.leaveCells()
        // The cell's menu (a sheet) goes first: one thing presented at a time. Beside the
        // cell (the Mac) the two are panels in the window.
        let waits = menu != nil && !DocDevice.isMac
        closeMenu()
        Task { @MainActor [weak self] in
            if waits { try? await Task.sleep(for: .milliseconds(450)) }
            guard let self, self.editing == key else { return }
            if DocDevice.isMac {
                self.formula = editing
                withAnimation(Tokens.Motion.reveal) { editing.isShown = true }
                return
            }
            // Shown at once: the table's flight is the formula page's own (DocFormulaView).
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { self.formula = editing }
        }
    }

    /// Done: the formula written into its cell (an empty one clears a formula there, and
    /// leaves other text as it was), one undo step.
    func writeFormula() {
        guard let formula else { return }
        let written = formula.text.trimmingCharacters(in: .whitespaces)
        let current = text(formula.key)
        let text = written.isEmpty ? (DatabaseFormula.isFormula(current) ? "" : current) : "=" + written
        bumpSession()
        changed(formula.key, to: text)
        bumpSession()
    }

    /// The Mac's panel closes: Return or a click elsewhere writes the formula, Esc leaves
    /// the cell as it was. The letters, numbers and rings fade with it.
    func finishFormula(writes: Bool) {
        guard let formula, formula.isShown else { return }
        if writes { writeFormula() }
        formula.field?.resignFirstResponder()
        withAnimation(Tokens.Motion.dismiss) {
            formula.isShown = false
        } completion: { [weak self] in
            if self?.formula === formula { self?.closeFormula() }
        }
    }

    /// The formula written in a panel by this table's cell (the Mac's): the table draws
    /// its letters, numbers and rings.
    func formulaPanel(in block: DocBlockID) -> DocFormulaEditing? {
        DocDevice.isMac && formula?.key.block == block ? formula : nil
    }

    /// The panel under the cell: centred on it, and open while its table's cells are
    /// clicked (they put their references in).
    func formulaPanelKeepsOpen(_ key: DocCellKey) -> @MainActor (CGPoint) -> Bool {
        { [weak self] point in self?.tableFrames[key.block]?.contains(point) == true }
    }

    /// The formula's page is gone (the table back on the page).
    func closeFormula() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { formula = nil }
    }
}

// MARK: The formula's page

/// The phone's: the table on a page of its own, the formula's field and keys above the
/// keyboard. Presented over the document, its colour coming as the table leaves the page
/// and going as the table flies back, the document fading in round it (its own table stays
/// hidden till this page is gone, so it's the one flying that lands there).
@MainActor
final class DocFormulaController: UIViewController {
    let formula: DocFormulaEditing
    private let controller: DocTableController
    private let scroller = UIScrollView()
    private let table = MarkdownUIKit.MarkdownTableView()
    private let placeholder = DocFormulaPlaceholderView()
    private lazy var doneButton = FlooButton(.primary, title: String(localized: "Done")) { [weak self] in self?.done() }
    private let panel = FlooGlassView(shape: .rounded(DocTokens.Radius.xxl))
    /// Where the table landed here, in the window: it flies between there and the page.
    private var landing: CGRect?

    private typealias Tokens = DocTokens

    init(formula: DocFormulaEditing, controller: DocTableController) {
        self.formula = formula
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scroller.keyboardDismissMode = .none
        scroller.alwaysBounceVertical = true
        view.addSubview(scroller)
        scroller.addSubview(table)
        table.alpha = 0
        doneButton.alpha = 0
        view.addSubview(doneButton)
        let content = DocFormulaPanelView(formula: formula, done: { [weak self] in self?.done() }, cancel: nil)
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(content)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.alpha = 0
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: Tokens.Space.sm),
            content.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -Tokens.Space.sm),
            content.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: Tokens.Space.sm),
            content.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -Tokens.Space.sm),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Tokens.Space.md),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Tokens.Space.md),
            panel.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Tokens.Space.sm),
        ])
        showTable()
    }

    /// The table as it is: its formula's cell reading "Edit Formula", a tap on a cell puts its
    /// reference in, the letters, numbers and rings over it.
    private func showTable() {
        guard let row = controller.demo.rows.first(where: { $0.table?.block == formula.key.block }), let snapshot = row.table else { return }
        var style = MarkdownUIKit.MarkdownStyle()
        style.typography = DocUIKitType.body(design: nil)
        style.addsEdgeInsets = false
        style.table.scrollsSideways = true
        style.table.bodyFont = .init(.body)
        style.table.appearance = controller.uikitAppearance(of: snapshot)
        style.table.cellsSelectable = true
        let cell = formula.cell
        style.table.replacedCells = [cell]
        style.table.replacement = { [weak self] position in
            guard let self, position == cell else { return nil }
            self.placeholder.show(key: self.formula.key, controller: self.controller, formula: self.formula)
            return self.placeholder
        }
        style.table.onCellTap = { [formula] position in formula.point(at: position) }
        style.table.decoration = { [formula] frames in DocFormulaDecorationView(frames: frames, formula: formula, ringsCell: true) }
        table.configure(source: row.sourceText, style: style)
        follow()
    }

    /// "Edit Formula" and what the cell shows, as the formula's shown.
    private func follow() {
        withObservationTracking {
            placeholder.show(key: formula.key, controller: controller, formula: formula)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.follow() } }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        let bar = doneButton.intrinsicContentSize
        doneButton.frame = CGRect(x: view.bounds.width - safe.right - Tokens.Space.lg - bar.width, y: safe.top + Tokens.Space.sm, width: bar.width, height: bar.height)
        let top = doneButton.frame.maxY + Tokens.Space.sm
        scroller.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: max(0, view.bounds.height - top))
        // As wide as on the page, moved right by the rows' numbers (Craft's): what that leaves
        // out on the right is its last column's room, and a table wider than the page scrolls as
        // it does there.
        let width = controller.tableFrames[formula.key.block]?.width ?? view.bounds.width - DocFormulaDecoration.leadingRoom
        let height = table.height(forWidth: width)
        let y = Tokens.Space.lg + DocFormulaDecoration.gutterHeight + DocFormulaDecoration.gap
        table.frame = CGRect(x: safe.left + DocFormulaDecoration.leadingRoom, y: y, width: width, height: height)
        scroller.contentSize = CGSize(width: view.bounds.width, height: y + height + Tokens.Space.lg)
        if landing == nil, view.window != nil, height > 0 { landed() }
    }

    /// The table is laid out here: it flies from its place on the page.
    private func landed() {
        let frame = table.convert(table.bounds, to: nil)
        landing = frame
        if let origin = controller.tableFrames[formula.key.block] {
            table.transform = CGAffineTransform(translationX: origin.minX - frame.minX, y: origin.minY - frame.minY)
        }
        table.alpha = 1
        let fly = { [table] in table.transform = .identity }
        if let motion = Tokens.Motion.layout {
            UIView.animate(motion, changes: fly) { [formula] in formula.field?.becomeFirstResponder() }
        } else {
            fly()
            formula.field?.becomeFirstResponder()
        }
        formula.isShown = true
        FlooMotion.appear.animate { [self] in
            view.backgroundColor = DocTokens.UIKitColor.canvas
            doneButton.alpha = 1
            panel.alpha = 1
        }
    }

    /// The formula written, the table flies back to its place on the page.
    private func done() {
        controller.writeFormula()
        formula.field?.resignFirstResponder()
        // Where the table is on the page after this render (its text has changed).
        Task { @MainActor [self] in
            formula.isShown = false
            FlooMotion.disappear.animate { [self] in
                doneButton.alpha = 0
                panel.alpha = 0
            }
            let back = { [self] in
                view.backgroundColor = .clear
                if let landing, let origin = controller.tableFrames[formula.key.block] {
                    table.transform = CGAffineTransform(translationX: origin.minX - landing.minX, y: origin.minY - landing.minY)
                }
            }
            if let motion = Tokens.Motion.layout {
                UIView.animate(motion, changes: back) { [controller] in controller.closeFormula() }
            } else {
                back()
                controller.closeFormula()
            }
        }
    }
}

/// The phone's formula page: its letters' and numbers' room round the table (DocFormulaDecorationView).
enum DocFormulaDecoration {
    /// The numbers' strip: on the Mac it's in the page's margin, which is narrower.
    static let gutterWidth: CGFloat = DocDevice.isMac ? 20 : 24
    static let gutterHeight: CGFloat = 24
    static let gap: CGFloat = DocTokens.Space.xs
    /// What the table leaves on its left for the rows' numbers: a cell's fill reaches past
    /// its text, then the gap, the numbers, and a little room to the screen's edge.
    static let leadingRoom = MarkdownTableAppearance.rowOutset.leading + gap + gutterWidth + DocTokens.Space.xs
}

// MARK: The field and its keys

/// The Mac's: in a panel under the cell.
final class DocFormulaPage: DocStackPage {
    /// Craft's panel's width, measured on its Mac app.
    private static let width: CGFloat = 352
    private var formula: DocFormulaEditing
    private let done: () -> Void
    private let cancel: () -> Void

    init(formula: DocFormulaEditing, done: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.formula = formula
        self.done = done
        self.cancel = cancel
        super.init(width: Self.width)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        showPanel()
    }

    /// Writes `formula` now: a panel on its way out, brought back for the next formula,
    /// takes it (its field taking the keyboard as it comes in).
    func show(_ formula: DocFormulaEditing) {
        guard formula !== self.formula else { return }
        self.formula = formula
        guard isViewLoaded else { return }
        for view in stack.arrangedSubviews where view is DocFormulaPanelView { view.removeFromSuperview() }
        showPanel()
    }

    private func showPanel() {
        stack.addArrangedSubview(DocFormulaPanelView(formula: formula, done: done, cancel: cancel) { [weak self] change in
            self?.flooUpdateSheetContent(change)
        })
    }

    override func closePage() { cancel() }
}

/// The formula after "=", and the keys under it, by what's at the caret: the functions while
/// nothing's typed (the rest in a menu), what a function takes right after its "(", else the
/// operators. A phone has them in a row; the Mac in rows of three, the directions two by two, the
/// operators in one (Craft's). Keys share a row's width, however many it has.
final class DocFormulaPanelView: UIView {
    private enum Key: Hashable {
        case function(String), text(String), more
    }

    private let formula: DocFormulaEditing
    private let field = DocFormulaTextField()
    private let keysStack = UIStackView()
    private var shownKeys: [Key] = []
    /// Its size changing by what's in it, the panel moving with it.
    private let resizing: (@MainActor (@escaping () -> Void) -> Void)?

    private static let metrics = FlooButtonMetrics.of(.medium)
    private static var spacing: CGFloat { DocTokens.Space.sm }

    init(formula: DocFormulaEditing, done: @escaping () -> Void, cancel: (() -> Void)?, resizing: (@MainActor (@escaping () -> Void) -> Void)? = nil) {
        self.formula = formula
        self.resizing = resizing
        super.init(frame: .zero)
        field.formula = formula
        field.done = done
        field.cancel = cancel
        field.show(formula.text, selection: formula.selection)

        let equals = UILabel()
        equals.text = "="
        equals.font = .preferredFont(forTextStyle: .body)
        equals.textColor = .floo(.placeholder)
        equals.setContentHuggingPriority(.required, for: .horizontal)
        let line = UIStackView(arrangedSubviews: [equals, field])
        line.spacing = DocTokens.Space.xs
        line.alignment = .center
        line.translatesAutoresizingMaskIntoConstraints = false
        let box = UIView()
        box.backgroundColor = .floo(.controlFill)
        box.layer.cornerRadius = DocTokens.Radius.md
        box.layer.cornerCurve = .continuous
        box.addSubview(line)

        keysStack.axis = .vertical
        keysStack.spacing = Self.spacing
        let stack = UIStackView(arrangedSubviews: [box, keysStack])
        stack.axis = .vertical
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: box.topAnchor),
            line.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: DocTokens.Space.md),
            line.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -DocTokens.Space.md),
            box.heightAnchor.constraint(equalToConstant: DocTokens.Control.prominentHeight),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        showKeys()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func showKeys() {
        let keys = withObservationTracking {
            formula.text.isEmpty ? DocFormulaEditing.functions.map(Key.function) + [.more]
                : formula.opensArguments ? DocFormulaEditing.directions.map(Key.text)
                : DocFormulaEditing.operators.map(Key.text)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.showKeys() } }
        }
        guard keys != shownKeys else { return }
        let isFirst = shownKeys.isEmpty
        shownKeys = keys
        let change = { [self] in
            keysStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let columns = !DocDevice.isMac || keys.count > 6 ? keys.count : keys.count == 4 ? 2 : 3
            for start in stride(from: 0, to: keys.count, by: columns) {
                let row = UIStackView(arrangedSubviews: keys[start..<min(start + columns, keys.count)].map(button))
                row.spacing = Self.spacing
                row.distribution = .fillEqually
                keysStack.addArrangedSubview(row)
            }
        }
        if isFirst || resizing == nil { change() } else { resizing?(change) }
    }

    private func button(_ key: Key) -> UIView {
        let content: UIView
        switch key {
        case .function(let title), .text(let title):
            let label = UILabel()
            label.text = title
            label.font = .systemFont(ofSize: Self.metrics.fontSize, weight: .medium)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
            content = label
        case .more:
            let image = UIImageView(image: UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: Self.metrics.iconSize, weight: .medium)))
            image.contentMode = .center
            content = image
        }
        let button = FlooContentButton(content: content, surface: .control) { [weak self] in
            guard let self else { return }
            switch key {
            case .function(let name): formula.insert(function: name)
            case .text(let text): formula.insert(text)
            case .more: break
            }
        }
        if case .more = key {
            button.accessibilityLabel = "More Functions"
            button.menu = UIMenu(children: DocFormulaEditing.moreFunctions.map { name in
                UIAction(title: name) { [weak self] _ in self?.formula.insert(function: name) }
            })
            button.showsMenuAsPrimaryAction = true
        }
        button.heightAnchor.constraint(equalToConstant: Self.metrics.height).isActive = true
        return button
    }
}

final class DocFormulaTextField: UITextField, UITextFieldDelegate {
    weak var formula: DocFormulaEditing?
    var done: (() -> Void)?
    var cancel: (() -> Void)?

    init() {
        super.init(frame: .zero)
        delegate = self
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        autocapitalizationType = .allCharacters
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        returnKeyType = .done
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addTarget(self, action: #selector(edited), for: .editingChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Its text being set: where the caret passes on the way isn't the person's.
    private var showing = false

    /// The formula's field is the one on screen (a panel on its way out may have made
    /// one too). On a phone the keyboard comes once the table has landed
    /// (DocFormulaView); the Mac's panel takes the typing as it opens.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, let formula else { return }
        formula.field = self
        if DocDevice.isMac {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.formula?.field === self else { return }
                self.becomeFirstResponder()
            }
        }
    }

    /// The model's text and caret (a key or a tap changed them).
    func show(_ text: String, selection: NSRange) {
        unmarkText()
        recolor(text, caret: selection)
    }

    @objc private func edited() {
        let text = text ?? ""
        formula?.typed(text, selection: selection)
        // Coloured once the input method has put its words in.
        guard markedTextRange == nil else { return }
        recolor(text, caret: selection)
    }

    private func recolor(_ text: String, caret: NSRange) {
        showing = true
        attributedText = colored(text)
        select(caret)
        showing = false
    }

    func textFieldDidChangeSelection(_ textField: UITextField) {
        guard !showing else { return }
        formula?.typed(text ?? "", selection: selection)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        done?()
        return false
    }

    /// Esc, where it cancels (the Mac's panel).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let cancel, presses.contains(where: { $0.key?.keyCode == .keyboardEscape }), markedTextRange == nil {
            return cancel()
        }
        super.pressesBegan(presses, with: event)
    }

    private var selection: NSRange {
        guard let range = selectedTextRange else { return NSRange(location: (text ?? "").utf16.count, length: 0) }
        return NSRange(location: offset(from: beginningOfDocument, to: range.start), length: offset(from: range.start, to: range.end))
    }

    private func select(_ range: NSRange) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length)
        else { return }
        selectedTextRange = textRange(from: start, to: end)
    }

    private func colored(_ text: String) -> NSAttributedString {
        let string = NSMutableAttributedString(string: text, attributes: [.font: font ?? .preferredFont(forTextStyle: .body), .foregroundColor: DocTokens.UIKitColor.primary])
        for (index, reference) in DatabaseFormula.references(in: text, at: formula?.place).enumerated() {
            string.addAttribute(.foregroundColor, value: DocFormulaEditing.uiColor(index),
                                range: NSRange(location: reference.range.lowerBound, length: reference.range.count))
        }
        typingAttributes = [.font: font ?? .preferredFont(forTextStyle: .body), .foregroundColor: DocTokens.UIKitColor.primary]
        return string
    }
}
