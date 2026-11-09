//
//  DocDemo.swift
//  DemoApp
//
//  D2/D3 (Docs/doc.md §11): a DocKit document shown one row per block, edited in the
//  same text views it is read in, and a scripted agent that inserts, edits a phrase,
//  rewrites, deletes and moves blocks. While the agent writes the document is a
//  read-only preview; what it is writing is a temporary layer rendered and revealed
//  like a streamed chat reply, committed as steps when done.
//

import SwiftUI
import DocKit
import CardModel
import Markdown
import MarkdownView

/// A text block's content as its row shows it: the tree DocKit builds from the model and
/// MarkdownView renders (no markdown written or parsed in between), a list item's level
/// (its bullet's), whether it's a quote; its text, for the row's first height.
struct DocTextRow: Equatable {
    let tree: MarkdownTree
    let depth: Int
    let isQuote: Bool
    let plain: String
}

/// A decorated row's part of its box: the box's top and bottom are rounded and padded.
struct DocRowBox: Equatable {
    let isFirst: Bool
    let isLast: Bool
}

/// A link, file or image's row in the page: on a line of its own, or one of a run of
/// cards or a gallery's images, side by side. Where it goes across the page is worked out
/// at the width the list lays it out at (DocMediaLayout.place), as text wraps.
struct DocRowRun: Equatable {
    /// Cards or a gallery; nil: on a line of its own, as wide as the page.
    var kind: DocMediaLayout.Run?
    var index: Int
    /// Each member's width over its height (a gallery's images; cards are all alike).
    var aspects: [CGFloat]
    /// Each member's size, in a run of floo's cards.
    var cards: [CardSize] = []
    /// A decoration's inset on each side of the page (a row on its own line).
    var inset: CGFloat = 0
}

/// One list row: a committed block, or a block of what the agent is writing.
struct DocRow: Identifiable, Equatable {
    let id: String
    /// The committed block the row shows; nil for the agent's temporary layer.
    let block: DocBlockID?
    let blocks: [MarkdownStreamBlock]
    /// Part of the agent's temporary layer: fades in through the reveal.
    let isStreaming: Bool
    /// A database block shown as an editable table (instead of `blocks`).
    let table: DocTableSnapshot?
    /// A collection block: its name, its views and its records (DocCollection).
    let collection: DocCollectionSnapshot?
    /// A page block: the page it opens and its title.
    let page: DocPage?
    /// A record's page: the record's fields, under the title (DocRecordFields).
    let recordFields: Int?
    /// A paragraph, heading, list item or quote, from the model (DocTextRow).
    let text: DocTextRow?
    /// Code, maths, a divider, a card or a table, as the tree DocKit builds from the model.
    let tree: MarkdownTree?
    /// A link, file or image block, drawn as itself (DocMedia).
    let media: BlockKind?
    /// A link, file or image's run across the page (nil: a row as wide as the page).
    var run: DocRowRun?
    /// A code or math block, edited as its source.
    let sourceKind: DocSourceKind?
    /// Its source's text: a code or math block's, a table's markdown.
    let sourceText: String
    var sourceIsEmpty: Bool { sourceText.isEmpty }
    /// Whether the row has text to edit: a text block's, a cell's, code's or maths'.
    var editsText: Bool { text != nil || sourceKind != nil || table != nil }
    /// A code block: its long lines scroll across, while it isn't selected too (on the
    /// Mac its row takes events for that, and its text view only the scrolling,
    /// DocSourceTextView.hitTest).
    var scrollsAcross: Bool {
        if case .code? = sourceKind { return true }
        return false
    }
    /// A view, a collection or a table: it takes its clicks (a view's controls, a table's
    /// cells), and scrolls across while it isn't selected.
    var takesClicks: Bool {
        if collection != nil || table != nil { return true }
        if case .view? = media { return true }
        return false
    }
    /// Space above the row and below it (the page's bottom, on the last row): the
    /// document's rhythm, set when the rows are published (DocTypography).
    var spacingAbove: CGFloat = 0
    var spacingBelow: CGFloat = 0
    /// What the row is, for its spacing and line height.
    var role: DocRowRole = .paragraph
    /// Its part of a decoration's box: decorated rows next to each other share one.
    var box: DocRowBox?
    /// Its block's level: the whole row goes in from the page's left (indentWidth).
    var indent = 0
    /// Its block's typeface (a text block's; a table's goes to its cells).
    var font: Typeface?
    /// Its markdown, or its text's plain words: what it shows.
    let source: String
    private let depth: Int?

