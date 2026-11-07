//
//  ChatConversation.swift
//  DemoApp
//
//  A conversation flattened into list rows the way flowith's block-level list did:
//  one row per prompt and one per markdown block, so a long reply is many small cells.
//

import SwiftUI
import MarkdownView
import MessagingUI

struct ChatRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case prompt(String)
        case block(MarkdownStreamBlock)
    }

    let id: String
    let exchange: Int
    let kind: Kind
    /// Part of the reply streaming in (or last streamed): its blocks fade in. Carried by the
    /// row, not read from the conversation, so starting a stream updates only its own rows.
    let isStreaming: Bool
    /// Drawn by MarkdownUIKit under `-chatRenderer uikit`. Worked out once, here: the list asks
    /// about a row often.
    let drawsInUIKit: Bool
    /// What the row shows, flattened so comparing rows copies nothing.
    private let text: String
    private let revealCount: Int

    init(id: String, exchange: Int, kind: Kind, isStreaming: Bool = false, drawsInUIKit known: Bool? = nil) {
        self.id = id
        self.exchange = exchange
        self.kind = kind
        self.isStreaming = isStreaming
        switch kind {
        case .prompt(let prompt):
            text = prompt
            revealCount = 0
            drawsInUIKit = ChatRenderer.current == .uikit && TiledPerf.on("promptrow")
        case .block(let block):
            text = block.source
            revealCount = block.revealPlainTextCount
            drawsInUIKit = known ?? ChatUIKitBlock.draws(block)
        }
    }

    /// The list compares every row on every update (SwiftUI, TiledView's diff, @Observable),
    /// so this must stay cheap: an unchanged row shares its text's storage with the last one.
    /// A block's rendering follows from its source (its document and descriptor come from it).
    static func == (lhs: ChatRow, rhs: ChatRow) -> Bool {
        lhs.id == rhs.id && lhs.revealCount == rhs.revealCount && lhs.isStreaming == rhs.isStreaming
            && lhs.text == rhs.text
    }
}

@MainActor
@Observable
final class ChatConversation {
    private struct Exchange {
        let id: Int
        var splitter = MarkdownBlockSplitter()
        /// Rows are built when the blocks change, not on every publish: an unchanged row
        /// keeps its id and text storage, so comparing it with the last publish is cheap.
        private(set) var rows: [ChatRow]
        private var rowIDs: [UUID: String] = [:]
        private var blocks: [MarkdownStreamBlock] = []
        var isStreaming = false {
            didSet { if isStreaming != oldValue { setBlocks(blocks) } }
        }

        init(id: Int, prompt: String) {
            self.id = id
            rows = [ChatRow(id: "\(id)#prompt", exchange: id, kind: .prompt(prompt))]
        }

        mutating func setBlocks(_ blocks: [MarkdownStreamBlock]) {
            self.blocks = blocks
            var ids: [UUID: String] = [:]
            // A block that hasn't changed needs no second look.
            let previous = Dictionary(rows.dropFirst().compactMap { row -> (UUID, (String, Bool))? in
                guard case .block(let block) = row.kind else { return nil }
                return (block.id, (block.source, row.drawsInUIKit))
            }, uniquingKeysWith: { first, _ in first })
            rows = [rows[0]] + blocks.map { block in
                let rowID = rowIDs[block.id] ?? "\(id)#\(block.id.uuidString)"
                ids[block.id] = rowID
                let known = previous[block.id].flatMap { $0.0 == block.source ? $0.1 : nil }
                return ChatRow(id: rowID, exchange: id, kind: .block(block), isStreaming: isStreaming, drawsInUIKit: known)
            }
            rowIDs = ids
        }
    }

    /// What the list shows, one exchange's rows changed at a time: no array to compare and diff.
    @ObservationIgnored let list = TiledList<ChatRow>()
    @ObservationIgnored static let usesList = TiledPerf.on("list")
    /// The rows as one array, when the list isn't used: compared and diffed on each change.
    private(set) var arrayRows: [ChatRow] = []
    var rows: [ChatRow] { Self.usesList ? list.items : arrayRows }
    /// Exchanges before this one aren't loaded yet: a paged conversation shows its latest
    /// page first and loads older ones as the list reaches the top.
    private(set) var firstLoadedExchange = 0
    var hasOlder: Bool { firstLoadedExchange > 0 }
    var exchangeCount: Int { exchanges.count }

    @ObservationIgnored let coordinator = StreamingRevealCoordinator<UUID>()
    @ObservationIgnored private var exchanges: [Exchange] = []
    @ObservationIgnored private var generation = 0

