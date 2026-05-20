//
//  MarkdownInlineHTMLTests.swift
//  MarkdownView
//

import Testing
@testable import MarkdownView

struct MarkdownInlineHTMLTests {
    @Test
    func breakTagsNormalizeToLineBreaks() {
        #expect(MarkdownInlineHTML.replacementText(for: "<br>") == "\n")
        #expect(MarkdownInlineHTML.replacementText(for: "<br/>") == "\n")
        #expect(MarkdownInlineHTML.replacementText(for: "<BR />") == "\n")
        #expect(MarkdownInlineHTML.replacementText(for: "<br class=\"compact\">") == "\n")
        #expect(MarkdownInlineHTML.replacementText(for: "<b>") == nil)
        #expect(MarkdownInlineHTML.replacementText(for: "</br>") == nil)
    }

    @Test
    func tablePlainTextCountsBreakTagsAsOneLineBreak() {
        let markdown = """
        | Name | Notes |
        | --- | --- |
        | A | first<br>second |
        """

        let blocks = MarkdownContent(markdown).topLevelBlocks()

        #expect(blocks.first?.plainText == "NameNotesAfirst\nsecond")
    }
}
