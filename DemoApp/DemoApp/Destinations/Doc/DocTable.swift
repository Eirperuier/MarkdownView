//
//  DocTable.swift
//  DemoApp
//
//  Editing a database block as a table, the way Craft does it. The table is
//  MarkdownView's, read or edited: clicking a cell puts an editor in that cell only
//  (MarkdownView's cell replacement), so the table keeps its look and layout.
//  - click a cell and type; the header row is the column names (plain text);
//  - a body cell's text is a text of the document's editor (DocEditor), shown by
//    MarkdownView as the table shows it: every mark a paragraph takes (bold, a link, a
//    colour, a mention…), by the same keys, selection toolbar, format panel and edit
//    menu, and the cell's menu's Format (Craft's Text Format: the selected text or all
//    of the cell's); a text column holds it with its marks;
//  - Tab / Shift-Tab: next / previous cell (Tab past a row's last cell adds a column),
//    Return: the cell below (past the last row adds a row), ↑↓ at a cell's first / last
//    line: the cell above / below, ⌘ + arrows: the table's edge, Esc: leave the table;
//  - right-click a cell (Mac) or its ⋮ (both): Craft's cell menu, ours (FlooDesign's
//    action menu, a sheet on a phone): Edit Table (insert, move, delete rows and
//    columns, delete the table), Format, a formula, sorting by the column, cut / copy /
//    paste, clearing the cell;
//  - bars on the table's top and left edges, over the edited cell's column and row
//    (Craft's): a click picks the column or row (the caret goes) and opens the menu for
//    all of it (copy, cut, paste, clear the lot; sort by the column);
//  - the dots where the edited cell's row and column meet the table's right and bottom
//    edges add a column and a row there, and edit the new cell beside or below.
//  Every change is one DocKit step (typing in a cell merges into one undo step), so
//  undo, redo and sync treat the table like the rest of the document.
//

import SwiftUI
import UIKit
import DocKit
import FlooDesign
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

/// The edited cell's row or column, picked by its bar on the cell's ring.
enum DocTableLine: Hashable { case row, column }

/// Whose menu is open: a cell's (its ⋮, a right-click), or its row's or column's (the bar).
struct DocTableMenuTarget: Equatable {
    let key: DocCellKey
    var line: DocTableLine?
}

enum DocTableAction: CaseIterable, Identifiable {
    case insertRowAbove, insertRowBelow, insertColumnLeft, insertColumnRight
    case moveRowUp, moveRowDown, moveColumnLeft, moveColumnRight
    case sortAscending, sortDescending, insertFormula
    case cut, copy, paste
    case deleteRow, deleteColumn, clearCell, deleteTable

    var id: Self { self }

    var title: String {
        switch self {
        case .insertRowAbove: String(localized: "Insert Row Above")
        case .insertRowBelow: String(localized: "Insert Row Below")
        case .insertColumnLeft: String(localized: "Insert Column Left")
        case .insertColumnRight: String(localized: "Insert Column Right")
        case .moveRowUp: String(localized: "Move Row Up")
        case .moveRowDown: String(localized: "Move Row Down")
        case .moveColumnLeft: String(localized: "Move Column Left")
        case .moveColumnRight: String(localized: "Move Column Right")
        case .sortAscending: String(localized: "Sort Ascending by This Column")
        case .sortDescending: String(localized: "Sort Descending by This Column")
        case .insertFormula: String(localized: "Insert Formula")
        case .deleteRow: String(localized: "Delete Row")
        case .deleteColumn: String(localized: "Delete Column")
        case .cut: String(localized: "Cut")
        case .copy: String(localized: "Copy")
        case .paste: String(localized: "Paste")
        case .clearCell: String(localized: "Clear Cell Contents")
        case .deleteTable: String(localized: "Delete Table")
        }
    }

