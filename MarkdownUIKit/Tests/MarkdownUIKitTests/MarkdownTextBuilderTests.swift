import Markdown
import FlooUIKit
import MarkdownCore
@testable import MarkdownUIKit
import RichTextCore
import UIKit
import XCTest

@MainActor
final class MarkdownTextBuilderTests: XCTestCase {
    private static let mixed = """
    # A title **bold**

    Plain *italic* `code`, a [link](https://example.com), https://bare.example.org and 中文。
    A soft break and a hard one  \nnext line with $x^2$ maths[^1] and a note^[inline].

    > A quote

    - One
    - [x] Done
    - {🚀} Emoji
    - {star.fill} Symbol
      - Nested
    1. First

       Second paragraph

    ==A highlight across **bold** and `code`== with :circle[a pen]{color=blue} and ^[red](color: red).

    [Cited](https://example.com/a "cite") [Folded](https://example.com/b "cite")

    ```swift
    let x = 1
    ```
    """

    private var style: MarkdownStyle {
        var style = MarkdownStyle()
        style.contentSizeCategory = .large
        style.linkSiteIcons = true
        let url = URL(string: "app://note")
        style.footnotes = MarkdownFootnotes(
            references: ["1": .init(number: 1, referenceURL: url, definitionURL: url)],
            inlineNotes: [.init(number: 2, url: url)]
        )
        return style
    }

    override func setUp() async throws {
        MarkdownHighlightSyntax.isEnabled = true
        MarkdownPenMarkSyntax.isEnabled = true
        MarkdownLinkChips.isEnabled = true
    }

    func testMapHasOneEntryPerCharacter() {
        let text = MarkdownTextBuilder.build(markdown: Self.mixed, style: style)
        XCTAssertEqual(text.storageToPlain.count, text.attributed.string.count)
    }

