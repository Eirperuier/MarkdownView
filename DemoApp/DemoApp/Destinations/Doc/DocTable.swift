//
//  DocTable.swift
//  DemoApp
//
//  Editing a database block as a table, the way Craft does it. The table is
//  MarkdownView's, read or edited: clicking a cell puts an editor in that cell only
//  (MarkdownView's cell replacement), so the table keeps its look and layout.
//  - click a cell and type; the header row is the column names;
//  - Tab / Shift-Tab: next / previous cell (Tab past a row's last cell adds a column),
//    Return: the cell below (past the last row adds a row), ↑↓ at a cell's first / last
//    line: the cell above / below, ⌘ + arrows: the table's edge, Esc: leave the table;
//  - right-click a cell (Mac) or its ⋯ button (both): insert, move, delete rows and
//    columns, sort by the column, clear the cell, delete the table;
//  - the + below and beside the table add a row and a column.
//  Every change is one DocKit step (typing in a cell merges into one undo step), so
//  undo, redo and sync treat the table like the rest of the document.
//

import SwiftUI
import UIKit
import DocKit
import MarkdownView

struct DocTableSnapshot: Equatable {
    let block: DocBlockID
    let database: Database
}

/// A cell: `row` nil is the header (the column's name).
struct DocCellKey: Hashable {
    let block: DocBlockID
    let row: RowID?
    let column: ColumnID
}

enum DocTableAction: CaseIterable, Identifiable {
    case insertRowAbove, insertRowBelow, insertColumnLeft, insertColumnRight
    case moveRowUp, moveRowDown, moveColumnLeft, moveColumnRight
    case sortAscending, sortDescending
    case deleteRow, deleteColumn, clearCell, deleteTable

    var id: Self { self }

    var title: String {
        switch self {
        case .insertRowAbove: "在上方插入行"
        case .insertRowBelow: "在下方插入行"
        case .insertColumnLeft: "在左侧插入列"
        case .insertColumnRight: "在右侧插入列"
        case .moveRowUp: "上移行"
        case .moveRowDown: "下移行"
        case .moveColumnLeft: "左移列"
        case .moveColumnRight: "右移列"
        case .sortAscending: "按此列升序排序"
        case .sortDescending: "按此列降序排序"
        case .deleteRow: "删除行"
        case .deleteColumn: "删除列"
        case .clearCell: "清除单元格内容"
        case .deleteTable: "删除表格"
        }
    }

    var symbol: String {
        switch self {
        case .insertRowAbove: "arrow.up.to.line"
        case .insertRowBelow: "arrow.down.to.line"
        case .insertColumnLeft: "arrow.left.to.line"
        case .insertColumnRight: "arrow.right.to.line"
        case .moveRowUp: "arrow.up"
        case .moveRowDown: "arrow.down"
        case .moveColumnLeft: "arrow.left"
        case .moveColumnRight: "arrow.right"
        case .sortAscending: "arrow.up.arrow.down"
        case .sortDescending: "arrow.up.arrow.down"
        case .deleteRow, .deleteColumn, .deleteTable: "trash"
        case .clearCell: "eraser"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .deleteRow, .deleteColumn, .clearCell, .deleteTable: true
        default: false
        }
    }

    /// The menu's sections, in order.
    static let sections: [[DocTableAction]] = [
        [.insertRowAbove, .insertRowBelow, .insertColumnLeft, .insertColumnRight],
        [.moveRowUp, .moveRowDown, .moveColumnLeft, .moveColumnRight],
        [.sortAscending, .sortDescending],
        [.clearCell, .deleteRow, .deleteColumn, .deleteTable],
    ]
}

@MainActor
@Observable
final class DocTableController {
    @ObservationIgnored private let demo: DocDemo
    @ObservationIgnored unowned let editor: DocEditor
    /// The cell shown as an editor (its table shows the + buttons, the cell its ⋯).
    /// It stays while a menu or button of the table is used, and goes when the focus
    /// goes elsewhere in the document or Esc leaves the table.
    private(set) var editing: DocCellKey?
    /// The cell whose text view has the focus.
    private(set) var active: DocCellKey?
    @ObservationIgnored private var views: [DocCellKey: [WeakCellView]] = [:]
    @ObservationIgnored private var pendingFocus: (key: DocCellKey, atEnd: Bool)?
    /// Typing in one cell is one undo step until another cell is edited.
    @ObservationIgnored private var session: UInt64 = 0

