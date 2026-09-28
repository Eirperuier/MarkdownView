//
//  ChatConversation.swift
//  DemoApp
//
//  A conversation flattened into list rows the way flowith's block-level list did:
//  one row per prompt and one per markdown block, so a long reply is many small cells.
//

import SwiftUI
import MarkdownView

struct ChatRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case prompt(String)
        case block(MarkdownStreamBlock)
    }

    let id: String
    let exchange: Int
    let kind: Kind
}

@MainActor
@Observable
final class ChatConversation {
    private struct Exchange {
        let id: Int
        let prompt: String
        var splitter = MarkdownBlockSplitter()
        var blocks: [MarkdownStreamBlock] = []
    }

    private(set) var rows: [ChatRow] = []
    /// The exchange whose reply streams (or last streamed); its blocks fade in.
    private(set) var streamingExchange: Int?
    var exchangeCount: Int { exchanges.count }

    @ObservationIgnored let coordinator = StreamingRevealCoordinator<UUID>()
    @ObservationIgnored private var exchanges: [Exchange] = []
    @ObservationIgnored private var generation = 0

    /// Replaces the conversation with `count` finished exchanges.
    func seed(_ count: Int) {
        exchanges = (0..<count).map { index in
            var exchange = Exchange(id: index, prompt: ChatCorpus.prompt(index))
            exchange.blocks = exchange.splitter.split(ChatCorpus.reply(index))
            return exchange
        }
        streamingExchange = nil
        coordinator.reset()
        publishRows()
    }

    /// Empties the list but keeps the exchanges, so `restore()` brings back the same rows (same ids).
    func hide() {
        rows = []
    }

    func restore() {
        publishRows()
    }

    /// Appends an exchange and streams `reply` into it chunk by chunk.
    func stream(_ reply: String, every interval: Duration) async {
        let id = (exchanges.last?.id ?? -1) + 1
        exchanges.append(Exchange(id: id, prompt: ChatCorpus.prompt(id)))
        coordinator.reset()
        generation = 0
        streamingExchange = id
        publishRows()

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
        exchanges[index].blocks = blocks
        generation += 1
        coordinator.syncBlocks(blocks.map { ($0.id, $0.revealPlainTextCount) }, generation: generation)
        publishRows()
    }

    private func publishRows() {
        rows = exchanges.flatMap { exchange in
            [ChatRow(id: "\(exchange.id)#prompt", exchange: exchange.id, kind: .prompt(exchange.prompt))]
                + exchange.blocks.map {
                    ChatRow(id: "\(exchange.id)#\($0.id.uuidString)", exchange: exchange.id, kind: .block($0))
                }
        }
    }
}