    func testMapNeverGoesBackAndEndsInsideTheTotal() {
        let text = MarkdownTextBuilder.build(markdown: Self.mixed, style: style)
        for (a, b) in zip(text.storageToPlain, text.storageToPlain.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b)
        }
        XCTAssertLessThanOrEqual(text.storageToPlain.last ?? 0, text.revealTotal)
    }

    func testPlainTextIsOneToOne() {
        let text = MarkdownTextBuilder.build(markdown: "Hello world", style: style)
        XCTAssertEqual(text.storageToPlain, Array(0..<11))
        XCTAssertEqual(text.revealTotal, 11)
    }

    func testHighlightDelimitersLeaveTheMap() {
        // Across nodes: the delimiters are found once the paragraph is put together.
        let text = MarkdownTextBuilder.build(markdown: "==a **b** c== d", style: style)
        XCTAssertEqual(text.attributed.string, "a b c d")
        XCTAssertEqual(text.storageToPlain.count, 7)
        XCTAssertEqual(text.revealTotal, 7)
    }

    func testMarkerHasNoPlainUnits() {
        let text = MarkdownTextBuilder.build(markdown: "- One", style: style)
        // "•", "\t", word joiner: anchored at the content's start.
        XCTAssertEqual(text.attributed.string.count, 6)
        XCTAssertEqual(text.storageToPlain, [0, 0, 0, 0, 1, 2])
        XCTAssertEqual(text.revealTotal, 3)
    }

    func testAPlaceholderAnchorsAtItsStart() {
        let text = MarkdownTextBuilder.build(markdown: "a $x$ b", style: style)
        XCTAssertEqual(text.attributed.string.filter { $0 == "\u{FFFC}" }.count, 1)
        XCTAssertEqual(text.storageToPlain.count, text.attributed.string.count)
    }

    func testPenAttributeIsThere() {
        let text = MarkdownTextBuilder.build(markdown: "a :circle[b]{color=blue} c", style: style)
        XCTAssertEqual(text.attributed.string, "a b c")
        let value = text.attributed.attribute(.richTextPenMark, at: 2, effectiveRange: nil) as? String
        XCTAssertEqual(MarkdownPenMarkSyntax.decodeAttributeValue(value ?? "")?.color, "blue")
    }

    func testAnItemsSecondParagraphIsItsOwn() {
        let text = MarkdownTextBuilder.build(markdown: "- First\n\n  Second", style: style)
        XCTAssertTrue(text.attributed.string.contains("First\nSecond"))
        XCTAssertEqual(text.storageToPlain.count, text.attributed.string.count)
    }

    func testNoColourIsResolvedAtBuildTime() {
        let text = MarkdownTextBuilder.build(markdown: "Plain **bold** [link](https://example.com) `code`", style: style)
        text.attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.attributed.length)) { value, _, _ in
            guard let color = value as? UIColor else { return XCTFail("A run with no colour") }
            let theme = FlooTheme.system.setting([.label: .systemPink, .accent: .systemOrange, .markdownInlineCode: .systemTeal])
            let themed = UITraitCollection { $0.flooTheme = theme }
            let plain = UITraitCollection { $0.flooTheme = .system }
            XCTAssertNotEqual(color.resolvedColor(with: themed), color.resolvedColor(with: plain))
        }
    }

    func testHeightWorksOffWindowAndDoesNotChangeInOne() {
        var style = self.style
        style.contentSizeCategory = .large
        var splitter = MarkdownBlockSplitter()
        for block in splitter.split(Self.mixed) {
            let view = MarkdownBlockView()
            view.configure(block, style: style)
            let off = view.height(forWidth: 400)
            if view.pendingBlock != nil {
                XCTAssertEqual(off, 0)
            } else {
                XCTAssertGreaterThan(off, 0, block.source)
            }
            let parent = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
            parent.addSubview(view)
            XCTAssertEqual(view.height(forWidth: 400), off, block.source)
        }
    }

    func testSimpleBlocksHaveAHeightOffWindow() {
        var style = self.style
        style.contentSizeCategory = .large
        style.blockDirectives["note"] = { _ in
            let view = UILabel()
            view.text = "A note"
            return view
        }
        for markdown in ["---", "<div>\nhtml\n</div>", "@note {\nA note.\n}", "![Alt](square.png)", "![Alt](https://catalog.test/never.png)", "- ![Alt](square.png)", "> ---"] {
            var splitter = MarkdownBlockSplitter()
            let block = splitter.split(markdown)[0]
            XCTAssertTrue(MarkdownBlockView.draws(block), markdown)
            let view = MarkdownBlockView()
            view.configure(block, style: style)
            XCTAssertNil(view.pendingBlock, markdown)
            XCTAssertGreaterThan(view.height(forWidth: 400), 0, markdown)
        }
    }

    func testARuleIsItsLineAndItsRoom() {
        var splitter = MarkdownBlockSplitter()
        let view = MarkdownBlockView()
        view.configure(splitter.split("---")[0], style: style)
        XCTAssertEqual(view.height(forWidth: 400), 31)
    }

    func testARelativeImageWithNoBaseIsItsDescription() {
        let text = MarkdownTextBuilder.build(markdown: "![Alt text only](square.png)", style: style)
        XCTAssertNotNil(text.attributed.attribute(.attachment, at: 0, effectiveRange: nil) as? MarkdownImageAttachment)
    }

    func testRolesOfSimpleBlocksFollowTheirFallbacks() {
        let light = UITraitCollection { $0.userInterfaceStyle = .light; $0.flooTheme = .system }
        XCTAssertEqual(UIColor.floo(.markdownImageCaption).resolvedColor(with: light), UIColor.secondaryLabel.resolvedColor(with: light))
    }

    func testARightToLeftItemKeepsItsLines() {
        var style = self.style
        style.contentSizeCategory = .large
        style.layoutDirection = .rightToLeft
        let line = String(repeating: "هذا نص عربي طويل جدا ", count: 12)
        let view = MarkdownBlockView()
        view.configure(markdown: "- \(line)", style: style)
        let height = view.height(forWidth: 400)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: height)
        view.layoutIfNeeded()
        let textView = view.textViews[0] as! InlineAttachmentTextView
        let frame: CGRect = textView.frame
        // All the room, and just the lines that needs.
        XCTAssertEqual(frame.width, 400)
        let oneItem = textView.sizeThatFits(CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude)).height
        XCTAssertEqual(frame.height, oneItem, accuracy: 0.5)
    }
}
