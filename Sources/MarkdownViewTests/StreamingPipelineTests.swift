//
//  StreamingPipelineTests.swift
//  MarkdownView
//

import Foundation
import Testing
@testable import MarkdownView

struct MarkdownSourceNormalizerTests {
    let normalizer = MarkdownSourceNormalizer()

    @Test func closesAnUnterminatedFence() {
        let normalized = normalizer.normalize("```swift\nlet x = 1")
        #expect(normalized == "```swift\nlet x = 1\n```")
    }

    @Test func marksOptedInFencesStillStreaming() {
        let normalizer = MarkdownSourceNormalizer(streamingFenceLanguages: ["writing"])
        let open = normalizer.normalize("```writing\nDraft")
        let body = open.dropFirst("```writing\n".count).dropLast("\n```".count)
        #expect(StreamingFenceMarker.peel(String(body)) == ("Draft", true))

        let closed = normalizer.normalize("```writing\nDraft\n```")
        #expect(!closed.contains(StreamingFenceMarker.line))
    }

    @Test func lengthensAnOuterFenceAroundALongerInnerRun() {
        // The inner ```` would otherwise close nothing and leave the outer fence ambiguous.
        let normalized = normalizer.normalize("```md\n````\n```")
        #expect(normalized == "`````md\n````\n`````")
    }

