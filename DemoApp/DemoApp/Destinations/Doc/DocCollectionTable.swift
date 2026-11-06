//
//  DocCollectionTable.swift
//  DemoApp
//
//  A collection's table view (Craft's): a row number, the view's fields in its order with
//  their type's symbol, a select as its coloured option, a checkbox as a box.
//  - a field's header opens its menu: edit it (name and type), sort or filter by it, hide
//    it, delete it; + after the last adds a field;
//  - a cell takes typing (outlined while it does); a select or multi-select opens its
//    options, a date a calendar;
//  - over a row its number turns into a box that picks it (picked rows copy or delete
//    together), and the title shows an arrow that opens the record whole;
//  - a row's right-click menu (Craft's) opens it, adds a row above or below, clears the
//    cell clicked, copies or deletes it;
//  - grouped (Group By), the records go under a head for each group (its name, how many),
//    which folds them away;
//  - the calculation row computes a column (Calculate on the pointer over it), + adds a record.
//

import FlooUIKit
import SwiftUI
import UIKit
import DocKit
import FlooDesign

private typealias Metrics = DocCollectionMetrics

struct DocCollectionTable: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let controller: DocCollectionController
    @State private var width: CGFloat = 0
    /// The pointer on the calculation row: its empty cells offer Calculate (Craft's).
    @State private var overFoot = false
    @State private var hoveredRow: RowID?
    /// The groups folded away, by key.
    @State private var folded: Set<String> = []

    private var block: DocBlockID { snapshot.block }
    private var columns: [Column] { DocCollectionController.fields(view, of: snapshot.database) }
    private var titleColumn: Column? { DocCollectionController.titleColumn(of: snapshot.database) }
    private var picked: Set<RowID> { controller.selectedRows[block] ?? [] }
    private var trailing: CGFloat { controller.isEditable ? Metrics.addFieldWidth : 0 }

    /// Each column as wide as its widest cell or its header on one line, up to a cap past
    /// which its cells wrap (a plain table's columns, MarkdownTable); stretched to fill the
    /// block when there's room, past it the table scrolls sideways.
    private func widths(_ rows: [Row]) -> [CGFloat] {
        let natural = columns.map { column in
            let isTitle = column.id == titleColumn?.id
            let widest = rows.map { DocCollectionWidths.cell($0.cells[column.id], in: column, isTitle: isTitle) }.max() ?? 0
            return min(max(widest, DocCollectionWidths.head(column), Metrics.minFieldWidth), Metrics.maxFieldWidth)
        }
        let fixed = Metrics.numberWidth + trailing
        let total = natural.reduce(0, +)
        guard width > total + fixed, total > 0 else { return natural }
        let excess = width - fixed - total
        return natural.map { $0 + excess * $0 / total }
    }

    var body: some View {
        let rows = controller.rows(snapshot, view)
        let widths = widths(rows)
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                head(widths)
                if let groups = view.groups(of: rows, in: snapshot.database), let column = groupColumn {
                    ForEach(groups, id: \.key) { group in
                        FlooDividerLine()
                        groupHead(group, column: column)
                        if !folded.contains(group.key) {
                            ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                                FlooDividerLine()
                                record(row, number: index + 1, widths: widths)
                            }
                        }
                    }
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        FlooDividerLine()
                        record(row, number: index + 1, widths: widths)
                    }
                }
                FlooDividerLine()
                foot(widths, rows: rows)
            }
            .fixedSize(horizontal: true, vertical: false)
            .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(DocTokens.Border.separator, lineWidth: DocTokens.Border.hairline))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    // MARK: Header

    private func head(_ widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "number")
                .font(.system(size: DocTokens.Icon.compact))
                .foregroundStyle(DocTokens.ColorRole.Content.tertiary)
                .frame(width: Metrics.numberWidth)
            ForEach(Array(zip(columns, widths)), id: \.0.id) { column, width in
                separator
                DocFieldHead(snapshot: snapshot, view: view, column: column, controller: controller)
                    .frame(width: width)
            }
            if controller.isEditable {
                separator
                addField
            }
        }
        .frame(height: Metrics.headHeight)
        .background(DocTokens.ColorRole.Surface.decoration)
    }

    private var addField: some View {
        Button {
            controller.show(.addField, in: block)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: DocTokens.Icon.compact, weight: .medium))
                .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                .frame(width: Metrics.addFieldWidth - DocTokens.Border.hairline, height: Metrics.headHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.flooContent(in: Rectangle()))
        .help(String(localized: "Add Field"))
        .accessibilityLabel(String(localized: "Add Field"))
        .docPanel(isPresented: controller.isShowing(.addField, in: block), alignment: .trailing,
                                 onDismiss: { controller.close(.addField, in: block) }) {
            DocFieldPanel(snapshot: snapshot, column: nil, controller: controller)
        }
    }

    // MARK: Groups

    private var groupColumn: Column? { snapshot.database.columns.first { $0.id == view.layout.groupBy } }

    /// A group's head (Craft's): a chevron under the row numbers that folds it, its name
    /// and how many.
    private func groupHead(_ group: CollectionGroup, column: Column) -> some View {
        let isFolded = folded.contains(group.key)
        return Button {
            // The block takes its new height as rows added or gone change it: at once.
            if isFolded { folded.remove(group.key) } else { folded.insert(group.key) }
        } label: {
            HStack(spacing: 0) {
                Image(systemName: "chevron.down")
                    .font(.system(size: DocTokens.Icon.inline, weight: .semibold))
                    .foregroundStyle(DocTokens.ColorRole.Content.tertiary)
                    .rotationEffect(.degrees(isFolded ? -90 : 0))
                    .frame(width: Metrics.numberWidth)
                HStack(spacing: DocTokens.Space.sm) {
                    DocGroupLabel(column: column, group: group)
                    Text("\(group.rows.count)")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                }
                .padding(.horizontal, Metrics.cellInset)
                Spacer(minLength: 0)
            }
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(DocGroupLabel.title(group.value, in: column))
        .accessibilityValue(isFolded ? String(localized: "Collapsed") : String(localized: "Expanded"))
    }

    // MARK: Records

    private func record(_ row: Row, number: Int, widths: [CGFloat]) -> some View {
        let isPicked = picked.contains(row.id)
        let isHovered = hoveredRow == row.id
        // Top-aligned, a wrapped cell as tall as it reads; the row as tall as its tallest.
        return HStack(alignment: .top, spacing: 0) {
            numberCell(row, number: number, isHovered: isHovered, isPicked: isPicked)
            ForEach(Array(zip(columns, widths)), id: \.0.id) { column, width in
                separator
                let place = DocCollectionCell.place(row: row, column: column, in: block) { menu(row, cell: column) }
                DocCollectionCell(snapshot: snapshot, row: row, column: column, controller: controller,
                                  isTitle: column.id == titleColumn?.id, rowHovered: isHovered, place: place)
                    .padding(.horizontal, Metrics.cellInset)
                    .frame(width: width, alignment: column.type == .number ? .trailing : .leading)
                    .flooDesignContextMenu(isEnabled: controller.isEditable) { _ in place.menu?.rows?() ?? [] }
            }
            if controller.isEditable {
                separator
                Color.clear.frame(width: Metrics.addFieldWidth - DocTokens.Border.hairline)
            }
        }
        .frame(minHeight: Metrics.rowHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(isPicked ? DocTokens.ColorRole.Surface.selected : .clear)
        .onHover { over in
            if over { hoveredRow = row.id } else if hoveredRow == row.id { hoveredRow = nil }
        }
        .flooDesignContextMenu(isEnabled: controller.isEditable) { _ in menu(row, cell: nil) }
    }

    /// A record's right-click menu (Craft's): open it, a new row above or below, clear the
    /// cell clicked, copy or delete it. On a picked row: copy or delete the picked rows.
    private func menu(_ row: Row, cell column: Column?) -> [FlooDesignActionMenuSection] {
        let rows = picked.contains(row.id) ? picked : [row.id]
        let copyAndDelete = FlooDesignActionMenuSection(.rows, [
            .action(rows.count > 1 ? String(localized: "Duplicate \(rows.count) Rows") : String(localized: "Duplicate Row"),
                    symbol: "plus.square.on.square") { controller.duplicate(rows: rows, in: block) },
            .action(rows.count > 1 ? String(localized: "Delete \(rows.count) Rows") : String(localized: "Delete Row"),
                    symbol: "trash", role: .destructive) { controller.delete(rows: rows, in: block) },
        ])
        guard !picked.contains(row.id) else { return [copyAndDelete] }
        var sections: [FlooDesignActionMenuSection] = []
        if let open = controller.openRecord {
            sections.append(.init(.rows, [.action(String(localized: "Open"), symbol: "arrow.right.circle") { open(row.id, block) }]))
        }
        sections.append(.init(.rows, [
            .action(String(localized: "Insert Row Above"), symbol: "arrow.up.to.line") {
                controller.insertRecord(beside: row.id, below: false, groupedBy: view.layout.groupBy, in: block)
            },
            .action(String(localized: "Insert Row Below"), symbol: "arrow.down.to.line") {
                controller.insertRecord(beside: row.id, below: true, groupedBy: view.layout.groupBy, in: block)
            },
        ]))
        if let column {
            sections.append(.init(.rows, [
                .action(String(localized: "Clear Cell Contents"), symbol: "eraser", isEnabled: row.cells[column.id] != nil) {
                    controller.set(nil, row: row.id, column: column.id, in: block)
                },
            ]))
        }
        sections.append(copyAndDelete)
        return sections
    }

    /// The row's number; over the row (or with rows picked) the box that picks it.
    @ViewBuilder
    private func numberCell(_ row: Row, number: Int, isHovered: Bool, isPicked: Bool) -> some View {
        let picking = controller.isEditable && (isHovered || !picked.isEmpty || !DocTokens.Platform.isPointer && isPicked)
        if picking {
            Button {
                controller.togglePicked(row.id, in: block)
            } label: {
                Image(systemName: isPicked ? "checkmark.square.fill" : "square")
                    .font(.system(size: DocTokens.Icon.standard))
                    .foregroundStyle(isPicked ? DocTokens.ColorRole.Content.primary : DocTokens.ColorRole.Content.tertiary)
                    .frame(width: Metrics.numberWidth, height: Metrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Select Row"))
        } else {
            Text("\(number)")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(DocTokens.ColorRole.Content.tertiary)
                .frame(width: Metrics.numberWidth, height: Metrics.rowHeight)
                .contentShape(Rectangle())
                .onTapGesture { if controller.isEditable { controller.togglePicked(row.id, in: block) } }
        }
    }

    /// The calculation row, with + for a new record under the row numbers.
    private func foot(_ widths: [CGFloat], rows: [Row]) -> some View {
        HStack(spacing: 0) {
            Button {
                controller.addRecord(to: block)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: DocTokens.Icon.compact, weight: .medium))
                    .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                    .frame(width: Metrics.numberWidth, height: Metrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!controller.isEditable)
            .help(String(localized: "Add Row"))
            .accessibilityLabel(String(localized: "Add Row"))
            if view.showsCalculations {
                ForEach(Array(zip(columns, widths)), id: \.0.id) { column, width in
                    DocCalculationCell(snapshot: snapshot, view: view, column: column, rows: rows, controller: controller,
                                       offers: overFoot || !DocTokens.Platform.isPointer)
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
        FlooDividerLine(.vertical)
    }
}

/// A field's header: its symbol and name, and on the pointer over it a chevron; it opens the
/// field's menu.
private struct DocFieldHead: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let column: Column
    let controller: DocCollectionController
    @State private var hovering = false

    private var block: DocBlockID { snapshot.block }

    var body: some View {
        Menu {
            if controller.isEditable {
                Button(String(localized: "Edit Field"), systemImage: "pencil") { controller.show(.editField(column.id), in: block) }
                Divider()
            }
            Button(String(localized: "Sort Ascending"), systemImage: "arrow.up") {
                controller.setSort([DatabaseSort(column: column.id, ascending: true)], in: view.id, of: block)
            }
            Button(String(localized: "Sort Descending"), systemImage: "arrow.down") {
                controller.setSort([DatabaseSort(column: column.id, ascending: false)], in: view.id, of: block)
            }
            Button(String(localized: "Filter"), systemImage: "line.3.horizontal.decrease") {
                let condition = CollectionFilter.conditions(for: column.type)[0]
                controller.setFilters(view.filters + [CollectionFilter(column: column.id, condition: condition)], in: view.id, of: block)
                controller.show(.filter, in: block)
            }
            if column.id != DocCollectionController.titleColumn(of: snapshot.database)?.id {
                Menu(String(localized: "Group by this Field"), systemImage: "rectangle.3.group") {
                    ForEach(DocGroupPanel.orders(manual: false), id: \.self) { order in
                        Button(DocGroupPanel.name(order, of: column)) {
                            controller.setGroup(column.id, in: view.id, of: block)
                            controller.setGrouping(CollectionGrouping(order: order), in: view.id, of: block)
                        }
                    }
                }
            }
            if controller.isEditable {
                Divider()
                Button(String(localized: "Hide Field"), systemImage: "eye.slash") { controller.setHidden(column.id, true, in: view.id, of: block) }
                    .disabled(column.id == DocCollectionController.titleColumn(of: snapshot.database)?.id)
                Button(String(localized: "Delete Field"), systemImage: "trash", role: .destructive) { controller.deleteField(column.id, in: block) }
                    .disabled(snapshot.database.columns.count < 2)
            }
        } label: {
            HStack(spacing: DocTokens.Space.xs + 2) {
                Image(systemName: DocFieldText.symbol(column))
                    .font(.system(size: DocTokens.Icon.compact))
                    .foregroundStyle(DocTokens.ColorRole.Content.tertiary)
                Text(column.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                    .lineLimit(1)
                if let sort = view.layout.sort.first(where: { $0.column == column.id }) {
                    Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: DocTokens.Icon.inline, weight: .semibold))
                        .foregroundStyle(DocTokens.ColorRole.Content.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: DocTokens.Icon.inline, weight: .semibold))
                    .foregroundStyle(DocTokens.ColorRole.Content.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Metrics.cellInset)
            .frame(maxWidth: .infinity, minHeight: Metrics.headHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.flooContent(in: Rectangle()))
        .onHover { hovering = $0 }
        .docPanel(isPresented: controller.isShowing(.editField(column.id), in: block),
                                 onDismiss: { controller.close(.editField(column.id), in: block) }) {
            DocFieldPanel(snapshot: snapshot, column: column, controller: controller)
        }
    }
}

/// One field of one record: in the table, and in a record's panel (`compact`, where a
/// select picks from a menu, as the panel can't open another).
struct DocCollectionCell: View {
    let snapshot: DocCollectionSnapshot
    let row: Row
    let column: Column
    let controller: DocCollectionController
    var isTitle = false
    var rowHovered = false
    var compact = false
    /// The field as a place (its right-click's menu; the keyboard bar's keys), in the table.
    var place: DocFieldPlace?
    @State private var text = ""
    @FocusState private var focused: Bool

    /// A record's cell in the table, its menu the record's right-click rows.
    static func place(row: Row, column: Column, in block: DocBlockID, menu: @escaping () -> [FlooDesignActionMenuSection]) -> DocFieldPlace {
        DocFieldPlace(field: [block, row.id, column.id] as [AnyHashable], block: block,
                      menu: DocPlaceMenu(title: String(localized: "Row Actions"), symbol: "tablecells.badge.ellipsis", opens: .rows(menu)))
    }

    private var block: DocBlockID { snapshot.block }
    private var value: CellValue? { row.cells[column.id] }

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: column.type == .number && !compact ? .trailing : .leading)
            .overlay {
                // The cell taking typing, outlined (Craft's).
                if focused {
                    RoundedRectangle(cornerRadius: DocTokens.Radius.xs, style: .continuous)
                        .strokeBorder(DocTokens.ColorRole.Accent.primary, lineWidth: Metrics.focusWidth)
                        .padding(.horizontal, compact ? -Metrics.cellInset / 2 : -Metrics.cellInset + 1)
                        .padding(.vertical, 1)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch column.type {
        case .select(let options), .multiSelect(let options):
            optionsCell(options)
        case .checkbox:
            let on = value == .checkbox(value: true)
            Button {
                controller.set(on ? nil : .checkbox(value: true), row: row.id, column: column.id, in: block)
            } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: DocTokens.Icon.standard))
                    .foregroundStyle(on ? DocTokens.ColorRole.Content.primary : DocTokens.ColorRole.Content.tertiary)
                    .frame(maxWidth: compact ? nil : .infinity, minHeight: Metrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!controller.isEditable)
        case .date:
            let panel = DocCollectionPanel.Kind.date(row: row.id, column: column.id)
            Button {
                controller.show(panel, in: block)
            } label: {
                Text(DocFieldText.text(value, in: column))
                    .font(.system(size: 14))
                    .foregroundStyle(DocTokens.ColorRole.Content.primary)
                    .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!controller.isEditable)
            .docPanel(isPresented: controller.isShowing(panel, in: block),
                                     onDismiss: { controller.close(panel, in: block) }) {
                DocDatePanel(row: row, column: column, block: block, controller: controller)
            }
        default:
            // The title opens the record (Craft's arrow, over the row): over the room kept
            // for it at the title's end, so its coming and going moves nothing.
            HStack(spacing: DocTokens.Space.sm) {
                // A record with a page written shows it before its title (Craft's).
                if isTitle, !compact, controller.hasPage?(row.id) == true {
                    DocRecordPageMark()
                }
                field
            }
            .padding(.trailing, isTitle && !compact ? Metrics.openButton + DocTokens.Space.xs : 0)
            .overlay(alignment: .trailing) {
                if isTitle, !compact, rowHovered || !DocTokens.Platform.isPointer {
                    DocOpenRecordButton(snapshot: snapshot, row: row, controller: controller)
                }
            }
        }
    }

    /// The whole text, in as many lines as the column's width makes it: none of it out of sight.
    private var field: some View {
        TextField("", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            // Text the field doesn't take (a word in a number, a link without a host) shows
            // faint while it's typed; it goes when the editing ends (Craft's).
            .foregroundStyle(DocFieldText.takes(text, in: column) ? DocTokens.ColorRole.Content.primary
                                                                 : DocTokens.ColorRole.Content.tertiary)
            .multilineTextAlignment(column.type == .number && !compact ? .trailing : .leading)
            .padding(.vertical, Metrics.cellLinePadding)
            .frame(minHeight: Metrics.rowHeight)
            .focused($focused)
            .disabled(!controller.isEditable)
            .onAppear {
                text = DocFieldText.text(value, in: column)
                if isTitle, !compact, controller.editingTitle == row.id {
                    controller.editingTitle = nil
                    Task { @MainActor in focused = true }
                }
            }
            // What's typed stays as typed while it reads as the cell's value ("1,5" is 1.5,
            // "example.com" is its https link); a change from elsewhere replaces it.
            .onChange(of: value) { _, value in
                if DocFieldText.value(typed: text, in: column) != value { text = DocFieldText.text(value, in: column) }
            }
            .onChange(of: text) { _, typed in
                // Return ends the editing, as on one line: the field wraps, its value doesn't break.
                if typed.contains("\n") {
                    text = typed.replacingOccurrences(of: "\n", with: "")
                    focused = false
                    return
                }
                if typed != DocFieldText.text(value, in: column) { controller.setText(typed, row: row.id, column: column.id, in: block) }
            }
            .onChange(of: focused) { _, focused in
                if !focused { text = DocFieldText.text(value, in: column) }
            }
            .onSubmit { focused = false }
            .modifier(DocFieldPlaceModifier(place: place, isFocused: focused, editor: controller.editor))
    }

    /// A select's or multi-select's chips; a click picks from its options (a panel in the
    /// table, a menu in a record's panel).
    @ViewBuilder
    private func optionsCell(_ options: [SelectOption]) -> some View {
        let chosen: [SelectOption] = switch value {
        case .select(let id)?: options.filter { $0.id == id }
        case .multiSelect(let ids)?: ids.compactMap { id in options.first { $0.id == id } }
        default: []
        }
        let chips = HStack(spacing: DocTokens.Space.xs) {
            ForEach(chosen, id: \.id) { DocChip($0, in: options) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight)
        .contentShape(Rectangle())
        if compact {
            Menu {
                ForEach(options, id: \.id) { option in
                    Toggle(option.name, isOn: Binding { chosen.contains(option) } set: { _ in
                        controller.toggle(option.id, row: row.id, column: column.id, in: block)
                    })
                }
            } label: { chips }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .disabled(!controller.isEditable)
        } else {
            Button {
                controller.show(.options(row: row.id, column: column.id), in: block)
            } label: { chips }
            .buttonStyle(.plain)
            .disabled(!controller.isEditable)
            .docPanel(isPresented: controller.isShowing(.options(row: row.id, column: column.id), in: block),
                                     onDismiss: { controller.close(.options(row: row.id, column: column.id), in: block) }) {
                DocOptionsPanel(snapshot: snapshot, row: row, column: column, controller: controller)
            }
        }
    }
}

/// How wide a table's column reads on one line: its header, and each of its cells as shown.
enum DocCollectionWidths {
    static func head(_ column: Column) -> CGFloat {
        // The type's symbol, its gap, the name, the chevron's room, the insets.
        width(column.name, size: 13, weight: .medium) + DocTokens.Icon.compact + 3 * DocTokens.Space.xs + 2
            + 12 + 2 * Metrics.cellInset
    }

    static func cell(_ value: CellValue?, in column: Column, isTitle: Bool) -> CGFloat {
        let inset = 2 * Metrics.cellInset
        switch (column.type, value) {
        case (.select(let options), .select(let id)?):
            return chips(options.filter { $0.id == id }) + inset
        case (.multiSelect(let options), .multiSelect(let ids)?):
            return chips(ids.compactMap { id in options.first { $0.id == id } }) + inset
        case (.checkbox, _):
            return DocTokens.Icon.standard + inset
        default:
            let title = isTitle ? Metrics.openButton + DocTokens.Space.xs : 0
            return width(DocFieldText.text(value, in: column), size: 14) + title + inset + 2
        }
    }

    private static func chips(_ options: [SelectOption]) -> CGFloat {
        options.map { width($0.name, size: 13, weight: .medium) + 14 }.reduce(0, +)
            + CGFloat(max(options.count - 1, 0)) * DocTokens.Space.xs
    }

    static func width(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// The arrow that opens a record as a page (Craft's; DocRecordPage).
struct DocOpenRecordButton: View {
    let snapshot: DocCollectionSnapshot
    let row: Row
    let controller: DocCollectionController

    var body: some View {
        Button {
            controller.openRecord?(row.id, snapshot.block)
        } label: {
            Image(systemName: "arrow.right.circle")
                .font(.system(size: DocTokens.Icon.standard))
                .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                .frame(width: Metrics.openButton, height: Metrics.openButton)
        }
        .buttonStyle(.flooContent(in: Circle()))
        .help(String(localized: "Open"))
        .accessibilityLabel(String(localized: "Open"))
    }
}

/// A column's cell in the calculation row: Calculate, or what it computes over the rows shown.
private struct DocCalculationCell: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let column: Column
    let rows: [Row]
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
            HStack(spacing: DocTokens.Space.xs) {
                Spacer(minLength: 0)
                if let calculation {
                    Text(DocCollectionMath.label(calculation))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DocTokens.ColorRole.Content.tertiary)
                    Text(DocCollectionMath.value(calculation, of: column, in: rows))
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                } else {
                    Text(String(localized: "Calculate"))
                        .font(.system(size: 12))
                        .foregroundStyle(DocTokens.ColorRole.Content.tertiary)
                        .opacity(controller.isEditable && offers ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
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
        calculation.result(of: column.id, in: rows).map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "–"
    }
}
