//
//  MarkdownPreparedHeightTests.swift
//  MarkdownUIKitTests
//
//  A block made ahead, off the main thread, comes to the height its view does: a list placing
//  rows by the one, and showing the other, would see the row jump.
//

import MarkdownCore
@testable import MarkdownUIKit
import UIKit
import XCTest

@MainActor
final class MarkdownPreparedHeightTests: XCTestCase {
    private let width: CGFloat = 360

    private func style(_ prepared: MarkdownPreparedTexts) -> MarkdownStyle {
        var style = MarkdownStyle()
        style.contentSizeCategory = .large
        style.drawsTextUntilTouched = true
        style.preparedTexts = prepared
        return style
    }

    private func blocks(_ markdown: String) -> [MarkdownStreamBlock] {
        var splitter = MarkdownBlockSplitter()
        return splitter.split(markdown)
    }

    /// The prepared height, once it's made; nil if nothing's made for this kind.
    private func preparedHeight(_ block: MarkdownStreamBlock, style: MarkdownStyle, prepared: MarkdownPreparedTexts) -> CGFloat? {
        prepared.request(block, style: style, width: width, traits: UITraitCollection.current)
        let deadline = Date().addingTimeInterval(5)
        while prepared.isPending(block, style: style, width: width), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return prepared.height(of: block, style: style, width: width)
    }

    private func check(_ markdown: String, file: StaticString = #filePath, line: UInt = #line) {
        for block in blocks(markdown) {
            let prepared = MarkdownPreparedTexts()
            let style = style(prepared)
            guard let ahead = preparedHeight(block, style: style, prepared: prepared) else {
                XCTFail("nothing made ahead for \(block.descriptor.kind)", file: file, line: line)
                continue
            }
            let view = MarkdownBlockView()
            view.configure(block, style: style)
            XCTAssertEqual(ahead, view.height(forWidth: width), accuracy: 0.01, "\(block.descriptor.kind): \(block.source.prefix(40))", file: file, line: line)
        }
    }

    func testText() { check("A paragraph with **bold** and `code` long enough to wrap onto a second line here.") }
    func testPenMarks() { check("A :circle[circled] word, :wavy[a wave] and :u[single] :u[thick]{style=thick}.") }
    func testQuote() { check("> A plain quote with **bold** that wraps onto a second line of its own.") }
    func testCallouts() {
        check("> [!caution]\n> A caution.")
        check("> [!tip] A longer custom title goes here and wraps\n> Body with **bold**.")
    }
    func testFootnotes() { check("[^1]: The first definition.\n[^named]: The second one, with **bold**.") }
    func testALoadedImage() {
        let url = URL(string: "https://example.com/prepared-height.png")!
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100)).image { _ in }
        MarkdownImageLoader.shared.finish(url, MarkdownLoadedImage(image: image, size: image.size, maxWidth: 200))
        check("Text before ![a picture](\(url)) and after it, long enough to wrap onto a second line.")
        check("![alone](\(url))")
        check("- an item\n\n  ![in a list](\(url))")
    }
    func testTableWithAFormula() { check("| Name | Value |\n| --- | --- |\n| [link](https://example.com) | *italic* |\n| first<br>second | $x^2$ |") }
}
