//
//  DocCollection.swift
//  DemoApp
//
//  A collection block, Craft's: its name, a tab for each view of its records (a table,
//  a kanban), and the view showing. The same records in every view, edited in any:
//  - the name and the tabs: click a tab to show it; right-click it to rename, duplicate
//    or delete it; + adds a table or a kanban grouped by a select column;
//  - the table: a row number, the columns with their type's symbol, a select as its
//    coloured option, a checkbox as a box; a cell takes typing, a select picks from its
//    options; the calculation row computes a column (Calculate), + adds a record;
//  - the kanban: a column per option of the grouping select, tinted with its colour, its
//    records as cards (the title, the other fields as chips); a card drags to another
//    column or place, + adds a card to a column, the + after the columns a new option.
//  Every change is DocKit steps (a database step for the records, a setBlock for the
//  name and views), so undo, redo and sync treat it like the rest of the document.
//  Sizes are measured from Craft's (Mac, 2026-10-13 recordings).
//

import SwiftUI
import UniformTypeIdentifiers
import DocKit
import FlooDesign
import MarkdownView

struct DocCollectionSnapshot: Equatable {
    let block: DocBlockID
    let collection: DocCollection
    let database: Database
}

// MARK: - Controller

@MainActor
@Observable
final class DocCollectionController {
    @ObservationIgnored private let demo: DocDemo
    @ObservationIgnored unowned let editor: DocEditor
    /// Typing in one field is one undo step until another is edited.
    @ObservationIgnored private var session: UInt64 = 0
    @ObservationIgnored private var typing: (row: RowID, column: ColumnID)?
    /// The card whose title takes typing as it shows (one just added).
    var editingTitle: RowID?

    init(demo: DocDemo, editor: DocEditor) {
        self.demo = demo
        self.editor = editor
    }

    var isEditable: Bool { editor.isEditable }

    private func snapshot(_ block: DocBlockID) -> (collection: DocCollection, database: Database)? {
        guard case .collection(let collection)? = demo.doc.block(block)?.kind,
              let database = demo.doc.databases[collection.database] else { return nil }
        return (collection, database)
    }

    private func commit(_ block: DocBlockID, _ steps: [DocStep], merging: Bool = false) {
        guard !steps.isEmpty else { return }
        if !merging { session &+= 1 }
        _ = demo.edit(steps, before: nil, after: nil, merge: merging ? .init(block: block, session: session) : nil)
        if !merging { session &+= 1 }
    }

    private func records(_ block: DocBlockID, _ steps: [DatabaseStep], merging: Bool = false) {
        guard let (collection, _) = snapshot(block) else { return }
        commit(block, steps.map { .database(id: collection.database, step: $0) }, merging: merging)
    }

    /// The block's name and views changed: one setBlock.
    private func change(_ block: DocBlockID, _ update: (inout DocCollection) -> Void) {
        guard let existing = demo.doc.block(block), case .collection(var collection) = existing.kind else { return }
        update(&collection)
        let kind = BlockKind.collection(collection: collection)
        guard kind != existing.kind else { return }
        commit(block, [.setBlock(block: block, kind: kind, indent: existing.indent, previousKind: existing.kind, previousIndent: existing.indent)])
    }

    // MARK: Name and views

    func rename(_ block: DocBlockID, to name: String) { change(block) { $0.name = name } }

    func show(_ view: CollectionViewID, in block: DocBlockID) { change(block) { $0.current = view } }

    func addTable(to block: DocBlockID) {
        change(block) { collection in
            let view = CollectionView(name: String(localized: "Table"), layout: .table(hidden: [], sort: []))
            collection.views.append(view)
            collection.current = view.id
        }
    }

    func addKanban(to block: DocBlockID, groupedBy column: ColumnID) {
        change(block) { collection in
            let view = CollectionView(name: String(localized: "Kanban"), layout: .kanban(groupBy: column, hidden: [], sort: []))
            collection.views.append(view)
            collection.current = view.id
        }
    }

    func rename(_ view: CollectionViewID, in block: DocBlockID, to name: String) {
        change(block) { collection in
            guard let index = collection.views.firstIndex(where: { $0.id == view }), !name.isEmpty else { return }
            collection.views[index].name = name
        }
    }

    func duplicate(_ view: CollectionViewID, in block: DocBlockID) {
        change(block) { collection in
            guard let index = collection.views.firstIndex(where: { $0.id == view }) else { return }
            var copy = collection.views[index]
            copy.id = .generate()
            collection.views.insert(copy, at: index + 1)
            collection.current = copy.id
        }
    }

    func delete(_ view: CollectionViewID, in block: DocBlockID) {
        change(block) { collection in
            guard collection.views.count > 1, let index = collection.views.firstIndex(where: { $0.id == view }) else { return }
            collection.views.remove(at: index)
            if collection.current == view { collection.current = collection.views[max(0, index - 1)].id }
        }
    }

    func setCalculation(_ calculation: CollectionCalculation?, for column: ColumnID, in view: CollectionViewID, of block: DocBlockID) {
        change(block) { collection in
            guard let index = collection.views.firstIndex(where: { $0.id == view }) else { return }
            collection.views[index].calculations[column] = calculation
        }
    }

