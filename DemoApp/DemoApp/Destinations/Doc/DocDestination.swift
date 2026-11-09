//
//  DocDestination.swift
//  DemoApp
//
//  The documents' window: its pages on SwiftUI's navigation stack, each UIKit's
//  (DocPageController), and what its rows share: a row's block type and box, and the
//  SwiftUI row a card is drawn in.
//

import FlooUIKit
import SwiftUI
import MarkdownView
import MessagingUI
import DocKit

struct DocDestination: View {
    /// Code blocks are coloured by Highlightr, read and edited alike.
    static let highlighter = HighlightrCodeHighlighter()

    static var autoruns: Bool { UserDefaults.standard.bool(forKey: "docAgent") }

    @State private var pages: DocPages
    /// A page shown, not edited, over something else (the floo chat's): its bar closes it.
    private let shown: Bool

    /// The documents; or a document of its own, shown (a page an agent wrote).
    init(doc: Doc? = nil) {
        _pages = State(initialValue: DocPages(root: doc.map { DocDemo(doc: $0) } ?? DocDemo()))
        shown = doc != nil
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        // Pages go in and out the system's way: its back button (a long press lists the
        // pages above), its swipe back, the page's title and the way to it in its bar.
        NavigationStack(path: $pages.stack) {
            page(pages.root, shown: shown)
                .navigationDestination(for: DocID.self) { id in
                    if let page = pages.page(id) {
                        self.page(page)
                    }
                }
        }
        .focusedSceneValue(\.docBack, pages.path.count > 1 ? DocBackAction { pages.back() } : nil)
    }

