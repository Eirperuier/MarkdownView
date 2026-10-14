//
//  DocCollectionPanels.swift
//  DemoApp
//
//  A collection's panels (Craft's), each anchored to what opened it, in FlooDesign's
//  floating panel: a title and ✕ over a rule, then what it sets.
//  - Layout & Visibility: table or kanban (and what it groups by), the calculation row,
//    which fields show and in what order (drag a field by its handle);
//  - Sort By and Filter: a rule per line, each change at once;
//  - Create Kanban, Name View, Add/Edit Field, Add/Edit Option: a form, Cancel and Save;
//  - a select's options: find one, tick it, or type a new one.
//

import SwiftUI
import DocKit
import FlooDesign

private typealias Metrics = DocCollectionMetrics
private typealias Tokens = FlooDesignTokens

// MARK: - Pieces

/// A panel's frame: its title and ✕, a rule, what it holds.
struct DocPanelFrame<Content: View>: View {
    let title: String
    var width: CGFloat = Metrics.panelWidth
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        FlooDesignFloatingPanelSurface(contentInset: Tokens.Component.FloatingPanel.roomyInset) {
            VStack(alignment: .leading, spacing: Tokens.Space.md) {
                HStack {
                    Text(title)
                        .font(Tokens.Typography.panelTitle.font)
                        .lineLimit(1)
                    Spacer(minLength: Tokens.Space.sm)
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Tokens.ColorRole.Content.secondary)
                    }
                    .buttonStyle(FlooDesignPlainButtonStyle(in: Circle()))
                    .accessibilityLabel(String(localized: "Close"))
                }
                FlooDesignDivider()
                content
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

/// A menu's face in a panel: its symbol, its choice and a chevron, outlined.
struct DocPanelMenuLabel: View {
    var symbol: String?
    let title: String
    var fills = false
    var quiet = false

    var body: some View {
        HStack(spacing: Tokens.Space.xs + 2) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: Tokens.Icon.compact))
                    .foregroundStyle(Tokens.ColorRole.Content.secondary)
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(quiet ? Tokens.ColorRole.Content.tertiary : Tokens.ColorRole.Content.primary)
                .lineLimit(1)
            if fills { Spacer(minLength: 0) }
            Image(systemName: "chevron.down")
                .font(.system(size: Tokens.Icon.inline, weight: .semibold))
                .foregroundStyle(Tokens.ColorRole.Content.tertiary)
        }
        .padding(.horizontal, Tokens.Space.sm + 2)
        .frame(maxWidth: fills ? .infinity : nil, minHeight: Metrics.fieldHeight)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm + 2, style: .continuous)
            .strokeBorder(Tokens.Border.subtle, lineWidth: Tokens.Border.standard))
        .contentShape(Rectangle())
    }
}

/// A small heading over a part of a panel.
private struct DocPanelSection: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Tokens.Typography.sectionLabel.font)
            .foregroundStyle(Tokens.ColorRole.Content.tertiary)
    }
}

/// Cancel and the panel's own button, as wide as each other.
private struct DocPanelButtons: View {
    let title: String
    var enabled = true
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.sm) {
            Button(action: cancel) { Text(String(localized: "Cancel")).frame(maxWidth: .infinity) }
                .buttonStyle(FlooDesignButtonStyle(.secondary))
            Button(action: save) { Text(title).frame(maxWidth: .infinity) }
                .buttonStyle(FlooDesignButtonStyle(.primary))
                .disabled(!enabled)
        }
        .compositingGroup()
    }
}

/// The six dots a field is dragged by: FlooDesign's handle, drawn only (the row takes the drag).
private struct DocDragDots: UIViewRepresentable {
    func makeUIView(context: Context) -> FlooDesignDragHandle {
        let handle = FlooDesignDragHandle()
        handle.isUserInteractionEnabled = false
        return handle
    }

    func updateUIView(_ handle: FlooDesignDragHandle, context: Context) {}
}

