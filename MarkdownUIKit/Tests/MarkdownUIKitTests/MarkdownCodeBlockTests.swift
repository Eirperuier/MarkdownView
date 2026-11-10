//
//  MarkdownCodeBlockTests.swift
//  MarkdownUIKitTests
//

import FlooUIKit
@testable import MarkdownCore
import UIKit
import XCTest
@testable import MarkdownUIKit

@MainActor
final class MarkdownCodeBlockTests: XCTestCase {
    func testALastNewlineIsNotALine() {
        XCTAssertEqual(MarkdownCodeLines(code: "a\nb\n").lines, ["a", "b"])
        XCTAssertEqual(MarkdownCodeLines(code: "a\n\nb").lines, ["a", "", "b"])
    }

    func testLinesPastTheLimitAreCounted() {
        let lines = MarkdownCodeLines(code: (1...20).map(String.init).joined(separator: "\n"))
        XCTAssertEqual(lines.shownCount(showsAll: false), markdownCodeLineLimit)
        XCTAssertEqual(lines.hiddenCount(showsAll: false), 20 - markdownCodeLineLimit)
        XCTAssertEqual(lines.hiddenCount(showsAll: true), 0)
    }

    /// Off any window, before any layout: the same height it has once it's laid out.
    func testHeightIsKnownBeforeLayout() {
        let code = "let short = 1\n" + String(repeating: "let long = 2 ", count: 40) + "\nlet last = 3"
        let block = MarkdownCodeBlockView()
        block.configure(code: code, language: "swift", style: MarkdownStyle())
        let height = block.height(forWidth: 300)
        XCTAssertGreaterThan(height, 0)
        block.frame = CGRect(x: 0, y: 0, width: 300, height: height)
        block.layoutIfNeeded()
        XCTAssertEqual(block.height(forWidth: 300), height)
        XCTAssertGreaterThan(height, block.height(forWidth: 600), "a long line wraps less when it's wider")
    }

    /// Past the limit, more lines don't make the block taller.
    func testHeightStopsAtTheLimit() {
        func height(_ count: Int) -> CGFloat {
            let block = MarkdownCodeBlockView()
            block.configure(code: (1...count).map { "line \($0)" }.joined(separator: "\n"), language: nil, style: MarkdownStyle())
            return block.height(forWidth: 400)
        }
        XCTAssertEqual(height(20), height(40))
        XCTAssertGreaterThan(height(15), height(14))
    }

    /// The same block growing keeps its text view; what's there stays, only the end is added.
    func testGrowingKeepsTheTextView() {
        var splitter = MarkdownBlockSplitter()
        let view = MarkdownBlockView()
        let first = splitter.split("```swift\nlet a = 1")[0]
        view.configure(first, style: MarkdownStyle())
        let textView = view.textViews.first
        XCTAssertNotNil(textView)
        let second = splitter.split("```swift\nlet a = 1\nlet b = 2")[0]
        XCTAssertEqual(first.id, second.id)
        view.configure(second, style: MarkdownStyle())
        XCTAssertTrue(view.textViews.first === textView)
        XCTAssertEqual(view.textViews.first?.textStorage.string, "let a = 1\nlet b = 2")
        view.prepareForReuse()
    }

    /// While a fence is open, a line that's ended has an empty row after it: where the next goes.
    func testAnEndedLineInAnOpenFenceKeepsARowForTheNext() {
        var splitter = MarkdownBlockSplitter()
        let view = MarkdownBlockView()
        view.configure(splitter.split("```swift\nlet a = 1\n")[0], style: MarkdownStyle())
        XCTAssertEqual(view.textViews.first?.textStorage.string, "let a = 1\n")
        view.prepareForReuse()
    }

    /// A reveal changes what shows, never the height, at any point in the text.
    func testRevealDoesNotChangeHeight() {
        var splitter = MarkdownBlockSplitter()
        let block = splitter.split("```swift\n" + (1...20).map { "let line\($0) = 1" }.joined(separator: "\n") + "\n```")[0]
        let plain = MarkdownBlockView()
        plain.configure(block, style: MarkdownStyle())
        let manager = StreamingRevealManager()
        let revealing = MarkdownBlockView()
        revealing.configure(block, style: MarkdownStyle(), reveal: MarkdownReveal(manager: manager))
        for revealed in [0, 3, 40, 400, Int.max] {
            manager.revealedCount = revealed
            XCTAssertEqual(revealing.height(forWidth: 320), plain.height(forWidth: 320))
        }
        plain.prepareForReuse()
        revealing.prepareForReuse()
    }

