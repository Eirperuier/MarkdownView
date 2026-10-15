//
//  DocCollectionKanban.swift
//  DemoApp
//
//  A collection's kanban view (Craft's): a column per group of the field it's grouped by
//  (DocKit's CollectionGroups) but those its grouping leaves out, an option's tinted with
//  its colour, the records the view shows as cards (the title, the view's other fields as
//  chips).
//  - a column's head: its group and how many; on the pointer over it, … (an option's:
//    rename or recolour it, delete it) and + (a new card at the top);
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

    private var block: DocBlockID { snapshot.block }
    private var column: Column? { snapshot.database.columns.first { $0.id == group } }

    var body: some View {
        let groups = DocCollectionController.lanes(view, of: controller.rows(snapshot, view), in: snapshot.database)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Metrics.columnGap) {
                if let column {
                    ForEach(groups, id: \.key) { lane in
                        DocKanbanLane(snapshot: snapshot, view: view, column: column, group: lane, controller: controller) { item, before in
                            drop(item, into: lane, before: before, among: groups)
                        }
                    }
                    if controller.isEditable, DocFieldText.hasOptions(column) {
                        addGroup
                    }
                }
            }
        }
    }

    /// A card ("row key", the column it left) dropped in `lane`.
    private func drop(_ item: String, into lane: CollectionGroup, before: RowID?, among groups: [CollectionGroup]) -> Bool {
        let parts = item.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let row = snapshot.database.rows.first(where: { $0.id.description == parts[0] }) else { return false }
        let source = groups.first { $0.key == (parts.count > 1 ? parts[1] : "") }?.value
        controller.move(row.id, from: source, to: lane.value, groupedBy: group, before: before, in: block)
        return true
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

/// One column of a kanban: its group and how many, its cards, + for a new card.
private struct DocKanbanLane: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let column: Column
    let group: CollectionGroup
    let controller: DocCollectionController
    let drop: (String, RowID?) -> Bool
    @State private var hovering = false
    @State private var targeted = false

    private var block: DocBlockID { snapshot.block }
    private var options: [SelectOption] { DocFieldText.options(column) }
    private var option: SelectOption? { options.first { $0.id.description == group.key } }

    private var tint: Color {
        option.map { DocOptionColor.color(DocOptionColor.token($0, in: options)) } ?? .secondary
    }

    /// The head's buttons: over the column on a Mac, always on a phone.
    private var showsActions: Bool { controller.isEditable && (hovering || !FlooDesignTokens.Platform.isPointer) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardGap) {
            head
            ForEach(group.rows, id: \.id) { row in
                DocKanbanCard(snapshot: snapshot, view: view, row: row, controller: controller)
                    .draggable("\(row.id.description) \(group.key)")
                    .dropDestination(for: String.self) { items, _ in
                        items.first.map { drop($0, row.id) } ?? false
                    }
            }
            if controller.isEditable {
                Button {
                    controller.addRecord(to: block, in: (column.id, group.value))
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
            items.first.map { drop($0, nil) } ?? false
        } isTargeted: { targeted = $0 }
    }

    private var head: some View {
        HStack(spacing: FlooDesignTokens.Space.sm) {
            DocGroupLabel(column: column, group: group)
                .flooDesignAnchoredPanel(isPresented: option.map { controller.isShowing(.editOption($0.id), in: block) } ?? false,
                                         onDismiss: { if let option { controller.close(.editOption(option.id), in: block) } }) {
                    if let option {
                        DocOptionPanel(snapshot: snapshot, column: column.id, option: option, controller: controller)
                    }
                }
            Text("\(group.rows.count)")
                .font(.system(size: 14))
                .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
            Spacer(minLength: 0)
            if let option {
                Menu {
                    Button(String(localized: "Edit Group"), systemImage: "pencil") { controller.show(.editOption(option.id), in: block) }
                    Button(String(localized: "Delete Group"), systemImage: "trash", role: .destructive) {
                        controller.deleteOption(option.id, in: column.id, of: block)
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
                controller.addRecord(to: block, in: (column.id, group.value), atTop: true)
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
            HStack(alignment: .top, spacing: FlooDesignTokens.Space.sm) {
                // A record with a page written shows it before its title, as the table does.
                if controller.hasPage?(row.id) == true {
                    DocRecordPageMark()
                }
                titleView
            }
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
            if !editing, hovering || !FlooDesignTokens.Platform.isPointer {
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
        .flooDesignContextMenu(isEnabled: controller.isEditable) { _ in
            [.init(.rows, [.action(String(localized: "Delete"), symbol: "trash", role: .destructive) { controller.delete(row.id, in: snapshot.block) }])]
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