/// A field's name with its type's symbol, outlined (Craft's in Visible Fields).
private struct DocFieldTag: View {
    let column: Column

    var body: some View {
        HStack(spacing: Tokens.Space.xs + 2) {
            Image(systemName: DocFieldText.symbol(column))
                .font(.system(size: Tokens.Icon.compact))
                .foregroundStyle(Tokens.ColorRole.Content.secondary)
            Text(column.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, Tokens.Space.sm + 2)
        .frame(minHeight: Metrics.fieldHeight)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm + 2, style: .continuous)
            .strokeBorder(Tokens.Border.subtle, lineWidth: Tokens.Border.standard))
    }
}

/// Picks one of the database's fields.
private struct DocFieldMenu: View {
    let columns: [Column]
    let chosen: Column?
    var placeholder = String(localized: "Select Field")
    var fills = false
    let pick: (Column) -> Void

    var body: some View {
        Menu {
            ForEach(columns, id: \.id) { column in
                Button(column.name, systemImage: DocFieldText.symbol(column)) { pick(column) }
            }
        } label: {
            DocPanelMenuLabel(symbol: chosen.map(DocFieldText.symbol), title: chosen?.name ?? placeholder, fills: fills, quiet: chosen == nil)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fills, vertical: false)
    }
}

/// An add line under a panel's rules: + and what it adds, a menu of fields.
private struct DocAddRuleMenu: View {
    let title: String
    let columns: [Column]
    let pick: (Column) -> Void

    var body: some View {
        Menu {
            ForEach(columns, id: \.id) { column in
                Button(column.name, systemImage: DocFieldText.symbol(column)) { pick(column) }
            }
        } label: {
            Label(title, systemImage: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tokens.ColorRole.Content.secondary)
                .padding(.vertical, Tokens.Space.xs)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(columns.isEmpty)
    }
}

private struct DocTrashButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: Tokens.Icon.compact))
                .foregroundStyle(Tokens.ColorRole.Content.secondary)
                .frame(width: Metrics.fieldHeight, height: Metrics.fieldHeight)
        }
        .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)))
        .accessibilityLabel(String(localized: "Remove"))
    }
}

// MARK: - Layout & Visibility