    init(id: String, block: DocBlockID?, blocks: [MarkdownStreamBlock] = [], text: DocTextRow? = nil, tree: MarkdownTree? = nil,
         isStreaming: Bool = false, table: DocTableSnapshot? = nil, collection: DocCollectionSnapshot? = nil, page: DocPage? = nil,
         recordFields: Int? = nil, media: BlockKind? = nil, sourceKind: DocSourceKind? = nil, sourceText: String = "") {
        self.id = id
        self.block = block
        self.blocks = blocks
        self.text = text
        self.tree = tree
        self.isStreaming = isStreaming
        self.table = table
        self.collection = collection
        self.page = page
        self.recordFields = recordFields
        self.media = media
        self.sourceKind = sourceKind
        self.sourceText = sourceText
        source = text?.plain ?? blocks.map(\.source).joined(separator: "\n\n")
        depth = text?.depth ?? blocks.first?.descriptor.listItemContext?.depth
    }

    static func == (lhs: DocRow, rhs: DocRow) -> Bool {
        lhs.id == rhs.id && lhs.isStreaming == rhs.isStreaming && lhs.source == rhs.source && lhs.text == rhs.text && lhs.tree == rhs.tree
            && lhs.table == rhs.table && lhs.collection == rhs.collection && lhs.page == rhs.page && lhs.recordFields == rhs.recordFields && lhs.media == rhs.media && lhs.run == rhs.run
            && lhs.sourceKind == rhs.sourceKind && lhs.sourceText == rhs.sourceText
            && lhs.depth == rhs.depth
            && lhs.spacingAbove == rhs.spacingAbove && lhs.spacingBelow == rhs.spacingBelow && lhs.role == rhs.role && lhs.box == rhs.box
            && lhs.indent == rhs.indent && lhs.font == rhs.font
            && lhs.blocks.map(\.revealPlainTextCount) == rhs.blocks.map(\.revealPlainTextCount)
    }
}

@MainActor
@Observable
final class DocDemo {
    private(set) var doc: Doc
    private(set) var rows: [DocRow] = [] {
        didSet { onRows?() }
    }
    /// The rows changed: the list takes them at once, in the change's own turn (a reshape's
    /// motion with them).
    @ObservationIgnored var onRows: (() -> Void)?
    /// What the agent is doing, shown in the bar; nil when idle.
    private(set) var agentStatus: String?
    /// A row the view should bring on screen (the agent's next change).
    private(set) var focus: (id: String, serial: Int, centered: Bool)?
    var undoDepth: Int { history.undoDepth }
    private(set) var canUndo = false
    private(set) var canRedo = false

    @ObservationIgnored let coordinator = StreamingRevealCoordinator<UUID>()
    /// The laid-out frame of a row, from the list (for the edit tests).
    @ObservationIgnored var rowFrame: (String) -> CGRect? = { _ in nil }
    @ObservationIgnored private var layer: Layer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var rng = DocDemoRNG(seed: 0xD0C)
    @ObservationIgnored private var focusSerial = 0
    /// The person's own undo history; the agent's steps only map through it (§7).
    @ObservationIgnored private var history = DocHistory()
    let person = DocAuthor.person(client: Identifier(rawValue: UUID(uuidString: "00000000-0000-7000-8000-0000000000E1")!))
    private let agent = DocAuthor.agent(client: Identifier(rawValue: UUID(uuidString: "00000000-0000-7000-8000-00000000A6E7")!))
    /// Pages' previews for bookmarks that say little about their page, filled in as the
    /// app's own steps: like the agent's, not the person's to undo.
    @ObservationIgnored private let previews = DocLinkPreviews()
    private let previewer = DocAuthor.agent(client: Identifier(rawValue: UUID(uuidString: "00000000-0000-7000-8000-0000000B00C0")!))

    /// The agent's writing in progress: shown in the list, not in the doc.
    private struct Layer {
        /// The temporary blocks go after this one, or in place of `replacing`.
        var after: DocBlockID?
        /// Ids the new blocks get on commit, decided before writing starts (§9.3).
        var ids: [DocBlockID]
        var blocks: [MarkdownStreamBlock] = []
        /// A block being rewritten in place: hidden until the rewrite commits.
        var replacing: DocBlockID?
        /// Already in the doc; the layer only stays while its reveal finishes.
        var committed = false
    }

