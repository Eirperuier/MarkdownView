//
//  MarkdownTree.swift
//  MarkdownView
//
//  A block handed over as its tree, built by the caller (a document model) instead of
//  written as markdown: rendered by the same selectable path, with nothing parsed and
//  nothing in its text read as syntax. What markdown has no node for is an inline
//  attributes node: a colour, a highlight, a pen mark (MarkdownInlineStyle), and inline
//  maths, `InlineAttributes(attributes: "math", Text(latex))`.
//

import Foundation
@preconcurrency import Markdown

public struct MarkdownTree: @unchecked Sendable, Hashable {
    public let document: Markdown.Document
    private let contentHash: Int

    public init(_ document: Markdown.Document) {
        self.document = document
        contentHash = document.stableContentHash
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

    static let mathAttribute = "math"

    /// The document with inline maths as the placeholders the visitor draws formulas
    /// at (their LaTeX kept in `math`, as markdown's preprocessing keeps it).
    func prepared(math: inout MarkdownRendererConfiguration.Math) -> Markdown.Document {
        var rewriter = InlineMathRewriter(math: math)
        let rewritten = rewriter.visit(document) as? Markdown.Document ?? document
        math = rewriter.math
        return rewritten
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
}
