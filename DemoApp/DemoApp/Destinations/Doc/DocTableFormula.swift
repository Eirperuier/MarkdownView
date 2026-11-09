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
    static func color(_ index: Int) -> Color { Color(uiColor: uiColor(index)) }

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

/// The table on a page of its own, the formula's field and keys above the keyboard.
struct DocFormulaView: View {
    let formula: DocFormulaEditing
    let controller: DocTableController
    /// The page's colour over the document: it comes as the table leaves the page, and
    /// goes as the table flies back, the document fading in round it (its own table stays
    /// hidden till this page is gone, so it's the one flying that lands there).
    @State private var covers = false
    /// Where the cell is here and was on the page (the window's space): the table flies
    /// between them.
    @State private var landing: CGRect?
    @State private var flight: CGSize = .zero

    private typealias Tokens = DocTokens

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(String(localized: "Done"), action: done)
                    .buttonStyle(.floo(.primary))
            }
            .padding(.horizontal, Tokens.Space.lg)
            .padding(.vertical, Tokens.Space.sm)
            .opacity(formula.isShown ? 1 : 0)
            ScrollView(.vertical) {
                // As wide as on the page, moved right by the rows' numbers (Craft's): what
                // that leaves out on the right is its last column's room, and a table wider
                // than the page scrolls as it does there.
                table
                    .frame(width: controller.tableFrames[formula.key.block]?.width)
                    .padding(.leading, DocFormulaDecoration.leadingRoom)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Tokens.Space.lg + DocFormulaDecoration.gutterHeight + DocFormulaDecoration.gap)
                    .padding(.bottom, Tokens.Space.lg)
                    .offset(flight)
                    .opacity(landing == nil ? 0 : 1)
            }
            .scrollDismissesKeyboard(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tokens.ColorRole.Surface.canvas.opacity(covers ? 1 : 0).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            DocFormulaPanel(formula: formula, done: done)
                .opacity(formula.isShown ? 1 : 0)
                .scaleEffect(formula.isShown ? 1 : Tokens.Motion.revealStartScale, anchor: .bottom)
        }
        .presentationBackground(.clear)
    }

    @ViewBuilder
    private var table: some View {
        if let row = controller.demo.rows.first(where: { $0.table?.block == formula.key.block }), let table = row.table, let tree = row.tree {
            let cell = formula.cell
            MarkdownBlockView(tree: tree)
                .markdownDisplayMathRendersSynchronously()
                .markdownTableAppearance(controller.appearance(of: table))
                .markdownTableCellsSelectable()
                .markdownTableCellTap { [formula] position in formula.point(at: position) }
                .markdownTableCellReplacement([cell]) { [key = formula.key, controller] position in
                    position == cell ? AnyView(DocFormulaPlaceholder(key: key, controller: controller, formula: formula)) : nil
                }
                .markdownTableDecoration { [formula] frames in
                    AnyView(DocFormulaDecoration(frames: frames, formula: formula, ringsCell: true))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(DocBlockType())
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { landed($0) }
        }
    }

    /// The table is laid out here: it flies from its place on the page.
    private func landed(_ frame: CGRect) {
        guard landing == nil else { return }
        landing = frame
        if let origin = controller.tableFrames[formula.key.block] {
            flight = CGSize(width: origin.minX - frame.minX, height: origin.minY - frame.minY)
        }
        withAnimation(Tokens.Motion.layout) {
            flight = .zero
        } completion: { [formula] in
            formula.field?.becomeFirstResponder()
        }
        withAnimation(Tokens.Motion.reveal) {
            covers = true
            formula.isShown = true
        }
    }

    /// The formula written, the table flies back to its place on the page.
    private func done() {
        controller.writeFormula()
        formula.field?.resignFirstResponder()
        // Where the table is on the page after this render (its text has changed).
        Task { @MainActor in
            withAnimation(Tokens.Motion.dismiss) { formula.isShown = false }
            withAnimation(Tokens.Motion.layout) {
                covers = false
                if let landing, let origin = controller.tableFrames[formula.key.block] {
                    flight = CGSize(width: origin.minX - landing.minX, height: origin.minY - landing.minY)
                }
            } completion: {
                controller.closeFormula()
            }
        }
    }
}

/// The formula's cell while it's written: Craft's "Edit Formula", in the room of what
/// the cell shows on the page, so its column is as wide as there (the table flies
/// between the two without its columns moving, the Mac's stays as it is); the words are
/// drawn in the column's room, smaller if they don't fit it. What the cell shows comes
/// back as the table flies back or the panel closes (the result of the formula just
/// written), so it lands as the page has it.
struct DocFormulaPlaceholder: View {
    let key: DocCellKey
    let controller: DocTableController
    let formula: DocFormulaEditing

    var body: some View {
        let look = controller.look(key)
        Text(verbatim: controller.result(key) ?? controller.text(key))
            .lineLimit(1)
            .opacity(formula.isShown ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: look.frameAlignment)
            .overlay(alignment: Alignment(horizontal: look.frameAlignment.horizontal, vertical: .center)) {
                Text("Edit Formula")
                    .foregroundStyle(DocTokens.ColorRole.Content.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(formula.isShown ? 1 : 0)
            }
    }
}

/// Over the table: the columns' letters and the rows' numbers, each reference's cells in
/// its colour, the formula's cell ringed (`ringsCell`; on the page the cell's editor rings it).
struct DocFormulaDecoration: View {
    let frames: MarkdownTableCellFrames
    let formula: DocFormulaEditing
    let ringsCell: Bool