    convenience init() {
        // -docFile NAME: a document (DocKit's JSON) in the app's temporary folder, in place of
        // the corpus: what a model wrote (floo's Apps/CardLab/Eval/doc_agent.py).
        if let name = UserDefaults.standard.string(forKey: "docFile"),
           let data = try? Data(contentsOf: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
           let written = try? JSONDecoder().decode(Doc.self, from: data) {
            self.init(doc: written)
        } else if let root = DocStore.shared.root, let kept = DocStore.shared.load(root) {
            // The first page as it was left (DocStore).
            self.init(doc: kept)
        } else {
            DocTiming.begin("corpus")
            let doc = DocDemoCorpus.doc(id: Identifier(rawValue: UUID()))
            DocStore.shared.setRoot(doc.id)
            self.init(doc: doc)
        }
    }

    /// A record's page: the collection whose record it is, whose fields show under its
    /// title (DocPages.openRecord).
    /// Brought up to where the collection is now each time the page opens (DocPages).
    @ObservationIgnored var record: DocRecordLink? {
        didSet { publish() }
    }

    /// A document of its own: the corpus's, or a page opened from another (a record's, its
    /// collection given).
    init(doc: Doc, record: DocRecordLink? = nil) {
        self.record = record
        DocTiming.mark("demo: doc in (\(doc.blocks.count) blocks)")
        self.doc = doc
        previews.onPreview = { [weak self] url, preview in self?.fill(url, with: preview) }
        DocStore.shared.attach(self)
        publish()
        DocTiming.mark("demo: rows published (\(rows.count) rows, \(Int(lastPublishMs)) ms)")
    }

    /// A page block's title and preview, as its page now has them: one undo step here.
    func setPageSummary(of block: DocBlockID, from page: Doc) {
        guard let existing = doc.block(block), case .page(var kept) = existing.kind else { return }
        (kept.title, kept.preview) = DocPage.summary(of: page)
        guard existing.kind != .page(page: kept) else { return }
        let page = kept
        edit([.setBlock(block: block, kind: .page(page: page), indent: existing.indent, previousKind: existing.kind, previousIndent: existing.indent)],
             before: nil, after: nil)
    }

    var isAgentWriting: Bool { agentStatus != nil }
    /// What the page's views sent the agent (DocDemoHost): kept, as nothing answers here.
    var sentToAgent: [String] = []

    /// Rows again: a record's fields came or went in its collection.
    func republish() { publish() }

    /// The corpus again; the documents kept (its pages too) gone with what was in them.
    func reset() {
        stop()
        DocStore.shared.removeAll()
        DocStore.shared.setRoot(doc.id)
        doc = DocDemoCorpus.doc(id: doc.id)
        history = DocHistory()
        publish()
        DocStore.shared.share(reset: self)
    }

    // MARK: Other windows

    /// The editor's part when another window changes the document (DocEditor).
    @ObservationIgnored var onReceive: (([DocStep]) -> Void)?
    /// The window's part when another window starts the document over (DocDestination).
    @ObservationIgnored var onTake: (() -> Void)?

    /// Another window's change (DocStore): applied as it was made, the person's history
    /// mapped through it, as the agent's are. The rows follow a moment later: the window
    /// typed in draws first (its new line takes the focus before the next key comes).
    func receive(_ steps: [DocStep]) {
        var applied: [DocStep] = []
        for step in steps {
            guard let resolved = try? doc.apply(step) else { continue }
            history.map(through: resolved)
            applied.append(resolved)
        }
        guard !applied.isEmpty else { return }
        onReceive?(applied)
        guard !publishing else { return }
        publishing = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.publishing else { return }
            self.publishing = false
            self.publish()
        }
    }

    /// Rows are coming for what another window changed.
    @ObservationIgnored private var publishing = false

    /// Another window started the document over: its document, no history here either.
    /// The agent stops where it is, what it was writing gone with the rest.
    func take(_ doc: Doc) {
        task?.cancel()
        task = nil
        layer = nil
        coordinator.revealAll()
        agentStatus = nil
        self.doc = doc
        history = DocHistory()
        onTake?()
        publishing = false
        publish()
    }

    // MARK: Rows

    /// Time the last publish took (ms), for the typing-speed test.
    private(set) var lastPublishMs: Double = 0
    /// Rows of blocks (and list runs) that haven't changed since the last publish: a
    /// keystroke re-renders its own block's row, not the document's.
    @ObservationIgnored private var rowCache: [DocBlockID: (block: DocBlock, database: Database?, row: DocRow)] = [:]
    @ObservationIgnored private var runCache: [DocBlockID: (run: [DocBlock], rows: [DocRow])] = [:]

