//
//  StrikethroughParsingTests.swift
//  MarkdownView
//

import Testing
@testable import MarkdownView

struct StrikethroughParsingTests {
    @Test
    func singleTildeRangesStayLiteral() {
        let text = """
        - **风力**：偏北风2级转3~4级，**阵风可达7~8级**
        - **假期最后两天**：以晴为主，气温回升，最高 24~28℃，最低 12~17℃
        """

        let blocks = MarkdownContent(text).topLevelBlocks(expandListItems: true)
        let plainTexts = blocks.map(\.plainText)

        #expect(plainTexts == [
            "风力：偏北风2级转3~4级，阵风可达7~8级",
            "假期最后两天：以晴为主，气温回升，最高 24~28℃，最低 12~17℃",
        ])
    }

    @Test
    func standardDoubleTildeStrikethroughIsPreserved() {
        let sanitized = MarkdownParseSanitizer.sanitizedForCmark("保留 ~~删除线~~，但 24~28℃ 是范围")

        #expect(sanitized == "保留 ~~删除线~~，但 24\\~28℃ 是范围")
    }

    @Test
    func codeSpansAndFencesAreNotEscaped() {
        let text = """
        `24~28℃`

        ```swift
        let range = "24~28"
        ```
        """

        #expect(MarkdownParseSanitizer.sanitizedForCmark(text) == text)
    }

    @Test
    func manuallyEscapedTildesAreNotEscapedAgain() {
        #expect(MarkdownParseSanitizer.sanitizedForCmark("24\\~28℃") == "24\\~28℃")
    }
}
