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
import Markdown
import MarkdownView

/// A text block's content as its row shows it: the tree DocKit builds from the model and
/// MarkdownView renders (no markdown written or parsed in between), how deep a list item
/// sits, whether it's a quote; its text, for the row's first height.
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
    /// A paragraph, heading, list item or quote, from the model (DocTextRow).
    let text: DocTextRow?
    /// Code, maths, a divider, a card or a table, as the tree DocKit builds from the model.
    let tree: MarkdownTree?
    /// A link, file or image block, drawn as itself (DocMedia).
    let media: BlockKind?
    /// Several of them in one row (cards side by side, a gallery); `block` is the first.
    var members: [DocMediaMember] = []
    /// A code or math block, edited as its source (and whether it's empty).
    let sourceKind: DocSourceKind?
    let sourceIsEmpty: Bool
    /// Space above the row and below it (the page's bottom, on the last row): the
    /// document's rhythm, set when the rows are published (DocTypography).
    var spacingAbove: CGFloat = 0
    var spacingBelow: CGFloat = 0
    /// What the row is, for its spacing and line height.
    var role: DocRowRole = .paragraph
    /// Its part of a decoration's box: decorated rows next to each other share one.
    var box: DocRowBox?
    private let source: String
    private let depth: Int?

    init(id: String, block: DocBlockID?, blocks: [MarkdownStreamBlock] = [], text: DocTextRow? = nil, tree: MarkdownTree? = nil,
         isStreaming: Bool = false, table: DocTableSnapshot? = nil, media: BlockKind? = nil, sourceKind: DocSourceKind? = nil,
         sourceIsEmpty: Bool = false) {
        self.id = id
        self.block = block
        self.blocks = blocks
        self.text = text
        self.tree = tree
        self.isStreaming = isStreaming
        self.table = table
        self.media = media
        self.sourceKind = sourceKind
        self.sourceIsEmpty = sourceIsEmpty
        source = text?.plain ?? blocks.map(\.source).joined(separator: "\n\n")
        depth = text?.depth ?? blocks.first?.descriptor.listItemContext?.depth
    }

    static func == (lhs: DocRow, rhs: DocRow) -> Bool {
        lhs.id == rhs.id && lhs.isStreaming == rhs.isStreaming && lhs.source == rhs.source && lhs.text == rhs.text && lhs.tree == rhs.tree
            && lhs.table == rhs.table && lhs.media == rhs.media && lhs.members == rhs.members
            && lhs.sourceKind == rhs.sourceKind && lhs.sourceIsEmpty == rhs.sourceIsEmpty
            && lhs.depth == rhs.depth
            && lhs.spacingAbove == rhs.spacingAbove && lhs.spacingBelow == rhs.spacingBelow && lhs.role == rhs.role && lhs.box == rhs.box
            && lhs.blocks.map(\.revealPlainTextCount) == rhs.blocks.map(\.revealPlainTextCount)
    }
}

@MainActor
@Observable
final class DocDemo {
    private(set) var doc: Doc
    private(set) var rows: [DocRow] = []
    /// What the agent is doing, shown in the bar; nil when idle.
    private(set) var agentStatus: String?
    /// A row the view should bring on screen (the agent's next change).
    private(set) var focus: (id: String, serial: Int)?
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

    init() {
        doc = DocDemoCorpus.doc(id: Identifier(rawValue: UUID()))
        previews.onPreview = { [weak self] url, preview in self?.fill(url, with: preview) }
        publish()
    }

    var isAgentWriting: Bool { agentStatus != nil }