    private func publish() {
        let started = CFAbsoluteTimeGetCurrent()
        defer { lastPublishMs = (CFAbsoluteTimeGetCurrent() - started) * 1000 }
        publishing = false
        // Every change comes through here: kept as it is now (written a moment later).
        DocStore.shared.save(doc)
        var result: [DocRow] = []
        var uncompiled: [BlockKind] = []
        var emitted = false
        func emitLayer() {
            guard let layer, !emitted else { return }
            result += zip(layer.ids, layer.blocks).map { id, block in
                DocRow(id: id.description, block: nil, blocks: [block], isStreaming: true)
            }
            emitted = true
        }
        let live = layer.flatMap { $0.committed ? nil : $0 }
        var index = 0
        while index < doc.blocks.count {
            let block = doc.blocks[index]
            if case .listItem = block.kind {
                let run = doc.blocks[index...].prefix { if case .listItem = $0.kind { true } else { false } }
                index += run.count
                let shown = run.filter { !(layer?.ids.contains($0.id) ?? false) }
                if shown.count < run.count { emitLayer() }
                if let first = shown.first, let cached = runCache[first.id], cached.run == shown {
                    result += cached.rows
                } else {
                    let rows = listRows(shown)
                    if let first = shown.first { runCache[first.id] = (shown, rows) }
                    result += rows
                }
                if let live, run.contains(where: { $0.id == live.after }) { emitLayer() }
                continue
            }
            index += 1
            // Committed but still revealing: the layer stands in for its blocks.
            if let layer, layer.ids.contains(block.id) {
                emitLayer()
                continue
            }
            if let live, live.replacing == block.id {
                emitLayer()
                continue
            }
            if case .collection(let collection) = block.kind, let database = doc.databases[collection.database] {
                if let cached = rowCache[block.id], cached.block == block, cached.database == database {
                    result.append(cached.row)
                } else {
                    let row = DocRow(id: block.id.description, block: block.id,
                                     collection: DocCollectionSnapshot(block: block.id, collection: collection, database: database))
                    rowCache[block.id] = (block, database, row)
                    result.append(row)
                }
                if let live, live.after == block.id { emitLayer() }
                continue
            }
            if case .page(let page) = block.kind {
                if let cached = rowCache[block.id], cached.block == block {
                    result.append(cached.row)
                } else {
                    let row = DocRow(id: block.id.description, block: block.id, page: page)
                    rowCache[block.id] = (block, nil, row)
                    result.append(row)
                }
                if let live, live.after == block.id { emitLayer() }
                continue
            }
            if case .database(let id, _) = block.kind, let database = doc.databases[id] {
                if let cached = rowCache[block.id], cached.block == block, cached.database == database {
                    result.append(cached.row)
                } else {
                    let alone = Doc(id: doc.id, blocks: [block], databases: [database.id: database])
                    // Its markdown is DocKit's (a GFM table of the same cells as its tree), which
                    // the UIKit row's table reads.
                    let row = DocRow(id: block.id.description, block: block.id, tree: Self.tree(block, in: alone),
                                     table: DocTableSnapshot(block: block.id, database: database), sourceText: alone.markdown(of: block.id) ?? "")
                    rowCache[block.id] = (block, database, row)
                    result.append(row)
                }
                if let live, live.after == block.id { emitLayer() }
                continue
            }
            if let cached = rowCache[block.id], cached.block == block, cached.database == nil {
                result.append(cached.row)
            } else {
                // Outside a list a block is its own: no neighbour changes it. Everything is
                // drawn from the model: text and the rest as their trees, links, files and
                // images as themselves.
                let alone = Doc(id: doc.id, blocks: [block])
                // A card or a view compiles just after the page shows, not in a scroll or an
                // animation (compileSoon).
                switch block.kind {
                case .card, .view: uncompiled.append(block.kind)
                default: break
                }
                let row = if let text = Self.textRow(block, in: alone) {
                    DocRow(id: block.id.description, block: block.id, text: text)
                } else {
                    DocRow(id: block.id.description, block: block.id, tree: Self.tree(block, in: alone),
                           media: DocMediaView.draws(block.kind) ? block.kind : nil,
                           sourceKind: DocSourceKind(block.kind), sourceText: DocSourceKind(block.kind) == nil ? "" : block.text.string)
                }
                rowCache[block.id] = (block, nil, row)
                result.append(row)
            }
            if let live, live.after == block.id { emitLayer() }
        }
        if let record, let fields = record.fieldCount,
           let heading = doc.blocks.first(where: { if case .heading = $0.kind { true } else { false } }),
           let index = result.firstIndex(where: { $0.block == heading.id }) {
            result.insert(DocRow(id: "record-fields", block: nil, recordFields: fields), at: index + 1)
        }
        place(&result)
        space(&result)
        compileSoon(uncompiled)
        rows = result
        canUndo = history.canUndo
        canRedo = history.canRedo
        askForPreviews()
    }

    /// Cards and views new to the page compile one a turn of the main loop, once the rows
    /// that show them are out: the page shows without waiting for them (a card's ~5–20 ms
    /// each), and they're ready before a scroll reaches them. One drawn first compiles as
    /// it draws (DocMediaLayout keeps each session).
    private func compileSoon(_ kinds: [BlockKind]) {
        guard !kinds.isEmpty else { return }
        Task { @MainActor in
            for kind in kinds {
                await Task.yield()
                switch kind {
                case .card(let card): _ = DocMediaLayout.session(for: card)
                case .view(let view): _ = DocMediaLayout.session(for: view)
                default: break
                }
            }
            DocTiming.mark("cards and views compiled")
        }
    }

