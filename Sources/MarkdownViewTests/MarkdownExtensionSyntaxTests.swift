//
//  MarkdownExtensionSyntaxTests.swift
//  MarkdownView
//

import Foundation
import Testing
import Markdown
@testable import MarkdownView

/// The syntax extensions an app turns on at launch: `==highlight==`, `:circle[…]` pen marks,
/// `{🚀}` list bullets, extended headings and citation chips.
struct MarkdownExtensionSyntaxTests {
    init() {
        MarkdownHighlightSyntax.isEnabled = true
        MarkdownPenMarkSyntax.isEnabled = true
        MarkdownLinkChips.isEnabled = true
    }

    @Test(arguments: [
        ("a ==b== c", "a b c"),
        ("==一== 和 ==二==", "一 和 二"),
        ("empty ==== stays", "empty ==== stays"),
        ("===x=== stays", "===x=== stays"),
        ("==open\nline==", "==open\nline=="),
    ])
    func highlightDropsItsDelimiters(_ source: String, _ plain: String) {
        #expect(MarkdownHighlightSyntax.strippedPlainText(source) == plain)
    }

    @Test(arguments: [
        ("a :circle[关键] b", "a 关键 b"),
        (":wavy[maybe] so", "maybe so"),
        (":smile[x] stays", ":smile[x] stays"),
        (": circle[x] stays", ": circle[x] stays"),
        (":circle[] stays", ":circle[] stays"),
    ])
    func penMarksDropTheirDelimiters(_ source: String, _ plain: String) {
        #expect(MarkdownPenMarkSyntax.strippedPlainText(source) == plain)
    }

    @Test func penMarksOnlyCircleShortPhrases() {
        let long = ":circle[" + String(repeating: "长", count: 60) + "]"
        #expect(MarkdownPenMarkSyntax.strippedPlainText(long) == long)
    }

    @Test func revealCountsTextWithoutDelimiters() {
        let blocks = MarkdownContent("x ==y== :wavy[z]").topLevelBlocks()
        #expect(blocks.first?.plainText == "x y z")
    }

    @Test func listBulletsTakeAnEmojiOrASymbol() throws {
        let emoji = try #require(ListItem.parseMarkerToken("{🚀} 内容"))
        #expect(emoji.marker == .emoji("🚀"))
        #expect(emoji.stripCount == 4)
        let symbol = try #require(ListItem.parseMarkerToken("{star.fill}内容"))
        #expect(symbol.marker == .symbol("star.fill"))
        #expect(symbol.stripCount == 11)
        #expect(ListItem.parseMarkerToken("plain item") == nil)
        #expect(ListItem.parseMarkerToken("{} empty") == nil)
    }

    @Test func twoSameLevelHeadingsMakeATitleAndSubtitle() {
        let blocks = MarkdownContent("## Title\n## Subtitle\n\nBody\n\n## Alone\n### Deeper").topLevelBlocks()
        #expect(blocks.count == 4)
        #expect(blocks[0].extendedHeadingContext?.level == 2)
        #expect(blocks[0].plainText == "Title\nSubtitle")
        #expect(blocks[2].extendedHeadingContext == nil)
        #expect(blocks[3].extendedHeadingContext == nil)
    }

    @Test func chipURLsCarryEveryTarget() throws {
        let targets = ["https://apple.com/a?b=1&c=2", "flowith-tool://search_ab12cd"]
        let url = try #require(MarkdownLinkChips.chipURL(for: targets))
        #expect(url.scheme == MarkdownLinkChips.scheme)
        #expect(MarkdownLinkChips.urls(from: url) == targets)
        #expect(MarkdownLinkChips.urls(from: URL(string: "https://apple.com")!) == nil)
    }
}