    init(demo: DocDemo, editor: DocEditor) {
        self.demo = demo
        self.editor = editor
    }

    var isEditable: Bool { editor.isEditable }

    // MARK: Model

    private func database(_ block: DocBlockID) -> (id: DatabaseID, database: Database)? {
        guard let kind = demo.doc.block(block)?.kind, case .database(let id, _) = kind, let database = demo.doc.databases[id] else { return nil }
        return (id, database)
    }

    static func text(of value: CellValue?) -> String {
        switch value {
        case .text(let value), .url(let value), .person(let value): value
        case .number(let value): value.formatted()
        case .checkbox(let value): value ? "✓" : ""
        default: ""
        }
    }

    func text(_ key: DocCellKey) -> String {
        guard let (_, database) = database(key.block) else { return "" }
        guard let row = key.row else { return database.columns.first { $0.id == key.column }?.name ?? "" }
        return Self.text(of: database.rows.first { $0.id == row }?.cells[key.column])
    }

    private func commit(_ block: DocBlockID, _ steps: [DatabaseStep], merging: Bool = false) {
        guard let (id, _) = database(block), !steps.isEmpty else { return }
        if !merging { session &+= 1 }
        _ = demo.edit(steps.map { .database(id: id, step: $0) }, before: nil, after: nil,
                      merge: merging ? .init(block: block, session: session) : nil)
        if !merging { session &+= 1 }
    }

    /// The text view typed `text` into the cell.
    func changed(_ key: DocCellKey, to text: String) {
        guard let (_, database) = database(key.block), text != self.text(key) else { return }
        if let row = key.row {
            let previous = database.rows.first { $0.id == row }?.cells[key.column]
            commit(key.block, [.setCell(row: row, column: key.column, value: text.isEmpty ? nil : .text(value: text), previous: previous)], merging: true)
        } else if let column = database.columns.first(where: { $0.id == key.column }) {
            var renamed = column
            renamed.name = text
            commit(key.block, [.updateColumn(column: renamed, previous: column)], merging: true)
        }
    }

    // MARK: Focus and moving between cells

    func register(_ view: DocCellTextView, for key: DocCellKey) {
        views[key, default: []].removeAll { $0.view == nil || $0.view === view }
        views[key, default: []].append(WeakCellView(view: view))
        if let pending = pendingFocus, pending.key == key { focusSoon(key, atEnd: pending.atEnd) }
    }

    /// The cell's text view on screen (TiledView also renders rows off screen to measure them).
    func view(for key: DocCellKey) -> DocCellTextView? {
        views[key]?.compactMap(\.view).first { $0.window?.isKeyWindow == true }
    }

    func began(_ key: DocCellKey) {
        if active != key { session &+= 1 }
        active = key
        editing = key
    }

    func ended(_ key: DocCellKey) {
        if active == key { active = nil }
    }

    /// The focus went to the document's text (or nowhere): no cell is edited.
    func endEditing() {
        pendingFocus = nil
        editing = nil
    }

    /// A click on a table cell MarkdownView rendered (row 0 is the header).
    func tapped(_ table: DocTableSnapshot, at position: MarkdownTableCellPosition) {
        guard isEditable, let key = key(in: table, at: position), key != active else { return }
        focus(key)
    }

    func key(in table: DocTableSnapshot, at position: MarkdownTableCellPosition) -> DocCellKey? {
        let database = table.database
        guard database.columns.indices.contains(position.column), position.row <= database.rows.count else { return nil }
        let row = position.row == 0 ? nil : database.rows[position.row - 1].id
        return DocCellKey(block: table.block, row: row, column: database.columns[position.column].id)
    }

    /// The editor MarkdownView shows instead of the edited cell's content.
    func replacement(in table: DocTableSnapshot, at position: MarkdownTableCellPosition) -> AnyView? {
        guard let editing, editing.block == table.block, let key = key(in: table, at: position), key == editing else { return nil }
        return AnyView(DocTableCellEditor(key: key, text: text(key), isHeader: key.row == nil, controller: self))
    }

