//
//  DocPages.swift
//  DemoApp
//
//  Pages (Craft's): a page block opens a document of its own, and the window goes into
//  it (pushed on the system's navigation stack; its back button and swipe come out). Each page is its own DocKit document
//  with its own undo history (a page opened again is as it was left). A page's title is
//  its first heading, edited there; the block in the page above keeps a copy of it and a
//  preview of what follows, brought up to date (one undo step there) when the page is left.
//  - a page block (Craft's Page style): a small sheet with lines, the title, the preview
//    under it; a click goes in;
//  - the navigation bar in a page: its title, the way to it as the subtitle;
//  - a collection's record opens as a page too (Craft's arrow): the document with the
//    record's id, its title the record's title, its fields under the title, then what's
//    written about it.
//

import SwiftUI
import DocKit
import FlooDesign

enum DocPageMetrics {
    /// The sheet's height and a little: the title and preview stand beside it.
    static let rowHeight: CGFloat = 44
    /// Craft's page block: a sheet taller than wide, its lines in the top corner.
    static let sheet = CGSize(width: 28, height: 36)
    static let sheetCorner: CGFloat = 5
    static let sheetInset: CGFloat = 6
    static let sheetLines: [CGFloat] = [14, 10, 12]
    static let lineHeight: CGFloat = 2
    static let lineGap: CGFloat = 3
    static let gap = FlooDesignTokens.Space.md
}

/// One open page: its document, its editor, and the block in the page above that opened it.
@MainActor
final class DocOpenPage {
    let demo: DocDemo
    let editor: DocEditor
    /// Where it was opened from last: a page block moves (Group, a cut and paste), and its
    /// page goes back out to where it is now.
    var parent: (page: DocOpenPage, block: DocBlockID)?
    /// Shown once: its launch options ran and its scroll was set (DocPageView).
    var appeared = false

    var id: DocID { demo.doc.id }

    init(demo: DocDemo, parent: (page: DocOpenPage, block: DocBlockID)? = nil) {
        self.demo = demo
        self.editor = DocEditor(demo: demo)
        self.parent = parent
    }

    /// The pages it's in, the first one first.
    var ancestors: [DocOpenPage] {
        var pages: [DocOpenPage] = []
        var above = parent?.page
        while let page = above {
            pages.insert(page, at: 0)
            above = page.parent?.page
        }
        return pages
    }

    /// A record's page: its collection, and its record.
    var record: DocRecordLink? { demo.record }

    /// Its title: the first heading's words, or "Untitled".
    var title: String {
        let heading = DocPage.summary(of: demo.doc).title
        return heading.isEmpty ? String(localized: "Untitled") : heading
    }
}

/// The pages open in the window: the way in from the first one to the one showing.
@MainActor
@Observable
final class DocPages {
    private(set) var path: [DocOpenPage]
    /// Pages opened before, kept as they were left.
    @ObservationIgnored private var opened: [DocID: DocOpenPage] = [:]
    /// The app's launch options (-docOpenPage and the rest) run once a process, on the
    /// first page of the first window that shows a document: going to the documents again
    /// (a phone's sidebar makes this window anew) doesn't run them again.
    static var ranLaunchOptions = false

    init(root: DocDemo) {
        let page = DocOpenPage(demo: root)
        path = [page]
        opened[page.id] = page
    }

    var current: DocOpenPage { path[path.count - 1] }
    var root: DocOpenPage { path[0] }

    /// The navigation stack's path: the pages past the first. The system shortening it
    /// (back, a swipe) leaves those pages.
    var stack: [DocID] {
        get { path.dropFirst().map(\.id) }
        set {
            guard newValue.count < path.count - 1, Array(stack.prefix(newValue.count)) == newValue else { return }
            back(to: newValue.count)
        }
    }

    /// A page opened in this window.
    func page(_ id: DocID) -> DocOpenPage? { opened[id] }

    /// The first page alone again (Reset): the pages opened before are gone.
    func reset() {
        path = [root]
        opened = [root.id: root]
        written = []
    }

    /// Goes into the page a block of the current page opens: as it was left (this run or
    /// before, DocStore), as the corpus has it, or new, its title as its first heading and
    /// an empty line under it.
    func open(_ block: DocBlockID) {
        DocTiming.begin("open page")
        let from = current
        guard case .page(let page)? = from.demo.doc.block(block)?.kind else { return }
        let opening: DocOpenPage
        if let known = opened[page.doc] {
            known.parent = (from, block)
            opening = known
        } else {
            let doc = DocStore.shared.load(page.doc) ?? DocDemoCorpus.page(page.doc) ?? Doc(id: page.doc, blocks: [
                DocBlock(id: .generate(), kind: .heading(level: 1), text: DocText(string: page.title)),
                DocBlock(id: .generate(), kind: .paragraph),
            ])
            opening = DocOpenPage(demo: DocDemo(doc: doc), parent: (from, block))
            opened[page.doc] = opening
        }
        from.editor.blocks.clear()
        DocTiming.mark("page made")
        path.append(opening)
    }