    // MARK: Records

    /// A new record at the end, or at the end of a kanban's column (its select set to the
    /// column's option); its title takes typing.
    @discardableResult
    func addRecord(to block: DocBlockID, in group: (column: ColumnID, option: OptionID?)? = nil) -> RowID? {
        guard let (_, database) = snapshot(block) else { return nil }
        var cells: [ColumnID: CellValue] = [:]
        if let group, let option = group.option { cells[group.column] = .select(option: option) }
        let row = Row(id: .generate(), cells: cells)
        let after = group.map { group in database.rows.last { Self.option(of: $0, in: group.column) == group.option }?.id } ?? database.rows.last?.id
        records(block, [.insertRow(row: row, after: after ?? database.rows.last?.id)])
        editingTitle = row.id
        return row.id
    }

    func setText(_ text: String, row: RowID, column: ColumnID, in block: DocBlockID) {
        guard let (_, database) = snapshot(block), let record = database.rows.first(where: { $0.id == row }),
              let field = database.columns.first(where: { $0.id == column }) else { return }
        let previous = record.cells[column]
        let value: CellValue? = switch field.type {
        case .number: Double(text.trimmingCharacters(in: .whitespaces)).map { .number(value: $0) } ?? (text.isEmpty ? nil : previous)
        case .url: text.isEmpty ? nil : .url(value: text)
        case .person: text.isEmpty ? nil : .person(value: text)
        default: text.isEmpty ? nil : .text(value: text)
        }
        guard value != previous else { return }
        let merging = typing.map { $0 == (row, column) } ?? false
        typing = (row, column)
        records(block, [.setCell(row: row, column: column, value: value, previous: previous)], merging: merging)
    }

    func set(_ value: CellValue?, row: RowID, column: ColumnID, in block: DocBlockID) {
        guard let (_, database) = snapshot(block), let record = database.rows.first(where: { $0.id == row }) else { return }
        let previous = record.cells[column]
        guard value != previous else { return }
        typing = nil
        records(block, [.setCell(row: row, column: column, value: value, previous: previous)])
    }

    func delete(_ row: RowID, in block: DocBlockID) {
        guard let (_, database) = snapshot(block), let index = database.rows.firstIndex(where: { $0.id == row }) else { return }
        records(block, [.deleteRow(row: database.rows[index], after: index == 0 ? nil : database.rows[index - 1].id)])
    }

    /// A card dropped in a kanban's column, before `before` (or at the column's end): its
    /// select takes the column's option, and it moves to its place among the records.
    func move(_ row: RowID, to option: OptionID?, groupedBy column: ColumnID, before: RowID?, in block: DocBlockID) {
        guard let (_, database) = snapshot(block), let record = database.rows.first(where: { $0.id == row }), row != before else { return }
        var steps: [DatabaseStep] = []
        let value: CellValue? = option.map { .select(option: $0) }
        if record.cells[column] != value {
            steps.append(.setCell(row: row, column: column, value: value, previous: record.cells[column]))
        }
        let others = database.rows.filter { $0.id != row }
        let from = database.rows.firstIndex { $0.id == row }.flatMap { $0 == 0 ? nil : database.rows[$0 - 1].id }
        let after: RowID?
        if let before, let index = others.firstIndex(where: { $0.id == before }) {
            after = index == 0 ? nil : others[index - 1].id
        } else {
            after = others.last { Self.option(of: $0, in: column) == option }?.id ?? others.last?.id
        }
        if after != from { steps.append(.moveRow(row: row, after: after, from: from)) }
        typing = nil
        records(block, steps)
    }

    /// A new option of a select column (a kanban's new column).
    func addOption(_ name: String, color: String, to column: ColumnID, in block: DocBlockID) {
        guard let (_, database) = snapshot(block), let field = database.columns.first(where: { $0.id == column }),
              case .select(var options) = field.type, !name.isEmpty else { return }
        options.append(SelectOption(id: .generate(), name: name, color: color))
        var updated = field
        updated.type = .select(options: options)
        records(block, [.updateColumn(column: updated, previous: field)])
    }

    nonisolated static func option(of row: Row, in column: ColumnID) -> OptionID? {
        if case .select(let option)? = row.cells[column] { option } else { nil }
    }
}

// MARK: - Looks

enum DocCollectionLayout {
    /// How wide a collection grows: past the page's text (720), as Craft's does.
    static let maxWidth: CGFloat = 1040
}

