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
//  - a card drags to another column or place, a line where it will land; its title takes
//    typing on a click; on the pointer over it, an arrow opens the record whole; its
//    right-click menu edits its fields, duplicates or deletes it (Craft's);
//  - a column's right-click menu adds a card, opens the grouping, hides the group;
//  - + under a column adds a card at its end, + after the columns a new option (a column).
//

import FlooUIKit
import SwiftUI
import UniformTypeIdentifiers
import DocKit

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
        // Scrolls out to the page's edges, as a plain table does (MarkdownTable).
        .scrollClipDisabled()
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
                .font(.system(size: DocTokens.Icon.compact, weight: .medium))
                .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                .frame(width: Metrics.columnHead, height: Metrics.columnHead)
        }
        .buttonStyle(.flooContent(in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)))
        .help(String(localized: "Add New Group"))
        .accessibilityLabel(String(localized: "Add New Group"))
        .docPanel(isPresented: controller.isShowing(.addOption(group), in: block),
                  onDismiss: { controller.close(.addOption(group), in: block) },
                  page: { DocOptionPage(snapshot: snapshot, column: group, option: nil, controller: controller).inNavigation() })
    }
}

/// One column of a kanban: its group and how many, its cards, + for a new card.
private struct DocKanbanLane: View {
    let snapshot: DocCollectionSnapshot
    let view: CollectionView
    let column: Column
    let group: CollectionGroup
    let controller: DocCollectionController
    let drop: @MainActor (String, RowID?) -> Bool
    @State private var hovering = false
    /// Where a card dragged over the column will land, while one is.
    @State private var landing: DocKanbanLanding?
    /// The cards' frames and the head's foot, in the column's space: where a drag lands.
    @State private var frames: [RowID: CGRect] = [:]
    @State private var headFoot: CGFloat = 0

    private static let space = "kanban-lane"

    private var block: DocBlockID { snapshot.block }
    private var options: [SelectOption] { DocFieldText.options(column) }
    private var option: SelectOption? { options.first { $0.id.description == group.key } }

    private var tint: Color {
        option.map { DocOptionColor.color(DocOptionColor.token($0, in: options)) } ?? .secondary
    }

