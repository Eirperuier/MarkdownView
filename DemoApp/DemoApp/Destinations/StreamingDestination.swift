//
//  StreamingDestination.swift
//  DemoApp
//
//  Streams a reply chunk by chunk through MarkdownBlockSplitter,
//  StreamingRevealCoordinator and MarkdownStreamBlockView.
//

import SwiftUI
import MarkdownView

struct StreamingDestination: View {
    @State private var splitter = MarkdownBlockSplitter(
        normalizer: MarkdownSourceNormalizer(streamingFenceLanguages: ["writing"])
    )
    @State private var coordinator = StreamingRevealCoordinator<UUID>()
    @State private var footnoteIndexCache = MarkdownFootnoteIndexCache()
    @State private var blocks: [MarkdownStreamBlock] = []
    @State private var streamTask: Task<Void, Never>?
    @State private var selectable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(streamTask == nil ? "Stream" : "Stop") {
                    streamTask == nil ? start() : stop()
                }
                .buttonStyle(.borderedProminent)
                Toggle("Selectable", isOn: $selectable)
                    .fixedSize()
            }

            let footnoteIndex = footnoteIndexCache.index(for: blocks)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { block in
                    MarkdownStreamBlockView(block)
                        .markdownStreaming(coordinator.ensureManager(for: block.id))
                        .markdownFadeReveal(
                            duration: 0.5,
                            startHue: MarkdownFadeRevealConfig.legacyHighlightStartHue,
                            endHue: MarkdownFadeRevealConfig.legacyHighlightEndHue
                        )
                        .markdownFootnotes(footnoteIndex.footnotes(
                            for: block.id,
                            referenceURL: { URL(string: "demo-footnote://ref/\($0)") },
                            definitionURL: { URL(string: "demo-footnote://def/\($0)") },
                            inlineURL: { URL(string: "demo-footnote://inline/\($0)") }
                        ))
                }
            }
            .markdownSelectableTextEnabled(selectable)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func start() {
        coordinator.reset()
        splitter.reset()
        blocks = []
        streamTask = Task {
            var text = ""
            var generation = 0
            for chunk in Self.chunks(of: Self.reply) {
                try? await Task.sleep(for: .milliseconds(60))
                if Task.isCancelled { break }
                text += chunk
                update(text, isStreaming: true, generation: &generation)
            }
            update(text, isStreaming: false, generation: &generation)
            coordinator.finishQuickly()
            streamTask = nil
        }
    }

    private func stop() {
        streamTask?.cancel()
        streamTask = nil
        coordinator.revealAll()
    }

    private func update(_ text: String, isStreaming: Bool, generation: inout Int) {
        blocks = splitter.split(text, isStreaming: isStreaming)
        generation += 1
        coordinator.syncBlocks(blocks.map { ($0.id, $0.revealPlainTextCount) }, generation: generation)
    }

    /// Uneven chunks, like a model's token stream.
    private static func chunks(of text: String) -> [String] {
        var chunks: [String] = []
        var rest = Substring(text)
        var size = 3
        while !rest.isEmpty {
            chunks.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
            size = size % 11 + 3
        }
        return chunks
    }

    private static let reply = #"""
    # Streaming reveal

    Text fades in **character by character** as it arrives, with a hue sweep behind the frontier. Long-press any paragraph to *select* it; the selection runs across lines like ordinary text. 中文与 **强调** 同样适用。

    - Blocks keep their ids while the text grows, so nothing re-renders from scratch.
    - A half-written [link](https://example.com) never flashes its raw source.
    - Inline math like $e^{i\pi} + 1 = 0$ and footnotes[^1] ride along.

    $$
    \int_0^1 x^2\,dx = \frac{1}{3}
    $$

    > Quotes are selectable too, with the same look as before.

    ```swift
    let splitter = MarkdownBlockSplitter()
    ```

    | Block | Selectable |
    |---|---|
    | Paragraph | Yes |
    | Table cell | Yes |

    [^1]: Footnote definitions render as their own list.
    """#
}

#Preview {
    ScrollView {
        StreamingDestination()
            .padding()
    }
}