/// The collection's measurements (Craft's, on a Mac).
private enum Metrics {
    static let titleSize: CGFloat = 22
    static let tabSize: CGFloat = 14
    static let tabHeight: CGFloat = 26
    static let headerGap = FlooDesignTokens.Space.sm
    static let corner = FlooDesignTokens.Radius.sm
    // Table
    static let rowHeight: CGFloat = 36
    static let headHeight: CGFloat = 32
    static let numberWidth: CGFloat = 46
    static let titleWidth: CGFloat = 200
    static let fieldWidth: CGFloat = 140
    static let cellInset = FlooDesignTokens.Space.sm
    // Kanban
    static let columnWidth: CGFloat = 268
    static let columnGap: CGFloat = 13
    static let columnInset = FlooDesignTokens.Space.sm
    static let columnHead: CGFloat = 40
    static let cardGap: CGFloat = 10
    static let cardInset = FlooDesignTokens.Space.md
    static let cardCorner: CGFloat = 8
    static let chipHeight: CGFloat = 21
    static let addHeight: CGFloat = 32
}

/// An option's colour: its own, or one by its place among the column's options.
enum DocOptionColor {
    static let order = ["purple", "cyan", "yellow", "blue", "green", "red", "orange", "mint", "brown", "slate", "lemon", "gray"]

    static func token(_ option: SelectOption, in options: [SelectOption]) -> String {
        option.color ?? order[(options.firstIndex(of: option) ?? 0) % order.count]
    }

    static func color(_ token: String) -> Color { MarkdownColorToken.text(token) ?? .secondary }
}

/// A field's value as a chip: a select's option in its colour, the rest quiet.
private struct DocChip: View {
    let text: String
    var color: Color?
    var systemImage: String?

    var body: some View {
        HStack(spacing: FlooDesignTokens.Space.xs) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: FlooDesignTokens.Icon.inline, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(color ?? FlooDesignTokens.ColorRole.Content.secondary)
        .padding(.horizontal, 7)
        .frame(height: Metrics.chipHeight)
        .background((color ?? .primary).opacity(color == nil ? FlooDesignTokens.Opacity.faint : 0.18),
                    in: RoundedRectangle(cornerRadius: FlooDesignTokens.Radius.xs + 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FlooDesignTokens.Radius.xs + 1, style: .continuous)
            .strokeBorder((color ?? .primary).opacity(color == nil ? FlooDesignTokens.Opacity.faint : 0.22), lineWidth: FlooDesignTokens.Border.hairline))
    }
}

/// Chips laid out in lines, as many as fit on each.
private struct DocFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: subviews.isEmpty ? 0 : y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// What a value reads as, and its chip.
enum DocFieldText {
    static func text(_ value: CellValue?, in column: Column) -> String {
        switch value {
        case .text(let value)?, .url(let value)?, .person(let value)?: value
        case .number(let value)?: value.formatted()
        case .date(let value)?: Date(timeIntervalSince1970: TimeInterval(value.millisecondsSince1970) / 1000).formatted(day)
        case .select(let option)?: options(column).first { $0.id == option }?.name ?? ""
        case .multiSelect(let ids)?: options(column).filter { ids.contains($0.id) }.map(\.name).joined(separator: ", ")
        case .checkbox(let on)?: on ? "✓" : ""
        case nil: ""
        }
    }

    /// A day as Craft shows it ("Oct 15 2026"): dates are days at midnight UTC.
    private static let day: Date.FormatStyle = {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        style.timeZone = TimeZone(identifier: "UTC")!
        return style
    }()

    static func options(_ column: Column) -> [SelectOption] {
        switch column.type {
        case .select(let options), .multiSelect(let options): options
        default: []
        }
    }

    /// The column's type as Craft shows it in the header.
    static func symbol(_ column: Column) -> String {
        switch column.type {
        case .text: "textformat"
        case .number: "number"
        case .select: "list.bullet.indent"
        case .multiSelect: "checklist"
        case .date: "calendar"
        case .checkbox: "checkmark.square"
        case .url: "link"
        case .person: "person"
        }
    }
}

// MARK: - The block

struct DocCollectionView: View {
    let snapshot: DocCollectionSnapshot
    let controller: DocCollectionController

    private var collection: DocCollection { snapshot.collection }
    private var database: Database { snapshot.database }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.headerGap) {
            DocCollectionHeader(snapshot: snapshot, controller: controller)
            if let view = collection.currentView {
                switch view.layout {
                case .table:
                    DocCollectionTable(snapshot: snapshot, view: view, controller: controller)
                case .kanban(let group, _, _):
                    DocCollectionKanban(snapshot: snapshot, group: group, controller: controller)
                }
            }
        }
        .padding(.vertical, FlooDesignTokens.Space.sm)
    }
}

/// The name, the toolbar, and a tab for each view.
private struct DocCollectionHeader: View {
    let snapshot: DocCollectionSnapshot
    let controller: DocCollectionController
    @State private var name = ""
    @State private var renaming: CollectionViewID?
    @State private var viewName = ""

