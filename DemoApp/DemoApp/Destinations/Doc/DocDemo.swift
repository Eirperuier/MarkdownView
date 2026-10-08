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
import MarkdownView

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
    /// A code or math block, edited as its source (and whether it's empty).
    let sourceKind: DocSourceKind?
    let sourceIsEmpty: Bool
    private let source: String
    private let depth: Int?

    init(id: String, block: DocBlockID?, blocks: [MarkdownStreamBlock], isStreaming: Bool = false, table: DocTableSnapshot? = nil,
         sourceKind: DocSourceKind? = nil, sourceIsEmpty: Bool = false) {
        self.id = id
        self.block = block
        self.blocks = blocks
        self.isStreaming = isStreaming
        self.table = table
        self.sourceKind = sourceKind
        self.sourceIsEmpty = sourceIsEmpty
        source = blocks.map(\.source).joined(separator: "\n\n")
        depth = blocks.first?.descriptor.listItemContext?.depth
    }

    static func == (lhs: DocRow, rhs: DocRow) -> Bool {
        lhs.id == rhs.id && lhs.isStreaming == rhs.isStreaming && lhs.source == rhs.source && lhs.table == rhs.table
            && lhs.sourceKind == rhs.sourceKind && lhs.sourceIsEmpty == rhs.sourceIsEmpty
            && lhs.depth == rhs.depth
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
    /// Rendering per markdown source: a block's own markdown, or a whole run of list
    /// items (split together so nesting and numbering are MarkdownView's own).
    @ObservationIgnored private var rendered: [String: [MarkdownStreamBlock]] = [:]
    @ObservationIgnored private var layer: Layer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var rng = DocDemoRNG(seed: 0xD0C)
    @ObservationIgnored private var focusSerial = 0
    /// The person's own undo history; the agent's steps only map through it (§7).
    @ObservationIgnored private var history = DocHistory()
    let person = DocAuthor.person(client: Identifier(rawValue: UUID(uuidString: "00000000-0000-7000-8000-0000000000E1")!))
    private let agent = DocAuthor.agent(client: Identifier(rawValue: UUID(uuidString: "00000000-0000-7000-8000-00000000A6E7")!))

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
        doc = Doc(id: Identifier(rawValue: UUID()), markdown: DocDemoCorpus.document)
        publish()
    }

    var isAgentWriting: Bool { agentStatus != nil }

    func reset() {
        stop()
        doc = Doc(id: doc.id, markdown: DocDemoCorpus.document)
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

    private static func markdown(of block: DocBlock, in database: Database) -> String {
        Doc(id: Identifier(rawValue: UUID()), blocks: [block], databases: [database.id: database]).markdown(of: block.id, style: .editing) ?? ""
    }

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
            if case .database(let id, _) = block.kind, let database = doc.databases[id] {
                if let cached = rowCache[block.id], cached.block == block, cached.database == database {
                    result.append(cached.row)
                } else {
                    let markdown = Self.markdown(of: block, in: database)
                    let row = DocRow(id: block.id.description, block: block.id, blocks: split(markdown), table: DocTableSnapshot(block: block.id, database: database))
                    rowCache[block.id] = (block, database, row)
                    result.append(row)
                }
                if let live, live.after == block.id { emitLayer() }
                continue
            }
            if let cached = rowCache[block.id], cached.block == block, cached.database == nil {
                result.append(cached.row)
            } else {
                // Outside a list a block's markdown is its own: no neighbour changes it.
                let markdown = Doc(id: doc.id, blocks: [block]).markdown(of: block.id, style: .editing) ?? ""
                let row = DocRow(id: block.id.description, block: block.id, blocks: split(markdown),
                                 sourceKind: DocSourceKind(block.kind), sourceIsEmpty: block.text.isEmpty)
                rowCache[block.id] = (block, nil, row)
                result.append(row)
            }
            if let live, live.after == block.id { emitLayer() }
        }
        rows = result
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    /// A run of list items is split as one list, so each item gets MarkdownView's
    /// marker, numbering and depth indentation; one descriptor per item.
    private func listRows(_ run: [DocBlock]) -> [DocRow] {
        let markdown = Doc(id: doc.id, blocks: run).markdown(style: .editing)
        let blocks = split(markdown)
        guard blocks.count == run.count else {
            return run.map { DocRow(id: $0.id.description, block: $0.id, blocks: split(doc.markdown(of: $0.id, style: .editing) ?? "")) }
        }
        return zip(run, blocks).map { DocRow(id: $0.id.description, block: $0.id, blocks: [$1]) }
    }

    private func split(_ markdown: String) -> [MarkdownStreamBlock] {
        if let cached = rendered[markdown] { return cached }
        // Every keystroke makes a new markdown: keep the cache from growing for ever.
        if rendered.count > 4000 { rendered.removeAll(keepingCapacity: true) }
        var splitter = MarkdownBlockSplitter()
        let blocks = splitter.split(markdown)
        rendered[markdown] = blocks
        return blocks
    }

    func bringIntoView(_ id: DocBlockID?) {
        guard let id else { return }
        focusSerial += 1
        focus = (id.description, focusSerial)
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
            agentStatus = "正在插入一段"
            await insert(DocDemoCorpus.inserted, after: anchor.id)
        }
        try? await Task.sleep(for: pause)
        if let target = block(containing: "self-sizing cells can change height"), !Task.isCancelled {
            agentStatus = "正在改一句话"
            await edit(target.id, find: "self-sizing cells can change height after the insert", replace: "a cell can still grow once it has been inserted")
        }
        try? await Task.sleep(for: pause)
        if let target = block(containing: "这周你的睡眠整体"), !Task.isCancelled {
            agentStatus = "正在改写一块"
            await rewrite(target.id, with: DocDemoCorpus.rewritten)
        }
        try? await Task.sleep(for: pause)
        if let target = block(containing: "Never set the offset"), !Task.isCancelled {
            agentStatus = "正在删除一块"
            bringIntoView(target.id)
            try? await Task.sleep(for: .milliseconds(500))
            apply([.deleteBlock(block: target, after: nil)])
        }
        try? await Task.sleep(for: pause)
        if let moving = block(containing: "Apply the insert without animation"),
            let after = block(containing: "Move the content offset"), !Task.isCancelled
        {
            agentStatus = "正在移动一块"
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
        let textWidth = max(100, min(width - 2 * DocBlockController.gutter, 720))
        let source = blocks.map(\.source).joined(separator: "\n")
        let lines = CGFloat(source.split(separator: "\n", omittingEmptySubsequences: false).count)
        if source.hasPrefix("```") { return lines * 18 + 56 }
        if source.hasPrefix("|") { return (lines - 1) * 44 + 10 }
        if source.hasPrefix("$$") || source.hasPrefix("\\begin") { return 90 }
        let perLine = max(1, Int(textWidth / 8.5))
        let wrapped = source.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + perLine - 1) / perLine) }
        return CGFloat(wrapped) * 24 + 10
    }
}
