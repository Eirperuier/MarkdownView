//
//  MarkdownRevealTests.swift
//  MarkdownUIKitTests
//

import MarkdownCore
import RichTextCore
import UIKit
import XCTest
@testable import MarkdownUIKit

@MainActor
final class MarkdownRevealTests: XCTestCase {
    private func block(_ text: String, splitter: inout MarkdownBlockSplitter) -> MarkdownStreamBlock {
        splitter.split(text)[0]
    }

    func testWhatIsDrawnHere() {
        var splitter = MarkdownBlockSplitter()
        XCTAssertTrue(MarkdownBlockView.draws(splitter.split("```swift\nlet a = 1\n```")[0]))
        var second = MarkdownBlockSplitter()
        XCTAssertTrue(MarkdownBlockView.draws(second.split("Some **text**.")[0]))
        var third = MarkdownBlockSplitter()
        XCTAssertFalse(MarkdownBlockView.draws(third.split("| a |\n|---|\n| b |")[0]))
    }

    /// The same block growing keeps its text view and what's in its storage: only the end changes.
    func testGrowingKeepsTheTextView() {
        var splitter = MarkdownBlockSplitter()
        let view = MarkdownBlockView()
        let manager = StreamingRevealManager()
        let reveal = MarkdownReveal(manager: manager)
        let first = block("The quick brown", splitter: &splitter)
        view.configure(first, style: MarkdownStyle(), reveal: reveal)
        let textView = view.textViews.first
        let second = block("The quick brown fox jumps", splitter: &splitter)
        XCTAssertEqual(first.id, second.id)
        view.configure(second, style: MarkdownStyle(), reveal: reveal)
        XCTAssertTrue(view.textViews.first === textView)
        XCTAssertEqual(view.textViews.first?.textStorage.string, "The quick brown fox jumps")
        view.prepareForReuse()
    }

    /// A height depends on the text alone, never on how much of it is revealed.
    func testRevealDoesNotChangeHeight() {
        var splitter = MarkdownBlockSplitter()
        let text = "The quick brown fox jumps over the lazy dog, then naps in the warm afternoon sun until the evening comes."
        let shown = block(text, splitter: &splitter)
        let plain = MarkdownBlockView()
        plain.configure(shown, style: MarkdownStyle())
        let revealing = MarkdownBlockView()
        let manager = StreamingRevealManager()
        manager.revealedCount = 3
        revealing.configure(shown, style: MarkdownStyle(), reveal: MarkdownReveal(manager: manager))
        XCTAssertEqual(plain.height(forWidth: 200), revealing.height(forWidth: 200))
        plain.prepareForReuse()
        revealing.prepareForReuse()
    }

    /// Past a fragment's end an emoji must still count: the frontier is in UTF-16 units.
    func testAllOfAnEmojiTextIsRevealedAtTheEnd() {
        var splitter = MarkdownBlockSplitter()
        let shown = block("🙂 a 👩‍💻 b", splitter: &splitter)
        let controller = MarkdownRevealController()
        let textView = InlineAttachmentTextView(usingTextLayoutManager: true)
        let text = MarkdownTextBuilder.build(markdown: shown.source, style: MarkdownStyle())
        textView.applyContent(NSMutableAttributedString(attributedString: text.attributed))
        let manager = StreamingRevealManager()
        controller.attach(textView, reveal: MarkdownReveal(manager: manager), storageToPlain: text.storageToPlain)
        manager.revealedCount = text.revealTotal
        let units = textView.textStorage.length
        XCTAssertTrue(controller.isRevealed(storageRange: NSRange(location: 0, length: units)))
        manager.revealedCount = 1
        XCTAssertFalse(controller.isRevealed(storageRange: NSRange(location: 0, length: units)))
        controller.detach()
    }
}