    private var collection: DocCollection { snapshot.collection }
    private var selects: [Column] {
        snapshot.database.columns.filter { if case .select = $0.type { true } else { false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlooDesignTokens.Space.sm) {
            HStack(alignment: .center) {
                TextField(String(localized: "Untitled Collection"), text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: Metrics.titleSize, weight: .bold))
                    .disabled(!controller.isEditable)
                    .onSubmit { controller.rename(snapshot.block, to: name) }
                    .onChange(of: name) { _, name in if name != collection.name { controller.rename(snapshot.block, to: name) } }
                Spacer(minLength: FlooDesignTokens.Space.md)
                if controller.isEditable {
                    Button {
                        controller.addRecord(to: snapshot.block, in: kanbanGroup)
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: FlooDesignTokens.Icon.toolbar))
                    }
                    .buttonStyle(FlooDesignPlainButtonStyle(in: Circle()))
                    .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                    .accessibilityLabel(String(localized: "New Item"))
                }
            }
            tabs
        }
        .onAppear { name = collection.name }
        .onChange(of: collection.name) { _, new in if new != name { name = new } }
    }

    /// A new card from the toolbar goes to the first column of a kanban.
    private var kanbanGroup: (column: ColumnID, option: OptionID?)? {
        guard case .kanban(let group, _, _)? = collection.currentView?.layout,
              let column = snapshot.database.columns.first(where: { $0.id == group }) else { return nil }
        return (group, DocFieldText.options(column).first?.id)
    }

    private var tabs: some View {
        HStack(spacing: FlooDesignTokens.Space.xxs) {
            ForEach(collection.views) { view in
                tab(view)
            }
            if controller.isEditable {
                Menu {
                    Button(String(localized: "Add Table View"), systemImage: "tablecells") { controller.addTable(to: snapshot.block) }
                    Menu(String(localized: "Add Kanban View")) {
                        ForEach(selects, id: \.id) { column in
                            Button(column.name) { controller.addKanban(to: snapshot.block, groupedBy: column.id) }
                        }
                    }
                    .disabled(selects.isEmpty)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: FlooDesignTokens.Icon.compact, weight: .semibold))
                        .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                        .frame(width: Metrics.tabHeight, height: Metrics.tabHeight)
                }
                .menuStyle(.button)
                .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)))
                .accessibilityLabel(String(localized: "Add View"))
            }
        }
        // A tab's words line up with the name; its fill reaches out past them (Craft's).
        .padding(.leading, -FlooDesignTokens.Space.sm)
    }

    @ViewBuilder
    private func tab(_ view: CollectionView) -> some View {
        let isCurrent = view.id == collection.currentView?.id
        if renaming == view.id {
            TextField("", text: $viewName)
                .textFieldStyle(.plain)
                .font(.system(size: Metrics.tabSize, weight: .medium))
                .fixedSize()
                .padding(.horizontal, FlooDesignTokens.Space.sm)
                .frame(height: Metrics.tabHeight)
                .background(FlooDesignTokens.ColorRole.Surface.selected, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
                .onSubmit {
                    controller.rename(view.id, in: snapshot.block, to: viewName)
                    renaming = nil
                }
        } else {
            Button {
                controller.show(view.id, in: snapshot.block)
            } label: {
                Text(view.name)
                    .font(.system(size: Metrics.tabSize, weight: .medium))
                    .foregroundStyle(isCurrent ? FlooDesignTokens.ColorRole.Content.primary : FlooDesignTokens.ColorRole.Content.secondary)
                    .padding(.horizontal, FlooDesignTokens.Space.sm)
                    .frame(height: Metrics.tabHeight)
                    .background(isCurrent ? FlooDesignTokens.ColorRole.Surface.selected : .clear,
                                in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            }
            .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)))
            .contextMenu {
                if controller.isEditable {
                    Button(String(localized: "Rename View"), systemImage: "character.cursor.ibeam") {
                        viewName = view.name
                        renaming = view.id
                    }
                    Button(String(localized: "Duplicate View"), systemImage: "plus.square.on.square") { controller.duplicate(view.id, in: snapshot.block) }
                    Button(String(localized: "Delete View"), systemImage: "trash", role: .destructive) { controller.delete(view.id, in: snapshot.block) }
                        .disabled(collection.views.count < 2)
                }
            }
        }
    }
}

// MARK: - Table

