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
//  - the navigation bar in a page: its title, the way to it as the subtitle.
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
    let parent: (page: DocOpenPage, block: DocBlockID)?
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
    /// The window's launch options run once, on its first page.
    @ObservationIgnored var ranLaunchOptions = false

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

    /// Goes into the page a block of the current page opens: as it was left, as the corpus
    /// has it, or new, its title as its first heading and an empty line under it.
    func open(_ block: DocBlockID) {
        DocTiming.begin("open page")
        let from = current
        guard case .page(let page)? = from.demo.doc.block(block)?.kind else { return }
        let opening: DocOpenPage
        if let known = opened[page.doc] {
            opening = known
        } else {
            let doc = DocDemoCorpus.page(page.doc) ?? Doc(id: page.doc, blocks: [
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

    /// Back out to the page at `index` of the path (the one above, by default); each page
    /// left brings its block's title and preview up to date.
    func back(to index: Int? = nil) {
        let target = index ?? path.count - 2
        guard target >= 0, target < path.count - 1 else { return }
        for page in path[(target + 1)...].reversed() {
            if let parent = page.parent {
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
        .accessibilityElement(children: .contain)
    }
}