    func focus(_ key: DocCellKey, atEnd: Bool = true) {
        editing = key
        guard let view = view(for: key) else {
            focusSoon(key, atEnd: atEnd)
            return
        }
        pendingFocus = nil
        active = key
        view.becomeFirstResponder()
        let offset = atEnd ? view.text.utf16.count : 0
        view.selectedRange = NSRange(location: offset, length: 0)
    }

    /// After a structural change the new cell renders on the next pass.
    private func focusSoon(_ key: DocCellKey, atEnd: Bool) {
        editing = key
        pendingFocus = (key, atEnd)
        Task { @MainActor [weak self] in
            for _ in 0..<30 {
                guard let self, let pending = self.pendingFocus, pending.key == key else { return }
                if self.view(for: key) != nil { return self.focus(key, atEnd: atEnd) }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    enum Move { case next, previous, down, up, top, bottom, first, last }

    /// Rows top to bottom with the header first (nil), and columns, of the cell's table.
    private func grid(_ key: DocCellKey) -> (rows: [RowID?], columns: [ColumnID])? {
        guard let (_, database) = database(key.block) else { return nil }
        return ([nil] + database.rows.map(\.id), database.columns.map(\.id))
    }

    func move(_ move: Move, from key: DocCellKey) {
        guard let (rows, columns) = grid(key), let r = rows.firstIndex(of: key.row), let c = columns.firstIndex(of: key.column) else { return }
        func cell(_ r: Int, _ c: Int) -> DocCellKey { DocCellKey(block: key.block, row: rows[r], column: columns[c]) }
        switch move {
        case .next:
            if c + 1 < columns.count { focus(cell(r, c + 1)) } else { perform(.insertColumnRight, at: key) }
        case .previous:
            if c > 0 { focus(cell(r, c - 1)) } else if r > 0 { focus(cell(r - 1, columns.count - 1)) }
        case .down:
            if r + 1 < rows.count { focus(cell(r + 1, c)) } else { perform(.insertRowBelow, at: key) }
        case .up:
            if r > 0 { focus(cell(r - 1, c)) }
        case .top: focus(cell(0, c))
        case .bottom: focus(cell(rows.count - 1, c))
        case .first: focus(cell(r, 0))
        case .last: focus(cell(r, columns.count - 1))
        }
    }

    func leave(_ key: DocCellKey) {
        view(for: key)?.resignFirstResponder()
        endEditing()
    }

    // MARK: Structure

    func isAvailable(_ action: DocTableAction, at key: DocCellKey) -> Bool {
        guard isEditable, let (rows, columns) = grid(key), let r = rows.firstIndex(of: key.row), let c = columns.firstIndex(of: key.column) else { return false }
        switch action {
        case .insertRowAbove: return r > 0
        case .moveRowUp: return r > 1
        case .moveRowDown: return r > 0 && r + 1 < rows.count
        case .moveColumnLeft: return c > 0
        case .moveColumnRight: return c + 1 < columns.count
        case .deleteRow: return r > 0
        case .deleteColumn: return columns.count > 1
        case .sortAscending, .sortDescending: return rows.count > 2
        default: return true
        }
    }

    /// Adds a row at the bottom (the + below the table) and edits its first cell.
    func appendRow(_ block: DocBlockID) {
        guard let (_, database) = database(block), let column = database.columns.first else { return }
        let row = Row(id: demo.newID())
        commit(block, [.insertRow(row: row, after: database.rows.last?.id)])
        focusSoon(DocCellKey(block: block, row: row.id, column: column.id), atEnd: true)
    }

    /// Adds a column at the end (the + beside the table) and edits its header.
    func appendColumn(_ block: DocBlockID) {
        guard let (_, database) = database(block) else { return }
        let column = Column(id: demo.newID(), name: "", type: .text)
        commit(block, [.insertColumn(column: column, after: database.columns.last?.id, cells: [:])])
        focusSoon(DocCellKey(block: block, row: nil, column: column.id), atEnd: true)
    }

    func perform(_ action: DocTableAction, at key: DocCellKey) {
        guard isAvailable(action, at: key), let (_, database) = database(key.block) else { return }
        let rows = database.rows
        let columns = database.columns
        let r = key.row.flatMap { id in rows.firstIndex { $0.id == id } }
        let c = columns.firstIndex { $0.id == key.column } ?? 0
        switch action {
        case .insertRowAbove, .insertRowBelow:
            let row = Row(id: demo.newID())
            let after: RowID? = switch (action, r) {
            case (.insertRowAbove, let r?): r > 0 ? rows[r - 1].id : nil
            case (.insertRowBelow, let r?): rows[r].id
            default: nil  // below the header: the first row
            }
            commit(key.block, [.insertRow(row: row, after: after)])
            focusSoon(DocCellKey(block: key.block, row: row.id, column: key.column), atEnd: true)
        case .insertColumnLeft, .insertColumnRight:
            let column = Column(id: demo.newID(), name: "", type: .text)
            let after = action == .insertColumnLeft ? (c > 0 ? columns[c - 1].id : nil) : key.column
            commit(key.block, [.insertColumn(column: column, after: after, cells: [:])])
            focusSoon(DocCellKey(block: key.block, row: key.row, column: column.id), atEnd: true)
        case .moveRowUp, .moveRowDown:
            guard let r else { return }
            let after: RowID? = action == .moveRowUp ? (r >= 2 ? rows[r - 2].id : nil) : rows[r + 1].id
            commit(key.block, [.moveRow(row: rows[r].id, after: after, from: nil)])
            focusSoon(key, atEnd: true)
        case .moveColumnLeft, .moveColumnRight:
            let column = columns[c]
            let values = rows.reduce(into: [RowID: CellValue]()) { $0[$1.id] = $1.cells[column.id] }
            var remaining = columns
            remaining.remove(at: c)
            let target = action == .moveColumnLeft ? c - 1 : c + 1
            let after = target > 0 ? remaining[target - 1].id : nil
            commit(key.block, [
                .deleteColumn(column: column, after: c > 0 ? columns[c - 1].id : nil, cells: values),
                .insertColumn(column: column, after: after, cells: values),
            ])
            focusSoon(key, atEnd: true)
        case .sortAscending, .sortDescending:
            let ascending = action == .sortAscending
            let sorted = rows.sorted { a, b in
                let x = Self.text(of: a.cells[key.column]), y = Self.text(of: b.cells[key.column])
                // Empty cells go last either way; numbers compare as numbers.
                if x.isEmpty != y.isEmpty { return !x.isEmpty }
                if let p = Double(x), let q = Double(y), p != q { return ascending ? p < q : p > q }
                let order = x.localizedStandardCompare(y)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            guard sorted.map(\.id) != rows.map(\.id) else { return }
            commit(key.block, sorted.enumerated().map { index, row in
                .moveRow(row: row.id, after: index == 0 ? nil : sorted[index - 1].id, from: nil)
            })
        case .deleteRow:
            guard let r else { return }
            commit(key.block, [.deleteRow(row: rows[r], after: r > 0 ? rows[r - 1].id : nil)])
            let next: RowID? = r + 1 < rows.count ? rows[r + 1].id : (r > 0 ? rows[r - 1].id : nil)
            focusSoon(DocCellKey(block: key.block, row: next, column: key.column), atEnd: true)
        case .deleteColumn:
            let column = columns[c]
            let values = rows.reduce(into: [RowID: CellValue]()) { $0[$1.id] = $1.cells[column.id] }
            commit(key.block, [.deleteColumn(column: column, after: c > 0 ? columns[c - 1].id : nil, cells: values)])
            let next = c + 1 < columns.count ? columns[c + 1].id : columns[c - 1].id
            focusSoon(DocCellKey(block: key.block, row: key.row, column: next), atEnd: true)
        case .clearCell:
            changed(key, to: "")
            session &+= 1
        case .deleteTable:
            deleteTable(key.block)
        }
    }

    /// The table's block goes, then its database (a database still shown can't go).
    func deleteTable(_ block: DocBlockID) {
        guard let (_, database) = database(block), let index = demo.doc.blocks.firstIndex(where: { $0.id == block }) else { return }
        if let editing { leave(editing) }
        active = nil
        let after = index > 0 ? demo.doc.blocks[index - 1].id : nil
        _ = demo.edit([.deleteBlock(block: demo.doc.blocks[index], after: after), .deleteDatabase(database: database)], before: nil, after: nil)
    }

    /// A new table (`rows` counts the header) made from `block`, or put after it; its
    /// first header cell is edited. A paragraph follows it when nothing else does.
    func insertTable(rows: Int, columns: Int, replacing block: DocBlock, keep: Bool) -> [DocStep] {
        let columnList = (0..<max(1, columns)).map { _ in Column(id: demo.newID(), name: "", type: .text) }
        let database = Database(id: demo.newID(), columns: columnList, rows: (0..<max(0, rows - 1)).map { _ in Row(id: demo.newID()) })
        let kind = BlockKind.database(id: database.id, view: .table(hidden: [], sort: []))
        var steps: [DocStep] = [.createDatabase(database: database)]
        let table: DocBlockID
        if keep {
            table = demo.newBlockID()
            steps.append(.insertBlock(block: DocBlock(id: table, kind: kind), after: block.id))
        } else {
            table = block.id
            steps.append(.setBlock(block: block.id, kind: kind, indent: 0, previousKind: block.kind, previousIndent: block.indent))
        }
        if demo.doc.blocks.last?.id == block.id {
            steps.append(.insertBlock(block: DocBlock(id: demo.newBlockID(), kind: .paragraph), after: table))
        }
        focusSoon(DocCellKey(block: table, row: nil, column: columnList[0].id), atEnd: true)
        return steps
    }
}

struct WeakCellView {
    weak var view: DocCellTextView?
}

// MARK: - Cell text view

/// A cell's text: native typing (IME included), every change goes to the model;
/// structural keys go to the controller; ⌘Z is the document's.
final class DocCellTextView: UITextView, UITextViewDelegate, UIContextMenuInteractionDelegate {
    var key: DocCellKey?
    weak var controller: DocTableController?
    var isHeader = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        #if targetEnvironment(macCatalyst)
        // Right-click a cell: the table's menu (on touch it's the cell's ⋯, so a long
        // press still selects text).
        addInteraction(UIContextMenuInteraction(delegate: self))
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let key, let controller else { return nil }
        if !isFirstResponder { controller.focus(key) }
        return UIContextMenuConfiguration(actionProvider: { _ in
            let table = DocTableMenu.uiMenu(for: key, controller: controller)
            return UIMenu(children: table.children)
        })
    }

    override var undoManager: UndoManager? { controller?.editor.undoManager }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(previousCell)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: .command, action: #selector(topCell)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: .command, action: #selector(bottomCell)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: .command, action: #selector(firstCell)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: .command, action: #selector(lastCell)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(leaveTable)),
        ]
        // ↑↓ leave the cell only from its first / last line.
        if let caret = selectedTextRange?.start, markedTextRange == nil {
            let line = caretRect(for: caret)
            if line.minY <= caretRect(for: beginningOfDocument).minY + 1 {
                commands.append(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(cellAbove)))
            }
            if line.minY >= caretRect(for: endOfDocument).minY - 1 {
                commands.append(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(cellBelow)))
            }
        }
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + commands
    }

    private func move(_ move: DocTableController.Move) {
        guard let key else { return }
        controller?.move(move, from: key)
    }

    @objc private func previousCell() { move(.previous) }
    @objc private func topCell() { move(.top) }
    @objc private func bottomCell() { move(.bottom) }
    @objc private func firstCell() { move(.first) }
    @objc private func lastCell() { move(.last) }
    @objc private func cellAbove() { move(.up) }
    @objc private func cellBelow() { move(.down) }
    @objc private func leaveTable() {
        if let key { controller?.leave(key) }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard controller?.isEditable == true else { return false }
        if markedTextRange == nil, text == "\t" { move(.next); return false }
        if markedTextRange == nil, text == "\n" { move(.down); return false }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        guard markedTextRange == nil, let key else { return }
        // A cell is one line of text: pasted line breaks and tabs become spaces.
        let flat = text.replacing(/[\n\t\r]/, with: " ")
        if flat != text { text = flat }
        controller?.changed(key, to: flat)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if let key { controller?.began(key) }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if let key { controller?.ended(key) }
    }

    /// Right-click (or the edit menu): the table's actions after the text ones.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let key, let controller else { return nil }
        return UIMenu(children: suggestedActions + [DocTableMenu.uiMenu(for: key, controller: controller)])
    }
}