    var symbol: String {
        switch self {
        case .cut: "scissors"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
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
        case .insertFormula: "function"
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
    /// The cell edited before, while the focus goes from it to the edited one: its editor
    /// stays until the next one has the focus. Taken out with the focus, it would put the
    /// keyboard away for the next to bring back (a long frame on a phone).
    private var handingOver: DocCellKey?
    /// The cell whose text view has the focus.
    private(set) var active: DocCellKey?
    /// The edited cell's row or column, picked by its bar: the menu acts on all of it.
    private(set) var line: DocTableLine?
    /// Whose menu is open.
    private(set) var menu: DocTableMenuTarget?
    @ObservationIgnored private var views: [DocCellKey: [WeakCellView]] = [:]
    @ObservationIgnored private var textIDs: [DocCellKey: DocBlockID] = [:]
    @ObservationIgnored private var textKeys: [DocBlockID: DocCellKey] = [:]
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
        case .richText(let text): text.string
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

    // MARK: A cell's text

    /// A body cell's text with its marks (other kinds of value as their text).
    func docText(_ key: DocCellKey) -> DocText {
        guard let (_, database) = database(key.block), let row = key.row else { return DocText(string: text(key)) }
        let value = database.rows.first { $0.id == row }?.cells[key.column]
        return value?.docText ?? DocText(string: Self.text(of: value))
    }

    /// A body cell's text is a text of the document's editor (DocEditor), under an id of
    /// its own: typing, marks, links, the selection's toolbar and undo work in it as in a
    /// paragraph, and its edits become the cell's value (`modelSteps`). The header's
    /// cells are the columns' names, plain text in a text view of their own.
    func textID(_ key: DocCellKey) -> DocBlockID {
        if let id = textIDs[key] { return id }
        let id = demo.newBlockID()
        textIDs[key] = id
        textKeys[id] = key
        return id
    }

    /// The cell whose text `id` is.
    func cell(of id: DocBlockID) -> DocCellKey? { textKeys[id] }

    /// The cell's text as the paragraph the editor edits; nil when `id` isn't a cell's.
    func textBlock(_ id: DocBlockID) -> DocBlock? {
        guard let key = textKeys[id], let (_, database) = database(key.block), let row = key.row,
              database.rows.contains(where: { $0.id == row }), database.columns.contains(where: { $0.id == key.column })
        else { return nil }
        return DocBlock(id: id, kind: .paragraph, text: docText(key))
    }

    /// The editor's steps, those on cells' texts as the cells' new values: the text steps
    /// edit the cell's text, which the cell takes as its column does (marks in a text
    /// column; a number column only a number). What a cell has no part in (splitting it,
    /// a block kind) is dropped.
    func modelSteps(_ steps: [DocStep]) -> [DocStep] {
        guard steps.contains(where: { Self.blocks(of: $0).contains { textKeys[$0] != nil } }) else { return steps }
        var result: [DocStep] = []
        var edited: [DocBlockID: DocText] = [:]
        var order: [DocBlockID] = []
        for step in steps {
            let ids = Self.blocks(of: step)
            guard ids.contains(where: { textKeys[$0] != nil }) else {
                result.append(step)
                continue
            }
            guard ids.count == 1, let id = ids.first, let block = textBlock(id) else { continue }
            var scratch = Doc(id: demo.doc.id, blocks: [DocBlock(id: id, kind: .paragraph, text: edited[id] ?? block.text)])
            switch step {
            case .insertText, .deleteText, .setMarks:
                guard (try? scratch.apply(step)) != nil, let text = scratch.block(id)?.text else { continue }
                if edited[id] == nil { order.append(id) }
                edited[id] = text
            default:
                continue
            }
        }
        for id in order {
            guard let key = textKeys[id], let row = key.row, let text = edited[id], let (_, database) = database(key.block),
                  let column = database.columns.first(where: { $0.id == key.column })
            else { continue }
            let previous = database.rows.first { $0.id == row }?.cells[key.column]
            let value: CellValue?
            if column.type == .text {
                value = text.isEmpty ? nil : .text(text)
            } else {
                guard DocFieldText.takes(text.string, in: column) else { continue }
                value = DocFieldText.value(typed: text.string, in: column)
            }
            if value != previous { result.append(.database(id: database.id, step: .setCell(row: row, column: column.id, value: value, previous: previous))) }
        }
        return result
    }

    /// The blocks a step names.
    private static func blocks(of step: DocStep) -> [DocBlockID] {
        switch step {
        case .insertText(let block, _, _), .deleteText(let block, _, _), .setMarks(let block, _, _, _, _),
             .setBlock(let block, _, _, _, _), .setDecoration(let block, _, _):
            [block]
        case .splitBlock(let block, _, let new, _, _, _): [block, new]
        case .joinBlock(let block, let into, _, _, _, _): [block, into]
        case .insertBlock(let block, let after), .deleteBlock(let block, let after): [block.id] + (after.map { [$0] } ?? [])
        case .moveBlock(let block, let after, let from): [block] + [after, from].compactMap { $0 }
        case .createDatabase, .deleteDatabase, .database: []
        }
    }

    private func commit(_ block: DocBlockID, _ steps: [DatabaseStep], merging: Bool = false) {
        guard let (id, _) = database(block), !steps.isEmpty else { return }
        if !merging { session &+= 1 }
        _ = demo.edit(steps.map { .database(id: id, step: $0) }, before: nil, after: nil,
                      merge: merging ? .init(block: block, session: session) : nil)
        if !merging { session &+= 1 }
        editor.settleSelection()
    }

    /// The text view typed `text` into the cell.
    func changed(_ key: DocCellKey, to text: String) {
        guard let (_, database) = database(key.block), text != self.text(key) else { return }
        if let row = key.row {
            // As the column holds it; text it doesn't take (a word in an agent's number
            // column) isn't written.
            guard let column = database.columns.first(where: { $0.id == key.column }), DocFieldText.takes(text, in: column) else { return }
            let previous = database.rows.first { $0.id == row }?.cells[key.column]
            commit(key.block, [.setCell(row: row, column: key.column, value: DocFieldText.value(typed: text, in: column), previous: previous)], merging: true)
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

    /// A cell's text view came on screen: the focus waiting for it goes to it.
    func arrived(_ key: DocCellKey) {
        if let pending = pendingFocus, pending.key == key, view(for: key) != nil { focus(key, atEnd: pending.atEnd) }
    }

    /// The cell's text view on screen (TiledView also renders rows off screen to measure
    /// them): a header cell's own, a body cell's the editor's.
    func view(for key: DocCellKey) -> UITextView? {
        if key.row != nil { return textIDs[key].flatMap(editor.textView(for:)) }
        return views[key]?.compactMap(\.view).first { $0.window?.isKeyWindow == true }
    }

    func began(_ key: DocCellKey) {
        if active != key { session &+= 1 }
        active = key
        editing = key
        handingOver = nil
        // Typing in the cell again: the cell, not its row or column.
        line = nil
        editor.sources.endEditing()
    }

    /// A cell's text view let the focus go. If a header cell's row was rendered anew
    /// (SwiftUI took the old view out, which lets the focus go first), the new view takes
    /// it (a body cell's text is the editor's, which does the same); a focus that went
    /// elsewhere (another cell, the text, the keyboard put away) leaves the old view where
    /// it was.
    func ended(_ key: DocCellKey, in view: UITextView) {
        if active == key { active = nil }
        if handingOver == key { handingOver = nil }
        guard key.row == nil, editing == key else { return }
        pendingFocus = (key, true)
        Task { @MainActor [weak self, weak view] in
            guard let self, self.pendingFocus?.key == key else { return }
            guard view?.window == nil, self.editing == key, self.active == nil else { return self.pendingFocus = nil }
            if self.view(for: key) != nil { self.focus(key) }
        }
    }

    /// After an undo: the edited cell shows the model's text now (see DocEditor.syncEditors),
    /// and a cell the undo took away is edited no more.
    func syncEditedText() {
        if let editing, !exists(editing) { return endEditing() }
        guard let editing, editing.row == nil, let view = view(for: editing), view.markedTextRange == nil else { return }
        let text = text(editing)
        if view.text != text {
            view.text = text
            view.selectedRange = NSRange(location: text.utf16.count, length: 0)
        }
    }

    /// The focus went to the document's text (or nowhere): no cell is edited.
    func endEditing() {
        pendingFocus = nil
        editing = nil
        handingOver = nil
        line = nil
        menu = nil
        editor.leaveCells()
    }

    /// A click on a table cell MarkdownView rendered (row 0 is the header).
    func tapped(_ table: DocTableSnapshot, at position: MarkdownTableCellPosition) {
        guard isEditable, let key = key(in: table, at: position), key != active || view(for: key)?.isFirstResponder != true else { return }
        focus(key)
    }

    private func exists(_ key: DocCellKey) -> Bool {
        guard let (_, database) = database(key.block), database.columns.contains(where: { $0.id == key.column }) else { return false }
        return key.row.map { row in database.rows.contains { $0.id == row } } ?? true
    }

    func key(in table: DocTableSnapshot, at position: MarkdownTableCellPosition) -> DocCellKey? {
        let database = table.database
        guard database.columns.indices.contains(position.column), position.row <= database.rows.count else { return nil }
        let row = position.row == 0 ? nil : database.rows[position.row - 1].id
        return DocCellKey(block: table.block, row: row, column: database.columns[position.column].id)
    }

    /// Where the edited cell is in this table (and the one handing the focus over), if
    /// they're in it: their editors show there.
    func replaced(in table: DocTableSnapshot) -> Set<MarkdownTableCellPosition> {
        Set([editing, handingOver].compactMap { $0.flatMap { position(of: $0, in: table) } })
    }

    private func position(of key: DocCellKey, in table: DocTableSnapshot) -> MarkdownTableCellPosition? {
        guard key.block == table.block, let column = table.database.columns.firstIndex(where: { $0.id == key.column }) else { return nil }
        guard let row = key.row else { return MarkdownTableCellPosition(row: 0, column: column) }
        return table.database.rows.firstIndex { $0.id == row }.map { MarkdownTableCellPosition(row: $0 + 1, column: column) }
    }

    /// The editor MarkdownView shows instead of the edited cell's content.
    func replacement(in table: DocTableSnapshot, at position: MarkdownTableCellPosition) -> AnyView? {
        guard let key = key(in: table, at: position), key == editing || key == handingOver else { return nil }
        return AnyView(DocTableCellEditor(key: key, controller: self))
    }

    /// The cell is the one edited (its editor shows): a menu of another cell goes, and a
    /// row or column picked in another.
    func willEdit(_ key: DocCellKey) {
        if menu?.key != key { menu = nil }
        if editing != key { line = nil }
        if let editing, editing != key, view(for: editing)?.isFirstResponder == true { handingOver = editing }
        editing = key
    }

    func focus(_ key: DocCellKey, atEnd: Bool = true) {
        willEdit(key)
        // A body cell's text is the editor's: the cursor goes there.
        if key.row != nil {
            pendingFocus = nil
            let id = textID(key)
            editor.place(DocPosition(block: id, offset: atEnd ? docText(key).length : 0))
            return
        }
        guard let view = view(for: key) else {
            focusSoon(key, atEnd: atEnd)
            return
        }
        pendingFocus = nil
        active = key
        view.becomeFirstResponder()
        let offset = atEnd ? view.text.utf16.count : 0
        view.selectedRange = NSRange(location: offset, length: 0)
        reveal(view)
    }

    /// Scrolls the document so the edited cell shows, above the keyboard too (which
    /// comes up a moment after the focus).
    func reveal(_ view: UITextView) {
        DocScrolling.reveal(view)
        Task { @MainActor [weak view] in
            try? await Task.sleep(for: .milliseconds(450))
            if let view, view.isFirstResponder { DocScrolling.reveal(view) }
        }
    }

    /// After a structural change the new cell renders on the next pass.
    private func focusSoon(_ key: DocCellKey, atEnd: Bool) {
        if key.row != nil { return focus(key, atEnd: atEnd) }
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

    func showMenu(_ key: DocCellKey) {
        if editing != key { focus(key) }
        line = nil
        menu = DocTableMenuTarget(key: key)
    }

    /// The bar on the edited cell's ring: its row or column picked (the caret goes), and
    /// the menu for it.
    func pick(_ line: DocTableLine, of key: DocCellKey) {
        guard editing == key else { return }
        view(for: key)?.resignFirstResponder()
        editor.leaveCells()
        self.line = line
        menu = DocTableMenuTarget(key: key, line: line)
    }

    func closeMenu() {
        menu = nil
    }

    func leave(_ key: DocCellKey) {
        view(for: key)?.resignFirstResponder()
        endEditing()
    }

    /// Esc in a cell: a menu or panel open takes it first (a level back, or it closes);
    /// else the table is left, and selected (where blocks are).
    func leaveByEscape(_ key: DocCellKey) {
        if FlooDesignPanels.escape() { return }
        leave(key)
        editor.blocks.selectAfterEditing(key.block)
    }

    // MARK: Format

    /// What the menu's Format acts on in a body cell of text: the text selected in it,
    /// else all of it (Craft's). Nil for a header cell, another kind of column, no text.
    func formatRange(_ key: DocCellKey) -> (block: DocBlockID, range: Range<Int>)? {
        guard isEditable, key.row != nil, let (_, database) = database(key.block),
              database.columns.first(where: { $0.id == key.column })?.type == .text
        else { return nil }
        let id = textID(key)
        let length = docText(key).length
        if let selection = editor.selection, selection.head.block == id, selection.anchor.block == id, selection.anchor.offset != selection.head.offset {
            let range = min(selection.anchor.offset, selection.head.offset)..<max(selection.anchor.offset, selection.head.offset)
            if range.upperBound <= length { return (id, range) }
        }
        return length > 0 ? (id, 0..<length) : nil
    }

    func formatIsOn(_ mark: Mark, at key: DocCellKey) -> Bool {
        guard let target = formatRange(key) else { return false }
        return DocEditor.covers(docText(key), target.range, with: mark.kind)
    }

    func toggleFormat(_ mark: Mark, at key: DocCellKey) {
        guard let target = formatRange(key) else { return }
        editor.toggle(mark, over: [target])
    }

    /// The text's colour (nil: the default one).
    func setColor(_ token: String?, at key: DocCellKey) {
        guard let target = formatRange(key) else { return }
        editor.set(.color, to: token.map(Mark.color), over: [target])
    }

    func color(at key: DocCellKey) -> Mark? {
        formatRange(key).flatMap { editor.common(.color, over: [$0]) }
    }

    func promptLink(at key: DocCellKey) {
        guard let target = formatRange(key), let view = view(for: key) else { return }
        editor.promptLink(over: target.range, in: target.block, from: view)
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
        case .insertFormula: return r > 0
        case .cut, .copy: return !text(key).isEmpty
        case .paste: return UIPasteboard.general.hasStrings
        default: return true
        }
    }

    /// Adds a row at the bottom (the dot on the table's bottom edge) and edits its cell
    /// in the column of `key`.
    func appendRow(below key: DocCellKey) {
        guard let (_, database) = database(key.block) else { return }
        let row = Row(id: demo.newID())
        commit(key.block, [.insertRow(row: row, after: database.rows.last?.id)])
        focusSoon(DocCellKey(block: key.block, row: row.id, column: key.column), atEnd: true)
    }

    /// Adds a column at the end (the dot on the table's right edge) and edits its cell in
    /// the row of `key`.
    func appendColumn(beside key: DocCellKey) {
        guard let (_, database) = database(key.block) else { return }
        let column = Column(id: demo.newID(), name: "", type: .text)
        commit(key.block, [.insertColumn(column: column, after: database.columns.last?.id, cells: [:])])
        focusSoon(DocCellKey(block: key.block, row: key.row, column: column.id), atEnd: true)
    }

    // MARK: A row or a column

    /// A row's cells (the header's are the column names), or a column's below its name.
    private func cells(_ line: DocTableLine, of key: DocCellKey) -> [DocCellKey] {
        guard let (_, database) = database(key.block) else { return [] }
        return switch line {
        case .row: database.columns.map { DocCellKey(block: key.block, row: key.row, column: $0.id) }
        case .column: database.rows.map { DocCellKey(block: key.block, row: $0.id, column: key.column) }
        }
    }

    /// As a spreadsheet copies them: a row's cells between tabs, a column's on lines.
    private func text(of cells: [DocCellKey], _ line: DocTableLine) -> String {
        cells.map(text).joined(separator: line == .row ? "\t" : "\n")
    }

    /// Every cell to `text` (as its column takes it; the header's are names): one undo step.
    private func set(_ cells: [DocCellKey], to text: String) {
        guard let block = cells.first?.block, let (_, database) = database(block) else { return }
        let steps: [DatabaseStep] = cells.compactMap { key in
            guard self.text(key) != text, let column = database.columns.first(where: { $0.id == key.column }) else { return nil }
            guard let row = key.row else {
                var renamed = column
                renamed.name = text
                return .updateColumn(column: renamed, previous: column)
            }
            guard DocFieldText.takes(text, in: column) else { return nil }
            return .setCell(row: row, column: column.id, value: DocFieldText.value(typed: text, in: column),
                            previous: database.rows.first { $0.id == row }?.cells[column.id])
        }
        commit(block, steps)
    }

    func isAvailable(_ action: DocTableAction, at key: DocCellKey, on line: DocTableLine?) -> Bool {
        guard let line else { return isAvailable(action, at: key) }
        switch action {
        case .insertFormula: return false
        case .sortAscending, .sortDescending: return line == .column && isAvailable(action, at: key)
        case .cut, .copy, .clearCell: return isEditable && cells(line, of: key).contains { !text($0).isEmpty }
        default: return isAvailable(action, at: key)
        }
    }

    /// The menu's action on the edited cell, or on all of its picked row or column.
    func perform(_ action: DocTableAction, at key: DocCellKey, on line: DocTableLine?) {
        guard let line else { return perform(action, at: key) }
        guard isAvailable(action, at: key, on: line) else { return }
        let cells = cells(line, of: key)
        switch action {
        case .copy:
            UIPasteboard.general.string = text(of: cells, line)
        case .cut:
            UIPasteboard.general.string = text(of: cells, line)
            set(cells, to: "")
        case .paste:
            // A range fills the cells from the line's first; one value goes in every cell.
            guard let string = UIPasteboard.general.string, let first = cells.first else { return }
            if !paste(string, at: first) { set(cells, to: string) }
        case .clearCell:
            set(cells, to: "")
        default:
            perform(action, at: key)
        }
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
        case .copy:
            UIPasteboard.general.string = text(key)
        case .cut:
            UIPasteboard.general.string = text(key)
            changed(key, to: "")
            session &+= 1
        case .paste:
            // As ⌘V in the cell: a range fills the cells, text goes in at the caret.
            view(for: key)?.paste(nil)
        case .clearCell:
            changed(key, to: "")
            session &+= 1
        case .insertFormula:
            // Craft starts a formula with "="; a sum of the cells above is the usual one.
            if !DatabaseFormula.isFormula(text(key)) {
                changed(key, to: "=SUM(ABOVE)")
                session &+= 1
            }
            focusSoon(key, atEnd: true)
        case .deleteTable:
            deleteTable(key.block)
        }
    }

    /// What a formula cell computes (nil for other cells).
    func result(_ key: DocCellKey) -> String? {
        guard let (_, database) = database(key.block), let row = key.row, DatabaseFormula.isFormula(text(key)),
              let r = database.rows.firstIndex(where: { $0.id == row }), let c = database.columns.firstIndex(where: { $0.id == key.column })
        else { return nil }
        return DatabaseFormula.displayed(text(key), in: database, row: r + 1, column: c)
    }

    /// Pasted text with tabs or line breaks (a range copied from a spreadsheet, or a
    /// table's cells): it fills the cells from `key` right and down, adding the rows and
    /// columns it needs. One undo step. Returns false for plain text (a normal paste).
    func paste(_ string: String, at key: DocCellKey) -> Bool {
        var lines = string.replacing("\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        let grid = lines.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        guard grid.count > 1 || (grid.first?.count ?? 0) > 1, let (_, database) = database(key.block),
              let c0 = database.columns.firstIndex(where: { $0.id == key.column })
        else { return false }
        let r0 = key.row.flatMap { id in database.rows.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        var steps: [DatabaseStep] = []
        var columns = database.columns
        var rows = database.rows
        let width = grid.map(\.count).max() ?? 0
        while columns.count < c0 + width {
            let column = Column(id: demo.newID(), name: "", type: .text)
            steps.append(.insertColumn(column: column, after: columns.last?.id, cells: [:]))
            columns.append(column)
        }
        while rows.count < r0 + grid.count - 1 {
            let row = Row(id: demo.newID())
            steps.append(.insertRow(row: row, after: rows.last?.id))
            rows.append(row)
        }
        for (i, line) in grid.enumerated() {
            for (j, value) in line.enumerated() {
                let column = columns[c0 + j]
                if r0 + i == 0 {
                    var renamed = column
                    renamed.name = value
                    if renamed != column { steps.append(.updateColumn(column: renamed, previous: column)) }
                } else {
                    let row = rows[r0 + i - 1]
                    let previous = row.cells[column.id]
                    guard DocFieldText.takes(value, in: column) else { continue }
                    let next = DocFieldText.value(typed: value, in: column)
                    if next != previous { steps.append(.setCell(row: row.id, column: column.id, value: next, previous: previous)) }
                }
            }
        }
        commit(key.block, steps)
        focusSoon(key, atEnd: true)
        return true
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
final class DocCellTextView: UITextView, UITextViewDelegate {
    var key: DocCellKey?
    weak var controller: DocTableController?
    var isHeader = false


    /// On screen at last (its row rendered late, after the focus was asked for): a
    /// focus waiting for this cell is taken now.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window?.isKeyWindow == true, let key { controller?.arrived(key) }
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

    override func paste(_ sender: Any?) {
        if let key, let string = UIPasteboard.general.string, controller?.paste(string, at: key) == true { return }
        super.paste(sender)
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
        if let key { controller?.leaveByEscape(key) }
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
        if let key { controller?.ended(key, in: self) }
    }

    #if targetEnvironment(macCatalyst)
    /// Right-click: the cell's menu (ours, by its ⋮), which has the text's Cut, Copy and
    /// Paste, instead of the system's. On touch the edit menu stays the text's.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        if let key { controller?.showMenu(key) }
        return UIMenu(children: [])
    }
    #endif
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
        view.textColor = FlooDesignTokens.UIKitColor.primary
        // The model is the truth; while typing it already equals the view.
        if view.text != text, view.markedTextRange == nil {
            let editing = view.isFirstResponder
            view.text = text
            if editing { view.selectedRange = NSRange(location: text.utf16.count, length: 0) }
        }
        controller.register(view, for: key)
    }

    /// MarkdownView's table fonts: the header is SF Compact subheadline, bold; the body is the
    /// page's body (DocTypography).
    static let bodyFont = UIFont.preferredFont(forTextStyle: .body).withSize(MarkdownTextScale.size(of: .body))
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

private typealias Handles = FlooDesignTokens.Component.TableHandles

/// The edited cell: its text (a column's name in a text view of its own, a body cell's
/// text the editor's), Craft's ring around the cell, its ⋮.
struct DocTableCellEditor: View {
    let key: DocCellKey
    let controller: DocTableController

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .anchorPreference(key: DocTableRingKey.self, value: .bounds) { DocTableRingAnchor(key: key, bounds: $0) }
            .overlay {
                // Out over the cell's padding (MarkdownView's: 8 across, 13 down). While its
                // row or column is picked, that one is ringed instead (DocTableEdges).
                RoundedRectangle(cornerRadius: Handles.ringRadius, style: .continuous)
                    .strokeBorder(FlooDesignTokens.ColorRole.Accent.primary, lineWidth: FlooDesignTokens.Border.focus)
                    .opacity(controller.line == nil ? 1 : 0)
                    .padding(.horizontal, -Handles.ringOutset.width)
                    .padding(.vertical, -Handles.ringOutset.height)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .trailing) {
                DocTableCellMenu(key: key, controller: controller)
                    .offset(x: 10)
            }
            .overlay(alignment: .bottomLeading) {
                // A formula is edited as its text; what it computes shows under the cell
                // (Craft shows the two the other way round).
                if let result = controller.result(key) {
                    FlooDesignBadge("= \(result)")
                        .offset(y: 30)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if key.row == nil {
            DocTableCellField(key: key, text: controller.text(key), isHeader: true, controller: controller)
        } else {
            DocTableCellText(text: controller.docText(key), hooks: controller.editor.hooks(for: controller.textID(key)))
        }
    }
}

/// A body cell's text being edited: MarkdownView's text of the cell as the table renders
/// it (its selectable cell), in the editor's hands (its hooks), so the cell looks the same
/// read and edited, marks and all.
struct DocTableCellText: View {
    let text: DocText
    let hooks: MarkdownSelectableTextHooks

    var body: some View {
        MarkdownSelectableText(tree: MarkdownTree(text.lineTree), applyEdgeInsets: false)
            .transformEnvironment(\.markdownPlatformTypography) { typography in
                typography = typography.tableCell
            }
            .environment(\.markdownSelectableTextHooks, hooks)
    }
}

/// A bar on the table's top edge over the edited cell's column, or on its left edge by
/// its row: a click picks the column or row and opens the menu for it.
struct DocTableGrip: View {
    let line: DocTableLine
    let key: DocCellKey
    let controller: DocTableController

    var body: some View {
        let size = line == .column ? Handles.columnGrip : Handles.rowGrip
        Button {
            controller.pick(line, of: key)
        } label: {
            Capsule()
                .fill(FlooDesignTokens.ColorRole.Accent.primary.opacity(Handles.gripOpacity))
                .frame(width: size.width, height: size.height)
                .frame(width: max(size.width, Handles.target), height: max(size.height, Handles.target))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line == .column ? String(localized: "Select Column") : String(localized: "Select Row"))
        .docTableMenu(DocTableMenuTarget(key: key, line: line), controller: controller)
    }
}

/// Where the edited cell's text is (its ring is out over its padding), for the table's edges.
struct DocTableRingAnchor {
    let key: DocCellKey
    let bounds: Anchor<CGRect>
}

struct DocTableRingKey: PreferenceKey {
    static let defaultValue: DocTableRingAnchor? = nil
    static func reduce(value: inout DocTableRingAnchor?, nextValue: () -> DocTableRingAnchor?) {
        value = value ?? nextValue()
    }
}

/// The table: MarkdownView renders it; clicks on cells edit them; around the edited cell,
/// the dots on the table's edges and the picked row or column (DocTableEdges).
struct DocTableRowView: View {
    let table: DocTableSnapshot
    let tree: MarkdownTree
    let controller: DocTableController
    @State private var tableBounds: Anchor<CGRect>?

    var body: some View {
        MarkdownBlockView(tree: tree)
            .markdownDisplayMathRendersSynchronously()
            .markdownTableCellsSelectable()
            .markdownTableCellTap { [table, controller] position in controller.tapped(table, at: position) }
            .markdownTableCellReplacement(controller.replaced(in: table)) { [table, controller] position in controller.replacement(in: table, at: position) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlayPreferenceValue(DocTableRingKey.self) { ring in
                // The table's own edges: wider than the page it scrolls, so its right edge
                // can be out of sight.
                GeometryReader { proxy in
                    if let ring, ring.key.block == table.block, controller.editing == ring.key {
                        DocTableEdges(key: ring.key, table: tableBounds.map { proxy[$0] } ?? CGRect(origin: .zero, size: proxy.size), controller: controller,
                                      cell: proxy[ring.bounds].insetBy(dx: -Handles.ringOutset.width, dy: -Handles.ringOutset.height))
                    }
                }
            }
            .onPreferenceChange(MarkdownTableBoundsKey.self) { tableBounds = $0 }
            // Room for the dots on the right and bottom edges, in the row (a touch out of it
            // goes nowhere).
            .padding(.trailing, Handles.target / 2)
            .padding(.bottom, Handles.target / 2)
    }
}

/// On the table's edges, by the edited cell (Craft's): bars on the top and left over its
/// column and row, which pick them; dots on the right and bottom, which add a column or
/// a row; the picked row or column ringed.
struct DocTableEdges: View {
    let key: DocCellKey
    /// The table's cells, in the row's space.
    let table: CGRect
    let controller: DocTableController
    /// The cell's ring, in the table's space.
    let cell: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let line = controller.line {
                let rect = line == .column
                    ? CGRect(x: cell.minX, y: table.minY, width: cell.width, height: table.height)
                    // Out over the first and last cells' text, as the cell's ring is.
                    : CGRect(x: table.minX - Handles.ringOutset.width, y: cell.minY,
                             width: table.width + 2 * Handles.ringOutset.width, height: cell.height)
                RoundedRectangle(cornerRadius: Handles.ringRadius, style: .continuous)
                    .strokeBorder(FlooDesignTokens.ColorRole.Accent.primary, lineWidth: FlooDesignTokens.Border.focus)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
            DocTableGrip(line: .column, key: key, controller: controller)
                .position(x: cell.midX, y: table.minY)
            DocTableGrip(line: .row, key: key, controller: controller)
                .position(x: table.minX - Handles.ringOutset.width, y: cell.midY)
            if controller.isEditable {
                DocTableEdgeDot(label: String(localized: "Add Column")) { controller.appendColumn(beside: key) }
                    .position(x: table.maxX, y: cell.midY)
                DocTableEdgeDot(label: String(localized: "Add Row")) { controller.appendRow(below: key) }
                    .position(x: cell.midX, y: table.maxY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A dot on the table's edge that adds a row or a column (Craft's); it swells under the pointer.
struct DocTableEdgeDot: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(FlooDesignTokens.ColorRole.Accent.primary)
                .frame(width: Handles.dot, height: Handles.dot)
                .scaleEffect(hovering ? Handles.dotHoverScale : 1)
                .frame(width: Handles.target, height: Handles.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(FlooDesignTokens.Motion.feedbackCurve, value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The edited cell's ⋮.
struct DocTableCellMenu: View {
    let key: DocCellKey
    let controller: DocTableController

    var body: some View {
        Button {
            controller.menu == DocTableMenuTarget(key: key) ? controller.closeMenu() : controller.showMenu(key)
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: FlooDesignTokens.Icon.compact, weight: .semibold))
                .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                .frame(width: FlooDesignTokens.Space.xxl, height: FlooDesignTokens.Control.compactHeight)
        }
        .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: FlooDesignTokens.Radius.sm, style: .continuous)))
        .accessibilityLabel("Table Actions")
        .docTableMenu(DocTableMenuTarget(key: key), controller: controller)
    }
}

extension View {
    /// The table's menu (Craft's, FlooDesign's action menu) from this view while it's
    /// `target`'s: beside it, or a sheet on a phone.
    func docTableMenu(_ target: DocTableMenuTarget, controller: DocTableController) -> some View {
        flooDesignActionMenu(isPresented: controller.menu == target,
                             onDismiss: { if controller.menu == target { controller.closeMenu() } }) { presentation in
            DocTableMenuSections(target: target, controller: controller).sections(for: presentation)
        }
    }
}

/// The menu's sections, Craft's: beside the cell, Edit Table opens a panel and the rest
/// are rows; on a phone the groups are tiles and buttons, the rest rows that open more.
@MainActor
struct DocTableMenuSections {
    let target: DocTableMenuTarget
    let controller: DocTableController

    private func item(_ action: DocTableAction, symbol: Bool = true) -> FlooDesignActionMenuItem {
        .action(action.title, symbol: symbol ? action.symbol : nil, role: action.isDestructive ? .destructive : .standard,
                isEnabled: controller.isAvailable(action, at: target.key, on: target.line), id: "\(action)") { [controller, target] in
            controller.perform(action, at: target.key, on: target.line)
        }
    }

    /// Craft's Text Format: the marks, a link, the colour, on the selected text or the cell's.
    private var format: FlooDesignActionMenuItem? {
        let key = target.key
        guard target.line == nil, controller.formatRange(key) != nil else { return nil }
        let marks: [FlooDesignActionMenuItem] = (DocFormatting.marks + [("highlight", "highlighter", String(localized: "Highlight"), Mark.highlight(color: nil))]).map { item in
            .action(item.title, symbol: item.symbol, isOn: controller.formatIsOn(item.mark, at: key), id: "format-\(item.id)") { [controller] in
                controller.toggleFormat(item.mark, at: key)
            }
        }
        let link = FlooDesignActionMenuItem.action(controller.formatIsOn(.link(url: ""), at: key) ? String(localized: "Edit Link…") : String(localized: "Link…"),
                                                   symbol: "link", id: "format-link") { [controller] in controller.promptLink(at: key) }
        let current = controller.color(at: key)
        let colors = FlooDesignActionMenuItem.submenu(String(localized: "Text Color"), symbol: "paintpalette", id: "format-color", sections: [
            .init(.rows, [.action(String(localized: "Default"), isOn: current == nil, id: "color-none") { [controller] in controller.setColor(nil, at: key) }]
                + DocColors.palette.map { item in
                    .action(item.title, isOn: current == .color(item.token), id: "color-\(item.token)") { [controller] in controller.setColor(item.token, at: key) }
                }),
        ])
        return .submenu(String(localized: "Format"), symbol: "textformat", id: "format", sections: [
            .init(.rows, marks),
            .init(.rows, [link, colors]),
        ])
    }

    func sections(for presentation: FlooDesignPanelPresentation) -> [FlooDesignActionMenuSection] {
        let editTable = FlooDesignActionMenuItem.submenu(String(localized: "Edit Table"), symbol: "tablecells.badge.ellipsis", sections: [
            .init(.rows, [item(.insertRowAbove), item(.insertRowBelow), item(.insertColumnLeft), item(.insertColumnRight)]),
            .init(.rows, [item(.moveRowUp), item(.moveRowDown), item(.moveColumnLeft), item(.moveColumnRight)]),
            .init(.plain, [item(.deleteRow), item(.deleteColumn), item(.deleteTable)]),
        ])
        let clear = FlooDesignActionMenuSection(.plain, [item(.clearCell, symbol: false)])
        switch presentation {
        case .anchored:
            return [
                .init(.rows, [editTable] + (format.map { [$0] } ?? []) + [item(.insertFormula)]),
                .init(.rows, [item(.sortAscending, symbol: false), item(.sortDescending, symbol: false)]),
                .init(.rows, [item(.cut, symbol: false), item(.copy, symbol: false), item(.paste, symbol: false)]),
                clear,
            ]
        case .sheet:
            return [
                .init(.tiles, [
                    editTable,
                    .submenu(String(localized: "Sort"), symbol: "line.3.horizontal.decrease.circle", sections: [
                        .init(.rows, [item(.sortAscending), item(.sortDescending)]),
                    ]),
                ]),
                .init(.buttons, (format.map { [$0] } ?? []) + [item(.insertFormula)]),
                .init(.rows, [
                    .submenu(String(localized: "Actions"), symbol: "command", sections: [
                        .init(.rows, [item(.cut), item(.copy), item(.paste)]),
                    ]),
                ]),
                clear,
            ]
        }
    }
}

/// Scrolling the document's list to show a view. TiledView's list keeps a huge virtual
/// content area (its content insets are hugely negative), so what shows is its bounds
/// less the bars and the keyboard.
@MainActor
enum DocScrolling {
    private(set) static var keyboard: CGRect = .null
    /// The keyboard bar's height while it is up on the keyboard (DocKeyboardBar): it
    /// covers the page too.
    static var keyboardBar: CGFloat = 0
    private static var observer: NSObjectProtocol?

    /// Starts following the keyboard's frame (screen coordinates).
    static func trackKeyboard() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .null
            MainActor.assumeIsolated { keyboard = frame }
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { keyboard = .null }
        }
    }

    static func list(of view: UIView) -> UIScrollView? {
        var ancestor = view.superview
        while let next = ancestor, !(next is UICollectionView) { ancestor = next.superview }
        return ancestor as? UIScrollView
    }

    /// The part of the list on screen, in its coordinates.
    static func visible(in list: UIScrollView) -> CGRect {
        var visible = list.bounds.inset(by: UIEdgeInsets(top: list.safeAreaInsets.top, left: 0, bottom: list.safeAreaInsets.bottom, right: 0))
        if !keyboard.isNull, let window = list.window {
            let overlap = list.convert(window.convert(keyboard, from: nil), from: window)
            let top = overlap.minY - keyboardBar
            if top < visible.maxY { visible.size.height = max(0, top - visible.minY) }
        }
        return visible
    }

    /// Scrolls the least that shows `rect` of `view` (with a margin).
    static func reveal(_ view: UIView, rect: CGRect? = nil) {
        guard let list = list(of: view), view.window != nil else { return }
        let frame = view.convert(rect ?? view.bounds, to: list).insetBy(dx: 0, dy: -24)
        let visible = visible(in: list)
        let delta: CGFloat = frame.height > visible.height || frame.minY < visible.minY ? frame.minY - visible.minY
            : frame.maxY > visible.maxY ? frame.maxY - visible.maxY : 0
        guard delta != 0 else { return }
        list.setContentOffset(CGPoint(x: list.contentOffset.x, y: list.contentOffset.y + delta), animated: true)
    }
}
