//
//  StreamingDestination.swift
//  DemoApp
//
//  Streams a reply chunk by chunk through MarkdownBlockSplitter,
//  StreamingRevealCoordinator and MarkdownStreamBlockView.
//

import SwiftUI
import MarkdownView
import FlooDesign

struct StreamingDestination: View {
    @State private var parser = MarkdownStreamParser(splitter: MarkdownBlockSplitter(
        normalizer: MarkdownSourceNormalizer(streamingFenceLanguages: ["writing"])
    ))
    @State private var coordinator = StreamingRevealCoordinator<UUID>()
    @State private var footnoteIndexCache = MarkdownFootnoteIndexCache()
    @State private var blocks: [MarkdownStreamBlock] = []
    @State private var streamTask: Task<Void, Never>?
    @State private var selectable = true
    @State private var layout = BlockSelectionScrollLayout()
    @State private var selection = {
        let selection = MarkdownBlockSelectionController()
        selection.motion = FlooDesignTokens.Motion.markdown
        return selection
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if selection.state.isActive {
                    selectionBar
                } else {
                    controls
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)

            BlockSelectionScrollView(layout: layout) {
                blockList
            }
            .overlay { MarkdownBlockSelectionOverlay(controller: selection) }
        }
        .task { selection.install(layout: layout) }
        .onChange(of: blocks.map(\.id), initial: true) { _, ids in
            selection.itemsProvider = {
                ids.map { .init(id: $0.uuidString, group: "reply", role: .candidate) }
            }
        }
    }

    private var controls: some View {
        HStack {
            Button(streamTask == nil ? "Stream" : "Stop") {
                streamTask == nil ? start() : stop()
            }
            .buttonStyle(.borderedProminent)
            Toggle("Selectable", isOn: $selectable)
                .fixedSize()
        }
    }

    private var selectionBar: some View {
        HStack {
            Text("\(selection.state.selectedItemIDs.count) selected")
            Spacer()
            Button("Copy") {
                let ids = Set(selection.selectedItems().map(\.id))
                UIPasteboard.general.string = blocks
                    .filter { ids.contains($0.id.uuidString) }
                    .map(\.source)
                    .joined(separator: "\n\n")
                selection.exitMode()
            }
            Button("Done") { selection.exitMode() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var blockList: some View {
        let footnoteIndex = footnoteIndexCache.index(for: blocks)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                let id = block.id.uuidString
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
                    .environment(\.markdownSelectableTextHooks, selection.hooks(for: id))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .blockSelectionItem(id, in: layout)
            }
        }
        .markdownSelectableTextEnabled(selectable)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func start() {
        coordinator.reset()
        parser.reset()
        blocks = []
        var generation = 0
        parser.onBlocks = { [coordinator] parsed in
            blocks = parsed
            generation += 1
            coordinator.syncBlocks(parsed.map { ($0.id, $0.revealPlainTextCount) }, generation: generation)
        }
        streamTask = Task {
            var text = ""
            for chunk in Self.chunks(of: Self.reply) {
                try? await Task.sleep(for: .milliseconds(60))
                if Task.isCancelled { break }
                text += chunk
                parser.submit(text, isStreaming: true)
            }
            await parser.update(text, isStreaming: false)
            coordinator.finishQuickly()
            streamTask = nil
        }
    }

    private func stop() {
        streamTask?.cancel()
        streamTask = nil
        coordinator.revealAll()
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

    Text fades in **character by character** as it arrives, with a hue sweep behind the frontier. Long-press any paragraph to *select* it; the selection runs across lines like ordinary text. Drag the selection past the paragraph to select whole blocks. 中文与 **强调** 同样适用。

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
    StreamingDestination()
}