enum DocTableMenu {
    @MainActor
    static func uiMenu(for key: DocCellKey, controller: DocTableController) -> UIMenu {
        let sections = DocTableAction.sections.map { section in
            UIMenu(options: .displayInline, children: section.map { action in
                let item = UIAction(title: action.title, image: UIImage(systemName: action.symbol),
                                    attributes: action.isDestructive ? .destructive : []) { [weak controller] _ in
                    controller?.perform(action, at: key)
                }
                if !controller.isAvailable(action, at: key) { item.attributes.insert(.disabled) }
                return item
            })
        }
        return UIMenu(title: "编辑表格", image: UIImage(systemName: "tablecells"), children: sections)
    }
}

struct DocTableCellField: UIViewRepresentable {
    let key: DocCellKey
    let text: String
    let isHeader: Bool
    let controller: DocTableController

    func makeUIView(context: Context) -> DocCellTextView {
        let view = DocCellTextView()
        view.delegate = view
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: DocCellTextView, context: Context) {
        view.key = key
        view.controller = controller
        view.isHeader = isHeader
        view.isEditable = controller.isEditable
        view.font = isHeader ? DocTableCellField.headerFont : DocTableCellField.bodyFont
        view.textColor = .label
        // The model is the truth; while typing it already equals the view.
        if view.text != text, view.markedTextRange == nil {
            let editing = view.isFirstResponder
            view.text = text
            if editing { view.selectedRange = NSRange(location: text.utf16.count, length: 0) }
        }
        controller.register(view, for: key)
    }