private struct DocCollectionTable: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let controller: DocCollectionController
    @State private var width: CGFloat = 0
    /// The pointer on the calculation row: its empty cells offer Calculate (Craft's).
    @State private var overFoot = false

    private var columns: [Column] {
        guard case .table(let hidden, _) = view.layout else { return snapshot.database.columns }
        return snapshot.database.columns.filter { !hidden.contains($0.id) }
    }

    private var rows: [Row] {
        guard case .table(_, let sort) = view.layout, !sort.isEmpty else { return snapshot.database.rows }
        return DocCollectionSorting.sorted(snapshot.database.rows, by: sort, in: snapshot.database)
    }

    /// Each column's width: the title wider, the rest alike, stretched to fill the block
    /// when there's room; past it the table scrolls sideways.
    private func widths() -> [CGFloat] {
        let natural = columns.enumerated().map { index, _ in index == 0 ? Metrics.titleWidth : Metrics.fieldWidth }
        let total = natural.reduce(Metrics.numberWidth, +)
        guard width > total, total > 0 else { return natural }
        let scale = (width - Metrics.numberWidth) / (total - Metrics.numberWidth)
        return natural.map { $0 * scale }
    }

    var body: some View {
        let widths = widths()
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                head(widths)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Divider().overlay(FlooDesignTokens.Border.subtle)
                    record(row, number: index + 1, widths: widths)
                }
                Divider().overlay(FlooDesignTokens.Border.subtle)
                foot(widths)
            }
            .fixedSize(horizontal: true, vertical: false)
            .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(FlooDesignTokens.Border.subtle, lineWidth: FlooDesignTokens.Border.standard))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func head(_ widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "number")
                .font(.system(size: FlooDesignTokens.Icon.compact))
                .foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
                .frame(width: Metrics.numberWidth)
            ForEach(Array(zip(columns, widths)), id: \.0.id) { column, width in
                separator
                Label(column.name, systemImage: DocFieldText.symbol(column))
                    .labelStyle(DocHeadLabelStyle())
                    .padding(.horizontal, Metrics.cellInset)
                    .frame(width: width, alignment: .leading)
            }
        }
        .frame(height: Metrics.headHeight)
        .background(FlooDesignTokens.ColorRole.Surface.decoration)
    }

    private func record(_ row: Row, number: Int, widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            Text("\(number)")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
                .frame(width: Metrics.numberWidth)
            ForEach(Array(zip(columns, widths)), id: \.0.id) { column, width in
                separator
                DocCollectionCell(block: snapshot.block, row: row, column: column, controller: controller)
                    .padding(.horizontal, Metrics.cellInset)
                    .frame(width: width, alignment: column.type == .number ? .trailing : .leading)
            }
        }
        .frame(minHeight: Metrics.rowHeight)
        .contextMenu {
            if controller.isEditable {
                Button(String(localized: "Delete Row"), systemImage: "trash", role: .destructive) { controller.delete(row.id, in: snapshot.block) }
            }
        }
    }

    /// The calculation row, with + for a new record under the row numbers.
    private func foot(_ widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            Button {
                controller.addRecord(to: snapshot.block)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: FlooDesignTokens.Icon.compact, weight: .medium))
                    .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                    .frame(width: Metrics.numberWidth, height: Metrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!controller.isEditable)
            .accessibilityLabel(String(localized: "Add Row"))
            if view.showsCalculations {
                ForEach(Array(zip(columns, widths)), id: \.0.id) { column, width in
                    DocCalculationCell(snapshot: snapshot, view: view, column: column, controller: controller,
                                       offers: overFoot || !FlooDesignTokens.Platform.isPointer)
                        .padding(.horizontal, Metrics.cellInset)
                        .frame(width: width, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Metrics.rowHeight)
        .onHover { overFoot = $0 }
    }

    private var separator: some View {
        Rectangle().fill(FlooDesignTokens.Border.subtle).frame(width: FlooDesignTokens.Border.standard)
    }
}

private struct DocHeadLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: FlooDesignTokens.Space.xs + 2) {
            configuration.icon.font(.system(size: FlooDesignTokens.Icon.compact)).foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
            configuration.title.font(.system(size: 13, weight: .medium)).foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary).lineLimit(1)
        }
    }
}

/// One field of one record in the table.
private struct DocCollectionCell: View {
    let block: DocBlockID
    let row: Row
    let column: Column
    let controller: DocCollectionController
    @State private var text = ""
    @State private var picking = false

    private var value: CellValue? { row.cells[column.id] }

    /// A date cell's day as a date to pick (days are midnight UTC).
    private var day: Binding<Date> {
        Binding {
            if case .date(let value)? = value { return Date(timeIntervalSince1970: TimeInterval(value.millisecondsSince1970) / 1000) }
            return .now
        } set: { date in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
            guard let midnight = calendar.date(from: parts) else { return }
            controller.set(.date(value: Timestamp(millisecondsSince1970: Int64(midnight.timeIntervalSince1970 * 1000))),
                           row: row.id, column: column.id, in: block)
        }
    }