    func testAFenceInAnItemIsSplitFromItsText() throws {
        let split = try XCTUnwrap(MarkdownFencedItemView.split("- Some text\n  ```swift\n  let x = 1\n  ```"))
        XCTAssertEqual(split.lead, "- Some text")
        XCTAssertEqual(split.rest, "```swift\nlet x = 1\n```")
    }

    /// An item starting with a fence has one code block: its closing line isn't another fence.
    func testAFenceOnTheMarkerLineOpensOneBlock() throws {
        let split = try XCTUnwrap(MarkdownFencedItemView.split("- ```swift\n  let x = 1\n  ```"))
        var splitter = MarkdownBlockSplitter()
        XCTAssertEqual(splitter.split(split.rest).count, 1)
        XCTAssertFalse(split.rest.hasSuffix("```\n```"))
    }

    /// An item's fence is closed as it's written: nothing is added that would open another.
    func testClosedFenceOnAMarkerLineStaysClosed() {
        let source = "- ```swift\n  let x = 1\n  ```\n- Next"
        XCTAssertEqual(sanitizeMarkdownCodeFences(source, streamingFenceLanguages: []), source)
    }

    /// `custom` draws the whole block: no box of this one's.
    func testCustomDrawsTheWholeBlock() {
        final class Box: UIView {
            override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: 77) }
        }
        var style = MarkdownStyle()
        var asked: (String, String?)?
        style.codeBlock.custom = { code, language, _ in
            asked = (code, language)
            return Box()
        }
        var splitter = MarkdownBlockSplitter()
        let view = MarkdownBlockView()
        view.configure(splitter.split("```swift\nlet a = 1\n```")[0], style: style)
        XCTAssertEqual(asked?.1, "swift")
        XCTAssertEqual(asked?.0.trimmingCharacters(in: .newlines), "let a = 1")
        XCTAssertEqual(view.height(forWidth: 300), 77)
        XCTAssertTrue(view.textViews.isEmpty)
        view.prepareForReuse()
    }

    // MARK: The box

    private func boxView(_ source: String, style: MarkdownStyle = MarkdownStyle()) -> MarkdownBlockView {
        var splitter = MarkdownBlockSplitter()
        let view = MarkdownBlockView()
        view.configure(splitter.split(source)[0], style: style)
        return view
    }

    func testTheDefaultLookIsTheBoxAndHeaderIsAnOption() {
        let box = boxView("```swift\nlet a = 1\n```")
        XCTAssertNotNil(box.subviews.first as? MarkdownCodeBoxView)
        box.prepareForReuse()
        var style = MarkdownStyle()
        style.codeBlock.look = .header
        let header = boxView("```swift\nlet a = 1\n```", style: style)
        XCTAssertNotNil(header.subviews.first as? MarkdownCodeBlockView)
        header.prepareForReuse()
    }

    /// A renderer's switch needs the header; a bare renderer is its own view.
    func testALanguageWithARendererKeepsTheHeader() {
        var style = MarkdownStyle()
        style.codeBlock.renderers["chart"] = MarkdownCodeRenderer { _, _ in UIView() }
        let view = boxView("```chart\nx\n```", style: style)
        XCTAssertNotNil(view.subviews.first as? MarkdownCodeBlockView)
        view.prepareForReuse()
    }

    /// From the line count alone, off any window, with every line and none wrapping.
    func testBoxHeightIsItsLines() {
        let metrics = MarkdownCodeBoxMetrics(bodySize: MarkdownStyle().resolvedBodyTextSize)
        let long = "let long = " + String(repeating: "2 ", count: 400)
        let view = boxView("```swift\n" + (1...40).map { "line \($0)" }.joined(separator: "\n") + "\n" + long + "\n```")
        let height = view.height(forWidth: 300)
        XCTAssertEqual(height, 2 + metrics.edge * 2 + 41 * metrics.pitch)
        XCTAssertEqual(view.height(forWidth: 600), height)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: height)
        view.layoutIfNeeded()
        XCTAssertEqual(view.height(forWidth: 300), height)
        view.prepareForReuse()
    }

    /// DocKit's sizes, measured at 13 points.
    func testBoxMetricsScaleFromThirteen() {
        let metrics = MarkdownCodeBoxMetrics(bodySize: 15.2)
        XCTAssertEqual(metrics.font.pointSize, 13)
        XCTAssertEqual(metrics.pitch, 20)
        XCTAssertEqual(metrics.edge, 9)
        XCTAssertEqual(metrics.numberTrailing, 10.5)
        XCTAssertEqual(metrics.codeLeading, 14)
    }

    func testBoxGrowingKeepsTheTextView() {
        var splitter = MarkdownBlockSplitter()
        let view = MarkdownBlockView()
        let first = splitter.split("```swift\nlet a = 1")[0]
        view.configure(first, style: MarkdownStyle())
        let textView = view.textViews.first
        XCTAssertNotNil(textView)
        view.configure(splitter.split("```swift\nlet a = 1\nlet b = 2")[0], style: MarkdownStyle())
        XCTAssertTrue(view.textViews.first === textView)
        XCTAssertEqual(view.textViews.first?.textStorage.string, "let a = 1\nlet b = 2")
        view.prepareForReuse()
    }

    /// Under `.system` the box is the text colour's opacities, as DocKit's; a theme's are stronger.
    func testBoxRolesFollowTheText() {
        func alpha(_ role: FlooColorRole, _ theme: FlooTheme) -> CGFloat {
            var value: CGFloat = 0
            UIColor.floo(role).resolvedColor(with: UITraitCollection { $0.userInterfaceStyle = .light; $0.flooTheme = theme }).getRed(nil, green: nil, blue: nil, alpha: &value)
            return value
        }
        let labelAlpha = alpha(.markdownText, .system)
        XCTAssertEqual(alpha(.markdownCodeBoxFill, .system), labelAlpha * 0.014, accuracy: 0.001)
        XCTAssertEqual(alpha(.markdownCodeBoxBorder, .system), labelAlpha * 0.09, accuracy: 0.001)
        XCTAssertGreaterThan(alpha(.markdownCodeBoxBorder, .surface(.systemOrange)), 0.1)
    }

    // MARK: Images

    /// An image alone has a panel at the width in DocKit's shape; one in a line stays small.
    func testAPanelIsWholeWidthOnlyAlone() throws {
        let url = URL(string: "https://example.invalid/x.png")!
        let alone = MarkdownImageView(content: .loading(url), isAlone: true, alternativeText: nil, fallbackText: nil, style: MarkdownStyle())
        XCTAssertEqual(alone.fittedSize(width: 400), CGSize(width: 400, height: 300))
        let inline = MarkdownImageView(content: .loading(url), isAlone: false, alternativeText: nil, fallbackText: nil, style: MarkdownStyle())
        XCTAssertEqual(inline.fittedSize(width: 400).width, 50)
    }

    /// Its own width at most, and 640 high.
    func testAPictureKeepsItsSizeUpToTheCap() {
        func fitted(_ size: CGSize, width: CGFloat) -> CGSize {
            let image = MarkdownLoadedImage(image: UIImage(), size: size, maxWidth: size.width)
            let view = MarkdownImageView(content: .loaded(image), isAlone: true, alternativeText: "A", fallbackText: nil, style: MarkdownStyle())
            return view.fittedSize(width: width)
        }
        XCTAssertEqual(fitted(CGSize(width: 200, height: 100), width: 700), CGSize(width: 200, height: 100))
        XCTAssertEqual(fitted(CGSize(width: 1000, height: 500), width: 700), CGSize(width: 700, height: 350))
        XCTAssertEqual(fitted(CGSize(width: 500, height: 2000), width: 700), CGSize(width: 500, height: 640))
    }

    /// A token's colour under `.system` is the highlighter's, in each mode.
    func testTokenColoursAreTheHighlightersOnSystem() {
        let light = MarkdownCodeColor(red: 0.6, green: 0.1, blue: 0.2, alpha: 1)
        let dark = MarkdownCodeColor(red: 0.2, green: 0.7, blue: 0.9, alpha: 1)
        let color = MarkdownCodeTokenColors.color(light: light, dark: dark)
        func rgb(_ style: UIUserInterfaceStyle) -> [CGFloat] {
            let resolved = color.resolvedColor(with: UITraitCollection { $0.userInterfaceStyle = style; $0.flooTheme = .system })
            var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
            resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b]
        }
        for (value, expected) in zip(rgb(.light), [0.6, 0.1, 0.2]) { XCTAssertEqual(value, expected, accuracy: 0.002) }
        for (value, expected) in zip(rgb(.dark), [0.2, 0.7, 0.9]) { XCTAssertEqual(value, expected, accuracy: 0.002) }
    }
}
