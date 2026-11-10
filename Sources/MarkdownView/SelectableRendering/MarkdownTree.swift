//
//  MarkdownTree.swift
//  MarkdownView
//

import Foundation
@preconcurrency import Markdown

extension MarkdownTree {
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