    var body: some View {
        switch column.type {
        case .select(let options):
            Menu {
                ForEach(options, id: \.id) { option in
                    Button {
                        controller.set(.select(option: option.id), row: row.id, column: column.id, in: block)
                    } label: {
                        if DocCollectionController.option(of: row, in: column.id) == option.id { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                    }
                }
                if value != nil {
                    Divider()
                    Button(String(localized: "Clear"), role: .destructive) { controller.set(nil, row: row.id, column: column.id, in: block) }
                }
            } label: {
                HStack {
                    if case .select(let id)? = value, let option = options.first(where: { $0.id == id }) {
                        DocChip(text: option.name, color: DocOptionColor.color(DocOptionColor.token(option, in: options)))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .disabled(!controller.isEditable)
        case .multiSelect(let options):
            DocFlow {
                ForEach(options.filter { if case .multiSelect(let ids)? = value { ids.contains($0.id) } else { false } }, id: \.id) { option in
                    DocChip(text: option.name, color: DocOptionColor.color(DocOptionColor.token(option, in: options)))
                }
            }
        case .checkbox:
            let on = value == .checkbox(value: true)
            Button {
                controller.set(on ? nil : .checkbox(value: true), row: row.id, column: column.id, in: block)
            } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: FlooDesignTokens.Icon.standard))
                    .foregroundStyle(on ? FlooDesignTokens.ColorRole.Content.primary : FlooDesignTokens.ColorRole.Content.tertiary)
                    .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight)
            }
            .buttonStyle(.plain)
            .disabled(!controller.isEditable)
        case .date:
            Button {
                picking = true
            } label: {
                Text(DocFieldText.text(value, in: column))
                    .font(.system(size: 14))
                    .foregroundStyle(FlooDesignTokens.ColorRole.Content.primary)
                    .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!controller.isEditable)
            .popover(isPresented: $picking) {
                VStack(spacing: FlooDesignTokens.Space.sm) {
                    DatePicker("", selection: day, displayedComponents: [.date])
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                    if value != nil {
                        Button(String(localized: "Clear")) {
                            controller.set(nil, row: row.id, column: column.id, in: block)
                            picking = false
                        }
                        .buttonStyle(FlooDesignButtonStyle(.secondary))
                    }
                }
                .padding(FlooDesignTokens.Component.FloatingPanel.roomyInset)
            }
        default:
            // One line, as Craft's cells are: a longer text runs on out of sight.
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1)
                .multilineTextAlignment(column.type == .number ? .trailing : .leading)
                .frame(minHeight: Metrics.rowHeight)
                .disabled(!controller.isEditable)
                .onAppear { text = DocFieldText.text(value, in: column) }
                .onChange(of: value) { _, value in
                    let shown = DocFieldText.text(value, in: column)
                    if shown != text, column.type != .number || Double(text) != value.flatMap({ if case .number(let n) = $0 { n } else { nil } }) { text = shown }
                }
                .onChange(of: text) { _, text in
                    if text != DocFieldText.text(value, in: column) { controller.setText(text, row: row.id, column: column.id, in: block) }
                }
        }
    }
}

/// A column's cell in the calculation row: Calculate, or what it computes.
private struct DocCalculationCell: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let column: Column
    let controller: DocCollectionController
    /// Whether an empty cell shows Calculate.
    let offers: Bool

    private var calculation: CollectionCalculation? { view.calculations[column.id] }

    var body: some View {
        Menu {
            ForEach(DocCollectionMath.available(for: column), id: \.self) { calculation in
                Button(DocCollectionMath.title(calculation)) {
                    controller.setCalculation(calculation, for: column.id, in: view.id, of: snapshot.block)
                }
            }
            if calculation != nil {
                Divider()
                Button(String(localized: "None")) { controller.setCalculation(nil, for: column.id, in: view.id, of: snapshot.block) }
            }
        } label: {
            HStack(spacing: FlooDesignTokens.Space.xs) {
                Spacer(minLength: 0)
                if let calculation {
                    Text(DocCollectionMath.label(calculation))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
                    Text(DocCollectionMath.value(calculation, of: column, in: snapshot.database.rows))
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                } else {
                    Text(String(localized: "Calculate"))
                        .font(.system(size: 12))
                        .foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
                        .opacity(controller.isEditable && offers ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(!controller.isEditable)
    }
}

/// What a calculation row computes.
enum DocCollectionMath {
    static func available(for column: Column) -> [CollectionCalculation] {
        column.type == .number ? CollectionCalculation.allCases : [.count, .countEmpty, .countFilled]
    }

    static func title(_ calculation: CollectionCalculation) -> String {
        switch calculation {
        case .count: String(localized: "Count All")
        case .countEmpty: String(localized: "Count Empty")
        case .countFilled: String(localized: "Count Filled")
        case .sum: String(localized: "Sum")
        case .average: String(localized: "Average")
        case .median: String(localized: "Median")
        case .min: String(localized: "Min")
        case .max: String(localized: "Max")
        case .range: String(localized: "Range")
        }
    }

    static func label(_ calculation: CollectionCalculation) -> String {
        switch calculation {
        case .count: "COUNT"
        case .countEmpty: "EMPTY"
        case .countFilled: "FILLED"
        case .sum: "SUM"
        case .average: "AVG"
        case .median: "MEDIAN"
        case .min: "MIN"
        case .max: "MAX"
        case .range: "RANGE"
        }
    }

    static func value(_ calculation: CollectionCalculation, of column: Column, in rows: [Row]) -> String {
        let numbers = rows.compactMap { if case .number(let value)? = $0.cells[column.id] { value } else { nil } }.sorted()
        let filled = rows.filter { $0.cells[column.id] != nil }.count
        let result: Double? = switch calculation {
        case .count: Double(rows.count)
        case .countEmpty: Double(rows.count - filled)
        case .countFilled: Double(filled)
        case .sum: numbers.reduce(0, +)
        case .average: numbers.isEmpty ? nil : numbers.reduce(0, +) / Double(numbers.count)
        case .median: numbers.isEmpty ? nil : numbers.count % 2 == 1 ? numbers[numbers.count / 2] : (numbers[numbers.count / 2 - 1] + numbers[numbers.count / 2]) / 2
        case .min: numbers.first
        case .max: numbers.last
        case .range: numbers.last.flatMap { last in numbers.first.map { last - $0 } }
        }
        return result.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "–"
    }
}

/// A view's sorting: by each sort column in turn, empties last.
enum DocCollectionSorting {
    static func sorted(_ rows: [Row], by sort: [DatabaseSort], in database: Database) -> [Row] {
        rows.sorted { a, b in
            for entry in sort {
                guard let column = database.columns.first(where: { $0.id == entry.column }) else { continue }
                let x = key(a.cells[entry.column], column), y = key(b.cells[entry.column], column)
                if x == y { continue }
                guard let x else { return false }
                guard let y else { return true }
                return entry.ascending ? x < y : x > y
            }
            return false
        }
    }

    private static func key(_ value: CellValue?, _ column: Column) -> String? {
        switch value {
        case .number(let number)?: String(format: "%020.6f", number + 1e12)
        case .date(let date)?: String(format: "%020lld", date.millisecondsSince1970)
        case .select(let option)?: DocFieldText.options(column).firstIndex { $0.id == option }.map { String(format: "%05d", $0) }
        case nil: nil
        default: DocFieldText.text(value, in: column).lowercased()
        }
    }
}

// MARK: - Kanban

private struct DocCollectionKanban: View {
    let snapshot: DocCollectionSnapshot
    let group: ColumnID
    let controller: DocCollectionController
    @State private var addingGroup = false

    private var column: Column? { snapshot.database.columns.first { $0.id == group } }
    private var options: [SelectOption] { column.map(DocFieldText.options) ?? [] }
    /// The column the records are titled by: the first text one.
    private var titleColumn: Column? { snapshot.database.columns.first { $0.type == .text } }

    private func records(_ option: OptionID?) -> [Row] {
        snapshot.database.rows.filter { row in
            let value = DocCollectionController.option(of: row, in: group)
            return option == nil ? (value == nil || !options.contains { $0.id == value }) : value == option
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Metrics.columnGap) {
                // Records with no option in a column of their own, first, when there are any.
                if !records(nil).isEmpty {
                    lane(nil)
                }
                ForEach(options, id: \.id) { option in
                    lane(option)
                }
                if controller.isEditable {
                    Button {
                        addingGroup = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: FlooDesignTokens.Icon.compact, weight: .medium))
                            .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                            .frame(width: Metrics.columnHead, height: Metrics.columnHead)
                    }
                    .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)))
                    .accessibilityLabel(String(localized: "Add New Group"))
                    .popover(isPresented: $addingGroup) {
                        DocNewGroupForm(column: column?.name ?? "") { name, color in
                            controller.addOption(name, color: color, to: group, in: snapshot.block)
                            addingGroup = false
                        } cancel: {
                            addingGroup = false
                        }
                    }
                }
            }
        }
    }

    private func lane(_ option: SelectOption?) -> some View {
        DocKanbanLane(snapshot: snapshot, group: group, option: option, options: options, records: records(option?.id),
                      titleColumn: titleColumn, controller: controller)
    }
}