struct DocLayoutPanel: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let controller: DocCollectionController

    private var block: DocBlockID { snapshot.block }
    private var selects: [Column] { DocCollectionController.selects(in: snapshot.database) }
    private var titleColumn: Column? { DocCollectionController.titleColumn(of: snapshot.database) }

    var body: some View {
        DocPanelFrame(title: String(localized: "Layout & Visibility"), close: { controller.close(.layout, in: block) }) {
            HStack(spacing: Tokens.Space.sm) {
                FlooDesignOption(String(localized: "Table"), isOn: view.layout.groupBy == nil) {
                    controller.setLayout(kanban: false, in: view.id, of: block)
                } picture: {
                    Image(systemName: "tablecells").font(.system(size: Tokens.Icon.prominent - 2))
                }
                FlooDesignOption(String(localized: "Kanban"), isOn: view.layout.groupBy != nil) {
                    controller.setLayout(kanban: true, in: view.id, of: block)
                } picture: {
                    Image(systemName: "rectangle.split.3x1").font(.system(size: Tokens.Icon.prominent - 2))
                }
                .disabled(selects.isEmpty)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                DocPanelSection(title: String(localized: "Options"))
                if let group = view.layout.groupBy {
                    HStack {
                        Text(String(localized: "Group By")).font(.system(size: 13))
                        Spacer()
                        DocFieldMenu(columns: selects, chosen: selects.first { $0.id == group }) { column in
                            controller.setLayout(kanban: true, groupedBy: column.id, in: view.id, of: block)
                        }
                    }
                } else {
                    HStack {
                        Text(String(localized: "Show Calculation Row")).font(.system(size: 13))
                        Spacer()
                        Toggle(String(localized: "Show Calculation Row"),
                               isOn: Binding { view.showsCalculations } set: { controller.setShowsCalculations($0, in: view.id, of: block) })
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(Tokens.ColorRole.Accent.primary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                DocPanelSection(title: String(localized: "Visible Fields"))
                ForEach(view.ordered(snapshot.database.columns), id: \.id) { column in
                    fieldRow(column)
                }
            }
        }
    }

    /// A field: its handle (drag it up or down), its name, whether it shows.
    private func fieldRow(_ column: Column) -> some View {
        HStack(spacing: Tokens.Space.sm) {
            DocDragDots()
                .frame(width: FlooDesignDragHandle.size.width, height: FlooDesignDragHandle.size.height)
            DocFieldTag(column: column)
            Spacer(minLength: Tokens.Space.sm)
            Toggle(column.name, isOn: Binding { !view.layout.hidden.contains(column.id) } set: { shows in
                controller.setHidden(column.id, !shows, in: view.id, of: block)
            })
            .labelsHidden()
            .toggleStyle(.switch)
                    .tint(Tokens.ColorRole.Accent.primary)
            // The title always shows, as a record's name.
            .disabled(column.id == titleColumn?.id || column.id == view.layout.groupBy)
        }
        .contentShape(Rectangle())
        .draggable(column.id.description)
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, let moved = snapshot.database.columns.first(where: { $0.id.description == item }) else { return false }
            controller.moveField(moved.id, before: column.id, in: view.id, of: block)
            return true
        }
    }
}

// MARK: - Sort

struct DocSortPanel: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let controller: DocCollectionController

    private var block: DocBlockID { snapshot.block }
    private var sort: [DatabaseSort] { view.layout.sort }
    private var columns: [Column] { snapshot.database.columns }
    private var unused: [Column] { columns.filter { column in !sort.contains { $0.column == column.id } } }

    var body: some View {
        DocPanelFrame(title: String(localized: "Sort By"), close: { controller.close(.sort, in: block) }) {
            if sort.isEmpty {
                DocFieldMenu(columns: columns, chosen: nil, fills: true) { set([DatabaseSort(column: $0.id)]) }
            } else {
                ForEach(Array(sort.enumerated()), id: \.offset) { index, entry in
                    HStack(spacing: Tokens.Space.sm) {
                        DocFieldMenu(columns: unused + columns.filter { $0.id == entry.column }, chosen: columns.first { $0.id == entry.column }) { column in
                            var sort = sort
                            sort[index].column = column.id
                            set(sort)
                        }
                        Menu {
                            Button(String(localized: "Ascending")) { direction(index, ascending: true) }
                            Button(String(localized: "Descending")) { direction(index, ascending: false) }
                        } label: {
                            DocPanelMenuLabel(title: entry.ascending ? String(localized: "Ascending") : String(localized: "Descending"))
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .fixedSize()
                        Spacer(minLength: 0)
                        DocTrashButton {
                            var sort = sort
                            sort.remove(at: index)
                            set(sort)
                        }
                    }
                }
                DocAddRuleMenu(title: String(localized: "Add Another Sort"), columns: unused) { set(sort + [DatabaseSort(column: $0.id)]) }
            }
        }
    }

    private func direction(_ index: Int, ascending: Bool) {
        var sort = sort
        sort[index].ascending = ascending
        set(sort)
    }

    private func set(_ sort: [DatabaseSort]) { controller.setSort(sort, in: view.id, of: block) }
}

// MARK: - Filter

struct DocFilterPanel: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let controller: DocCollectionController

    private var block: DocBlockID { snapshot.block }
    private var filters: [CollectionFilter] { view.filters }
    private var columns: [Column] { snapshot.database.columns }

    var body: some View {
        DocPanelFrame(title: String(localized: "Filter"), width: Metrics.wideFieldsPanel, close: { controller.close(.filter, in: block) }) {
            if filters.isEmpty {
                DocFieldMenu(columns: columns, chosen: nil, fills: true) { add($0) }
            } else {
                ForEach(Array(filters.enumerated()), id: \.offset) { index, filter in
                    if let column = columns.first(where: { $0.id == filter.column }) {
                        DocFilterRule(filter: filter, column: column, columns: columns, typingKey: [AnyHashable(view.id), AnyHashable(index)]) { changed, key in
                            var filters = filters
                            if let changed { filters[index] = changed } else { filters.remove(at: index) }
                            controller.setFilters(filters, typing: key, in: view.id, of: block)
                        }
                    }
                }
                DocAddRuleMenu(title: String(localized: "Add Filter"), columns: columns) { add($0) }
            }
        }
    }

    private func add(_ column: Column) {
        let filter = CollectionFilter(column: column.id, condition: CollectionFilter.conditions(for: column.type)[0],
                                      value: column.type == .checkbox ? .checkbox(value: true) : nil)
        controller.setFilters(filters + [filter], in: view.id, of: block)
    }
}

