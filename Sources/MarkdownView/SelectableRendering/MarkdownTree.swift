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
    private let hasMath: Bool

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

    static let mathAttribute = "math"

    /// The document with maths as what markdown's preprocessing makes of it: inline
    /// maths as the placeholders the visitor draws formulas at, display maths as
    /// `@math(uuid:)` directives, their LaTeX kept in `math`.
    func prepared(math: inout MarkdownRendererConfiguration.Math) -> Markdown.Document {
        guard hasMath else { return document }
        var rewriter = InlineMathRewriter(math: math)
        let rewritten = rewriter.visit(document) as? Markdown.Document ?? document
        math = rewriter.math
        return rewritten
    }
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

private struct InlineMathRewriter: MarkupRewriter {
    var math: MarkdownRendererConfiguration.Math

    mutating func visitInlineAttributes(_ attributes: InlineAttributes) -> (any Markup)? {
        guard attributes.attributes == MarkdownTree.mathAttribute else { return defaultVisit(attributes) }
        let latex = attributes.plainText
        // Stored delimited, as markdown's preprocessing stores what it found.
        let id = math.appendInlineMath(latex.contains("$") ? "\\(\(latex)\\)" : "$\(latex)$")
        return Text(MarkdownRendererConfiguration.Math.inlinePlaceholderPrefix + id + MarkdownRendererConfiguration.Math.inlinePlaceholderSuffix)
    }

    mutating func visitBlockDirective(_ directive: BlockDirective) -> (any Markup)? {
        guard directive.name == MarkdownTree.mathAttribute, directive.argumentText.isEmpty else { return defaultVisit(directive) }
        let latex = directive.children.compactMap { ($0 as? Paragraph)?.plainText }.joined(separator: "\n")
        // Stored delimited, as the markdown `$$` block it would be.
        let id = math.appendDisplayMath(latex.hasPrefix("\\begin{") ? latex : "$$\n\(latex)\n$$")
        return BlockDirective(name: MarkdownTree.mathAttribute, argumentText: "uuid:\(id.uuidString)")
    }
}