    /// Goes into a record's page (Craft's arrow on a record): the document with the record's
    /// id, as it was left (this run or before; its title brought up to the record's), or
    /// new: the record's title as its first heading, an empty line under it.
    func openRecord(_ row: RowID, in block: DocBlockID) {
        let from = current
        let link = DocRecordLink(parent: from.demo, editor: from.editor, block: block, row: row)
        guard let title = link.title else { return }
        let id = DocID(rawValue: row.rawValue)
        let opening: DocOpenPage
        if let known = opened[id] {
            // The collection may have moved since (Group, a cut and paste).
            known.parent = (from, block)
            known.demo.record = link
            opening = known
        } else {
            let doc = DocStore.shared.load(id) ?? Doc(id: id, blocks: [
                DocBlock(id: .generate(), kind: .heading(level: 1), text: DocText(string: title)),
                DocBlock(id: .generate(), kind: .paragraph),
            ])
            opening = DocOpenPage(demo: DocDemo(doc: doc, record: link), parent: (from, block))
            opened[id] = opening
        }
        // Its title is the record's as it is now.
        if let heading = opening.demo.doc.blocks.first, case .heading = heading.kind, heading.text.string != title {
            opening.demo.edit([.deleteText(block: heading.id, range: 0..<heading.text.length, removed: heading.text),
                               .insertText(block: heading.id, at: 0, text: DocText(string: title))], before: nil, after: nil)
        }
        from.editor.blocks.clear()
        path.append(opening)
    }

    /// The records whose pages have something written in them past the title, as they
    /// were left.
    private(set) var written: Set<RowID> = []

    /// Whether a record's page has something written in it (its title cell shows a page):
    /// as it was left, this run or before (DocStore).
    func recordHasPage(_ row: RowID) -> Bool {
        let id = DocID(rawValue: row.rawValue)
        guard opened[id] == nil else { return written.contains(row) }
        return DocStore.shared.load(id).map(Self.isWritten) ?? false
    }

    /// A duplicated record's page: a copy of the original's as it was left (none if it
    /// never was: the copy's is new too).
    func copyRecordPage(_ row: RowID, to copy: RowID) {
        DocStore.shared.copyPage(DocID(rawValue: row.rawValue), as: DocID(rawValue: copy.rawValue))
        if written.contains(row) { written.insert(copy) }
    }

    private static func isWritten(_ doc: Doc) -> Bool {
        doc.blocks.dropFirst().contains { !$0.text.isEmpty || !$0.kind.carriesText }
    }

    /// Back out to the page at `index` of the path (the one above, by default); each page
    /// left brings its block's title and preview up to date (a record's page, its record's
    /// title).
    func back(to index: Int? = nil) {
        let target = index ?? path.count - 2
        guard target >= 0, target < path.count - 1 else { return }
        for page in path[(target + 1)...].reversed() {
            if let record = page.record {
                record.setTitle(DocPage.summary(of: page.demo.doc).title)
                if Self.isWritten(page.demo.doc) { written.insert(record.row) } else { written.remove(record.row) }
            } else if let parent = page.parent {
                parent.page.demo.setPageSummary(of: parent.block, from: page.demo.doc)
            }
        }
        path.removeSubrange((target + 1)...)
    }
}

/// A page block (Craft's Page style): a small sheet, the title, and under it the words
/// the page starts with. It goes in as a card opens (DocBlockController): a tap on a
/// phone (a long press selects it), a double click on the Mac (a click selects it).
struct DocPageRowView: View {
    let page: DocPage

    var body: some View {
        HStack(spacing: DocPageMetrics.gap) {
            DocPageSheet()
            VStack(alignment: .leading, spacing: 0) {
                Text(page.title.isEmpty ? String(localized: "Untitled") : page.title)
                    .font(Font(DocTableCellField.bodyFont))
                    .fontWeight(.semibold)
                    .foregroundStyle(page.title.isEmpty ? FlooDesignTokens.ColorRole.Content.tertiary : FlooDesignTokens.ColorRole.Content.primary)
                if !page.preview.isEmpty {
                    Text(page.preview)
                        .font(Font(DocTableCellField.bodyFont))
                        .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(minHeight: DocPageMetrics.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(page.title)
        .accessibilityValue(page.preview)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "Opens the page"))
    }
}

/// A page's icon: a sheet with a few lines of writing at its top.
struct DocPageSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DocPageMetrics.lineGap) {
            ForEach(Array(DocPageMetrics.sheetLines.enumerated()), id: \.offset) { _, width in
                Capsule()
                    .fill(FlooDesignTokens.ColorRole.Content.tertiary)
                    .frame(width: width, height: DocPageMetrics.lineHeight)
            }
        }
        .padding(DocPageMetrics.sheetInset)
        .frame(width: DocPageMetrics.sheet.width, height: DocPageMetrics.sheet.height, alignment: .topLeading)
        .background(FlooDesignTokens.ColorRole.Surface.control,
                    in: RoundedRectangle(cornerRadius: DocPageMetrics.sheetCorner, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A page's title in the navigation bar (Craft's): its title, and under it the pages it's
/// in, each a step back out to it.
struct DocPageTitle: View {
    let page: DocOpenPage
    let pages: DocPages

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(page.title)
                .font(FlooDesignTokens.Typography.body.font.weight(.semibold))
            let ancestors = page.ancestors
            if !ancestors.isEmpty {
                HStack(spacing: FlooDesignTokens.Space.xxs) {
                    ForEach(Array(ancestors.enumerated()), id: \.element.id) { index, ancestor in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .imageScale(.small)
                        }
                        Button(ancestor.title) { pages.back(to: index) }
                            .buttonStyle(.plain)
                    }
                }
                .font(FlooDesignTokens.Typography.metadata.font)
                .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
            }
        }
        .lineLimit(1)
        // As wide as its words: the bar's leading place would squeeze it to a letter.
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
    }
}