    /// MarkdownView's table fonts: the header is SF Compact subheadline, bold; the body is body.
    static let bodyFont = UIFont.preferredFont(forTextStyle: .body)
    static let headerFont: UIFont = {
        let size = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        guard let compact = UIFont(name: "SFCompactText-Bold", size: size) else {
            return UIFont.systemFont(ofSize: size, weight: .bold)
        }
        return UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: compact)
    }()

    /// Unconstrained: the text's own width (the table sizes its columns from it, as it
    /// does from a rendered cell); proposed a width: that width, wrapped.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DocCellTextView, context: Context) -> CGSize? {
        let font = isHeader ? Self.headerFont : Self.bodyFont
        let natural = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: max(ceil(height), ceil(font.lineHeight)))
    }
}

// MARK: - The table

/// The edited cell: its text view, Craft's blue frame around the cell, its ⋯.
struct DocTableCellEditor: View {
    let key: DocCellKey
    let text: String
    let isHeader: Bool
    let controller: DocTableController

    var body: some View {
        DocTableCellField(key: key, text: text, isHeader: isHeader, controller: controller)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                // Out over the cell's padding (MarkdownView's: 8 across, 13 down).
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(.horizontal, -6)
                    .padding(.vertical, -9)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .trailing) {
                DocTableCellMenu(key: key, controller: controller)
                    .offset(x: 10)
            }
    }
}

