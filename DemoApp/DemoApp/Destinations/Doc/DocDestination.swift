//
//  DocDestination.swift
//  DemoApp
//
//  The document page: top-anchored, one TiledView row per block, edited in place.
//  While the agent writes, the page is a read-only preview and the bar says so.
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

    var body: some View {
        // Pages go in and out the system's way: its back button (a long press lists the
        // pages above), its swipe back, the page's title and the way to it in its bar.
        NavigationStack(path: $pages.stack) {
            DocPageView(page: pages.root, pages: pages, shown: shown)
                .navigationDestination(for: DocID.self) { id in
                    if let page = pages.page(id) {
                        DocPageView(page: page, pages: pages)
                    }
                }
        }
        .focusedSceneValue(\.docBack, pages.path.count > 1 ? DocBackAction { pages.back() } : nil)
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

/// One page of the window: its bar, its blocks.
private struct DocPageView: View {
    let page: DocOpenPage
    let pages: DocPages
    /// Shown, not edited, with a close in its bar (DocDestination(doc:)).
    var shown = false
    @Environment(\.dismiss) private var dismiss
    @State private var scrollPosition = TiledScrollPosition()
    @State private var reader = TiledViewReader<String>()
    /// The app's: links, files and images open with it (DocBlockController.openURL).
    @Environment(\.openURL) private var openURL

    private var demo: DocDemo { page.demo }
    private var editor: DocEditor { page.editor }

    var body: some View {
        let _ = DocTiming.mark("page view body \(page.title)", once: true)
        VStack(spacing: 0) {
            // A page shown has nothing to edit with.
            if !shown { pageBar }
            TiledView(items: demo.rows, scrollPosition: $scrollPosition) { row in
                DocRowCell(item: row, demo: demo, editor: editor)
            }
            // The phone's block selection is drawn over the rows as they scroll.
            .reader(reader, invalidatesOnScroll: editor.blocks.isSelecting)
            // A swipe across a block selects it (DocBlockController), not the chat's
            // swipe to show the times.
            .revealConfiguration(.disabled)
            .heightEstimate { row, width in
                row.estimatedHeight(width: width)
            }
            // Links, files and images across the page at the width it's laid out at, as
            // text wraps (DocMediaLayout.place).
            .itemPlacement { row, width in
                row.run.map { run in
                    // An indented run is laid out in what the indent leaves of the page.
                    let indent = DocBlockController.indentWidth(row.indent)
                    let place = DocMediaLayout.place(run, inPage: max(0, DocBlockController.pageWidth(inWidth: width) - indent))
                    return TiledItemPlacement(x: DocBlockController.pageLeft(inWidth: width) + indent + place.frame.minX, width: place.frame.width,
                                              sharesLine: place.sharesLine)
                }
            }
            // A document is anchored at its top: the keyboard (the safe area) adds room
            // under the page and leaves where it is scrolled alone. By default the
            // bottom stays pinned, as a chat's does, and the page moves by the
            // keyboard's height at once. Showing the caret above the keyboard is the
            // editor's.
            .keyboardAvoidance(false, preservesContentOffset: true)
            .overlay(alignment: .topLeading) {
                // A phone's block selection, the chat's (MarkdownBlockSelectionOverlay): a
                // tint on the blocks (links, files and images outline themselves), a dot
                // over each one's right edge. TiledView lays out past the top and bottom
                // safe area; the overlay does the same, to share its origin.
                if !DocBlockController.usesHandles {
                    MarkdownBlockSelectionOverlay(
                        controller: editor.blocks.selection,
                        topInset: { [demo] item in (demo.rows.first { $0.id == item.id }?.spacingAbove ?? 0) - DocBlockController.highlightOutset },
                        bottomInset: { [demo] item in (demo.rows.first { $0.id == item.id }?.spacingBelow ?? 0) - DocBlockController.highlightOutset },
                        highlights: { [demo] item in demo.rows.first { $0.id == item.id }?.media == nil }
                    )
                    .environment(\.markdownMotion, DocTokens.Motion.markdown)
                    .ignoresSafeArea(edges: .vertical)
                }
            }
            #if !targetEnvironment(macCatalyst)
            .overlay { DocKeyboardBarHost(stage: editor.keyboardBarStage).ignoresSafeArea() }
            // A math block's LaTeX and keys, on the keyboard bar (DocSourceEditing).
            .overlay(alignment: .bottom) { DocMathKeyboardPanel(controller: editor.sources, demo: demo) }
            #endif
            .overlay { DocSlashMenuView(menu: editor.slash) }
            .overlay(alignment: .bottom) { DocBlockSelectionBar(blocks: editor.blocks) }
        }
        .modifier(DocBlockOverlays(reader: reader, blocks: editor.blocks))
        #if !targetEnvironment(macCatalyst)
        // A cell's formula, written on the table's own page (DocTableFormula).
        .fullScreenCover(item: Binding(get: { editor.tables.formula }, set: { if $0 == nil { editor.tables.closeFormula() } })) { formula in
            DocFormulaView(formula: formula, controller: editor.tables)
        }
        #endif
        .onChange(of: demo.focus?.serial) {
            if let focus = demo.focus { reader.scrollTo(id: focus.id, anchor: focus.centered ? .center : nil) }
        }
        // The agent writing makes the whole page a preview (§6.3).
        .onChange(of: demo.isAgentWriting) {
            editor.blocks.clear()
            editor.isEditable = !demo.isAgentWriting
        }
        // The system's navigation bar, its title drawn our way: the page's title over the
        // pages it's in (Craft's), each a way back. The window keeps the title as its name.
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            if #available(iOS 26, macCatalyst 26, *) {
                // Words, not a control: no glass behind them.
                ToolbarItem(placement: .topBarLeading) { DocPageTitle(page: page, pages: pages) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarLeading) { DocPageTitle(page: page, pages: pages) }
            }
            if shown {
                ToolbarItem(placement: .topBarTrailing) {
                    if #available(iOS 26, macCatalyst 26, *) {
                        Button(role: .close) { dismiss() }
                    } else {
                        Button(String(localized: "Done")) { dismiss() }
                    }
                }
            }
        }
        .task {
            DocTiming.mark("page task \(page.title)", once: true)
            editor.blocks.openURL = openURL
            editor.blocks.cardHost = DocDemoHost { [demo] in demo.sentToAgent.append($0) }
            // The rest once a page: coming back to it (a page above it left) keeps its place.
            guard !page.appeared else { return }
            page.appeared = true
            demo.rowFrame = { [reader] id in reader.frame(forItem: id) }
            if shown { editor.isEditable = false }
            editor.blocks.attach(reader)
            editor.blocks.openPage = { [pages] block in pages.open(block) }
            editor.collections.openRecord = { [pages] row, block in pages.openRecord(row, in: block) }
            editor.collections.hasPage = { [pages] row in pages.recordHasPage(row) }
            editor.collections.copyPage = { [pages] row, copy in pages.copyRecordPage(row, to: copy) }
            // The launch options below run once a process (DocPages.ranLaunchOptions).
            guard !DocPages.ranLaunchOptions else { return }
            DocPages.ranLaunchOptions = true
            // -docOpenPage YES: the first page block's page open (-docShot draws it there).
            if UserDefaults.standard.bool(forKey: "docOpenPage"),
               let block = demo.doc.blocks.first(where: { if case .page = $0.kind { true } else { false } }) {
                Task { @MainActor [pages] in
                    pages.open(block.id)
                    try? await Task.sleep(for: .seconds(1.5))
                    if let path = UserDefaults.standard.string(forKey: "docShot") { DocBlockController.drawWindow(to: path) }
                }
                return
            }
            // -docShow code|math|media|view|table: open at the first code, math,
            // link/file/image, view or table block (the top of the first media or view);
            // -docEdit YES edits code or math.
            if let kind = UserDefaults.standard.string(forKey: "docShow"),
               let row = demo.rows.first(where: { row in
                   switch kind {
                   case "code": if case .code = row.sourceKind { true } else { false }
                   case "media": row.media != nil
                   case "view": if case .view? = row.media { true } else { false }
                   case "page": row.page != nil
                   case "table": row.table != nil
                   default: row.sourceKind == .math
                   }
               }),
               let block = row.block {
                reader.scrollTo(id: row.id, anchor: kind == "media" || kind == "view" ? .top : .center, animated: false)
                if UserDefaults.standard.bool(forKey: "docEdit") {
                    try? await Task.sleep(for: .milliseconds(400))
                    editor.sources.focus(block)
                }
            }
            // -docCollectionPanel KIND: the first collection with a panel open (screenshots):
            // layout, sort, filter, group, chart, createKanban, createChart, addField, editField, options, date, addOption;
            // -docCollectionView table|kanban|chart shows that view of it first.
            if let name = UserDefaults.standard.string(forKey: "docCollectionPanel"),
               let block = demo.doc.blocks.first(where: { if case .collection = $0.kind { true } else { false } }),
               case .collection(var collection) = block.kind, let database = demo.doc.databases[collection.database] {
                let collections = editor.collections
                if let layout = UserDefaults.standard.string(forKey: "docCollectionView"),
                   let view = collection.views.first(where: { ($0.layout.chart != nil ? "chart" : $0.layout.isKanban ? "kanban" : "table") == layout }) {
                    collections.show(view.id, in: block.id)
                    collection.current = view.id
                }
                let view = collection.currentView
                let select = database.columns.first { if case .select = $0.type { true } else { false } }
                let kind: DocCollectionPanel.Kind? = switch name {
                case "layout": .layout
                case "sort": .sort
                case "filter": .filter
                case "createKanban": .createKanban
                case "createChart": .createChart
                case "chart": .chart
                case "addField": .addField
                case "editField": database.columns.last.map { .editField($0.id) }
                case "options": database.rows.first.flatMap { row in select.map { .options(row: row.id, column: $0.id) } }
                case "date": database.rows.first.flatMap { row in database.columns.first { $0.type == .date }.map { .date(row: row.id, column: $0.id) } }
                case "addOption": view?.layout.groupBy.map { .addOption($0) }
                case "group": .group
                default: nil
                }
                if let view, name == "sort", view.layout.sort.isEmpty, let column = database.columns.last {
                    collections.setSort([DatabaseSort(column: column.id, ascending: false)], in: view.id, of: block.id)
                }
                if let view, name == "filter", view.filters.isEmpty, let select, case .select(let options) = select.type, let option = options.first {
                    collections.setFilters([CollectionFilter(column: select.id, condition: .is, value: .select(option: option.id)),
                                            CollectionFilter(column: database.columns[0].id, condition: .contains)], in: view.id, of: block.id)
                }
                if let row = demo.rows.first(where: { $0.collection != nil }) { reader.scrollTo(id: row.id, anchor: .top, animated: false) }
                try? await Task.sleep(for: .milliseconds(800))
                if let kind { collections.show(kind, in: block.id) }
            }
            // -docPageShots NAME: the page a screen at a time, top to bottom, to NAME-<n>.png in
            // the app's (sandboxed) temporary folder; then the app quits.
            if let name = UserDefaults.standard.string(forKey: "docPageShots") {
                try? await Task.sleep(for: .seconds(2))
                for page in 0..<40 {
                    let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(page).png").path
                    DocBlockController.drawWindow(to: path)
                    // Rows are measured as they show, so the page's end is asked again each time.
                    let offset = reader.contentOffsetY(), visible = reader.visibleContentHeight() ?? 600
                    let end = demo.rows.last.flatMap { reader.frame(forItem: $0.id)?.maxY } ?? 0
                    guard offset + visible < end - 1 else { break }
                    reader.scrollToContentOffsetY(min(offset + visible - 48, end - visible), animated: false)
                    try? await Task.sleep(for: .milliseconds(1500))
                }
                exit(0)
            }
            // -docShowTable YES: open at the first table (screenshots, trying tables out).
            if UserDefaults.standard.bool(forKey: "docShowTable"), let table = demo.rows.first(where: { $0.table != nil }) {
                reader.scrollTo(id: table.id, anchor: .center, animated: false)
                // -docEditCell YES: and edit a cell of it.
                if UserDefaults.standard.bool(forKey: "docEditCell"), let snapshot = table.table {
                    try? await Task.sleep(for: .milliseconds(400))
                    editor.tables.tapped(snapshot, at: MarkdownTableCellPosition(row: 2, column: 1))
                    // -docCellMenu YES: and open its menu.
                    if UserDefaults.standard.bool(forKey: "docCellMenu"),
                       let key = editor.tables.key(in: snapshot, at: MarkdownTableCellPosition(row: 2, column: 1)) {
                        try? await Task.sleep(for: .milliseconds(400))
                        editor.tables.showMenu(key)
                    }
                }
                // -docFormula <text>: and write a formula in the cell under 21%, 16%, 17%, <text>
                // typed in it.
                if let text = UserDefaults.standard.string(forKey: "docFormula"), let snapshot = table.table,
                   let key = editor.tables.key(in: snapshot, at: MarkdownTableCellPosition(row: 4, column: 2)) {
                    try? await Task.sleep(for: .milliseconds(400))
                    editor.tables.tapped(snapshot, at: MarkdownTableCellPosition(row: 4, column: 2))
                    editor.tables.perform(.insertFormula, at: key)
                    try? await Task.sleep(for: .milliseconds(900))
                    if let formula = editor.tables.formula {
                        let caret = NSRange(location: text.utf16.count, length: 0)
                        formula.typed(text, selection: caret)
                        formula.field?.show(text, selection: caret)
                    }
                }
            }
            // -docShowHandle YES: a list item's handle under the pointer and the item after
            // it selected (on a phone, selecting).
            if UserDefaults.standard.bool(forKey: "docShowHandle"),
               let index = demo.doc.blocks.firstIndex(where: { $0.text.string.hasPrefix("嵌套列表") }) {
                let blocks = demo.doc.blocks
                // A phone has no handle: its selection mode instead.
                if DocBlockController.usesHandles {
                    editor.blocks.click(blocks[index + 3].id)
                } else {
                    editor.blocks.beginSelecting(blocks[index + 3].id)
                }
                editor.blocks.testHover(blocks[index].id)
            }
            // -docColors YES: a colour, highlights and pen marks on the first paragraph
            // of section 1 (screenshots of them).
            if UserDefaults.standard.bool(forKey: "docColors"),
               let block = demo.doc.blocks.first(where: { $0.text.string.hasPrefix("Loading older") }) {
                func range(_ words: String) -> [(block: DocBlockID, range: Range<Int>)] {
                    guard let found = block.text.string.range(of: words) else { return [] }
                    let start = block.text.string.utf16.distance(from: block.text.string.startIndex, to: found.lowerBound)
                    return [(block.id, start..<(start + words.utf16.count))]
                }
                editor.set(.color, to: .color("red"), over: range("Loading older messages"))
                editor.set(.highlight, to: .highlight(color: nil), over: range("everything"))
                editor.set(.highlight, to: .highlight(color: "blue"), over: range("below them"))
                editor.set(.pen, to: .pen(kind: "circle", color: nil), over: range("list"))
                editor.set(.pen, to: .pen(kind: "wavy", color: "blue"), over: range("across the update"))
            }
            // -docFocus <text>: the cursor at the end of the first block starting with it,
            // keyboard up; -docSelect N selects its first N characters, -docFocusNewLine YES
            // opens an empty line after it (the keyboard bar's states).
            if let prefix = UserDefaults.standard.string(forKey: "docFocus"),
               let block = demo.doc.blocks.first(where: { $0.text.string.hasPrefix(prefix) }) {
                demo.bringIntoView(block.id)
                try? await Task.sleep(for: .milliseconds(400))
                let selected = UserDefaults.standard.integer(forKey: "docSelect")
                let end = DocPosition(block: block.id, offset: block.text.length)
                editor.place(selected > 0 ? DocSelection(anchor: .init(block: block.id, offset: 0), head: .init(block: block.id, offset: selected))
                                          : DocSelection(anchor: end, head: end))
                if UserDefaults.standard.bool(forKey: "docFocusNewLine") {
                    try? await Task.sleep(for: .milliseconds(300))
                    editor.insert(.kind(.paragraph), at: block)
                }
            }
            // -docMediaLayouts YES: the links, files and images selected, their layouts shown.
            if UserDefaults.standard.bool(forKey: "docMediaLayouts"),
               let first = demo.doc.blocks.first(where: { DocMediaView.draws($0.kind) }) {
                editor.blocks.beginSelecting(first.id)
                editor.blocks.select(demo.doc.blocks.filter { DocMediaView.draws($0.kind) }.map(\.id))
                editor.blocks.isChoosingLayout = true
            }
            // -docSelectKind link|image: the first link or image selected, as a click selects it.
            if let kind = UserDefaults.standard.string(forKey: "docSelectKind"),
               let block = demo.doc.blocks.first(where: {
                   switch $0.kind {
                   case .link: kind == "link"
                   case .image: kind == "image"
                   default: false
                   }
               }) {
                if DocBlockController.usesHandles { editor.blocks.click(block.id) } else { editor.blocks.beginSelecting(block.id) }
            }
            // -docSheet main|styles|colors|more: the phone's format sheet at that page, over
            // the selected blocks (-docShowHandle) or the caret's block, as Aa (-docFocus).
            if let page = UserDefaults.standard.string(forKey: "docSheet") {
                let pages: [String: DocFormatSheetPage] = ["main": .main, "styles": .styles, "colors": .colors, "more": .more]
                try? await Task.sleep(for: .milliseconds(500))
                if !editor.blocks.isSelecting { editor.blocks.formatCaretBlock() }
                editor.panels.sheetPage = pages[page] ?? .main
            }
            // -docShot <path>: what the options above show, drawn to a PNG there
            // (screenshots without screen recording).
            if let path = UserDefaults.standard.string(forKey: "docShot") {
                try? await Task.sleep(for: .milliseconds(800))
                if let hovered = editor.blocks.hovered { editor.blocks.testHover(hovered) }
                DocBlockController.drawWindow(to: path)
            }
            if UserDefaults.standard.bool(forKey: "docEditTest") {
                // Not the page's task: going into a page takes this page's view (and its task) away.
                await Task { @MainActor [demo, editor, pages] in await DocEditTests(demo: demo, editor: editor, pages: pages).run() }.value
            }
            if DocDestination.autoruns {
                try? await Task.sleep(for: .seconds(1))
                demo.runScript()
            }
        }
    }

    /// Its bar, and the line under it.
    @ViewBuilder
    private var pageBar: some View {
        bar
            .frame(maxWidth: .infinity, minHeight: DocTokens.Control.prominentHeight, alignment: .leading)
            .padding(.horizontal, DocTokens.Space.lg)
            .padding(.vertical, DocTokens.Space.sm)
            // The Mac's format panel: under the bar at the window's right, open until
            // its Aa closes it (Craft's).
            .docMenuPanel(isPresented: editor.panels.showsFormat, title: String(localized: "Format"), alignment: .trailing, staysBeside: true, keepsOpen: { _ in true },
                          onDismiss: { editor.panels.showsFormat = false }) { [editor] _ in
                DocFormatMenu(editor: editor).sections
            }
        Divider()
    }

    @ViewBuilder
    private var bar: some View {
        HStack {
            if editor.blocks.isSelecting {
                // Selecting blocks: only the way out, as Craft has it.
                Spacer()
                Button("Done", systemImage: "checkmark") { editor.blocks.endSelecting() }
                    .buttonStyle(.floo(.primary, iconOnly: true))
            } else if let status = demo.agentStatus {
                ProgressView()
                    .controlSize(.small)
                Text("Agent · \(status)")
                    .font(DocTokens.Typography.body.font)
                Text("Read-only preview")
                    .font(DocTokens.Typography.metadata.font)
                    .foregroundStyle(DocTokens.ColorRole.Content.secondary)
                Spacer()
                Button("Stop") { demo.stop() }
                    .buttonStyle(.floo(.tertiary))
            } else {
                Button("Undo", systemImage: "arrow.uturn.backward") { editor.requestUndo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!demo.canUndo)
                    .buttonStyle(.floo(.plain, iconOnly: true))
                Button("Redo", systemImage: "arrow.uturn.forward") { editor.requestRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!demo.canRedo)
                    .buttonStyle(.floo(.plain, iconOnly: true))
                Spacer()
                #if targetEnvironment(macCatalyst)
                Button("Format", systemImage: "textformat") { editor.panels.showsFormat.toggle() }
                    .frame(width: DocTokens.Control.compactHeight, height: DocTokens.Control.minimumHitTarget)
                    .buttonStyle(.flooContent(in: RoundedRectangle(cornerRadius: DocTokens.Radius.sm, style: .continuous), isOn: editor.panels.showsFormat))
                    .help("Format")
                #endif
                // The demo's own controls, on its first page.
                if page === pages.root {
                    Button("Reset") {
                        pages.reset()
                        editor.resetDocument()
                    }
                    .buttonStyle(.floo(.plain))
                    .fixedSize()
                    Button("Agent Demo") { demo.runScript() }
                        .buttonStyle(.floo(.primary))
                        .fixedSize()
                }
            }
        }
        .labelStyle(.iconOnly)
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

struct DocRowCell: TiledCellContent {
    let item: DocRow
    let demo: DocDemo
    let editor: DocEditor

    func body(context: CellContext<Void>) -> some View {
        let hooks = MainActor.assumeIsolated { [item, editor] in item.block.map { editor.hooks(for: $0) } }
        let (tables, collections, sources, blocks) = MainActor.assumeIsolated { (editor.tables, editor.collections, editor.sources, editor.blocks) }
        DocRowView(row: item, coordinator: demo.coordinator, hooks: hooks, tables: tables, collections: collections, sources: sources, blocks: blocks,
                   demo: demo)
    }
}

private struct DocRowView: View {
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
            if let table = row.table, let tree = row.tree, !row.isStreaming {
                DocTableRowView(table: table, tree: tree, controller: tables)
            } else if let block = row.block, case .code(let language) = row.sourceKind, !row.isStreaming {
                DocCodeRowView(block: block, text: row.sourceText, language: language, controller: sources)
            } else if let block = row.block, row.sourceKind == .math, let tree = row.tree, !row.isStreaming {
                DocMathRowView(block: block, tree: tree, isEmpty: row.sourceIsEmpty, controller: sources)
            } else if let text = row.text, !row.isStreaming {
                textView(text)
            } else if let tree = row.tree, !row.isStreaming {
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

    /// A paragraph, heading, list item or quote, from its tree (as MarkdownStreamBlockView
    /// lays out a stream block of that kind).
    private func textView(_ text: DocTextRow) -> some View {
        // One view whatever the kind: a block that becomes a quote (or stops being one)
        // keeps its text view and goes to its new shape with the change's animation. A
        // quote's text keeps its edge insets inside the quote, as SelectableBlockQuote's.
        // A list item's level picks its bullet (• then ◦, Craft's); the row is indented.
        MarkdownSelectableText(tree: text.tree, listDepthOffset: text.depth, applyEdgeInsets: text.isQuote)
            .markdownBlockQuote(text.isQuote)
        .lineSpacing(row.role.lineSpacing)
        .modifier(DocRowTypeface(font: row.font))
        .modifier(DocCaptionType(isOn: row.role == .caption))
        .markdownDisplayMathRendersSynchronously()
        .environment(\.markdownSelectableTextHooks, hooks)
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// A block's typeface: its text's, headings and list markers too; inline code stays
/// monospaced.
private struct DocRowTypeface: ViewModifier {
    let font: Typeface?

    func body(content: Content) -> some View {
        content.transformEnvironment(\.markdownPlatformTypography) { typography in
            guard let font else { return }
            let design = DocCellLook.design(font)
            typography.body.design = design
            for level in typography.headings.indices { typography.headings[level].design = design }
        }
    }
}

/// A caption's type: smaller, secondary.
private struct DocCaptionType: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content
                .markdownPlatformTypography(DocTypography.captionFonts)
                .markdownBaseTextColor(DocTokens.ColorRole.Content.secondary)
        } else {
            content
        }
    }
}

/// Rows changed (an edit, a measured height): the handle and the selection follow.
private struct DocBlockOverlays: ViewModifier {
    let reader: TiledViewReader<String>
    let blocks: DocBlockController

    func body(content: Content) -> some View {
        content.onChange(of: reader.version) {
            blocks.attach(reader)
            blocks.layoutOverlays()
        }
    }
}

