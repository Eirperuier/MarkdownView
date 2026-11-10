//
//  CatalogReveal.swift
//  DemoApp
//
//  Frames in the middle of a reveal, `-catalogRevealProbe YES`: a fixture's blocks at a fixed
//  revealed count. The reveal's clock is held still, so each renderer draws the same moment
//  every time and two sets compare pixel by pixel.
//
//  Each fixture comes twice:
//  - `.settled`: long after the count got there. All that shows is where it stops.
//  - `.fading`: its last characters came 0.1 s ago and those before them 0.3 s ago, so their
//    opacity and tint are part way.
//

import MarkdownView
import SwiftUI

/// What a frame is drawn from: the blocks and their reveals.
@MainActor
struct CatalogRevealed {
    let blocks: [MarkdownStreamBlock]
    let managers: [UUID: StreamingRevealManager]
}

@MainActor
enum CatalogReveal {
    private struct Source {
        let id: String
        let title: String
        let count: Int
        let markdown: String
    }

    private static let sources: [Source] = [
        .init(id: "paragraph", title: "Paragraph", count: 90, markdown: "The quick brown fox jumps over the lazy dog, then naps in the warm afternoon sun until the evening comes, and a little longer than that."),
        .init(id: "cjk", title: "Chinese", count: 30, markdown: "敏捷的棕色狐狸跳过了懒狗，然后在温暖的午后阳光下打盹，一直睡到傍晚。标点、数字 123 和 English 混排时间距要对。"),
        .init(id: "inline", title: "Bold, links, inline code", count: 60, markdown: "Some **bold words** and a [link to a page](https://example.com) with `inline code` and *italic text* running on after them."),
        .init(id: "emoji", title: "Emoji", count: 14, markdown: "🙂 Hello 👩‍💻 world 🇨🇳 and some more text 🎉 after it."),
        .init(id: "heading", title: "Heading", count: 12, markdown: "## A heading of a good length"),
        .init(id: "list", title: "List", count: 70, markdown: "- The first item, long enough to run across the line and wrap onto a second one in the row\n- The second item with **bold**\n- The third"),
        .init(id: "ordered", title: "Ordered list", count: 30, markdown: "1. Before applying the change, remember one visible cell\n2. Apply the insert without animation"),
        .init(id: "task", title: "Task list", count: 20, markdown: "- [x] A done thing to do\n- [ ] One not done yet, with a little more text"),
        .init(id: "quote", title: "Quote", count: 50, markdown: "> Never set the offset while the user is dragging or decelerating: even setting the current value stops the momentum."),
        .init(id: "math", title: "Inline maths", count: 40, markdown: "The curve $y = x^2$ stays low for most of the interval, and $\\omega$ alone sets how quickly it settles down."),
        .init(id: "blocks", title: "Three blocks", count: 150, markdown: "## Heading\n\nThe quick brown fox jumps over the lazy dog, then naps in the warm afternoon sun.\n\nThe quick brown fox jumps over the lazy dog, then naps in the warm afternoon sun."),
    ]

    static let group = CatalogGroup(id: "reveal", title: "Reveal", fixtures: sources.flatMap { source in
        ["settled", "fading"].map { CatalogFixture("reveal.\(source.id).\($0)", "\(source.title), \($0)", source.markdown) }
    })

    /// A fixed moment. Its hue in the highlight's cycle is fixed with it.
    private static let moment = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Holds the clock at the fixture's moment and brings its blocks there. Nil for any other fixture.
    static func prepare(_ fixture: CatalogFixture) -> CatalogRevealed? {
        guard fixture.id.hasPrefix("reveal."),
              let source = sources.first(where: { fixture.id.hasPrefix("reveal.\($0.id).") }) else { return nil }
        let fading = fixture.id.hasSuffix(".fading")
        var splitter = MarkdownBlockSplitter()
        let blocks = splitter.split(fixture.markdown)
        let managers = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, StreamingRevealManager()) })
        func advance(to count: Int) {
            var left = count
            for block in blocks {
                managers[block.id]?.revealedCount = min(left, block.revealPlainTextCount)
                left = max(0, left - block.revealPlainTextCount)
            }
        }
        MarkdownRevealClock.frozen = moment
        advance(to: max(0, source.count - 12))
        MarkdownRevealClock.frozen = moment.addingTimeInterval(0.2)
        advance(to: source.count)
        // 0.3 s and 0.1 s after each; or long after.
        MarkdownRevealClock.frozen = moment.addingTimeInterval(fading ? 0.3 : 30)
        return CatalogRevealed(blocks: blocks, managers: managers)
    }

    static func finish() {
        MarkdownRevealClock.frozen = nil
    }
}

/// The SwiftUI path's frame, as chat's rows reveal.
struct CatalogRevealView: View {
    let revealed: CatalogRevealed

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(revealed.blocks, id: \.id) { block in
                MarkdownStreamBlockView(block)
                    .markdownDisplayMathRendersSynchronously()
                    .markdownStreaming(revealed.managers[block.id])
                    .markdownFadeReveal(
                        duration: AppMotion.streamReveal.duration,
                        startHue: MarkdownFadeRevealConfig.legacyHighlightStartHue,
                        endHue: MarkdownFadeRevealConfig.legacyHighlightEndHue
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
