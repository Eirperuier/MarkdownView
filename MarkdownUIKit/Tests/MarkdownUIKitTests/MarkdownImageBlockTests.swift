//
//  MarkdownImageBlockTests.swift
//  MarkdownUIKitTests
//

import FlooUIKit
@testable import MarkdownCore
import UIKit
import XCTest
@testable import MarkdownUIKit

@MainActor
final class MarkdownImageBlockTests: XCTestCase {
    private func imageView(in view: UIView) -> MarkdownImageView? {
        if let image = view as? MarkdownImageView { return image }
        return view.subviews.lazy.compactMap { self.imageView(in: $0) }.first
    }

    /// A paragraph that's one picture has no text to lay out, and lands where TextKit put it:
    /// a paragraph's 5 pt above and below, the panel the whole width at 3:4 while it loads.
    func testALonePictureLaysOutWithoutText() {
        for width in [300.0, 601.0] as [CGFloat] {
            var splitter = MarkdownBlockSplitter()
            let block = splitter.split("![a](https://none.invalid/x.png)")[0]
            let view = MarkdownBlockView()
            view.configure(block, style: MarkdownStyle())
            XCTAssertTrue(view.textViews.isEmpty)
            let panel = (width * 0.75).rounded()
            let height = view.height(forWidth: width)
            XCTAssertEqual(height, panel + 10)
            view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            view.layoutIfNeeded()
            XCTAssertEqual(imageView(in: view)?.frame, CGRect(x: 0, y: 5, width: width, height: panel))
            XCTAssertTrue(view.isWaitingForImages)
            view.prepareForReuse()
        }
    }

    /// With text beside it, or with no URL to fetch, it's text as before.
    func testAPictureWithTextIsText() {
        for source in ["Look: ![a](https://none.invalid/x.png)", "![a](relative.png)"] {
            var splitter = MarkdownBlockSplitter()
            let view = MarkdownBlockView()
            var style = MarkdownStyle()
            style.drawsTextUntilTouched = false
            view.configure(splitter.split(source)[0], style: style)
            XCTAssertFalse(view.textViews.isEmpty, source)
            view.prepareForReuse()
        }
    }
}
