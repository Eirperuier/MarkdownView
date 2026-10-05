//
//  DocDemo.swift
//  DemoApp
//
//  D2 (Docs/doc.md §11): a DocKit document shown one row per block, and a scripted
//  agent that inserts, edits a phrase, rewrites, deletes and moves blocks. While it
//  writes the document is a read-only preview; what it is writing is a temporary layer
//  rendered and revealed like a streamed chat reply, committed as steps when done.
//

import SwiftUI
import DocKit
import MarkdownView

/// One list row: a committed block, or a block of what the agent is writing.
struct DocRow: Identifiable, Equatable {
    let id: String
    let blocks: [MarkdownStreamBlock]
    /// List nesting; the block's own markdown carries no indentation.
    let indent: Int
    /// Part of the agent's temporary layer: fades in through the reveal.
    let isStreaming: Bool
    /// The block an agent rewrite is replacing, while the new text streams in below it.
    let isFading: Bool
    private let source: String

    init(id: String, blocks: [MarkdownStreamBlock], indent: Int, isStreaming: Bool = false, isFading: Bool = false) {
        self.id = id
        self.blocks = blocks
        self.indent = indent
        self.isStreaming = isStreaming
        self.isFading = isFading
        source = blocks.map(\.source).joined(separator: "\n\n")
    }

    static func == (lhs: DocRow, rhs: DocRow) -> Bool {
        lhs.id == rhs.id && lhs.indent == rhs.indent && lhs.isStreaming == rhs.isStreaming
            && lhs.isFading == rhs.isFading && lhs.source == rhs.source
            && lhs.blocks.map(\.revealPlainTextCount) == rhs.blocks.map(\.revealPlainTextCount)
    }
}

/// How an agent's rewrite of a whole block replaces the old text (doc.md §9.3, 待定).
enum DocReplaceStyle: String, CaseIterable, Identifiable {
    /// The old block goes; the new text writes itself in its place.
    case inPlace = "原处重写"
    /// The old block dims and stays until the new text, written below it, is done.
    case fadeOld = "旧文变淡"
    /// The new text writes below the untouched old block, which then collapses.
    case thenCollapse = "写完收起"

    var id: String { rawValue }
}

@MainActor
@Observable
final class DocDemo {
    private(set) var doc: Doc
    private(set) var rows: [DocRow] = []
    /// What the agent is doing, shown in the bar; nil when idle.
    private(set) var agentStatus: String?
    var replaceStyle: DocReplaceStyle = .fadeOld
    /// A row the view should bring on screen (the agent's next change).
    private(set) var focus: (id: String, serial: Int)?

    @ObservationIgnored let coordinator = StreamingRevealCoordinator<UUID>()
    @ObservationIgnored private var rendered: [String: [MarkdownStreamBlock]] = [:]
    @ObservationIgnored private var layer: Layer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var rng = DocDemoRNG(seed: 0xD0C)
    @ObservationIgnored private var focusSerial = 0
    private let agent = DocAuthor.agent(client: Identifier(rawValue: UUID(uuidString: "00000000-0000-7000-8000-00000000A6E7")!))

    /// The agent's writing in progress: shown in the list, not in the doc.
    private struct Layer {
        /// The temporary blocks go after this one (nil: at the top).
        var after: DocBlockID?
        /// Ids the new blocks get on commit, decided before writing starts (§9.3).
        var ids: [DocBlockID]
        var blocks: [MarkdownStreamBlock] = []
        /// A block being rewritten: hidden, or dimmed, until the rewrite commits.
        var replacing: DocBlockID?
        var hidesReplaced: Bool
        var dimsReplaced: Bool
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
        publish()
    }

    // MARK: Rows

    private func publish() {
        var result: [DocRow] = []
        var layout = DocRowLayout()
        var emitted = false
        func emitLayer() {
            guard let layer, !emitted else { return }
            result += layerRows(layer)
            emitted = true
        }
        let live = layer.flatMap { $0.committed ? nil : $0 }
        if let live, live.after == nil { emitLayer() }
        for block in doc.blocks {
            let indent = layout.indent(of: block)
            // Committed but still revealing: the layer stands in for its blocks.
            if let layer, layer.ids.contains(block.id) {
                emitLayer()
                continue
            }
            if let live, live.replacing == block.id, live.hidesReplaced {
                emitLayer()
                continue
            }
            let markdown = doc.markdown(of: block.id) ?? ""
            let blocks = rendered[markdown] ?? {
                var splitter = MarkdownBlockSplitter()
                return splitter.split(markdown)
            }()
            rendered[markdown] = blocks
            let fading = live?.replacing == block.id && live?.dimsReplaced == true
            result.append(DocRow(id: block.id.description, blocks: blocks, indent: indent, isFading: fading))
            if let live, live.after == block.id { emitLayer() }
        }
        rows = result
    }

    private func layerRows(_ layer: Layer) -> [DocRow] {
        zip(layer.ids, layer.blocks).map { id, block in
            DocRow(id: id.description, blocks: [block], indent: 0, isStreaming: true)
        }
    }

    private func bringIntoView(_ id: DocBlockID?) {
        guard let id else { return }
        focusSerial += 1
        focus = (id.description, focusSerial)
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

    /// Stops the agent: committed operations stay; a rewrite or edit in progress is
    /// dropped, an insert keeps what it has written (doc.md §9.3).
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
            await edit(target.id, find: "self-sizing cells can change height *after* the insert".replacing("*", with: ""), replace: "a cell can still grow once it has been inserted")
        }
        try? await Task.sleep(for: pause)
        if let target = block(containing: "这周你的睡眠整体"), !Task.isCancelled {
            agentStatus = "正在改写一块(\(replaceStyle.rawValue))"
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
        let layer = Layer(after: anchor, ids: newIDs(), hidesReplaced: false, dimsReplaced: false)
        guard let text = await stream(markdown, into: layer) else { return }
        commitInsert(layer, markdown: text)
        await settle()
    }

    private func rewrite(_ target: DocBlockID, with markdown: String) async {
        bringIntoView(target)
        try? await Task.sleep(for: .milliseconds(400))
        let previous = doc.blocks.firstIndex { $0.id == target }.flatMap { $0 > 0 ? doc.blocks[$0 - 1].id : nil }
        let style = replaceStyle
        let layer = Layer(
            after: target, ids: newIDs(), replacing: target,
            hidesReplaced: style == .inPlace, dimsReplaced: style == .fadeOld
        )
        guard let text = await stream(markdown, into: layer) else { return }
        if style == .thenCollapse { try? await Task.sleep(for: .milliseconds(600)) }
        guard let old = doc.block(target) else { return }
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

    /// One agent operation is one transaction (§9.2).
    private func apply(_ steps: [DocStep]) {
        do {
            try doc.apply(DocTransaction(steps: steps, author: agent, time: .now))
        } catch {
            print("DocDemo: step failed: \(error)")
        }
        publish()
    }
}

/// List nesting as the export lays it out: an item is at most one level below the one
/// before it.
private struct DocRowLayout {
    private var depth = -1

    mutating func indent(of block: DocBlock) -> Int {
        guard case .listItem = block.kind else {
            depth = -1
            return 0
        }
        depth = min(block.indent, depth + 1)
        return depth
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
        let textWidth = max(100, min(width, 752) - 32 - CGFloat(indent) * 22)
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