/// One filter: its field, its condition and (unless it tests for empty) the value.
private struct DocFilterRule: View {
    let filter: CollectionFilter
    let column: Column
    let columns: [Column]
    let typingKey: AnyHashable
    /// The filter changed (nil: removed), and the key typing in its value goes under.
    let change: (CollectionFilter?, AnyHashable?) -> Void
    @State private var text = ""

    private var needsValue: Bool { filter.condition != .isEmpty && filter.condition != .isNotEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            HStack(spacing: Tokens.Space.sm) {
                DocFieldMenu(columns: columns, chosen: column) { picked in
                    guard picked.id != column.id else { return }
                    change(CollectionFilter(column: picked.id, condition: CollectionFilter.conditions(for: picked.type)[0],
                                            value: picked.type == .checkbox ? .checkbox(value: true) : nil), nil)
                }
                Menu {
                    ForEach(CollectionFilter.conditions(for: column.type), id: \.self) { condition in
                        Button(Self.name(condition, for: column.type)) {
                            var changed = filter
                            changed.condition = condition
                            change(changed, nil)
                        }
                    }
                } label: {
                    DocPanelMenuLabel(title: Self.name(filter.condition, for: column.type))
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                Spacer(minLength: 0)
                DocTrashButton { change(nil, nil) }
            }
            if needsValue { value }
        }
        .onAppear { text = shownText }
        .onChange(of: filter.column) { _, _ in text = shownText }
    }

    private var shownText: String {
        switch filter.value {
        case .text(let text)?, .url(let text)?, .person(let text)?: text
        case .number(let number)?: number.formatted()
        default: ""
        }
    }

