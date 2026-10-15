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
//  - over a row its number turns into a box that picks it (picked rows delete together),
//    and the title shows an arrow that opens the record whole;
//  - the calculation row computes a column (Calculate on the pointer over it), + adds a record.
//

import SwiftUI
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

    private var block: DocBlockID { snapshot.block }
    private var columns: [Column] { DocCollectionController.fields(view, of: snapshot.database) }
    private var titleColumn: Column? { DocCollectionController.titleColumn(of: snapshot.database) }
    private var picked: Set<RowID> { controller.selectedRows[block] ?? [] }
    private var trailing: CGFloat { controller.isEditable ? Metrics.addFieldWidth : 0 }

    /// Each column's width: the title wider, the rest alike, stretched to fill the block
    /// when there's room; past it the table scrolls sideways.
    private func widths() -> [CGFloat] {
        let natural = columns.map { $0.id == titleColumn?.id ? Metrics.titleWidth : Metrics.fieldWidth }
        let fixed = Metrics.numberWidth + trailing
        let total = natural.reduce(0, +)
        guard width > total + fixed, total > 0 else { return natural }
        let scale = (width - fixed) / total
        return natural.map { $0 * scale }
    }

    var body: some View {
        let widths = widths()
        let rows = controller.rows(snapshot, view)
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                head(widths)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    FlooDesignDivider()
                    record(row, number: index + 1, widths: widths)
                }
                FlooDesignDivider()
                foot(widths, rows: rows)
            }
            .fixedSize(horizontal: true, vertical: false)
            .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(FlooDesignTokens.Border.separator, lineWidth: FlooDesignTokens.Border.hairline))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    // MARK: Header

    private func head(_ widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "number")
                .font(.system(size: FlooDesignTokens.Icon.compact))
                .foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
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
        .background(FlooDesignTokens.ColorRole.Surface.decoration)
    }

    private var addField: some View {
        Button {
            controller.show(.addField, in: block)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: FlooDesignTokens.Icon.compact, weight: .medium))
                .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                .frame(width: Metrics.addFieldWidth - FlooDesignTokens.Border.hairline, height: Metrics.headHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(FlooDesignPlainButtonStyle(in: Rectangle()))
        .help(String(localized: "Add Field"))
        .accessibilityLabel(String(localized: "Add Field"))
        .flooDesignAnchoredPanel(isPresented: controller.isShowing(.addField, in: block), configuration: .init(horizontalAlignment: .trailing),
                                 onDismiss: { controller.close(.addField, in: block) }) {
            DocFieldPanel(snapshot: snapshot, column: nil, controller: controller)
        }
    }

    // MARK: Records

    private func record(_ row: Row, number: Int, widths: [CGFloat]) -> some View {
        let isPicked = picked.contains(row.id)
        let isHovered = hoveredRow == row.id
        return HStack(spacing: 0) {
            numberCell(row, number: number, isHovered: isHovered, isPicked: isPicked)
            ForEach(Array(zip(columns, widths)), id: \.0.id) { column, width in
                separator
                DocCollectionCell(snapshot: snapshot, row: row, column: column, controller: controller,
                                  isTitle: column.id == titleColumn?.id, rowHovered: isHovered)
                    .padding(.horizontal, Metrics.cellInset)
                    .frame(width: width, alignment: column.type == .number ? .trailing : .leading)
            }
            if controller.isEditable {
                separator
                Color.clear.frame(width: Metrics.addFieldWidth - FlooDesignTokens.Border.hairline)
            }
        }
        .frame(minHeight: Metrics.rowHeight)
        .background(isPicked ? FlooDesignTokens.ColorRole.Surface.selected : .clear)
        .onHover { over in
            if over { hoveredRow = row.id } else if hoveredRow == row.id { hoveredRow = nil }
        }
        .flooDesignContextMenu(isEnabled: controller.isEditable) { _ in
            if isPicked, picked.count > 1 {
                [.init(.rows, [.action(String(localized: "Delete \(picked.count) Rows"), symbol: "trash", role: .destructive) {
                    controller.delete(rows: picked, in: block)
                }])]
            } else {
                [.init(.rows, [.action(String(localized: "Delete Row"), symbol: "trash", role: .destructive) { controller.delete(row.id, in: block) }])]
            }
        }
    }

    /// The row's number; over the row (or with rows picked) the box that picks it.
    @ViewBuilder
    private func numberCell(_ row: Row, number: Int, isHovered: Bool, isPicked: Bool) -> some View {
        let picking = controller.isEditable && (isHovered || !picked.isEmpty || !FlooDesignTokens.Platform.isPointer && isPicked)
        if picking {
            Button {
                controller.togglePicked(row.id, in: block)
            } label: {
                Image(systemName: isPicked ? "checkmark.square.fill" : "square")
                    .font(.system(size: FlooDesignTokens.Icon.standard))
                    .foregroundStyle(isPicked ? FlooDesignTokens.ColorRole.Content.primary : FlooDesignTokens.ColorRole.Content.tertiary)
                    .frame(width: Metrics.numberWidth, height: Metrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Select Row"))
        } else {
            Text("\(number)")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
                .frame(width: Metrics.numberWidth)
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
                    .font(.system(size: FlooDesignTokens.Icon.compact, weight: .medium))
                    .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
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
        FlooDesignDivider(.vertical)
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
            if controller.isEditable {
                Divider()
                Button(String(localized: "Hide Field"), systemImage: "eye.slash") { controller.setHidden(column.id, true, in: view.id, of: block) }
                    .disabled(column.id == DocCollectionController.titleColumn(of: snapshot.database)?.id)
                Button(String(localized: "Delete Field"), systemImage: "trash", role: .destructive) { controller.deleteField(column.id, in: block) }
                    .disabled(snapshot.database.columns.count < 2)
            }
        } label: {
            HStack(spacing: FlooDesignTokens.Space.xs + 2) {
                Image(systemName: DocFieldText.symbol(column))
                    .font(.system(size: FlooDesignTokens.Icon.compact))
                    .foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
                Text(column.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                    .lineLimit(1)
                if let sort = view.layout.sort.first(where: { $0.column == column.id }) {
                    Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: FlooDesignTokens.Icon.inline, weight: .semibold))
                        .foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: FlooDesignTokens.Icon.inline, weight: .semibold))
                    .foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Metrics.cellInset)
            .frame(maxWidth: .infinity, minHeight: Metrics.headHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(FlooDesignPlainButtonStyle(in: Rectangle()))
        .onHover { hovering = $0 }
        .flooDesignAnchoredPanel(isPresented: controller.isShowing(.editField(column.id), in: block),
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
    @State private var text = ""
    @FocusState private var focused: Bool

    private var block: DocBlockID { snapshot.block }
    private var value: CellValue? { row.cells[column.id] }

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: column.type == .number && !compact ? .trailing : .leading)
            .overlay {
                // The cell taking typing, outlined (Craft's).
                if focused {
                    RoundedRectangle(cornerRadius: FlooDesignTokens.Radius.xs, style: .continuous)
                        .strokeBorder(FlooDesignTokens.ColorRole.Accent.primary, lineWidth: Metrics.focusWidth)
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
                    .font(.system(size: FlooDesignTokens.Icon.standard))
                    .foregroundStyle(on ? FlooDesignTokens.ColorRole.Content.primary : FlooDesignTokens.ColorRole.Content.tertiary)
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
                    .foregroundStyle(FlooDesignTokens.ColorRole.Content.primary)
                    .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!controller.isEditable)
            .flooDesignAnchoredPanel(isPresented: controller.isShowing(panel, in: block),
                                     configuration: .init(anchorGap: 0),
                                     onDismiss: { controller.close(panel, in: block) }) {
                DocDatePanel(row: row, column: column, block: block, controller: controller)
            }
        default:
            // The title opens the record (Craft's arrow, over the row): over the room kept
            // for it at the title's end, so its coming and going moves nothing.
            HStack(spacing: FlooDesignTokens.Space.sm) {
                // A record with a page written shows it before its title (Craft's).
                if isTitle, !compact, controller.hasPage?(row.id) == true {
                    DocRecordPageMark()
                }
                field
            }
            .padding(.trailing, isTitle && !compact ? Metrics.openButton + FlooDesignTokens.Space.xs : 0)
            .overlay(alignment: .trailing) {
                if isTitle, !compact, rowHovered || !FlooDesignTokens.Platform.isPointer {
                    DocOpenRecordButton(snapshot: snapshot, row: row, controller: controller)
                }
            }
        }
    }

    /// One line, as Craft's cells are: a longer text runs on out of sight.
    private var field: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            // Text the field doesn't take (a word in a number, a link without a host) shows
            // faint while it's typed; it goes when the editing ends (Craft's).
            .foregroundStyle(DocFieldText.takes(text, in: column) ? FlooDesignTokens.ColorRole.Content.primary
                                                                 : FlooDesignTokens.ColorRole.Content.tertiary)
            .lineLimit(1)
            .multilineTextAlignment(column.type == .number && !compact ? .trailing : .leading)
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
            .onChange(of: text) { _, text in
                if text != DocFieldText.text(value, in: column) { controller.setText(text, row: row.id, column: column.id, in: block) }
            }
            .onChange(of: focused) { _, focused in
                if !focused { text = DocFieldText.text(value, in: column) }
            }
            .onSubmit { focused = false }
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
        let chips = HStack(spacing: FlooDesignTokens.Space.xs) {
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
            .flooDesignAnchoredPanel(isPresented: controller.isShowing(.options(row: row.id, column: column.id), in: block),
                                     configuration: .init(anchorGap: 0),
                                     onDismiss: { controller.close(.options(row: row.id, column: column.id), in: block) }) {
                DocOptionsPanel(snapshot: snapshot, row: row, column: column, controller: controller)
            }
        }
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
                .font(.system(size: FlooDesignTokens.Icon.standard))
                .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                .frame(width: Metrics.openButton, height: Metrics.openButton)
        }
        .buttonStyle(FlooDesignPlainButtonStyle(in: Circle()))
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
            HStack(spacing: FlooDesignTokens.Space.xs) {
                Spacer(minLength: 0)
                if let calculation {
                    Text(DocCollectionMath.label(calculation))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
                    Text(DocCollectionMath.value(calculation, of: column, in: rows))
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
