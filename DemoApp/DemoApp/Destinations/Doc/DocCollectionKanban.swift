//
//  DocCollectionKanban.swift
//  DemoApp
//
//  A collection's kanban view (Craft's): a column per option of the grouping select,
//  tinted with its colour, the records the view shows as cards (the title, the view's
//  other fields as chips).
//  - a column's head: its option and how many; on the pointer over it, … (rename or
//    recolour the option, delete it) and + (a new card at the top);
//  - a card drags to another column or place; its title takes typing on a click; on the
//    pointer over it, an arrow opens the record whole;
//  - + under a column adds a card at its end, + after the columns a new option (a column).
//

import SwiftUI
import DocKit
import FlooDesign

private typealias Metrics = DocCollectionMetrics

struct DocCollectionKanban: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let group: ColumnID
    let controller: DocCollectionController
    @State private var hoveringAdd = false

    private var block: DocBlockID { snapshot.block }
    private var column: Column? { snapshot.database.columns.first { $0.id == group } }
    private var options: [SelectOption] { column.map(DocFieldText.options) ?? [] }

    var body: some View {
        let rows = controller.rows(snapshot, view)
        let lanes = Dictionary(grouping: rows) { row -> OptionID? in
            let value = DocCollectionController.option(of: row, in: group)
            return options.contains { $0.id == value } ? value : nil
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Metrics.columnGap) {
                // Records with no option in a column of their own, first, when there are any.
                if let loose = lanes[nil], !loose.isEmpty {
                    lane(nil, loose)
                }
                ForEach(options, id: \.id) { option in
                    lane(option, lanes[option.id] ?? [])
                }
                if controller.isEditable {
                    addGroup
                }
            }
        }
    }

    private func lane(_ option: SelectOption?, _ records: [Row]) -> some View {
        DocKanbanLane(snapshot: snapshot, view: view, group: group, option: option, options: options, records: records,
                      controller: controller)
    }

    private var addGroup: some View {
        Button {
            controller.show(.addOption(group), in: block)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: FlooDesignTokens.Icon.compact, weight: .medium))
                .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                .frame(width: Metrics.columnHead, height: Metrics.columnHead)
        }
        .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)))
        .help(String(localized: "Add New Group"))
        .accessibilityLabel(String(localized: "Add New Group"))
        .flooDesignAnchoredPanel(isPresented: controller.isShowing(.addOption(group), in: block),
                                 onDismiss: { controller.close(.addOption(group), in: block) }) {
            DocOptionPanel(snapshot: snapshot, column: group, option: nil, controller: controller)
        }
    }
}

/// One column of a kanban: its option and how many, its cards, + for a new card.
private struct DocKanbanLane: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let group: ColumnID
    let option: SelectOption?
    let options: [SelectOption]
    let records: [Row]
    let controller: DocCollectionController
    @State private var hovering = false
    @State private var targeted = false

    private var block: DocBlockID { snapshot.block }

    private var tint: Color {
        option.map { DocOptionColor.color(DocOptionColor.token($0, in: options)) } ?? .secondary
    }

    /// The head's buttons: over the column on a Mac, always on a phone.
    private var showsActions: Bool { controller.isEditable && (hovering || !FlooDesignTokens.Platform.isPointer) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardGap) {
            head
            ForEach(records, id: \.id) { row in
                DocKanbanCard(snapshot: snapshot, view: view, row: row, controller: controller)
                    .draggable(row.id.description)
                    .dropDestination(for: String.self) { items, _ in
                        drop(items, before: row.id)
                    }
            }
            if controller.isEditable {
                Button {
                    controller.addRecord(to: block, in: (group, option?.id))
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

    private var head: some View {
        HStack(spacing: FlooDesignTokens.Space.sm) {
            Group {
                if let option {
                    DocChip(option, in: options)
                } else {
                    DocChip(text: String(localized: "No Value"))
                }
            }
            .flooDesignAnchoredPanel(isPresented: option.map { controller.isShowing(.editOption($0.id), in: block) } ?? false,
                                     onDismiss: { if let option { controller.close(.editOption(option.id), in: block) } }) {
                if let option {
                    DocOptionPanel(snapshot: snapshot, column: group, option: option, controller: controller)
                }
            }
            Text("\(records.count)")
                .font(.system(size: 14))
                .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
            Spacer(minLength: 0)
            if let option {
                Menu {
                    Button(String(localized: "Edit Group"), systemImage: "pencil") { controller.show(.editOption(option.id), in: block) }
                    Button(String(localized: "Delete Group"), systemImage: "trash", role: .destructive) {
                        controller.deleteOption(option.id, in: group, of: block)
                    }
                } label: {
                    headIcon("ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: FlooDesignTokens.Radius.xs, style: .continuous)))
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
                .accessibilityLabel(String(localized: "Group Options"))
            }
            Button {
                controller.addRecord(to: block, in: (group, option?.id), atTop: true)
            } label: {
                headIcon("plus")
            }
            .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: FlooDesignTokens.Radius.xs, style: .continuous)))
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .accessibilityLabel(String(localized: "New Item"))
        }
        .frame(height: Metrics.columnHead - Metrics.columnInset)
    }

    private func headIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: FlooDesignTokens.Icon.compact, weight: .medium))
            .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
            .frame(width: 24, height: 24)
    }

    private func drop(_ items: [String], before: RowID?) -> Bool {
        guard let item = items.first, let row = snapshot.database.rows.first(where: { $0.id.description == item }) else { return false }
        controller.move(row.id, to: option?.id, groupedBy: group, before: before, in: block)
        return true
    }
}

/// A record as a card: its title (typed in place), then the view's other fields as chips.
private struct DocKanbanCard: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let row: Row
    let controller: DocCollectionController
    @State private var title = ""
    @State private var editing = false
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var titleColumn: Column? { DocCollectionController.titleColumn(of: snapshot.database) }

    private var fields: [Column] {
        DocCollectionController.fields(view, of: snapshot.database).filter { $0.id != titleColumn?.id && row.cells[$0.id] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlooDesignTokens.Space.sm) {
            // Room at the title's end for the arrow, there or not.
            titleView
                .padding(.trailing, Metrics.openButton + FlooDesignTokens.Space.xs)
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
        // The arrow over the card's corner, by the title's first line: it moves nothing.
        .overlay(alignment: .topTrailing) {
            if !editing, hovering || !FlooDesignTokens.Platform.isPointer || controller.isShowing(.record(row.id), in: snapshot.block) {
                DocOpenRecordButton(snapshot: snapshot, row: row, controller: controller)
                    .padding(.top, Metrics.cardInset - 2)
                    .padding(.trailing, Metrics.cardInset - FlooDesignTokens.Space.xs)
            }
        }
        .background(FlooDesignTokens.ColorRole.Surface.canvas, in: RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
            .strokeBorder(editing ? FlooDesignTokens.ColorRole.Accent.primary : FlooDesignTokens.Border.subtle,
                          lineWidth: editing ? Metrics.focusWidth : FlooDesignTokens.Border.standard))
        .onHover { hovering = $0 }
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
                DocChip(option, in: options)
            }
        case (.multiSelect(let options), .multiSelect(let ids)?):
            ForEach(options.filter { ids.contains($0.id) }, id: \.id) { option in
                DocChip(option, in: options)
            }
        case (.checkbox, .checkbox(let on)?):
            DocChip(text: column.name, systemImage: on ? "checkmark.square.fill" : "square")
        default:
            DocChip(text: DocFieldText.text(value, in: column))
        }
    }
}
