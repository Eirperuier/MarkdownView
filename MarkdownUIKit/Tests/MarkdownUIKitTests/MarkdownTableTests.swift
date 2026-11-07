//
//  MarkdownTableTests.swift
//  MarkdownUIKitTests
//

import MarkdownCore
@testable import MarkdownUIKit
import UIKit
import XCTest

@MainActor
final class MarkdownTableTests: XCTestCase {
    private let source = "| Name | Value |\n| --- | :-: |\n| One | **Two** |\n| Three | [Four](https://example.com) |"

    private func style() -> MarkdownStyle {
        var style = MarkdownStyle()
        style.contentSizeCategory = .large
        return style
    }

    private func block(_ markdown: String) -> MarkdownStreamBlock {
        var splitter = MarkdownBlockSplitter()
        return splitter.split(markdown)[0]
    }

    func testEveryKindIsDrawn() {
        for markdown in [source, "$$\nx^2\n$$", "> | a | b |\n> | - | - |\n> | 1 | 2 |"] {
            XCTAssertTrue(MarkdownBlockView.draws(block(markdown)), markdown)
            let view = MarkdownBlockView()
            view.configure(block(markdown), style: style())
            XCTAssertGreaterThan(view.height(forWidth: 400), 0, markdown)
        }
    }

    func testHeightIsTheSameInAParent() {
        let view = MarkdownTableView()
        view.configure(source: source, style: style())
        let off = view.height(forWidth: 400)
        XCTAssertGreaterThan(off, 0)
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        parent.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: off)
        view.layoutIfNeeded()
        XCTAssertEqual(view.height(forWidth: 400), off)
    }

    func testAnEmptyCellHasARow() {
        let view = MarkdownTableView()
        view.configure(source: "| A | B |\n| - | - |\n|  |  |", style: style())
        XCTAssertGreaterThan(view.height(forWidth: 400), 0)
    }

    func testNoTextViewUntilTouched() {
        let view = MarkdownTableView()
        view.configure(source: source, style: style())
        _ = view.height(forWidth: 400)
        XCTAssertTrue(view.textViews.isEmpty)
    }

    func testAFormulaTakesATextViewForItsCellOnly() {
        let view = MarkdownTableView()
        view.configure(source: "| A | B |\n| - | - |\n| $x^2$ | plain |", style: style())
        _ = view.height(forWidth: 400)
        XCTAssertEqual(view.textViews.count, 1)
    }

    func testAGrownTableKeepsTheRowsItHad() {
        let content = MarkdownTableContent()
        let head = "| A | B |\n| - | - |\n| one | two |\n| three | fo"
        XCTAssertTrue(content.update(source: head, style: style(), inlineMath: nil, displayMath: nil))
        let first = content.rows[1][0]
        XCTAssertEqual(content.rows.count, 3)
        XCTAssertEqual(content.rows[2][1].string.string, "fo")
        XCTAssertTrue(content.update(source: head + "ur |\n| five | six |", style: style(), inlineMath: nil, displayMath: nil))
        XCTAssertTrue(content.rows[1][0] === first, "a row before the last was built again")
        XCTAssertEqual(content.rows.count, 4)
        XCTAssertEqual(content.rows[2][1].string.string, "four")
        XCTAssertEqual(content.firstChangedRow, 2)
        // The same as a table parsed at once, down to where its cells are for a reveal.
        let whole = MarkdownTableContent()
        XCTAssertTrue(whole.update(source: head + "ur |\n| five | six |", style: style(), inlineMath: nil, displayMath: nil))
        XCTAssertEqual(content.spans, whole.spans)
        XCTAssertEqual(content.flat.map(\.string.string), whole.flat.map(\.string.string))
    }

    func testARevealHidesWhatItHasntReached() {
        let manager = StreamingRevealManager()
        manager.revealedCount = 0
        let view = MarkdownTableView()
        view.configure(source: source, style: style(), reveal: MarkdownReveal(manager: manager))
        _ = view.height(forWidth: 400)
        XCTAssertEqual(view.textViews.count, 1, "the frontier's cell fades in in a text view")
        manager.revealedCount = Int.max
        view.setReveal(nil)
        XCTAssertTrue(view.textViews.isEmpty)
    }

    func testColumnsShareOnThePixelGrid() {
        // As a stack does: 752 by 7 at 2x comes to whole pixels, and adds up.
        let widths = MarkdownTableColumns.sharing(752, minimums: Array(repeating: 8, count: 7), maximums: Array(repeating: .greatestFiniteMagnitude, count: 7), pixelScale: 2)
        XCTAssertEqual(widths.reduce(0, +), 752)
        XCTAssertEqual(widths.first, 107.5)
        // Centred text takes what it needs, first.
        let mixed = MarkdownTableColumns.sharing(300, minimums: [8, 8, 8], maximums: [.greatestFiniteMagnitude, 50, .greatestFiniteMagnitude], pixelScale: 2)
        XCTAssertEqual(mixed, [125, 50, 125])
    }

    func testParentheticals() {
        let text = "Price (USD (net)) and （kg）"
        XCTAssertEqual(MarkdownTableParentheticals.ranges(in: text).map { String(text[$0]) }, ["(USD (net))", "（kg）"])
    }
}