    /// The head's buttons: over the column on a Mac, always on a phone.
    private var showsActions: Bool { controller.isEditable && (hovering || !DocTokens.Platform.isPointer) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardGap) {
            head
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).maxY } action: { headFoot = $0 }
            ForEach(group.rows, id: \.id) { row in
                DocKanbanCard(snapshot: snapshot, view: view, row: row, controller: controller)
                    .draggable("\(row.id.description) \(group.key)")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[row.id] = $0 }
            }
            if controller.isEditable {
                Button {
                    controller.addRecord(to: block, in: (column.id, group.value))
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: DocTokens.Icon.compact, weight: .medium))
                        .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.addHeight)
                        .overlay(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                            .strokeBorder(DocTokens.Border.subtle, lineWidth: DocTokens.Border.standard))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.flooContent(in: RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)))
                .accessibilityLabel(String(localized: "New Item"))
            }
        }
        .padding(Metrics.columnInset)
        .frame(width: Metrics.columnWidth, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .background(tint.opacity(landing != nil ? 0.2 : 0.1), in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay(alignment: .topLeading) { line }
        .onHover { hovering = $0 }
        // A card's own menu wins over the column's (the smaller catcher).
        .flooContextMenu(isEnabled: controller.isEditable) { menu }
        // The whole column takes the drop, its cards too: where between them follows the pointer.
        .onDrop(of: [.text], delegate: DocKanbanDrop(landing: $landing, place: place, drop: drop))
    }

    /// The column's right-click menu (Craft's): a new card at its end, the grouping's
    /// panel, leaving the group out.
    private var menu: [FlooMenuSection] {
        [
            .init([.action(String(localized: "Add Item"), symbol: "plus") {
                controller.addRecord(to: block, in: (column.id, group.value))
            }]),
            .init([
                .action(String(localized: "Edit Grouping"), symbol: "rectangle.3.group") { controller.show(.view, in: block) },
                .action(String(localized: "Hide Group"), symbol: "eye.slash") { controller.hide(group: group.key, in: view.id, of: block) },
            ]),
        ]
    }

    /// Before the first card whose middle is below `y`, else after the last.
    private func place(_ y: CGFloat) -> DocKanbanLanding {
        group.rows.first { (frames[$0.id]?.midY ?? .infinity) > y }.map { .before($0.id) } ?? .end
    }

    /// Where a dragged card will land: a line in the accent between the cards (the
    /// document's drop line).
    @ViewBuilder
    private var line: some View {
        if let landing {
            let half = Metrics.cardGap / 2
            let y: CGFloat = switch landing {
            case .before(let id): (frames[id]?.minY ?? headFoot + Metrics.cardGap) - half
            case .end: group.rows.last.flatMap { frames[$0.id] }.map { $0.maxY + half } ?? headFoot + half
            }
            let indicator = DocTokens.Component.DropIndicator.self
            Capsule()
                .fill(DocTokens.ColorRole.Accent.primary)
                .frame(width: Metrics.columnWidth - 2 * Metrics.columnInset + 2 * indicator.overhang, height: indicator.thickness)
                .offset(x: Metrics.columnInset - indicator.overhang, y: y - indicator.thickness / 2)
                .allowsHitTesting(false)
        }
    }

    private var head: some View {
        HStack(spacing: DocTokens.Space.sm) {
            DocGroupLabel(column: column, group: group)
                .docPanel(isPresented: option.map { controller.isShowing(.editOption($0.id), in: block) } ?? false,
                          onDismiss: { if let option { controller.close(.editOption(option.id), in: block) } },
                          page: { DocOptionPage(snapshot: snapshot, column: column.id, option: option, controller: controller).inNavigation() })
            Text("\(group.rows.count)")
                .font(.system(size: 14))
                .foregroundStyle(DocTokens.ColorRole.Content.secondary)
            Spacer(minLength: 0)
            if let option {
                FlooLabeledMenu(sections: {
                    [.init([
                        .action(String(localized: "Edit Group"), symbol: "pencil") { controller.show(.editOption(option.id), in: block) },
                        .action(String(localized: "Delete Group"), symbol: "trash", role: .destructive) {
                            controller.deleteOption(option.id, in: column.id, of: block)
                        },
                    ])]
                }) {
                    headIcon("ellipsis")
                }
                .buttonStyle(.flooContent(in: RoundedRectangle(cornerRadius: DocTokens.Radius.xs, style: .continuous)))
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
                .accessibilityLabel(String(localized: "Group Options"))
            }
            Button {
                controller.addRecord(to: block, in: (column.id, group.value), atTop: true)
            } label: {
                headIcon("plus")
            }
            .buttonStyle(.flooContent(in: RoundedRectangle(cornerRadius: DocTokens.Radius.xs, style: .continuous)))
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .accessibilityLabel(String(localized: "New Item"))
        }
        .frame(height: Metrics.columnHead - Metrics.columnInset)
    }

    private func headIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: DocTokens.Icon.compact, weight: .medium))
            .foregroundStyle(DocTokens.ColorRole.Content.secondary)
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

    private var block: DocBlockID { snapshot.block }
    private var titleColumn: Column? { DocCollectionController.titleColumn(of: snapshot.database) }

    private var fields: [Column] {
        DocCollectionController.fields(view, of: snapshot.database).filter { $0.id != titleColumn?.id && row.cells[$0.id] != nil }
    }

    /// Text that reads as words (a note, a link, a person) goes under the title whole; the
    /// short values (options, numbers, dates, a box) are chips.
    private static func reads(_ column: Column) -> Bool {
        switch column.type {
        case .text, .url, .person: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DocTokens.Space.sm) {
            // Room at the title's end for the arrow, there or not.
            HStack(alignment: .top, spacing: DocTokens.Space.sm) {
                // A record with a page written shows it before its title, as the table does.
                if controller.hasPage?(row.id) == true {
                    DocRecordPageMark()
                }
                titleView
            }
            .padding(.trailing, Metrics.openButton + DocTokens.Space.xs)
            ForEach(fields.filter(Self.reads), id: \.id) { column in
                Text(DocFieldText.text(row.cells[column.id], in: column))
                    .font(.system(size: 13))
                    .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            let chips = fields.filter { !Self.reads($0) }
            if !chips.isEmpty {
                DocFlow {
                    ForEach(chips, id: \.id) { column in
                        chip(column)
                    }
                }
            }
        }
        .padding(Metrics.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The arrow over the card's corner, by the title's first line: it moves nothing.
        .overlay(alignment: .topTrailing) {
            if !focused, hovering || !DocTokens.Platform.isPointer {
                DocOpenRecordButton(snapshot: snapshot, row: row, controller: controller)
                    .padding(.top, Metrics.cardInset - 2)
                    .padding(.trailing, Metrics.cardInset - DocTokens.Space.xs)
            }
        }
        .background(DocTokens.ColorRole.Surface.canvas, in: RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
        // Outlined while its title has the caret: the focus, not the click asking for it,
        // so a click whose focus went elsewhere leaves no outline behind.
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
            .strokeBorder(focused ? DocTokens.ColorRole.Accent.primary : DocTokens.Border.subtle,
                          lineWidth: focused ? Metrics.focusWidth : DocTokens.Border.standard))
        .onHover { hovering = $0 }
        .flooContextMenu(isEnabled: controller.isEditable) { place.menu?.rows?() ?? [] }
        .docPanel(isPresented: fieldPanel != nil,
                  onDismiss: { if let fieldPanel { controller.close(fieldPanel, in: block) } },
                  page: { fieldPanelPage },
                  update: { page in
            guard let options = page as? DocOptionsPage, case .options(_, let id)? = fieldPanel,
                  let column = snapshot.database.columns.first(where: { $0.id == id }) else { return }
            options.update(row: row, column: column)
        })
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
                .docEditingPlace(place, isFocused: focused, editor: controller.editor)
        } else {
            Text(title.isEmpty ? String(localized: "Title") : title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(title.isEmpty ? DocTokens.ColorRole.Content.tertiary : DocTokens.ColorRole.Content.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if controller.isEditable, titleColumn != nil { startEditing() } }
        }
    }

    /// Craft's card menu: a field to edit (or a new one), a copy, gone.
    /// The card's title as a place: its menu the card's right-click rows.
    private var place: DocFieldPlace {
        DocFieldPlace(field: [block, row.id, "card"] as [AnyHashable], block: block,
                      menu: DocPlaceMenu(title: String(localized: "Card Actions"), symbol: "ellipsis.circle", opens: .rows { menu }))
    }

    private var menu: [FlooMenuSection] {
        let others = snapshot.database.columns.filter { $0.id != titleColumn?.id }
        let properties = FlooMenuItem.submenu(String(localized: "Edit Properties"), symbol: "slider.horizontal.3", [
            .init(others.map { column in
                .action(column.name, symbol: DocFieldText.symbol(column.type)) { edit(column) }
            }),
            .init([.action(String(localized: "Add Field"), symbol: "plus") { controller.show(.cardField(row.id), in: block) }]),
        ])
        return [
            .init([properties]),
            .init([
                .action(String(localized: "Duplicate Item"), symbol: "plus.square.on.square") { controller.duplicate(row: row.id, in: block) },
                .action(String(localized: "Delete Item"), symbol: "trash", role: .destructive) { controller.delete(row.id, in: block) },
            ]),
        ]
    }

    /// A field from the menu: its options, its calendar, a field to type in; a checkbox
    /// turns over.
    private func edit(_ column: Column) {
        switch column.type {
        case .select, .multiSelect: controller.show(.options(row: row.id, column: column.id), in: block)
        case .date: controller.show(.date(row: row.id, column: column.id), in: block)
        case .checkbox:
            let on = row.cells[column.id] == .checkbox(value: true)
            controller.set(on ? nil : .checkbox(value: true), row: row.id, column: column.id, in: block)
        default: controller.show(.property(row: row.id, column: column.id), in: block)
        }
    }

    /// The panel the card's menu opened, if one is showing.
    private var fieldPanel: DocCollectionPanel.Kind? {
        guard let panel = controller.panel, panel.block == block else { return nil }
        switch panel.kind {
        case .options(row.id, _), .date(row.id, _), .property(row.id, _), .cardField(row.id): return panel.kind
        default: return nil
        }
    }

    private var fieldPanelPage: UIViewController {
        let field = { (id: ColumnID) in snapshot.database.columns.first { $0.id == id } }
        switch fieldPanel {
        case .options(_, let id)?:
            if let column = field(id) { return DocOptionsPage(row: row, column: column, block: block, controller: controller) }
        case .date(_, let id)?:
            if let column = field(id) { return DocDatePage(row: row, column: column, block: block, controller: controller) }
        case .property(_, let id)?:
            if let column = field(id) { return DocPropertyPage(row: row, column: column, block: block, controller: controller) }
        case .cardField?:
            return DocFieldPage(column: nil, block: block, controller: controller, panel: .cardField(row.id)).inNavigation()
        default:
            break
        }
        return UIViewController()
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

/// Where a card dragged over a column will land.
private enum DocKanbanLanding: Equatable {
    case before(RowID)
    case end
}

/// A column's drop: the landing follows the pointer over the column and its cards; a card
/// dropped there moves (its "row key" text, see DocCollectionKanban.drop).
private struct DocKanbanDrop: DropDelegate {
    @Binding var landing: DocKanbanLanding?
    let place: (CGFloat) -> DocKanbanLanding
    let drop: @MainActor (String, RowID?) -> Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let landing = place(info.location.y)
        if self.landing != landing { self.landing = landing }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { landing = nil }

    func performDrop(info: DropInfo) -> Bool {
        let before: RowID? = if case .before(let id) = place(info.location.y) { id } else { nil }
        landing = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let drop = drop
        _ = provider.loadTransferable(type: String.self) { result in
            guard case .success(let item) = result else { return }
            Task { @MainActor in _ = drop(item, before) }
        }
        return true
    }
}