/// The table: MarkdownView renders it; clicks on cells edit them; the + strips add a
/// row and a column.
struct DocTableRowView: View {
    let table: DocTableSnapshot
    let blocks: [MarkdownStreamBlock]
    let controller: DocTableController
    @State private var hovering = false

    private var showsAdders: Bool {
        controller.isEditable && (hovering || controller.editing?.block == table.block)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(spacing: 2) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownStreamBlockView(block)
                        .markdownDisplayMathRendersSynchronously()
                        .markdownTableCellTap { [table, controller] position in controller.tapped(table, at: position) }
                        .markdownTableCellReplacement { [table, controller] position in controller.replacement(in: table, at: position) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DocTableAdder(systemImage: "plus", label: "添加行", isVisible: showsAdders) { controller.appendRow(table.block) }
                    .frame(height: 16)
            }
            DocTableAdder(systemImage: "plus", label: "添加列", isVisible: showsAdders) { controller.appendColumn(table.block) }
                .frame(width: 16)
                .padding(.bottom, 18)
        }
        .onHover { hovering = $0 }
    }
}

/// The edited cell's ⋯: the same actions as the right-click menu (and the only way
/// to them by touch).
struct DocTableCellMenu: View {
    let key: DocCellKey
    let controller: DocTableController

    var body: some View {
        Menu {
            ForEach(Array(DocTableAction.sections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(section) { action in
                        Button(role: action.isDestructive ? .destructive : nil) {
                            controller.perform(action, at: key)
                        } label: {
                            Label(action.title, systemImage: action.symbol)
                        }
                        .disabled(!controller.isAvailable(action, at: key))
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("表格操作")
    }
}

/// Craft's thin + strip beside and below the table.
struct DocTableAdder: View {
    let systemImage: String
    let label: String
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
    }
}
