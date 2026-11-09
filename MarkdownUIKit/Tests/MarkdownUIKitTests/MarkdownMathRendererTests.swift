//
//  MarkdownMathRendererTests.swift
//  MarkdownUIKitTests
//

import UIKit
import XCTest
@testable import MarkdownUIKit

final class MarkdownMathRendererTests: XCTestCase {
    private func piece(_ latex: String, _ kind: MarkdownMathPiece.Kind = .inlineEquation) -> MarkdownMathPiece {
        MarkdownMathRenderer.piece(latex: latex, kind: kind, xHeight: 8.5, foreground: "#112233", scale: 2)
    }

    func testDelimitersSayHowItsSet() {
        XCTAssertEqual(MarkdownMathRenderer.stripped("$$a$$", kind: .inlineEquation).isDisplay, true)
        XCTAssertEqual(MarkdownMathRenderer.stripped("\\[a\\]", kind: .inlineEquation).body, "a")
        XCTAssertEqual(MarkdownMathRenderer.stripped("\\(a\\)", kind: .displayEquation).isDisplay, false)
        XCTAssertEqual(MarkdownMathRenderer.stripped("$a$", kind: .displayEquation).body, "a")
        XCTAssertEqual(MarkdownMathRenderer.stripped("a", kind: .displayEquation).isDisplay, true)
    }

    /// CJK isn't in KaTeX's fonts: it comes from the system's, in text and in maths.
    func testCJKDraws() {
        for latex in [#"\text{速度} = \frac{\text{距离}}{\text{时间}}"#, #"v = \frac{距离}{时间}"#, #"\text{日本語} + \text{한국어}"#] {
            let piece = piece(latex, .displayEquation)
            XCTAssertNotNil(piece.image, latex)
            XCTAssertGreaterThan(piece.metrics?.imageSize.width ?? 0, 30, latex)
        }
    }

    /// No colours of its own: a template the view tints. `\color`: baked, the rest in the foreground.
    func testColorsOfItsOwnAreBaked() {
        let plain = piece(#"x^2"#)
        XCTAssertEqual(plain.color, .template)
        XCTAssertEqual(plain.image?.renderingMode, .alwaysTemplate)
        let colored = piece(#"\color{red}{x} + y"#)
        XCTAssertEqual(colored.color, .baked(foreground: "#112233"))
        XCTAssertEqual(colored.image?.renderingMode, .alwaysOriginal)
    }

    /// In a line, the image's bottom is below the baseline by the formula's depth; on its own, 0.
    func testDepthIsTheOffset() {
        XCTAssertEqual(piece("x").metrics?.baselineOffset, 0)
        XCTAssertLessThan(piece("y").metrics?.baselineOffset ?? 0, 0)
        XCTAssertEqual(piece("y", .displayEquation).metrics?.baselineOffset, 0)
    }

    func testWhatDoesntParseShowsItsSource() {
        let failed = piece(#"\frac{a"#)
        XCTAssertNil(failed.image)
        XCTAssertEqual(failed.originalText, #"\frac{a"#)
    }
}