    @ViewBuilder
    private var value: some View {
        switch column.type {
        case .select(let options), .multiSelect(let options):
            Menu {
                ForEach(options, id: \.id) { option in
                    Button(option.name) { set(.select(option: option.id)) }
                }
            } label: {
                if case .select(let id)? = filter.value, let option = options.first(where: { $0.id == id }) {
                    HStack {
                        DocChip(option, in: options)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: Tokens.Icon.inline, weight: .semibold))
                            .foregroundStyle(Tokens.ColorRole.Content.tertiary)
                    }
                    .padding(.horizontal, Tokens.Space.sm)
                    .frame(minHeight: Metrics.fieldHeight)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm + 2, style: .continuous)
                        .strokeBorder(Tokens.Border.subtle, lineWidth: Tokens.Border.standard))
                    .contentShape(Rectangle())
                } else {
                    DocPanelMenuLabel(title: String(localized: "Select Option"), fills: true, quiet: true)
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        case .checkbox:
            let on = filter.value != .checkbox(value: false)
            Menu {
                Button(String(localized: "Checked")) { set(.checkbox(value: true)) }
                Button(String(localized: "Unchecked")) { set(.checkbox(value: false)) }
            } label: {
                DocPanelMenuLabel(symbol: on ? "checkmark.square.fill" : "square",
                                  title: on ? String(localized: "Checked") : String(localized: "Unchecked"), fills: true)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        case .date:
            DatePicker(String(localized: "Date"), selection: Binding {
                if case .date(let day)? = filter.value { return DocFieldText.date(of: day) }
                return .now
            } set: { date in
                set(.date(value: DocFieldText.timestamp(of: date)))
            }, displayedComponents: [.date])
            .datePickerStyle(.compact)
            .labelsHidden()
        default:
            TextField(String(localized: "Value"), text: $text)
                .textFieldStyle(FlooDesignTextFieldStyle())
                .onChange(of: text) { _, text in
                    guard text != shownText else { return }
                    let value: CellValue? = switch column.type {
                    case .number: Double(text.trimmingCharacters(in: .whitespaces)).map { .number(value: $0) }
                    case .url: .url(value: text)
                    case .person: .person(value: text)
                    default: .text(value: text)
                    }
                    var changed = filter
                    changed.value = text.isEmpty ? nil : value
                    change(changed, typingKey)
                }
        }
    }

    private func set(_ value: CellValue) {
        var changed = filter
        changed.value = value
        change(changed, nil)
    }

    static func name(_ condition: CollectionFilter.Condition, for type: ColumnType) -> String {
        let dated = type == .date
        return switch condition {
        case .contains: String(localized: "Contains")
        case .doesNotContain: String(localized: "Does Not Contain")
        case .is: String(localized: "Is")
        case .isNot: String(localized: "Is Not")
        case .greaterThan: dated ? String(localized: "Is After") : String(localized: "Greater Than")
        case .lessThan: dated ? String(localized: "Is Before") : String(localized: "Less Than")
        case .isEmpty: String(localized: "Is Empty")
        case .isNotEmpty: String(localized: "Is Not Empty")
        }
    }
}

// MARK: - New views

/// Craft's Create Kanban: its name and the select it groups by.
struct DocCreateKanbanPanel: View {
    let snapshot: DocCollectionSnapshot
    let controller: DocCollectionController
    @State private var name = String(localized: "New Kanban")
    @State private var group: ColumnID?

    private var block: DocBlockID { snapshot.block }
    private var selects: [Column] { DocCollectionController.selects(in: snapshot.database) }
    private var chosen: Column? { selects.first { $0.id == group } ?? selects.first }

    var body: some View {
        DocPanelFrame(title: String(localized: "Create Kanban"), close: close) {
            TextField(String(localized: "Name"), text: $name)
                .textFieldStyle(FlooDesignTextFieldStyle())
                .onSubmit(save)
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                DocPanelSection(title: String(localized: "Group By"))
                DocFieldMenu(columns: selects, chosen: chosen) { group = $0.id }
            }
            DocPanelButtons(title: String(localized: "Save"), enabled: chosen != nil, cancel: close, save: save)
        }
    }

    private func close() { controller.close(.createKanban, in: block) }

    private func save() {
        guard let chosen else { return }
        controller.addView(to: block, name: name.isEmpty ? String(localized: "New Kanban") : name,
                           layout: .kanban(groupBy: chosen.id, hidden: [], sort: []))
        close()
    }
}

/// Craft's Name View, for a view just added.
struct DocNameViewPanel: View {
    let block: DocBlockID
    let view: CollectionView
    let controller: DocCollectionController
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        DocPanelFrame(title: String(localized: "Name View"), close: close) {
            TextField(String(localized: "Name"), text: $name)
                .textFieldStyle(FlooDesignTextFieldStyle())
                .focused($focused)
                .onSubmit(save)
            DocPanelButtons(title: String(localized: "Save"), enabled: !name.isEmpty, cancel: close, save: save)
        }
        .onAppear {
            name = view.name
            Task { @MainActor in focused = true }
        }
    }

    private func close() { controller.close(.nameView(view.id), in: block) }

    private func save() {
        controller.rename(view.id, in: block, to: name)
        close()
    }
}