    /// Replaces the conversation with `count` finished exchanges, showing the last `loaded`
    /// of them (all by default).
    func seed(_ count: Int, loaded: Int? = nil) {
        ChatUIKitBlockViews.dropViews(keepingHeights: false)
        exchanges = (0..<count).map { index in
            var exchange = Exchange(id: index, prompt: ChatCorpus.prompt(index))
            exchange.setBlocks(exchange.splitter.split(ChatCorpus.reply(index)))
            return exchange
        }
        firstLoadedExchange = max(0, count - (loaded ?? count))
        coordinator.reset()
        publishRows()
    }

    /// Loads the `count` exchanges before the loaded ones, after `latency` (a fetch).
    func loadOlder(_ count: Int, latency: Duration) async {
        guard hasOlder else { return }
        try? await Task.sleep(for: latency)
        let before = firstLoadedExchange
        firstLoadedExchange = max(0, firstLoadedExchange - count)
        if Self.usesList {
            list.prepend(exchanges[firstLoadedExchange..<before].flatMap(\.rows))
        } else {
            publishRows()
        }
    }

    /// Empties the list but keeps the exchanges, so `restore()` brings back the same rows (same ids).
    func hide() {
        if Self.usesList { list.reset([]) } else { arrayRows = [] }
        ChatUIKitBlockViews.dropViews(keepingHeights: true)
    }

    func restore() {
        publishRows()
    }

    /// Appends an exchange and streams `reply` into it chunk by chunk.
    func stream(_ reply: String, every interval: Duration) async {
        let id = (exchanges.last?.id ?? -1) + 1
        // The last streamed reply stops fading in; the new one starts.
        for index in exchanges.indices where exchanges[index].isStreaming {
            change(index) { $0.isStreaming = false }
        }
        var exchange = Exchange(id: id, prompt: ChatCorpus.prompt(id))
        exchange.isStreaming = true
        exchanges.append(exchange)
        coordinator.reset()
        generation = 0
        if Self.usesList {
            list.append(exchange.rows)
        } else {
            publishRows()
        }

        // Parsing runs off the main actor; blocks arrive as each parse commits.
        let parser = MarkdownStreamParser()
        parser.onBlocks = { [weak self] blocks in
            self?.commit(blocks, toExchange: id)
        }
        var text = ""
        for chunk in ChatCorpus.chunks(of: reply) {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { break }
            text += chunk
            parser.submit(text, isStreaming: true)
        }
        await parser.update(text, isStreaming: false)
        coordinator.finishQuickly()
    }

    private func commit(_ blocks: [MarkdownStreamBlock], toExchange id: Int) {
        guard let index = exchanges.lastIndex(where: { $0.id == id }) else { return }
        change(index) { $0.setBlocks(blocks) }
        generation += 1
        coordinator.syncBlocks(blocks.map { ($0.id, $0.revealPlainTextCount) }, generation: generation)
        if !Self.usesList { publishRows() }
    }

    /// Changes one exchange, and only its rows in the list.
    private func change(_ index: Int, _ body: (inout Exchange) -> Void) {
        let old = exchanges[index].rows
        body(&exchanges[index])
        guard Self.usesList, index >= firstLoadedExchange else { return }
        let before = index > firstLoadedExchange ? exchanges[index - 1].rows.last?.id : nil
        list.replace(old, with: exchanges[index].rows, after: before)
    }

    private func publishRows() {
        let rows = exchanges[firstLoadedExchange...].flatMap(\.rows)
        if Self.usesList { list.reset(rows) } else { arrayRows = rows }
    }
}

extension ChatRow {
    /// A rough height from the text alone, for the list to use until the row is measured.
    func estimatedHeight(width: CGFloat) -> CGFloat {
        let textWidth = max(100, min(width, 752) - 32)
        func proseHeight(_ text: String, lineHeight: CGFloat, charWidth: CGFloat) -> CGFloat {
            let perLine = max(1, Int(textWidth / charWidth))
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + max(1, ($1.count + perLine - 1) / perLine) }
            return CGFloat(lines) * lineHeight
        }
        switch kind {
        case .prompt(let text):
            return proseHeight(text, lineHeight: 22, charWidth: 8.5) + 52
        case .block(let block):
            let source = block.source
            let lines = CGFloat(source.split(separator: "\n", omittingEmptySubsequences: false).count)
            if source.hasPrefix("```") { return lines * 18 + 56 }
            if source.hasPrefix("|") { return (lines - 1) * 44 + 10 }
            if source.hasPrefix("$$") || source.hasPrefix("\\[") || source.contains("@math(") { return 90 }
            return proseHeight(source, lineHeight: 24, charWidth: 8.5) + 10
        }
    }
}