/// One column of a kanban: its option and how many, its cards, + for a new card.
private struct DocKanbanLane: View {
    let snapshot: DocCollectionSnapshot
    let group: ColumnID
    let option: SelectOption?
    let options: [SelectOption]
    let records: [Row]
    let titleColumn: Column?
    let controller: DocCollectionController
    @State private var hovering = false
    @State private var targeted = false

    private var tint: Color {
        option.map { DocOptionColor.color(DocOptionColor.token($0, in: options)) } ?? .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardGap) {
            HStack(spacing: FlooDesignTokens.Space.sm) {
                if let option {
                    DocChip(text: option.name, color: tint)
                } else {
                    DocChip(text: String(localized: "No Value"))
                }
                Text("\(records.count)")
                    .font(.system(size: 14))
                    .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                Spacer(minLength: 0)
                if controller.isEditable {
                    Button {
                        controller.addRecord(to: snapshot.block, in: (group, option?.id))
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: FlooDesignTokens.Icon.compact, weight: .medium))
                            .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: FlooDesignTokens.Radius.xs, style: .continuous)))
                    .opacity(hovering || !FlooDesignTokens.Platform.isPointer ? 1 : 0)
                    .accessibilityLabel(String(localized: "New Item"))
                }
            }
            .frame(height: Metrics.columnHead - Metrics.columnInset)
            ForEach(records, id: \.id) { row in
                DocKanbanCard(snapshot: snapshot, row: row, group: group, titleColumn: titleColumn, controller: controller)
                    .draggable(row.id.description)
                    .dropDestination(for: String.self) { items, _ in
                        drop(items, before: row.id)
                    }
            }
            if controller.isEditable {
                Button {
                    controller.addRecord(to: snapshot.block, in: (group, option?.id))
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: FlooDesignTokens.Icon.compact, weight: .medium))
                        .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.addHeight)
                        .overlay(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                            .strokeBorder(FlooDesignTokens.Border.subtle, lineWidth: FlooDesignTokens.Border.standard))
                        .contentShape(Rectangle())
                }
                .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)))
                .accessibilityLabel(String(localized: "New Item"))
            }
        }
        .padding(Metrics.columnInset)
        .frame(width: Metrics.columnWidth, alignment: .topLeading)
        .background(tint.opacity(targeted ? 0.2 : 0.1), in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { items, _ in
            drop(items, before: nil)
        } isTargeted: { targeted = $0 }
    }

    private func drop(_ items: [String], before: RowID?) -> Bool {
        guard let item = items.first, let row = snapshot.database.rows.first(where: { $0.id.description == item }) else { return false }
        controller.move(row.id, to: option?.id, groupedBy: group, before: before, in: snapshot.block)
        return true
    }
}

