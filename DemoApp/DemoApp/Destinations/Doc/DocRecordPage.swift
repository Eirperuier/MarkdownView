//
//  DocRecordPage.swift
//  DemoApp
//
//  A collection's record as a page (Craft's): its title is the record's title, its fields
//  show under it — a name on the left, the value to edit on the right, then Add Field —
//  and a line, then what's written about the record (the page's own blocks).
//  The fields are the collection's, edited where they live (the document above); this
//  page has a collection controller of its own over that document, so its panels are
//  apart from the table's.
//

import FlooUIKit
import SwiftUI
import DocKit
import FlooDesign

private typealias Metrics = DocCollectionMetrics

/// A record's page's way to its record: the document the collection is in, the
/// collection, the record.
@MainActor
final class DocRecordLink {
    let parent: DocDemo
    let block: DocBlockID
    let row: RowID
    /// The collection's controller for this page (its own panels, the document above's edits).
    let controller: DocCollectionController

    init(parent: DocDemo, editor: DocEditor, block: DocBlockID, row: RowID) {
        self.parent = parent
        self.block = block
        self.row = row
        controller = DocCollectionController(demo: parent, editor: editor)
    }

    /// The collection as the document above has it now.
    var snapshot: DocCollectionSnapshot? {
        guard case .collection(let collection)? = parent.doc.block(block)?.kind,
              let database = parent.doc.databases[collection.database] else { return nil }
        return DocCollectionSnapshot(block: block, collection: collection, database: database)
    }

    var record: Row? { snapshot?.database.rows.first { $0.id == row } }

    /// The record's title (nil: the record is gone).
    var title: String? {
        guard let snapshot, let record else { return nil }
        return DocCollectionController.titleColumn(of: snapshot.database).map { DocFieldText.text(record.cells[$0.id], in: $0) } ?? ""
    }

    /// The fields under the title: all but the title, in the collection's order.
    var fields: [Column] {
        guard let snapshot else { return [] }
        let title = DocCollectionController.titleColumn(of: snapshot.database)
        let ordered = snapshot.collection.currentView?.ordered(snapshot.database.columns) ?? snapshot.database.columns
        return ordered.filter { $0.id != title?.id }
    }

    /// How many fields show (nil: the record is gone).
    var fieldCount: Int? { record == nil ? nil : fields.count }

    /// The page's title, as the record's title: one undo step in the document above.
    func setTitle(_ title: String) {
        guard let snapshot, let column = DocCollectionController.titleColumn(of: snapshot.database), self.title != title else { return }
        controller.setText(title, row: row, column: column.id, in: block)
    }
}

/// A record's fields on its page: each a row of its name and its value, Add Field, a line.
struct DocRecordFields: View {
    let link: DocRecordLink
    /// The page: its rows again when fields come or go.
    let page: DocDemo

    private var controller: DocCollectionController { link.controller }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot = link.snapshot, let record = link.record {
                ForEach(link.fields, id: \.id) { column in
                    HStack(spacing: DocTokens.Space.md) {
                        Label(column.name, systemImage: DocFieldText.symbol(column))
                            .font(.system(size: 15))
                            .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        DocCollectionCell(snapshot: snapshot, row: record, column: column, controller: controller, compact: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: Metrics.rowHeight)
                }
                if controller.isEditable {
                    Button {
                        controller.show(.addField, in: link.block)
                    } label: {
                        Label(String(localized: "Add Field"), systemImage: "plus")
                            .font(.system(size: 15))
                            .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .docPanel(isPresented: controller.isShowing(.addField, in: link.block),
                                             alignment: .leading,
                                             onDismiss: { controller.close(.addField, in: link.block) }) {
                        DocFieldPanel(snapshot: snapshot, column: nil, controller: controller)
                    }
                }
            }
            FlooDividerLine()
        }
        .onChange(of: link.fieldCount) { page.republish() }
    }
}

/// A record with a page written, before its title in the collection (Craft's): the page's sheet, small.
struct DocRecordPageMark: View {
    var body: some View {
        DocPageSheet()
            .scaleEffect(0.5, anchor: .topLeading)
            .frame(width: DocPageMetrics.sheet.width / 2, height: DocPageMetrics.sheet.height / 2, alignment: .topLeading)
    }
}