    /// Links, files and images in runs: cards next to each other side by side (a card on
    /// its own too, a column of the page wide), images in a gallery (not while the agent
    /// writes); the rest on lines of their own, an image alone at its own size. A run
    /// doesn't cross a change of indent or decoration; each of its members has a box of
    /// its own.
    private func place(_ rows: inout [DocRow]) {
        let blocks = Dictionary(uniqueKeysWithValues: doc.blocks.map { ($0.id, $0) })
        func block(_ row: DocRow) -> DocBlock? {
            guard row.media != nil, !row.isStreaming, let id = row.block else { return nil }
            return blocks[id]
        }
        var index = 0
        while index < rows.count {
            guard let first = block(rows[index]) else {
                rows[index].run = nil
                index += 1
                continue
            }
            let kind = layer == nil ? DocMediaLayout.run(first.kind) : nil
            var end = index + 1
            if let kind {
                while end < rows.count, let next = block(rows[end]), DocMediaLayout.run(next.kind) == kind,
                      next.indent == first.indent, next.decoration == first.decoration {
                    end += 1
                }
            }
            if let kind, kind != .gallery || end - index > 1 {
                let members = rows[index..<end].compactMap(block).map(\.kind)
                let aspects = members.map(DocMediaLayout.aspect)
                let cards = members.compactMap(DocMediaLayout.cardSize)
                for offset in 0..<(end - index) {
                    rows[index + offset].run = DocRowRun(kind: kind, index: offset, aspects: aspects, cards: cards)
                }
            } else {
                let inset = first.decoration == nil ? 0 : DocTokens.Component.DecorationBox.inset
                rows[index].run = DocRowRun(kind: nil, index: 0, aspects: [], inset: inset)
            }
            index = end
        }
    }