/// A record as a card: its title (typed in place), then its other fields as chips.
private struct DocKanbanCard: View {
    let snapshot: DocCollectionSnapshot
    let row: Row
    let group: ColumnID
    let titleColumn: Column?
    let controller: DocCollectionController
    @State private var title = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    private var fields: [Column] {
        snapshot.database.columns.filter { $0.id != titleColumn?.id && row.cells[$0.id] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlooDesignTokens.Space.sm) {
            titleView
            if !fields.isEmpty {
                DocFlow {
                    ForEach(fields, id: \.id) { column in
                        chip(column)
                    }
                }
            }
        }
        .padding(Metrics.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlooDesignTokens.ColorRole.Surface.canvas, in: RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
            .strokeBorder(editing ? Color.accentColor : FlooDesignTokens.Border.subtle, lineWidth: editing ? 2 : FlooDesignTokens.Border.standard))
        .contextMenu {
            if controller.isEditable {
                Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) { controller.delete(row.id, in: snapshot.block) }
            }
        }
        .onAppear {
            title = titleColumn.map { DocFieldText.text(row.cells[$0.id], in: $0) } ?? ""
            if controller.editingTitle == row.id { startEditing() }
        }
        .onChange(of: row) { _, row in
            let shown = titleColumn.map { DocFieldText.text(row.cells[$0.id], in: $0) } ?? ""
            if !editing, shown != title { title = shown }
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if editing, let titleColumn {
            TextField(String(localized: "Title"), text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .focused($focused)
                .onChange(of: title) { _, title in controller.setText(title, row: row.id, column: titleColumn.id, in: snapshot.block) }
                .onChange(of: focused) { _, focused in if !focused { editing = false } }
                .onSubmit { focused = false }
        } else {
            Text(title.isEmpty ? String(localized: "Title") : title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(title.isEmpty ? FlooDesignTokens.ColorRole.Content.tertiary : FlooDesignTokens.ColorRole.Content.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if controller.isEditable, titleColumn != nil { startEditing() } }
        }
    }

    private func startEditing() {
        editing = true
        if controller.editingTitle == row.id { controller.editingTitle = nil }
        Task { @MainActor in focused = true }
    }

    @ViewBuilder
    private func chip(_ column: Column) -> some View {
        let value = row.cells[column.id]
        switch (column.type, value) {
        case (.select(let options), .select(let id)?):
            if let option = options.first(where: { $0.id == id }) {
                DocChip(text: option.name, color: DocOptionColor.color(DocOptionColor.token(option, in: options)))
            }
        case (.multiSelect(let options), .multiSelect(let ids)?):
            ForEach(options.filter { ids.contains($0.id) }, id: \.id) { option in
                DocChip(text: option.name, color: DocOptionColor.color(DocOptionColor.token(option, in: options)))
            }
        case (.checkbox, .checkbox(let on)?):
            DocChip(text: column.name, systemImage: on ? "checkmark.square.fill" : "square")
        default:
            DocChip(text: DocFieldText.text(value, in: column))
        }
    }
}

/// Craft's Add Option: a name and a colour for a kanban's new column.
private struct DocNewGroupForm: View {
    let column: String
    let add: (String, String) -> Void
    let cancel: () -> Void
    @State private var name = ""
    @State private var color = DocOptionColor.order[0]

    var body: some View {
        VStack(alignment: .leading, spacing: FlooDesignTokens.Space.md) {
            Text(String(localized: "Add Option to \(column)"))
                .font(FlooDesignTokens.Typography.panelTitle.font)
            TextField(String(localized: "Name"), text: $name)
                .textFieldStyle(FlooDesignTextFieldStyle())
                .onSubmit { add(name, color) }
            HStack(spacing: FlooDesignTokens.Space.xs + 2) {
                ForEach(DocOptionColor.order, id: \.self) { token in
                    Button {
                        color = token
                    } label: {
                        Circle()
                            .fill(DocOptionColor.color(token))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(FlooDesignTokens.ColorRole.Content.primary, lineWidth: color == token ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(token)
                }
            }
            HStack {
                Button(String(localized: "Cancel"), action: cancel)
                    .buttonStyle(FlooDesignButtonStyle(.secondary))
                Button(String(localized: "Add")) { add(name, color) }
                    .buttonStyle(FlooDesignButtonStyle(.primary))
                    .disabled(name.isEmpty)
            }
        }
        .padding(FlooDesignTokens.Component.FloatingPanel.roomyInset)
        .frame(width: 280)
    }
}
