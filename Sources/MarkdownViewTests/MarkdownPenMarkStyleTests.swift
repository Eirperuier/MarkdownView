//
//  MarkdownPenMarkStyleTests.swift
//  MarkdownView
//

import Foundation
import SwiftUI
import Testing
import Markdown
@testable import MarkdownView

/// The `:name[text]{attrs}` marks beyond circle and wavy — marker, box, underline,
/// strikethrough, text color — and `> [!note]` callouts.
struct MarkdownPenMarkStyleTests {
    init() {
        MarkdownHighlightSyntax.isEnabled = true
        MarkdownPenMarkSyntax.isEnabled = true
        MarkdownCalloutSyntax.isEnabled = true
    }

    @Test(arguments: [
        (":marker[重点]{color=pink} 后", "重点 后"),
        (":box[框]", "框"),
        (":u[线]{style=double color=blue}", "线"),
        (":s[旧价]", "旧价"),
        (":color[涨]{c=positive}", "涨"),
        // Unknown attributes are dropped with the block; the text still shows.
        (":marker[x]{glow=yes}", "x"),
        // An attribute block that never closes stays as text.
        (":box[x]{color=red", "x{color=red"),
    ])
    func everyMarkDropsItsSyntax(_ source: String, _ plain: String) {
        #expect(MarkdownPenMarkSyntax.strippedPlainText(source) == plain)
    }

    @Test func attributesParseLeniently() throws {
        let match = try #require(MarkdownPenMarkSyntax.matchOffsets(":u[a]{Style=\"Dash\", COLOR=#F00}").first)
        #expect(match.kind == .u)
        #expect(match.style == "dash")
        #expect(match.color == "#f00")
        let short = try #require(MarkdownPenMarkSyntax.matchOffsets(":color[a]{c=warning}").first)
        #expect(short.color == "warning")
    }

    @Test func markValuesRoundTrip() throws {
        let match = try #require(MarkdownPenMarkSyntax.matchOffsets(":u[词]{style=thick color=green}").first)
        let decoded = try #require(MarkdownPenMarkSyntax.decodeAttributeValue(
            MarkdownPenMarkSyntax.encodeAttributeValue(match)))
        #expect(decoded == MarkdownPenMarkSyntax.Mark(kind: .u, color: "green", style: "thick", seed: match.seed))
        // Values written before style existed still decode.
        #expect(MarkdownPenMarkSyntax.decodeAttributeValue("circle|blue|12")?.style == nil)
    }

    @Test func colorBecomesAForegroundRun() {
        let shown = MarkdownPenMarkSyntax.applied(to: AttributedString("a :color[b]{c=negative} c"))
        #expect(String(shown.characters) == "a b c")
        let colored = shown.runs.filter { $0.foregroundColor != nil }
        #expect(colored.count == 1)
        #expect(colored.first?.foregroundColor == .red)
        #expect(!shown.hasPenMark)
    }

    @Test func unknownColorsLeaveTheTextAlone() {
        let shown = MarkdownPenMarkSyntax.applied(to: AttributedString(":color[b]{c=sparkly}"))
        #expect(String(shown.characters) == "b")
        #expect(shown.runs.allSatisfy { $0.foregroundColor == nil })
    }

    @Test func onlyTheMarkerDrawsUnderTheText() {
        let under = MarkdownPenMarkSyntax.Kind.allCases.filter(\.isUnderlay)
        #expect(under == [.marker])
    }

    @Test(arguments: ["single", "thick", "double", "dot", "dash", "dashdot", "wavy", "nonsense"])
    func everyLineStyleDraws(_ style: String) {
        let mark = MarkdownPenMarkSyntax.Mark(kind: .u, color: nil, style: style, seed: 1)
        let rect = CGRect(x: 0, y: 0, width: 80, height: 20)
        let strokes = PenMarkGeometry.strokes(for: mark, in: rect, baseline: 16)
        #expect(strokes.count == (style == "double" ? 2 : 1))
        // Underlines sit below the baseline, inside the descent.
        #expect(strokes.allSatisfy { $0.path.boundingBoxOfPath.minY >= 16 })
    }

    @Test func strikethroughCrossesTheMiddleOfLowercase() throws {
        let mark = MarkdownPenMarkSyntax.Mark(kind: .s, color: nil, style: nil, seed: 1)
        let stroke = try #require(PenMarkGeometry.strokes(
            for: mark, in: CGRect(x: 0, y: 0, width: 80, height: 20), baseline: 16).first)
        let y = stroke.path.boundingBoxOfPath.midY
        #expect(y > 8 && y < 14)
    }

    @Test(arguments: [MarkdownPenMarkSyntax.Kind.circle, .wavy, .box, .marker])
    func handDrawnMarksStayCloseToTheirText(_ kind: MarkdownPenMarkSyntax.Kind) {
        let rect = CGRect(x: 20, y: 20, width: 60, height: 20)
        let mark = MarkdownPenMarkSyntax.Mark(kind: kind, color: nil, style: nil, seed: 4242)
        for stroke in PenMarkGeometry.strokes(for: mark, in: rect, baseline: 36) {
            let reach = rect.insetBy(dx: -PenMarkGeometry.overhang, dy: -PenMarkGeometry.overhang)
            #expect(reach.contains(stroke.path.boundingBoxOfPath))
        }
    }

    @Test func semanticColorsResolve() {
        #expect(MarkdownPenInk.color("positive") == .green)
        #expect(MarkdownPenInk.color("warning") == .orange)
        #expect(MarkdownPenInk.color("#336699") != nil)
        #expect(MarkdownPenInk.color("#zz") == nil)
        #expect(MarkdownPenInk.textColor("accent") == .accentColor)
    }

    // MARK: - Callouts

    @Test(arguments: [
        ("[!note]", MarkdownCallout(kind: .note, customTitle: nil)),
        ("[!WARNING] 别在主线程做", MarkdownCallout(kind: .warning, customTitle: "别在主线程做")),
        ("[!tip]- 折叠", MarkdownCallout(kind: .tip, customTitle: "折叠")),
        ("[!danger]", MarkdownCallout(kind: .caution, customTitle: nil)),
    ])
    func calloutsParse(_ line: String, _ expected: MarkdownCallout) {
        #expect(MarkdownCallout.parse(firstLine: line) == expected)
    }

    @Test(arguments: ["[!sparkles]", "[note]", "[!]", "text [!note]"])
    func otherQuotesStayQuotes(_ line: String) {
        #expect(MarkdownCallout.parse(firstLine: line) == nil)
    }

    @Test func calloutMarkerIsNotRevealed() {
        let blocks = MarkdownContent("> [!note] 标题\n> 正文 :marker[重点]").topLevelBlocks()
        #expect(blocks.first?.plainText == "正文 重点")
    }

    @Test func calloutBodyComesFromTheRemainingLines() throws {
        let split = try #require(MarkdownCallout.split(innerMarkdown: "[!tip]\n第一行\n\n第二段"))
        #expect(split.callout.kind == .tip)
        #expect(split.body == "第一行\n\n第二段")
    }
}