    /// Each row's space above by what it is and what comes before it. A run's members
    /// (cards, a gallery's images) are each the gap below the line above them, so the
    /// members of whatever line the list puts them on line up; the row before the run
    /// carries the rest of its space. The last row carries the page's bottom (a run's
    /// last member is on its last line). Decorated rows next to each other make one box;
    /// a run's members each have one of their own.
    private func space(_ rows: inout [DocRow]) {
        let kinds = Dictionary(uniqueKeysWithValues: doc.blocks.map { ($0.id, $0.kind) })
        let indents = Dictionary(uniqueKeysWithValues: doc.blocks.map { ($0.id, $0.indent) })
        let decorations = Dictionary(uniqueKeysWithValues: doc.blocks.map { ($0.id, $0.decoration) })
        let fonts = Dictionary(uniqueKeysWithValues: doc.blocks.map { ($0.id, $0.font) })
        let decorated = rows.map { row in row.block.flatMap { decorations[$0] } ?? nil }
        let inRun = rows.map { $0.run?.kind != nil }
        var previous: DocRowRole?
        var runSpace: CGFloat = 0
        for index in rows.indices {
            let row = rows[index]
            let role = row.block.flatMap { kinds[$0] }.map(DocRowRole.init) ?? DocRowRole(markdown: row.blocks.first?.source ?? "")
            rows[index].role = role
            rows[index].indent = row.block.flatMap { indents[$0] } ?? 0
            rows[index].font = row.block.flatMap { fonts[$0] } ?? nil
            rows[index].spacingBelow = index == rows.count - 1 ? DocTypography.pageBottom : 0
            if let run = row.run, run.kind == .floo {
                // Cards carry the gutter above them, at their scale (DocCardGap).
                rows[index].spacingAbove = 0
                rows[index].box = decorated[index].map { _ in DocRowBox(isFirst: true, isLast: true) }
            } else if let run = row.run, run.kind != nil {
                if run.index == 0 {
                    let space = role.spacing(after: previous)
                    if index > 0 {
                        rows[index - 1].spacingBelow += space - DocMediaLayout.gap
                        runSpace = DocMediaLayout.gap
                    } else {
                        runSpace = space
                    }
                }
                rows[index].spacingAbove = runSpace
                rows[index].box = decorated[index].map { _ in DocRowBox(isFirst: true, isLast: true) }
            } else {
                rows[index].spacingAbove = role.spacing(after: previous)
                rows[index].box = decorated[index].map { decoration in
                    DocRowBox(isFirst: index == 0 || inRun[index - 1] || decorated[index - 1] != decoration,
                              isLast: index == rows.count - 1 || inRun[index + 1] || decorated[index + 1] != decoration)
                }
            }
            previous = role
        }
        spacingAbove = Dictionary(rows.map { ($0.id, $0.spacingAbove) }, uniquingKeysWith: { first, _ in first })
        spacingBelow = Dictionary(rows.map { ($0.id, $0.spacingBelow) }, uniquingKeysWith: { first, _ in first })
        runs = Dictionary(rows.compactMap { row in row.run.flatMap { run in row.block.map { ($0, run) } } },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Each link, file or image block's run (DocRowRun).
    @ObservationIgnored private(set) var runs: [DocBlockID: DocRowRun] = [:]
    /// The space below each row (by row id): the page's bottom, or a run's after it.
    @ObservationIgnored private(set) var spacingBelow: [String: CGFloat] = [:]

    /// The space above each row (by row id), for laying things over the rows.
    @ObservationIgnored private(set) var spacingAbove: [String: CGFloat] = [:]

    /// A run of list items: each item's tree is numbered and nested as it is in the run.
    private func listRows(_ run: [DocBlock]) -> [DocRow] {
        let list = Doc(id: doc.id, blocks: run)
        return run.map { DocRow(id: $0.id.description, block: $0.id, text: Self.textRow($0, in: list)) }
    }

    /// A paragraph, heading, list item or quote as its row shows it; nil for other kinds.
    private static func textRow(_ block: DocBlock, in doc: Doc) -> DocTextRow? {
        guard block.kind.allowsMarks, let (document, depth) = doc.markupTree(of: block.id) else { return nil }
        // A quote's row draws the quote around what it holds (markdownBlockQuote).
        if case .quote = block.kind, let quote = document.child(at: 0) {
            let content = Markdown.Document(quote.children.compactMap { $0 as? any BlockMarkup })
            return DocTextRow(tree: MarkdownTree(content), depth: 0, isQuote: true, plain: block.text.string)
        }
        return DocTextRow(tree: MarkdownTree(document), depth: depth, isQuote: false, plain: block.text.string)
    }

    /// Code, maths, a divider, a card or a table as its tree; nil for what's drawn as itself.
    private static func tree(_ block: DocBlock, in doc: Doc) -> MarkdownTree? {
        doc.markupTree(of: block.id).map { MarkdownTree($0.document) }
    }

    /// Scrolls to the block's row: to the middle of the page (what the agent works on),
    /// or (`centered` false) the least that puts it on screen (where the caret goes).
    func bringIntoView(_ id: DocBlockID?, centered: Bool = true) {
        guard let id else { return }
        focusSerial += 1
        // The row it is in: its own, or the one it shares with others.
        focus = (id.description, focusSerial, centered)
    }

    // MARK: Editing

    /// Applies one of the person's edits as a transaction, recorded for undo.
    /// Nil when the steps don't apply.
    @discardableResult
    func edit(
        _ steps: [DocStep],
        before: DocSelection?,
        after: DocSelection?,
        merge: DocHistory.MergeKey? = nil
    ) -> DocTransaction? {
        guard !isAgentWriting, !steps.isEmpty else { return nil }
        let transaction = DocTransaction(steps: steps, selectionBefore: before, selectionAfter: after, author: person, time: .now)
        guard let resolved = try? doc.apply(transaction) else { return nil }
        if UserDefaults.standard.bool(forKey: "docTrace") {
            for step in resolved.steps { print("DOCTRACE step \(step)".prefix(300)) }
            if let id = after?.head.block, let index = doc.blocks.firstIndex(where: { $0.id == id }) {
                for block in doc.blocks[max(0, index - 2)...min(doc.blocks.count - 1, index + 2)] {
                    print("DOCTRACE   \(block.id == id ? ">" : " ") \(block.kind) \(block.text.string.prefix(30).debugDescription) md=\((doc.markdown(of: block.id, style: .editing) ?? "").prefix(40).debugDescription)")
                }
            }
        }
        history.record(resolved, merge: merge)
        DocStore.shared.share(resolved.steps, from: self)
        publish()
        return resolved
    }

    /// Undoes the person's last transaction; returns where the cursor goes.
    func undo() -> DocSelection? {
        guard !isAgentWriting, let transaction = history.undo(&doc) else { return nil }
        DocStore.shared.share(transaction.steps, from: self)
        publish()
        return transaction.selectionBefore
    }

    func redo() -> DocSelection? {
        guard !isAgentWriting, let transaction = history.redo(&doc) else { return nil }
        DocStore.shared.share(transaction.steps, from: self)
        publish()
        return transaction.selectionBefore
    }

    // MARK: Agent

    func runScript() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.script()
            self?.agentStatus = nil
            self?.task = nil
        }
    }

    /// Stops the agent: committed operations stay; a rewrite in progress is dropped, an
    /// insert keeps what it has written (doc.md §9.3).
    func stop() {
        task?.cancel()
        task = nil
        if let layer, layer.replacing == nil, !layer.committed {
            commitInsert(layer, markdown: layer.blocks.map(\.source).joined(separator: "\n\n"))
        }
        layer = nil
        coordinator.revealAll()
        agentStatus = nil
        publish()
    }

