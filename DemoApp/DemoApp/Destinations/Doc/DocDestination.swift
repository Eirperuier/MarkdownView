//
//  DocDestination.swift
//  DemoApp
//
//  The document page: top-anchored, one TiledView row per block, edited in place.
//  While the agent writes, the page is a read-only preview and the bar says so.
//

import SwiftUI
import MarkdownView
import MessagingUI
import DocKit
import FlooDesign

struct DocDestination: View {
    /// Code blocks are coloured by Highlightr, read and edited alike.
    static let highlighter = HighlightrCodeHighlighter()

    @State private var demo: DocDemo
    @State private var editor: DocEditor
    @State private var scrollPosition = TiledScrollPosition()
    @State private var reader = TiledViewReader<String>()
    /// The app's: links, files and images open with it (DocBlockController.openURL).
    @Environment(\.openURL) private var openURL

    static var autoruns: Bool { UserDefaults.standard.bool(forKey: "docAgent") }

    init() {
        let demo = DocDemo()
        _demo = State(initialValue: demo)
        _editor = State(initialValue: DocEditor(demo: demo))
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, FlooDesignTokens.Space.sm)
                // The Mac's format panel: under the bar at the window's right, open until
                // its Aa closes it (Craft's).
                .flooDesignAnchoredPanel(isPresented: editor.panels.showsFormat,
                                  configuration: .init(horizontalAlignment: .trailing, anchorGap: 0, dismissesOnOutsideTouch: false),
                                  onDismiss: { editor.panels.showsFormat = false }) {
                    FlooDesignFloatingPanelSurface(contentInset: FlooDesignTokens.Component.FloatingPanel.roomyInset) {
                        DocFormatPanel(editor: editor, demo: demo)
                    }
                }
            Divider()
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
                    let place = DocMediaLayout.place(run, inPage: DocBlockController.pageWidth(inWidth: width))
                    return TiledItemPlacement(x: DocBlockController.pageLeft(inWidth: width) + place.frame.minX, width: place.frame.width,
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
                    .environment(\.markdownMotion, FlooDesignTokens.Motion.markdown)
                    .ignoresSafeArea(edges: .vertical)
                }
            }
            #if !targetEnvironment(macCatalyst)
            .overlay { DocKeyboardBarHost(stage: editor.keyboardBarStage).ignoresSafeArea() }
            #endif
            .overlay { DocSlashMenuView(menu: editor.slash) }
            .overlay(alignment: .bottom) { DocBlockSelectionBar(blocks: editor.blocks) }
        }
        .modifier(DocBlockOverlays(reader: reader, blocks: editor.blocks))
        .onChange(of: demo.focus?.serial) {
            if let id = demo.focus?.id { reader.scrollTo(id: id, anchor: .center) }
        }
        // The agent writing makes the whole page a preview (§6.3).
        .onChange(of: demo.isAgentWriting) {
            editor.blocks.clear()
            editor.isEditable = !demo.isAgentWriting
        }
        .task {
            editor.blocks.openURL = openURL
            // Opening a document starts at its top (TiledView's first offset tucks the
            // first row under the bar's edge).
            try? await Task.sleep(for: .milliseconds(150))
            if let first = demo.rows.first?.id { reader.scrollTo(id: first, anchor: .top, animated: false) }
            demo.rowFrame = { [reader] id in reader.frame(forItem: id) }
            editor.blocks.attach(reader)
            // -docShow code|math|media: open at the first code, math or link/file/image
            // block (the top of the first media); -docEdit YES edits code or math.
            if let kind = UserDefaults.standard.string(forKey: "docShow"),
               let row = demo.rows.first(where: { row in
                   switch kind {
                   case "code": if case .code = row.sourceKind { true } else { false }
                   case "media": row.media != nil
                   default: row.sourceKind == .math
                   }
               }),
               let block = row.block {
                reader.scrollTo(id: row.id, anchor: kind == "media" ? .top : .center, animated: false)
                if UserDefaults.standard.bool(forKey: "docEdit") {
                    try? await Task.sleep(for: .milliseconds(400))
                    editor.sources.focus(block)
                }
            }
            // -docShowTable YES: open at the first table (screenshots, trying tables out).
            if UserDefaults.standard.bool(forKey: "docShowTable"), let table = demo.rows.first(where: { $0.table != nil }) {
                reader.scrollTo(id: table.id, anchor: .center, animated: false)
                // -docEditCell YES: and edit a cell of it.
                if UserDefaults.standard.bool(forKey: "docEditCell"), let snapshot = table.table {
                    try? await Task.sleep(for: .milliseconds(400))
                    editor.tables.tapped(snapshot, at: MarkdownTableCellPosition(row: 2, column: 1))
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
            // the selected blocks (-docShowHandle) or the caret's block, as Aa (-docFocus);
            // -docColorsKey YES: the colours over the keyboard bar's highlight key (-docSelect).
            if let page = UserDefaults.standard.string(forKey: "docSheet") {
                let pages: [String: DocFormatSheetPage] = ["main": .main, "styles": .styles, "colors": .colors, "more": .more]
                try? await Task.sleep(for: .milliseconds(500))
                if !editor.blocks.isSelecting { editor.blocks.formatCaretBlock() }
                editor.panels.sheetPage = pages[page] ?? .main
            }
            if UserDefaults.standard.bool(forKey: "docColorsKey") {
                try? await Task.sleep(for: .milliseconds(500))
                editor.keyboardBar.testTap("highlight")
            }
            // -docShot <path>: what the options above show, drawn to a PNG there
            // (screenshots without screen recording).
            if let path = UserDefaults.standard.string(forKey: "docShot") {
                try? await Task.sleep(for: .milliseconds(800))
                if let hovered = editor.blocks.hovered { editor.blocks.testHover(hovered) }
                DocBlockController.drawWindow(to: path)
            }
            if UserDefaults.standard.bool(forKey: "docEditTest") {
                await DocEditTests(demo: demo, editor: editor).run()
            }
            if Self.autoruns {
                try? await Task.sleep(for: .seconds(1))
                demo.runScript()
            }
        }
    }

    @ViewBuilder
    private var bar: some View {
        HStack {
            if editor.blocks.isSelecting {
                // Selecting blocks: only the way out, as Craft has it.
                Spacer()
                Button("Done", systemImage: "checkmark") { editor.blocks.endSelecting() }
                    .buttonStyle(FlooDesignRoundButtonStyle())
            } else if let status = demo.agentStatus {
                ProgressView()
                    .controlSize(.small)
                Text("Agent · \(status)")
                    .font(.subheadline)
                Text("Read-only preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { demo.stop() }
                    .buttonStyle(.bordered)
            } else {
                Button("Undo", systemImage: "arrow.uturn.backward") { editor.requestUndo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!demo.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward") { editor.requestRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!demo.canRedo)
                Spacer()
                #if targetEnvironment(macCatalyst)
                Button("Format", systemImage: "textformat") { editor.panels.showsFormat.toggle() }
                    .frame(width: FlooDesignTokens.Control.compactHeight, height: FlooDesignTokens.Control.minimumHitTarget)
                    .buttonStyle(FlooDesignTileButtonStyle(isOn: editor.panels.showsFormat, surface: .chip, cornerRadius: FlooDesignTokens.Radius.sm))
                    .help("Format")
                #endif
                Button("Reset") {
                    demo.reset()
                    editor.resetHistory()
                }
                Button("Agent Demo") { demo.runScript() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .labelStyle(.iconOnly)
    }
}

struct DocRowCell: TiledCellContent {
    let item: DocRow
    let demo: DocDemo
    let editor: DocEditor

    func body(context: CellContext<Void>) -> some View {
        let hooks = MainActor.assumeIsolated { [item, editor] in item.block.map { editor.hooks(for: $0) } }
        let (tables, sources, blocks) = MainActor.assumeIsolated { (editor.tables, editor.sources, editor.blocks) }
        DocRowView(row: item, coordinator: demo.coordinator, hooks: hooks, tables: tables, sources: sources, blocks: blocks)
    }
}

private struct DocRowView: View {
    let row: DocRow
    let coordinator: StreamingRevealCoordinator<UUID>
    let hooks: MarkdownSelectableTextHooks?
    let tables: DocTableController
    let sources: DocSourceController
    let blocks: DocBlockController

    var body: some View {
        Group {
            if let run = row.run, let media = row.media, let block = row.block, !row.isStreaming {
                placed(DocMediaCell(id: block, kind: media, blocks: blocks, inGallery: run.kind == .gallery), in: run)
            } else {
                page
            }
        }
        // On the Mac a click first selects the block; on a phone, while selecting, a tap
        // selects it (DocBlockController.blockTakes).
        .allowsHitTesting(row.block.map { blocks.blockTakes($0, editsText: row.editsText) } ?? true)
        // A dropped block shows once what flies to it is down.
        .opacity(row.block.map(blocks.isLanding) == true ? 0 : 1)
    }

    /// A link, file or image where the list places its row (DocRowRun), laid out at the
    /// row's width as text is.
    private func placed(_ content: some View, in run: DocRowRun) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .modifier(DocRowBoxing(box: row.box, spacingAbove: row.spacingAbove, run: run))
            .padding(.bottom, row.spacingBelow)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            // By position, not by the rendered block's id: an edit re-renders the block
            // with a new id, and the text view being typed in must stay the same view.
            if let table = row.table, let tree = row.tree, !row.isStreaming {
                DocTableRowView(table: table, tree: tree, controller: tables)
            } else if let block = row.block, case .code(let language) = row.sourceKind, let tree = row.tree, !row.isStreaming {
                DocCodeRowView(block: block, language: language, tree: tree, controller: sources)
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
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.leading, DocBlockController.leadingGutter)
        .padding(.trailing, DocBlockController.trailingGutter)
        .frame(maxWidth: .infinity)
        // Tables and code change height when an editor comes or goes (links, files and
        // images are as tall as their layout says).
        .modifier(DocRowHeightReporter(isOn: row.table != nil || row.sourceKind != nil))
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

    /// A paragraph, heading, list item or quote, from its tree (as MarkdownStreamBlockView
    /// lays out a stream block of that kind).
    private func textView(_ text: DocTextRow) -> some View {
        Group {
            if text.isQuote {
                SelectableBlockQuote(content: text.tree)
            } else {
                MarkdownSelectableText(tree: text.tree, listDepthOffset: text.depth, applyEdgeInsets: false)
                    // 20 pt a level, as MarkdownStreamBlockView indents a nested item.
                    .padding(.leading, CGFloat(text.depth) * 20)
            }
        }
        .lineSpacing(row.role.lineSpacing)
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

    private typealias Box = FlooDesignTokens.Component.DecorationBox

    func body(content: Content) -> some View {
        if let box, run?.kind != nil {
            content
                .padding(.horizontal, Box.inset)
                .padding(.vertical, Box.padding)
                .background(RoundedRectangle(cornerRadius: Box.cornerRadius, style: .continuous).fill(Box.fill))
                .padding(.top, spacingAbove)
        } else if let box {
            let radius = Box.cornerRadius
            let shape = UnevenRoundedRectangle(topLeadingRadius: box.isFirst ? radius : 0, bottomLeadingRadius: box.isLast ? radius : 0,
                                               bottomTrailingRadius: box.isLast ? radius : 0, topTrailingRadius: box.isFirst ? radius : 0,
                                               style: .continuous)
            content
                .padding(.horizontal, run == nil ? Box.inset : 0)
                .padding(.top, box.isFirst ? Box.padding : spacingAbove)
                .padding(.bottom, box.isLast ? Box.padding : 0)
                .background(shape.fill(Box.fill).padding(.horizontal, -(run?.inset ?? 0) - Box.outset))
                .padding(.top, box.isFirst ? spacingAbove : 0)
        } else {
            content.padding(.top, spacingAbove)
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
                .markdownBaseTextColor(.secondary)
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

/// A link, file or image's layouts, as a menu (the Mac's right-click).
struct DocMediaMenu: View {
    let kind: BlockKind
    let block: DocBlockID
    let blocks: DocBlockController

    var body: some View {
        let ids = blocks.selected.contains(block) ? blocks.selected : [block]
        switch kind {
        case .link(let link): layouts(link.layout, ids)
        case .file(let file): layouts(file.layout, ids)
        case .image(let image):
            Section("Image Display") {
                Toggle("Fit", isOn: binding(image.fit == .fit) { blocks.setImage(fit: .fit, of: ids) })
                Toggle("Fill", isOn: binding(image.fit == .fill) { blocks.setImage(fit: .fill, of: ids) })
            }
            Section("Image Size") {
                Toggle("Auto", isOn: binding(image.size == .auto) { blocks.setImage(size: .auto, of: ids) })
                Toggle("Large", isOn: binding(image.size == .large) { blocks.setImage(size: .large, of: ids) })
            }
        default: EmptyView()
        }
    }

    private func layouts(_ current: DocLayout, _ ids: [DocBlockID]) -> some View {
        Section("Layout") {
            ForEach(DocLayout.allCases, id: \.self) { layout in
                Toggle(layout.title, isOn: binding(current == layout) { blocks.setLayout(layout, of: ids) })
            }
        }
    }

    private func binding(_ isOn: Bool, choose: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { isOn }, set: { if $0 { choose() } })
    }
}