    @Test(arguments: [
        ("Area $a^2$ here", #"Area \(a^2\) here"#),
        ("Costs $5 and $10", "Costs $5 and $10"),
        ("`$x$` stays code", "`$x$` stays code"),
        (#"Escaped \$x$"#, #"Escaped \$x$"#),
    ])
    func convertsInlineDollarMath(source: String, expected: String) {
        #expect(normalizer.normalize(source) == expected)
    }

    @Test func unescapesNewlinesOutsideMathAndCode() {
        #expect(normalizer.normalize(#"a\nb `c\nd` $e\nf$"#) == "a\nb `c\\nd` \\(e\\nf\\)")
    }

    @Test(arguments: [
        ("See [the docs", "See "),
        ("See [the docs](https://exa", "See "),
        ("![img](https://x", ""),
        ("Done [a](b) now", "Done [a](b) now"),
        ("```json\n{\"items\":[{", "```json\n{\"items\":[{"),
    ])
    func trimsAHalfWrittenTailLink(source: String, expected: String) {
        #expect(MarkdownSourceNormalizer.trimmingStreamingTailPartialLink(source) == expected)
    }
}

struct MarkdownBlockSplitterTests {
    @Test func keepsIdsAcrossStreamingUpdates() {
        var splitter = MarkdownBlockSplitter()
        let first = splitter.split("# Title\n\nFirst para", isStreaming: true)
        let second = splitter.split("# Title\n\nFirst paragraph grows\n\n- one\n- two", isStreaming: true)

        #expect(first.count == 2)
        #expect(second.count == 4)
        #expect(second[0].id == first[0].id)
        #expect(second[1].id == first[1].id)
        #expect(Set(second.map(\.id)).count == second.count)
    }

    @Test func reusesTheDocumentOfAnUnchangedBlock() {
        var splitter = MarkdownBlockSplitter()
        let first = splitter.split("Intro\n\nTail")
        let second = splitter.split("Intro\n\nTail grows")
        #expect(second[0].content == first[0].content)
        #expect(second[1].content != first[1].content)
    }

    @Test func nestedFenceStaysOneBlock() {
        var splitter = MarkdownBlockSplitter()
        let blocks = splitter.split("""
        ````writing
        ## UI updates

        ```swift
        @MainActor
        final class ProfileViewModel: ObservableObject {}
        ```

        After the code block.
        ````
        """)
        #expect(blocks.count == 1)
        #expect(blocks.first?.source.hasPrefix("````writing") == true)
        #expect(blocks.first?.source.contains("After the code block.") == true)
    }

    @Test func customFencesAreHeldUntilRenderable() {
        var splitter = MarkdownBlockSplitter(customFence: { language, source in
            guard language == "card" else { return nil }
            return source.contains("}")
        })
        let pending = splitter.split("Text\n\n```card\n{\"a\":", isStreaming: true)
        #expect(pending.count == 1)

        let ready = splitter.split("Text\n\n```card\n{\"a\":1}\n```")
        #expect(ready.count == 2)
        #expect(ready[1].kind == .customFence(language: "card"))
        #expect(ready[1].revealPlainTextCount == 1)
    }

    @Test func extractsMathIntoStorage() {
        var splitter = MarkdownBlockSplitter()
        let blocks = splitter.split("Inline $x^2$ here\n\n$$\nE = mc^2\n$$")
        #expect(blocks.first?.inlineMathStorage?.values.contains(#"\(x^2\)"#) == true)
        #expect(blocks.first?.displayMathStorage?.values.contains { $0.contains("E = mc^2") } == true)
    }

    @Test func collectsHeadings() {
        var splitter = MarkdownBlockSplitter()
        _ = splitter.split("# One\n\ntext\n\n## Two")
        #expect(splitter.headings.map(\.text) == ["One", "Two"])
        #expect(splitter.headings.map(\.level) == [1, 2])
    }
}

@MainActor
struct StreamingRevealCoordinatorTests {
    @Test func revealAllFinishesEveryBlock() {
        let coordinator = StreamingRevealCoordinator<Int>()
        coordinator.syncBlocks([(id: 1, plainTextCount: 10), (id: 2, plainTextCount: 5)])
        coordinator.revealAll()
        #expect(coordinator.manager(for: 1)?.revealedCount == Int.max)
        #expect(coordinator.manager(for: 2)?.revealedCount == Int.max)
    }

    @Test func keepsTheDistanceToTheTailWhenTextShrinks() {
        let coordinator = StreamingRevealCoordinator<Int>()
        coordinator.syncBlocks([(id: 1, plainTextCount: 20)])
        coordinator.manager(for: 1)?.revealedCount = 18
        // `**bo` → `**bold**`: syntax closes and the plain text gets shorter.
        coordinator.syncBlocks([(id: 1, plainTextCount: 16)])
        #expect(coordinator.manager(for: 1)?.revealedCount == 14)
    }

    @Test func dropsManagersOfRemovedBlocks() {
        let coordinator = StreamingRevealCoordinator<Int>()
        coordinator.syncBlocks([(id: 1, plainTextCount: 3), (id: 2, plainTextCount: 3)])
        coordinator.syncBlocks([(id: 2, plainTextCount: 3)])
        #expect(coordinator.manager(for: 1) == nil)
        #expect(coordinator.manager(for: 2) != nil)
    }

    @Test func skipsARepeatedGeneration() {
        let coordinator = StreamingRevealCoordinator<Int>()
        coordinator.syncBlocks([(id: 1, plainTextCount: 3)], generation: 7)
        #expect(!coordinator.needsSync(generation: 7))
        #expect(coordinator.needsSync(generation: 8))
    }
}

struct MarkdownFootnoteIndexTests {
    @Test func numbersReferencesAndInlineNotesInDocumentOrder() {
        var splitter = MarkdownBlockSplitter()
        let blocks = splitter.split("""
        First^[inline note] then a ref[^b] and[^a].

        [^a]: Note A
        [^b]: Note B
        [^c]: Never referenced
        """)
        let index = MarkdownFootnoteIndex.build(blocks: blocks)

        #expect(index.inlineContents[1] == "inline note")
        #expect(index.standard["b"]?.number == 2)
        #expect(index.standard["a"]?.number == 3)
        #expect(index.standard["c"]?.number == 4)
        #expect(index.standard["c"]?.firstReferenceBlock == nil)
        #expect(index.standard["a"]?.definitionBlock == blocks[1].id)
    }

    @Test func ignoresFootnoteSyntaxInCode() {
        var splitter = MarkdownBlockSplitter()
        let blocks = splitter.split("```\nx[^a]\n```\n\n[^a]: Note")
        let index = MarkdownFootnoteIndex.build(blocks: blocks)
        #expect(index.standard["a"]?.firstReferenceBlock == nil)
    }

    @Test func buildsABlockContextWithCallerURLs() throws {
        var splitter = MarkdownBlockSplitter()
        // A one-word definition is also a valid link reference definition to cmark.
        let blocks = splitter.split("Ref[^a]\n\n[^a]: Note")
        #expect(blocks.count == 2)
        let index = MarkdownFootnoteIndex.build(blocks: blocks)
        let footnotes = try #require(index.footnotes(
            for: blocks[0].id,
            referenceURL: { URL(string: "app://ref/\($0)") },
            definitionURL: { URL(string: "app://def/\($0)") },
            inlineURL: { URL(string: "app://inline/\($0)") }
        ))
        #expect(footnotes.references["a"]?.referenceURL?.absoluteString == "app://ref/a")
        #expect(footnotes.references["a"]?.number == 1)
    }
}

@MainActor
struct MarkdownStreamParserTests {
    @Test func coalescesAndCommitsTheFinalText() async {
        let parser = MarkdownStreamParser()
        var commits: [[MarkdownStreamBlock]] = []
        parser.onBlocks = { commits.append($0) }
        var text = ""
        let words = (0..<200).map { "word\($0) " }
        for word in words {
            text += word
            parser.submit("# Title\n\n" + text, isStreaming: true)
        }
        let final = "# Title\n\n" + text + "\n\nTail."
        await parser.update(final, isStreaming: false)

        #expect(commits.count < words.count + 1, "superseded texts are skipped")
        #expect(parser.blocks.map(\.source) == ["# Title", text.trimmingCharacters(in: .whitespaces), "Tail."])
        // The heading kept its id from the first commit.
        #expect(parser.blocks.first?.id == commits.first?.first?.id)
    }

    @Test func resetDropsTheParseInFlight() async {
        let parser = MarkdownStreamParser()
        parser.submit("Old document.")
        parser.reset()
        await parser.update("New document.")
        #expect(parser.blocks.map(\.source) == ["New document."])
    }
}