    /// A page, UIKit's (DocPageController): its title the window's name too.
    private func page(_ page: DocOpenPage, shown: Bool = false) -> some View {
        DocPageHost(page: page, pages: pages, shown: shown, openURL: openURL, close: { dismiss() })
            .ignoresSafeArea()
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Back out of the page showing (the Navigation menu's Back, ⌘[).
struct DocBackAction {
    let perform: () -> Void
}

extension FocusedValues {
    @Entry var docBack: DocBackAction?
}

/// The app's Navigation menu: Back, as Craft has it.
struct DocCommands: Commands {
    @FocusedValue(\.docBack) private var back

    var body: some Commands {
        CommandMenu("Navigation") {
            Button("Back") { back?.perform() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(back == nil)
        }
    }
}

/// A row's space: its host's (the row is at the host's top left), where UIKit finds
/// what's under a point in it.
enum DocRowSpace {
    static let name = "doc-row"
}

/// How MarkdownView sets the page's blocks (a row's, and a table on a page of its own).
struct DocBlockType: ViewModifier {
    func body(content: Content) -> some View {
        content
            .codeHighlighter(DocDestination.highlighter)
            // Wide tables scroll sideways instead of squeezing their columns.
            .markdownTableScrollable()
            // The document's type, and its own spacing between blocks (not a stream block's).
            .markdownPlatformTypography(DocTypography.fonts)
            .markdownStreamBlockEdgeInsets(false)
            // Code at the text's size, monospaced (the editor uses the same font); a table's
            // cells at the page's body size (their editor's).
            .font(Font(docCodeFont), for: .codeBlock)
            .font(Font(DocTableCellField.bodyFont), for: .tableBody)
    }
}

extension DocRow {
    /// The UIKit row that shows it: a paragraph, heading, list item, caption or quote, a code
    /// or math block, a table, a link, file or image, a page block, a divider, a collection's
    /// table or kanban, a record's fields, and what the agent is writing. Nil: DocRowView
    /// shows it (a floo card or view, a collection's chart).
    @MainActor
    func uikitContent(editor: DocEditor) -> (any TiledUIKitCellContent)? {
        if isStreaming {
            return DocStreamRowContent(row: self, coordinator: editor.demo.coordinator, blocks: editor.blocks)
        }
        if let collection {
            return DocCollectionRowContent.draws(collection) ? DocCollectionRowContent(row: self, snapshot: collection, controller: editor.collections) : nil
        }
        if recordFields != nil {
            return editor.demo.record.map { DocRecordFieldsRowContent(row: self, link: $0, page: editor.demo) }
        }
        if let media {
            guard let block, run != nil, DocMediaRowContent.draws(media) else { return nil }
            return DocMediaRowContent(row: self, block: block, kind: media, blocks: editor.blocks)
        }
        if let page {
            return DocPageRowContent(row: self, page: page, blocks: editor.blocks)
        }
        if let table {
            return tree == nil ? nil : DocTableRowContent(row: self, table: table, source: sourceText, controller: editor.tables)
        }
        if let block, case .code(let language) = sourceKind {
            return DocCodeRowContent(row: self, block: block, code: sourceText, language: language, sources: editor.sources)
        }
        if let block, sourceKind == .math {
            return DocMathRowContent(row: self, block: block, latex: sourceText, sources: editor.sources)
        }
        if let text, sourceKind == nil {
            return DocTextRowContent(row: self, text: text, editor: editor)
        }
        if let block, tree != nil, editor.demo.doc.block(block)?.kind == .divider {
            return DocDividerRowContent(row: self, blocks: editor.blocks)
        }
        return nil
    }
}

struct DocRowView: View {
    let row: DocRow
    let coordinator: StreamingRevealCoordinator<UUID>
    let hooks: MarkdownSelectableTextHooks?
    let tables: DocTableController
    let collections: DocCollectionController
    let sources: DocSourceController
    let blocks: DocBlockController
    let demo: DocDemo

    var body: some View {
        let _ = DocTiming.firstRow()
        Group {
            if let run = row.run, let media = row.media, let block = row.block, !row.isStreaming {
                placed(DocMediaCell(id: block, kind: media, blocks: blocks, inGallery: run.kind == .gallery), in: run)
            } else if let collection = row.collection, !row.isStreaming {
                wide(DocCollectionView(snapshot: collection, controller: collections))
            } else if let page = row.page, !row.isStreaming {
                inPage(DocPageRowView(page: page))
            } else if row.recordFields != nil, let record = demo.record {
                inPage(DocRecordFields(link: record, page: demo))
            } else {
                page
            }
        }
        // On the Mac a click first selects the block; on a phone, while selecting, a tap
        // selects it (DocBlockController.blockTakes).
        .allowsHitTesting(row.block.map {
            blocks.blockTakes($0, editsText: row.editsText, takesClicks: row.takesClicks) || (DocBlockController.usesHandles && row.scrollsAcross)
        } ?? true)
        // A dropped block shows once what flies to it is down.
        .opacity(row.block.map(blocks.isLanding) == true ? 0 : 1)
        .coordinateSpace(.named(DocRowSpace.name))
    }

    /// How far the row goes in: its block's level.
    private var indent: CGFloat { DocBlockController.indentWidth(row.indent) }

    /// A link, file or image where the list places its row (DocRowRun), laid out at the
    /// row's width as text is.
    private func placed(_ content: some View, in run: DocRowRun) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .modifier(DocRowBoxing(box: row.box, spacingAbove: row.spacingAbove, run: run))
            .padding(.bottom, row.spacingBelow)
    }

    /// A block drawn in the page's text column (a page block).
    private func inPage(_ content: some View) -> some View {
        content
            .modifier(DocRowBoxing(box: row.box, spacingAbove: row.spacingAbove))
            .padding(.bottom, row.spacingBelow)
            .padding(.leading, indent)
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.leading, DocBlockController.leadingGutter)
            .padding(.trailing, DocBlockController.trailingGutter)
            .frame(maxWidth: .infinity)
    }

    /// A collection, wider than the page's text (Craft's), centred on it.
    private func wide(_ content: some View) -> some View {
        content
            .modifier(DocRowBoxing(box: row.box, spacingAbove: row.spacingAbove))
            .padding(.bottom, row.spacingBelow)
            .padding(.leading, indent)
            .frame(maxWidth: DocCollectionLayout.maxWidth, alignment: .leading)
            .padding(.leading, DocBlockController.leadingGutter)
            .padding(.trailing, DocBlockController.trailingGutter)
            .frame(maxWidth: .infinity)
            .modifier(DocRowHeightReporter(isOn: true))
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            // By position, not by the rendered block's id: an edit re-renders the block
            // with a new id, and the text view being typed in must stay the same view.
            if let tree = row.tree, !row.isStreaming {
                // A divider or a card.
                MarkdownBlockView(tree: tree)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(row.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
        }
        .modifier(DocRowBoxing(box: row.box, spacingAbove: row.spacingAbove))
        .padding(.bottom, row.spacingBelow)
        // The whole block goes in by its level, its box with it; the right edge stays.
        .padding(.leading, indent)
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.leading, DocBlockController.leadingGutter)
        .padding(.trailing, DocBlockController.trailingGutter)
        .frame(maxWidth: .infinity)
        // Tables and code change height when an editor comes or goes (links, files and
        // images are as tall as their layout says).
        .modifier(DocRowHeightReporter(isOn: row.table != nil || row.sourceKind != nil))
        .modifier(DocBlockType())
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownStreamBlock) -> some View {
        let view = MarkdownStreamBlockView(block)
            .lineSpacing(row.role.isHeading ? DocTypography.headingLineSpacing : DocTypography.lineSpacing)
            // Rows are measured off screen before they show; math needs its real height then.
            .markdownDisplayMathRendersSynchronously()
            .environment(\.markdownSelectableTextHooks, hooks)
            // Code the agent writes is in the box it's read and edited in.
            .codeBlockStyle(DocCodeBlockStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
        if row.isStreaming {
            view
                .markdownStreaming(coordinator.ensureManager(for: block.id))
                .markdownFadeReveal(
                    duration: 0.5,
                    startHue: MarkdownFadeRevealConfig.legacyHighlightStartHue,
                    endHue: MarkdownFadeRevealConfig.legacyHighlightEndHue
                )
        } else {
            view
        }
    }
}


/// The space above a row, and its part of a decoration's box (Craft's Block: a grey box,
/// out past the text's edges, the text inset in it). Below the box's first row the box
/// fills the space between rows too. A link, file or image on its own line is inside the
/// inset already; a card or a gallery's image has a box of its own around it.
private struct DocRowBoxing: ViewModifier {
    let box: DocRowBox?
    let spacingAbove: CGFloat
    var run: DocRowRun?

    private typealias Box = DocTokens.Component.DecorationBox

    func body(content: Content) -> some View {
        // One layout with or without a box (no branches), so a row going into or out of a
        // box keeps its view and changes shape with the change's animation, as the rows
        // round it move. A card or a gallery's image has a whole box of its own.
        let boxed = box != nil
        let own = boxed && run?.kind != nil
        let first = own || box?.isFirst == true
        let last = own || box?.isLast == true
        // Out of a box the (hidden) box is a whole one: a block boxed alone only fades in.
        let top = Box.cornerRadius * (first || !boxed ? 1 : 0)
        let bottom = Box.cornerRadius * (last || !boxed ? 1 : 0)
        let shape = UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                           bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
        content
            .padding(.horizontal, boxed && (own || run == nil) ? Box.inset : 0)
            .padding(.top, !boxed ? 0 : first ? Box.padding : spacingAbove)
            .padding(.bottom, boxed && last ? Box.padding : 0)
            .background(shape.fill(Box.fill).opacity(boxed ? 1 : 0).padding(.horizontal, own ? 0 : -(run?.inset ?? 0) - Box.outset))
            .padding(.top, !boxed || first ? spacingAbove : 0)
    }
}