// MARK: - Fields

/// Add Field, or Edit Field for one there is: its name and its type.
struct DocFieldPanel: View {
    let snapshot: DocCollectionSnapshot
    let column: Column?
    let controller: DocCollectionController
    @State private var name = ""
    @State private var type: ColumnType = .text
    @FocusState private var focused: Bool

    private var block: DocBlockID { snapshot.block }
    private var kind: DocCollectionPanel.Kind { column.map { .editField($0.id) } ?? .addField }

    var body: some View {
        DocPanelFrame(title: column == nil ? String(localized: "Add Field") : String(localized: "Edit Field"), close: close) {
            HStack(spacing: Tokens.Space.sm) {
                Image(systemName: DocFieldText.symbol(type))
                    .font(.system(size: Tokens.Icon.standard))
                    .foregroundStyle(Tokens.ColorRole.Content.secondary)
                    .frame(width: Tokens.Component.TextField.minHeight, height: Tokens.Component.TextField.minHeight)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Component.TextField.cornerRadius, style: .continuous)
                        .strokeBorder(Tokens.Border.subtle, lineWidth: Tokens.Border.standard))
                TextField(String(localized: "Field Name"), text: $name)
                    .textFieldStyle(FlooDesignTextFieldStyle())
                    .focused($focused)
                    .onSubmit(save)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                DocPanelSection(title: String(localized: "Type"))
                Menu {
                    ForEach(Array(DocFieldText.types.enumerated()), id: \.offset) { index, type in
                        if index == 6 { Divider() }
                        Button(DocFieldText.name(type), systemImage: DocFieldText.symbol(type)) { self.type = type }
                    }
                } label: {
                    DocPanelMenuLabel(symbol: DocFieldText.symbol(type), title: DocFieldText.name(type), fills: true)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            }
            DocPanelButtons(title: column == nil ? String(localized: "Add") : String(localized: "Save"),
                            enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty, cancel: close, save: save)
        }
        .onAppear {
            if let column {
                name = column.name
                type = column.type
            }
            Task { @MainActor in focused = true }
        }
    }

    private func close() { controller.close(kind, in: block) }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let column {
            controller.editField(column.id, name: name, type: type, in: block)
        } else {
            controller.addField(name, type: type, to: block)
        }
        close()
    }
}

// MARK: - Options

/// A select's or multi-select's options for one record (Craft's Set …): type to find one,
/// or a new one, which Return adds; a click ticks one (a select's closes the panel).
struct DocOptionsPanel: View {
    let snapshot: DocCollectionSnapshot
    let row: Row
    let column: Column
    let controller: DocCollectionController
    @State private var text = ""
    @FocusState private var focused: Bool

    private var block: DocBlockID { snapshot.block }
    private var options: [SelectOption] { DocFieldText.options(column) }
    private var isMulti: Bool { if case .multiSelect = column.type { true } else { false } }
    private var query: String { text.trimmingCharacters(in: .whitespaces) }
    private var shown: [SelectOption] { query.isEmpty ? options : options.filter { $0.name.localizedCaseInsensitiveContains(query) } }

    private func isChosen(_ option: SelectOption) -> Bool {
        switch row.cells[column.id] {
        case .select(let id)?: id == option.id
        case .multiSelect(let ids)?: ids.contains(option.id)
        default: false
        }
    }