    private func script() async {
        let blocks = doc.blocks
        func block(containing text: String) -> DocBlock? {
            blocks.first { $0.text.string.contains(text) }
        }
        let pause = Duration.milliseconds(900)

        if let anchor = block(containing: "the list has to") {
            agentStatus = String(localized: "Inserting a paragraph")
            await insert(DocDemoCorpus.inserted, after: anchor.id)
        }
        try? await Task.sleep(for: pause)
        if let target = block(containing: "self-sizing cells can change height"), !Task.isCancelled {
            agentStatus = String(localized: "Changing a sentence")
            await edit(target.id, find: "self-sizing cells can change height after the insert", replace: "a cell can still grow once it has been inserted")
        }
        try? await Task.sleep(for: pause)
        if let target = block(containing: "这周你的睡眠整体"), !Task.isCancelled {
            agentStatus = String(localized: "Rewriting a block")
            await rewrite(target.id, with: DocDemoCorpus.rewritten)
        }
        try? await Task.sleep(for: pause)
        if let target = block(containing: "Never set the offset"), !Task.isCancelled {
            agentStatus = String(localized: "Deleting a block")
            bringIntoView(target.id)
            try? await Task.sleep(for: .milliseconds(500))
            apply([.deleteBlock(block: target, after: nil)])
        }
        try? await Task.sleep(for: pause)
        if let moving = block(containing: "Apply the insert without animation"),
            let after = block(containing: "Move the content offset"), !Task.isCancelled
        {
            agentStatus = String(localized: "Moving a block")
            bringIntoView(moving.id)
            try? await Task.sleep(for: .milliseconds(500))
            apply([.moveBlock(block: moving.id, after: after.id, from: nil)])
        }
    }

    /// Streams `markdown` as a temporary layer after `anchor`, then commits it.
    private func insert(_ markdown: String, after anchor: DocBlockID) async {
        bringIntoView(anchor)
        try? await Task.sleep(for: .milliseconds(400))
        let layer = Layer(after: anchor, ids: newIDs())
        guard let text = await stream(markdown, into: layer) else { return }
        commitInsert(layer, markdown: text)
        await settle()
    }

    /// Rewrites a block in place: the old text goes and the new one writes itself
    /// where it was.
    private func rewrite(_ target: DocBlockID, with markdown: String) async {
        bringIntoView(target)
        try? await Task.sleep(for: .milliseconds(400))
        let previous = doc.blocks.firstIndex { $0.id == target }.flatMap { $0 > 0 ? doc.blocks[$0 - 1].id : nil }
        let layer = Layer(after: target, ids: newIDs(), replacing: target)
        guard let text = await stream(markdown, into: layer), let old = doc.block(target) else { return }
        var steps: [DocStep] = [.deleteBlock(block: old, after: nil)]
        steps += insertSteps(DocFragment(markdown: text, at: .now, using: &rng), ids: layer.ids, after: previous)
        self.layer?.committed = true
        apply(steps)
        await settle()
    }

    /// A phrase edit commits at once. The range fade-in it should get (only the new
    /// words fade, §6.3) needs a suffix-aware reveal in MarkdownView: not built yet.
    private func edit(_ target: DocBlockID, find: String, replace: String) async {
        bringIntoView(target)
        try? await Task.sleep(for: .milliseconds(600))
        guard let block = doc.block(target), let range = block.text.string.range(of: find) else { return }
        let lower = block.text.string.utf16.distance(from: block.text.string.startIndex, to: range.lowerBound)
        let upper = lower + find.utf16.count
        apply([
            .deleteText(block: target, range: lower..<upper, removed: DocText()),
            .insertText(block: target, at: lower, text: DocText(string: replace)),
        ])
    }

    /// Streams markdown into the layer the way a chat reply streams. Nil when stopped.
    private func stream(_ markdown: String, into layer: Layer) async -> String? {
        coordinator.reset()
        self.layer = layer
        publish()
        let parser = MarkdownStreamParser()
        var generation = 0
        parser.onBlocks = { [weak self] blocks in
            guard let self, self.layer != nil else { return }
            self.layer?.blocks = Array(blocks.prefix(layer.ids.count))
            generation += 1
            self.coordinator.syncBlocks(blocks.map { ($0.id, $0.revealPlainTextCount) }, generation: generation)
            self.publish()
        }
        var text = ""
        for chunk in DocDemoCorpus.chunks(of: markdown) {
            try? await Task.sleep(for: .milliseconds(30))
            if Task.isCancelled { return nil }
            text += chunk
            parser.submit(text, isStreaming: true)
        }
        await parser.update(text, isStreaming: false)
        coordinator.finishQuickly()
        return text
    }

