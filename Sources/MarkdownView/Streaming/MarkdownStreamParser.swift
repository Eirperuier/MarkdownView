//
//  MarkdownStreamParser.swift
//  MarkdownView
//
//  Parses a growing document off the main actor. Ported from ios-flowith's
//  MessageParser and MessageParserUpdateScheduler (Views/Components/MarkdownRenderView.swift):
//  at most one parse in flight, the latest text wins, and texts superseded while a parse
//  runs are never parsed. Each parse is still of the whole text; unchanged blocks keep
//  their documents (see MarkdownBlockSplitter), so only the growing block re-renders.
//

import Foundation

@MainActor
public final class MarkdownStreamParser {
    /// Called on the main actor with each committed parse.
    public var onBlocks: (([MarkdownStreamBlock]) -> Void)?
    /// The last committed parse.
    public private(set) var blocks: [MarkdownStreamBlock] = []
    public private(set) var headings: [MarkdownBlockSplitter.Heading] = []

    private struct Request {
        let id: Int
        let text: String
        let isStreaming: Bool
    }

    /// Owned by the parse in flight while one runs, so it is never copied mid-parse.
    private var splitter: MarkdownBlockSplitter?
    private var pending: Request?
    private var isParsing = false
    private var nextRequestID = 0
    private var completedThrough = 0
    /// Bumped by `reset()`; a parse started before it is dropped.
    private var generation = 0
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    public init(splitter: MarkdownBlockSplitter = MarkdownBlockSplitter()) {
        self.splitter = splitter
    }

    /// Queues `text` for parsing, replacing any queued text not yet started.
    /// For each chunk of a stream; blocks arrive through ``onBlocks``.
    public func submit(_ text: String, isStreaming: Bool = false) {
        _ = enqueue(text, isStreaming: isStreaming)
    }

    /// Like ``submit(_:isStreaming:)``, and returns once this text's blocks are committed
    /// or a later text superseded it. Await the final text before finishing a reveal.
    public func update(_ text: String, isStreaming: Bool = false) async {
        await waitForCompletion(of: enqueue(text, isStreaming: isStreaming))
    }

    private func enqueue(_ text: String, isStreaming: Bool) -> Int {
        nextRequestID += 1
        let id = nextRequestID
        // Whatever was queued is superseded, not parsed.
        finish(through: id - 1)
        pending = Request(id: id, text: text, isStreaming: isStreaming)
        parseNextIfIdle()
        return id
    }

    /// Drops queued and in-flight work and forgets block ids; the next update starts fresh.
    public func reset() {
        generation += 1
        pending = nil
        finish(through: nextRequestID)
        blocks = []
        headings = []
        if !isParsing {
            splitter?.reset()
        }
    }

    private func parseNextIfIdle() {
        guard !isParsing, let request = pending, var splitter = splitter.take() else { return }
        pending = nil
        isParsing = true
        let generation = generation
        Task {
            let parsed = await Self.parse(request.text, isStreaming: request.isStreaming, with: splitter)
            splitter = parsed.splitter
            if generation != self.generation {
                // Reset while parsing: this splitter's ids belong to the old document.
                splitter.reset()
            } else {
                // Commit even when a newer text is queued: it is newer than what shows, and
                // dropping superseded results would starve while text outpaces parsing.
                blocks = parsed.blocks
                headings = splitter.headings
                onBlocks?(parsed.blocks)
            }
            self.splitter = splitter
            isParsing = false
            finish(through: request.id)
            parseNextIfIdle()
        }
    }

    @concurrent
    private nonisolated static func parse(
        _ text: String,
        isStreaming: Bool,
        with splitter: MarkdownBlockSplitter
    ) async -> (blocks: [MarkdownStreamBlock], splitter: MarkdownBlockSplitter) {
        var splitter = splitter
        let blocks = splitter.split(text, isStreaming: isStreaming)
        return (blocks, splitter)
    }

    private func waitForCompletion(of id: Int) async {
        guard id > completedThrough else { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    private func finish(through id: Int) {
        guard id > completedThrough else { return }
        completedThrough = id
        for key in waiters.keys where key <= id {
            waiters.removeValue(forKey: key)?.forEach { $0.resume() }
        }
    }
}