    /// The numbers' strip: on the Mac it's in the page's margin, which is narrower.
    static let gutterWidth: CGFloat = DocDevice.isMac ? 20 : 24
    static let gutterHeight: CGFloat = 24
    static let gap: CGFloat = DocTokens.Space.xs
    /// What the table leaves on its left for the rows' numbers: a cell's fill reaches past
    /// its text, then the gap, the numbers, and a little room to the screen's edge.
    static let leadingRoom = MarkdownTableAppearance.rowOutset.leading + gap + gutterWidth + DocTokens.Space.xs

    private typealias Tokens = DocTokens

    var body: some View {
        let columns = Self.line(frames) { MarkdownTableCellPosition(row: 0, column: $0) }
        let rows = Self.line(frames) { MarkdownTableCellPosition(row: $0, column: 0) }
        ZStack(alignment: .topLeading) {
            if let first = columns.first, let last = columns.last {
                let strip = CGRect(x: first.minX, y: first.minY - Self.gap - Self.gutterHeight, width: last.maxX - first.minX, height: Self.gutterHeight)
                gutter(strip, cuts: columns.dropFirst().map { $0.minX - strip.minX }, vertical: true)
                ForEach(Array(columns.enumerated()), id: \.offset) { index, frame in
                    label(DatabaseFormula.columnName(index), in: CGRect(x: frame.minX, y: strip.minY, width: frame.width, height: strip.height))
                }
            }
            if let first = rows.first, let last = rows.last {
                let strip = CGRect(x: first.minX - Self.gap - Self.gutterWidth, y: first.minY, width: Self.gutterWidth, height: last.maxY - first.minY)
                gutter(strip, cuts: rows.dropFirst().map { $0.minY - strip.minY }, vertical: false)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, frame in
                    label(String(index + 1), in: CGRect(x: strip.minX, y: frame.minY, width: strip.width, height: frame.height))
                }
            }
            ForEach(Array(formula.references.enumerated()), id: \.offset) { index, reference in
                if let frame = frame(of: reference) {
                    let color = DocFormulaEditing.color(index)
                    let shape = RoundedRectangle(cornerRadius: MarkdownTableAppearance.cellCornerRadius, style: .continuous)
                    shape.fill(color.opacity(Tokens.Opacity.faint))
                        .overlay(shape.strokeBorder(color.opacity(Tokens.Opacity.strong), lineWidth: Tokens.Border.focus))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            if ringsCell, let frame = frames[formula.cell] {
                RoundedRectangle(cornerRadius: MarkdownTableAppearance.cellCornerRadius, style: .continuous)
                    .strokeBorder(Tokens.ColorRole.Accent.primary, lineWidth: Tokens.Border.focus)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(formula.isShown ? 1 : 0)
    }

    /// The first row's cells, or the first column's, in order.
    private static func line(_ frames: MarkdownTableCellFrames, _ position: (Int) -> MarkdownTableCellPosition) -> [CGRect] {
        var line: [CGRect] = []
        while let frame = frames[position(line.count)] { line.append(frame) }
        return line
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

    /// A strip of letters or numbers: a rounded frame, lines between its parts.
    private func gutter(_ strip: CGRect, cuts: [CGFloat], vertical: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.xs, style: .continuous)
        return shape.fill(Tokens.ColorRole.Surface.canvas)
            .overlay {
                Path { path in
                    for cut in cuts {
                        path.move(to: vertical ? CGPoint(x: cut, y: 0) : CGPoint(x: 0, y: cut))
                        path.addLine(to: vertical ? CGPoint(x: cut, y: strip.height) : CGPoint(x: strip.width, y: cut))
                    }
                }
                .stroke(Tokens.Border.subtle, lineWidth: Tokens.Border.standard)
            }
            .overlay(shape.strokeBorder(Tokens.Border.subtle, lineWidth: Tokens.Border.standard))
            .frame(width: strip.width, height: strip.height)
            .offset(x: strip.minX, y: strip.minY)
    }

    private func label(_ text: String, in frame: CGRect) -> some View {
        Text(text)
            .font(Tokens.Typography.metadata.font)
            .foregroundStyle(Tokens.ColorRole.Content.secondary)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }
}

// MARK: The field and its keys

/// The formula after its "=", and the keys: on glass above the keyboard (a phone), or in
/// the panel under the cell (the Mac).
struct DocFormulaPanel: View {
    let formula: DocFormulaEditing
    let done: () -> Void

    private typealias Tokens = DocTokens

    var body: some View {
        DocFormulaPanelHost(formula: formula, done: done)
            .padding(Tokens.Space.sm)
            .flooGlass(in: RoundedRectangle(cornerRadius: Tokens.Radius.xxl, style: .continuous))
            .padding(.horizontal, Tokens.Space.md)
            .padding(.bottom, Tokens.Space.sm)
    }
}

/// The phone's: the panel's view on the table's page.
private struct DocFormulaPanelHost: UIViewRepresentable {
    let formula: DocFormulaEditing
    let done: () -> Void

    func makeUIView(context: Context) -> DocFormulaPanelView {
        DocFormulaPanelView(formula: formula, done: done, cancel: nil)
    }

    func updateUIView(_ view: DocFormulaPanelView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DocFormulaPanelView, context: Context) -> CGSize? {
        uiView.systemLayoutSizeFitting(CGSize(width: proposal.width ?? 320, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    }
}

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
            string.addAttribute(.foregroundColor, value: UIColor(DocFormulaEditing.color(index)),
                                range: NSRange(location: reference.range.lowerBound, length: reference.range.count))
        }
        typingAttributes = [.font: font ?? .preferredFont(forTextStyle: .body), .foregroundColor: DocTokens.UIKitColor.primary]
        return string
    }
}