    var body: some View {
        FlooDesignFloatingPanelSurface {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                TextField(String(localized: "Set \(column.name)"), text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(submit)
                    .padding(.horizontal, Tokens.Space.sm)
                    .frame(minHeight: Metrics.fieldHeight)
                FlooDesignDivider()
                ForEach(shown, id: \.id) { option in
                    Button {
                        pick(option.id)
                    } label: {
                        HStack(spacing: Tokens.Space.sm) {
                            if isMulti {
                                Image(systemName: isChosen(option) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: Tokens.Icon.standard))
                                    .foregroundStyle(isChosen(option) ? Tokens.ColorRole.Content.primary : Tokens.ColorRole.Content.tertiary)
                            }
                            DocChip(option, in: options)
                            Spacer(minLength: 0)
                            if !isMulti, isChosen(option) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: Tokens.Icon.compact, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, Tokens.Space.sm)
                        .frame(minHeight: Metrics.fieldHeight + 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)))
                    .contextMenu {
                        Button(String(localized: "Delete Option"), systemImage: "trash", role: .destructive) {
                            controller.deleteOption(option.id, in: column.id, of: block)
                        }
                    }
                }
                if !query.isEmpty, !options.contains(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
                    Button(action: submit) {
                        Label(String(localized: "Create “\(query)”"), systemImage: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Tokens.ColorRole.Content.secondary)
                            .padding(.horizontal, Tokens.Space.sm)
                            .frame(maxWidth: .infinity, minHeight: Metrics.fieldHeight, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)))
                }
            }
            .frame(width: 260)
        }
        .onAppear { Task { @MainActor in focused = true } }
    }

    private func pick(_ option: OptionID) {
        controller.toggle(option, row: row.id, column: column.id, in: block)
        text = ""
        if !isMulti { controller.close(.options(row: row.id, column: column.id), in: block) }
    }

    /// Return: the option typed (an existing one by its name, else a new one).
    private func submit() {
        guard !query.isEmpty else { return }
        if let found = options.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            pick(found.id)
        } else if let added = controller.addOption(query, to: column.id, in: block) {
            pick(added)
        }
    }
}

/// Craft's Add Option (a kanban's new column), or one to rename and recolour.
struct DocOptionPanel: View {
    let snapshot: DocCollectionSnapshot
    let column: ColumnID
    let option: SelectOption?
    let controller: DocCollectionController
    @State private var name = ""
    @State private var color = DocOptionColor.offered[0]
    @FocusState private var focused: Bool

    private var block: DocBlockID { snapshot.block }
    private var field: Column? { snapshot.database.columns.first { $0.id == column } }
    private var kind: DocCollectionPanel.Kind { option.map { .editOption($0.id) } ?? .addOption(column) }

    var body: some View {
        DocPanelFrame(title: option == nil ? String(localized: "Add Option to \(field?.name ?? "")") : String(localized: "Edit Option"), close: close) {
            TextField(String(localized: "Name"), text: $name)
                .textFieldStyle(FlooDesignTextFieldStyle())
                .focused($focused)
                .onSubmit(save)
            HStack(spacing: Tokens.Space.xs + 2) {
                ForEach(DocOptionColor.offered, id: \.self) { token in
                    Button {
                        color = token
                    } label: {
                        FlooDesignSwatch(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous),
                                         fill: DocOptionColor.color(token), isOn: color == token)
                            .frame(width: Metrics.swatch, height: Metrics.swatch)
                    }
                    .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)))
                    .help(token)
                    .accessibilityLabel(token)
                }
            }
            FlooDesignDivider()
            DocPanelButtons(title: option == nil ? String(localized: "Add") : String(localized: "Save"),
                            enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty, cancel: close, save: save)
        }
        .onAppear {
            if let option, let field {
                name = option.name
                color = DocOptionColor.token(option, in: DocFieldText.options(field))
            } else if let field {
                let used = Set(DocFieldText.options(field).map { DocOptionColor.token($0, in: DocFieldText.options(field)) })
                color = DocOptionColor.offered.first { !used.contains($0) } ?? DocOptionColor.offered[0]
            }
            Task { @MainActor in focused = true }
        }
    }

    private func close() { controller.close(kind, in: block) }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let option {
            controller.updateOption(option.id, name: name, color: color, in: column, of: block)
        } else {
            controller.addOption(name, color: color, to: column, in: block)
        }
        close()
    }
}