    func reset() {
        stop()
        doc = DocDemoCorpus.doc(id: doc.id)
        history = DocHistory()
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
        var result: [DocRow] = []
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
            // Cards next to each other share a row, as do images (not while the agent writes).
            if layer == nil, let kind = DocMediaLayout.run(block.kind) {
                let run = doc.blocks[(index - 1)...].prefix { DocMediaLayout.run($0.kind) == kind && $0.indent == block.indent }
                if run.count > 1 {
                    index += run.count - 1
                    // A new row when the members change: the list makes a row anew at its
                    // measured height; one updated in place can grow without redrawing. The
                    // same members in a new order are the same row (reordered in place).
                    let key = run.map(\.id.description).min() ?? block.id.description
                    var row = DocRow(id: "\(key)+\(run.count)", block: block.id, blocks: [], media: nil)
                    row.members = run.map { DocMediaMember(id: $0.id, kind: $0.kind) }
                    result.append(row)
                    continue
                }
            }
            if case .database(let id, _) = block.kind, let database = doc.databases[id] {
                if let cached = rowCache[block.id], cached.block == block, cached.database == database {
                    result.append(cached.row)
                } else {
                    let alone = Doc(id: doc.id, blocks: [block], databases: [database.id: database])
                    let row = DocRow(id: block.id.description, block: block.id, tree: Self.tree(block, in: alone),
                                     table: DocTableSnapshot(block: block.id, database: database))
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
                let row = if let text = Self.textRow(block, in: alone) {
                    DocRow(id: block.id.description, block: block.id, text: text)
                } else {
                    DocRow(id: block.id.description, block: block.id, tree: Self.tree(block, in: alone),
                           media: DocMediaView.draws(block.kind) ? block.kind : nil,
                           sourceKind: DocSourceKind(block.kind), sourceIsEmpty: block.text.isEmpty)
                }
                rowCache[block.id] = (block, nil, row)
                result.append(row)
            }
            if let live, live.after == block.id { emitLayer() }
        }
        space(&result)
        rows = result
        places = [:]
        for row in result where !row.members.isEmpty {
            for (index, member) in row.members.enumerated() { places[member.id] = (row.id, index) }
        }
        canUndo = history.canUndo
        canRedo = history.canRedo
        askForPreviews()
    }

    /// Each row's space above by what it is and what comes before it; the last row
    /// carries the page's bottom. Decorated rows next to each other make one box.
    private func space(_ rows: inout [DocRow]) {
        let kinds = Dictionary(uniqueKeysWithValues: doc.blocks.map { ($0.id, $0.kind) })
        let decorations = Dictionary(uniqueKeysWithValues: doc.blocks.map { ($0.id, $0.decoration) })
        let decorated = rows.map { row in row.block.flatMap { decorations[$0] } ?? nil }
        for index in rows.indices {
            guard let decoration = decorated[index] else {
                rows[index].box = nil
                continue
            }
            rows[index].box = DocRowBox(isFirst: index == 0 || decorated[index - 1] != decoration,
                                        isLast: index == rows.count - 1 || decorated[index + 1] != decoration)
        }
        var previous: DocRowRole?
        for index in rows.indices {
            let row = rows[index]
            let role = row.block.flatMap { kinds[$0] }.map(DocRowRole.init) ?? DocRowRole(markdown: row.blocks.first?.source ?? "")
            rows[index].role = role
            rows[index].spacingAbove = role.spacing(after: previous)
            rows[index].spacingBelow = index == rows.count - 1 ? DocTypography.pageBottom : 0
            previous = role
        }
        spacingAbove = Dictionary(rows.map { ($0.id, $0.spacingAbove) }, uniquingKeysWith: { first, _ in first })
    }

    /// Where a block sits in a row of several: the row and its place among the members.
    @ObservationIgnored private(set) var places: [DocBlockID: (row: String, index: Int)] = [:]

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
        // A quote's row draws the quote around what it holds (SelectableBlockQuote).
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

    func bringIntoView(_ id: DocBlockID?) {
        guard let id else { return }
        focusSerial += 1
        // The row it is in: its own, or the one it shares with others.
        focus = (places[id]?.row ?? id.description, focusSerial)
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
        publish()
        return resolved
    }

    /// Undoes the person's last transaction; returns where the cursor goes.
    func undo() -> DocSelection? {
        guard !isAgentWriting, let transaction = history.undo(&doc) else { return nil }
        publish()
        return transaction.selectionBefore
    }

    func redo() -> DocSelection? {
        guard !isAgentWriting, let transaction = history.redo(&doc) else { return nil }
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
        publish()
    }

    /// One agent operation is one transaction (§9.2); the person's history maps
    /// through it rather than recording it.
    private func apply(_ steps: [DocStep]) {
        do {
            let resolved = try doc.apply(DocTransaction(steps: steps, author: agent, time: .now))
            for step in resolved.steps { history.map(through: step) }
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
        let textWidth = max(100, min(width - DocBlockController.leadingGutter - DocBlockController.trailingGutter, 720))
        let boxPadding = FlooDesignTokens.Component.DecorationBox.padding
        let spacing = spacingAbove + spacingBelow + (box.map { ($0.isFirst ? boxPadding : 0) + ($0.isLast ? boxPadding : 0) } ?? 0)
        if !members.isEmpty {
            return DocMediaLayout.groupHeight(members.map(\.kind), width: min(720, width - DocBlockController.leadingGutter - DocBlockController.trailingGutter)) + spacing
        }
        if let media, let height = DocMediaLayout.estimatedHeight(media) { return height + spacing }
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
