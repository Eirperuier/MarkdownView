//
//  MarkdownTree.swift
//  MarkdownView
//
//  A block handed over as its tree, built by the caller (a document model) instead of
//  written as markdown: rendered by the same selectable path, with nothing parsed and
//  nothing in its text read as syntax. What markdown has no node for is an inline
//  attributes node: a colour, a highlight, a pen mark (MarkdownInlineStyle), and inline
//  maths, `InlineAttributes(attributes: "math", Text(latex))`; display maths is a `math`
//  directive, `BlockDirective(name: "math", children: [Paragraph(Text(latex))])`.
//  Text blocks render through `MarkdownSelectableText(tree:)`, the rest (code, maths,
//  tables) through `MarkdownBlockView(tree:)`.
//

import Foundation
@preconcurrency import Markdown

public struct MarkdownTree: @unchecked Sendable, Hashable {
    public let document: Markdown.Document
    private let contentHash: Int
    /// Whether any maths is in it: without, `prepared` has nothing to rewrite (a rewriter
    /// builds every node again, a whole table's on each render).
    package let hasMath: Bool

    public init(_ document: Markdown.Document) {
        self.document = document
        contentHash = document.stableContentHash
        var finder = MathFinder()
        finder.visit(document)
        hasMath = finder.found
    }

    public static func == (lhs: MarkdownTree, rhs: MarkdownTree) -> Bool {
        lhs.contentHash == rhs.contentHash
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(contentHash)
    }

    /// The node inline maths is: its LaTeX as the text inside.
    public static func inlineMath(_ latex: String) -> InlineAttributes {
        InlineAttributes(attributes: mathAttribute, Text(latex))
    }

    /// The node display maths is: its LaTeX as the text inside.
    public static func displayMath(_ latex: String) -> BlockDirective {
        BlockDirective(name: mathAttribute, children: [Paragraph(Text(latex))])
    }

    public static let mathAttribute = "math"
}

private struct MathFinder: MarkupWalker {
    var found = false

    mutating func visitInlineAttributes(_ attributes: InlineAttributes) {
        if attributes.attributes == MarkdownTree.mathAttribute { found = true } else { descendInto(attributes) }
    }

    mutating func visitBlockDirective(_ directive: BlockDirective) {
        if directive.name == MarkdownTree.mathAttribute, directive.argumentText.isEmpty { found = true } else { descendInto(directive) }
    }

    mutating func defaultVisit(_ markup: any Markup) {
        guard !found else { return }
        descendInto(markup)
    }
}