    /// Keeps the layer on screen until its reveal has played, then shows the commit.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(900))
        layer = nil
        publish()
    }

    private func commitInsert(_ layer: Layer, markdown: String) {
        let fragment = DocFragment(markdown: markdown, at: .now, using: &rng)
        self.layer?.committed = true
        apply(insertSteps(fragment, ids: layer.ids, after: layer.after))
    }

    private func insertSteps(_ fragment: DocFragment, ids: [DocBlockID], after anchor: DocBlockID?) -> [DocStep] {
        var steps = fragment.databases.values.map { DocStep.createDatabase(database: $0) }
        var after = anchor
        for (index, var block) in fragment.blocks.enumerated() where index < ids.count {
            block.id = ids[index]
            steps.append(.insertBlock(block: block, after: after))
            after = block.id
        }
        return steps
    }

    private func newIDs() -> [DocBlockID] {
        (0..<64).map { _ in Identifier.generate(at: .now, using: &rng) }
    }

    func newBlockID() -> DocBlockID {
        Identifier.generate(at: .now, using: &rng)
    }

    /// A fresh row, column or database id.
    func newID<Tag>() -> Identifier<Tag> {
        Identifier.generate(at: .now, using: &rng)
    }

    // MARK: Link previews

    /// Asks for the pages of the bookmarks that say little about them; one undone back
    /// to before its preview gets it again.
    private func askForPreviews() {
        for block in doc.blocks {
            guard case .link(let link) = block.kind, DocLinkPreviews.wants(link) else { continue }
            if let preview = previews.previews[link.url] {
                DispatchQueue.main.async { [weak self] in self?.fill(link.url, with: preview) }
            } else {
                previews.ask(link.url)
            }
        }
    }

    /// The bookmarks of `url` with what they leave empty filled in from its page.
    private func fill(_ url: String, with preview: DocLinkPreviews.Preview) {
        let steps: [DocStep] = doc.blocks.compactMap { block in
            guard case .link(let link) = block.kind, link.url == url, DocLinkPreviews.wants(link) else { return nil }
            let filled = preview.filling(link)
            guard filled != link else { return nil }
            return .setBlock(block: block.id, kind: .link(link: filled), indent: block.indent, previousKind: block.kind, previousIndent: block.indent)
        }
        guard !steps.isEmpty, let resolved = try? doc.apply(DocTransaction(steps: steps, author: previewer, time: .now)) else { return }
        for step in resolved.steps { history.map(through: step) }
        DocStore.shared.share(resolved.steps, from: self)
        publish()
    }

    /// One agent operation is one transaction (§9.2); the person's history maps
    /// through it rather than recording it.
    private func apply(_ steps: [DocStep]) {
        do {
            let resolved = try doc.apply(DocTransaction(steps: steps, author: agent, time: .now))
            for step in resolved.steps { history.map(through: step) }
            DocStore.shared.share(resolved.steps, from: self)
        } catch {
            print("DocDemo: step failed: \(error)")
        }
        publish()
    }
}

/// Reproducible ids for the demo's commits.
struct DocDemoRNG: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }
}

extension DocRow {
    /// A rough height for the list to use until the row is measured.
    func estimatedHeight(width: CGFloat) -> CGFloat {
        let indent = DocBlockController.indentWidth(indent)
        let textWidth = max(100, min(width - DocBlockController.leadingGutter - DocBlockController.trailingGutter, 720) - indent)
        let boxPadding = DocTokens.Component.DecorationBox.padding
        let spacing = spacingAbove + spacingBelow + (box.map { ($0.isFirst ? boxPadding : 0) + ($0.isLast ? boxPadding : 0) } ?? 0)
        if let run, run.kind != nil {
            let page = max(0, DocBlockController.pageWidth(inWidth: width) - indent)
            let gap = run.kind == .floo ? DocMediaLayout.flooGap(in: page) : 0
            return DocMediaLayout.place(run, inPage: page).frame.height + gap + spacing
        }
        if let media, let height = DocMediaLayout.estimatedHeight(media, width: textWidth) { return height + spacing }
        if page != nil { return DocPageMetrics.rowHeight + spacing }
        if let recordFields { return CGFloat(recordFields + 1) * DocCollectionMetrics.rowHeight + 1 + spacing }
        if let collection {
            // The header, then the table's rows, a chart, or a kanban's longest column.
            if let chart = collection.collection.currentView?.layout.chart {
                let groups = Set(collection.database.rows.compactMap { $0.cells[chart.groupBy].map { "\($0)" } }).count
                return 80 + (chart.kind == .bar ? CGFloat(groups) * 26 : 230) + spacing
            }
            guard let view = collection.collection.currentView, view.layout.isKanban else {
                return 80 + CGFloat(collection.database.rows.count + 2) * 36 + spacing
            }
            let lanes = DocCollectionController.lanes(view, of: collection.database.rows, in: collection.database)
            return 80 + 40 + CGFloat(lanes.map(\.rows.count).max() ?? 0) * 80 + 42 + spacing
        }
        switch tree?.document.child(at: 0) {
        case let code as CodeBlock:
            return CGFloat(max(1, code.code.split(separator: "\n", omittingEmptySubsequences: false).count - 1)) * 18 + 46 + spacing
        case let table as Markdown.Table:
            return CGFloat(table.body.childCount + 1) * 44 + spacing
        case is BlockDirective:
            return 80 + spacing
        default:
            break
        }
        // Text, or the agent's markdown while it writes.
        let source = text?.plain ?? blocks.map(\.source).joined(separator: "\n")
        let perLine = max(1, Int(textWidth / 8.5))
        let wrapped = source.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + perLine - 1) / perLine) }
        return CGFloat(wrapped) * (22 + DocTypography.lineSpacing) + spacing
    }
}
